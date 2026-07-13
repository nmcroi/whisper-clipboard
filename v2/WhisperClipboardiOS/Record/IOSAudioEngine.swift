import AVFoundation
import Combine
import Core
import Foundation
import WhisperShared

/// Errors surfaced by ``IOSAudioEngine``.
enum IOSAudioEngineError: LocalizedError {
    case microphonePermissionDenied
    case sessionConfigFailed(String)
    case engineStartFailed(String)
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Geen toegang tot de microfoon. Sta toegang toe in Instellingen › Privacy › Microfoon."
        case .sessionConfigFailed(let detail):
            return "Audiosessie kon niet worden geconfigureerd: \(detail)"
        case .engineStartFailed(let detail):
            return "Microfoon kon niet starten: \(detail)"
        case .converterUnavailable:
            return "Audioformaat kon niet worden omgezet."
        }
    }
}

/// Publishes a smoothed microphone level (0…1) for the record meter.
@MainActor
final class AudioLevelMeter: ObservableObject {
    @Published private(set) var level: Double = 0

    private let smoothing = 0.3

    func update(rawLevel: Double) {
        let clamped = min(max(rawLevel, 0), 1)
        level = level * (1 - smoothing) + clamped * smoothing
    }

    func reset() { level = 0 }
}

/// iOS microphone capture: activates an `AVAudioSession` in `.record` /
/// `.measurement` mode, taps `AVAudioEngine`'s input node, converts each buffer
/// to 16 kHz mono Float32 and yields `AudioBufferBox`es as an `AsyncStream` —
/// exactly what ``ParakeetEngine`` consumes via `feed(_:)`.
///
/// Confined to the main actor like the mac `AudioEngine`: `AVAudioEngine` and its
/// tap callbacks aren't `Sendable`; the tap hops back to the main actor to
/// convert and yield. Adds the two iOS-only concerns the mac engine doesn't
/// need: audio-session activation/deactivation and interruption handling (an
/// incoming call, Siri, etc. stops the tap — we finish the stream so the record
/// controller can gracefully stop).
@MainActor
final class IOSAudioEngine {
    let levelMeter = AudioLevelMeter()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var continuation: AsyncStream<AudioBufferBox>.Continuation?
    private var isRunning = false
    private var interruptionObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    /// Bewaard zodat we de tap na een onderbreking opnieuw kunnen installeren.
    private var tapHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var nativeFormat: AVAudioFormat?

    /// Called (on the main actor) when the OS interrupts capture and we could NOT
    /// keep it alive — the record controller finalizes what was captured so far.
    /// Used as the fallback (media-services reset, `.ended` zonder `shouldResume`,
    /// of een mislukte hervatting).
    var onInterruption: (() -> Void)?

    /// Called (on the main actor) when capture is PAUSED by an interruption but
    /// the session/stream stays alive. The controller reflects this in the UI.
    var onPause: (() -> Void)?

    /// Called (on the main actor) when a paused capture is successfully RESUMED.
    var onResume: (() -> Void)?

    /// Waarom de capture gepauzeerd is. Een gebruikerspauze (de pauzeknop) en
    /// een OS-onderbreking (telefoontje, Siri) delen hetzelfde mechanisme —
    /// tap eraf, engine gepauzeerd, sessie en stream blijven leven — maar
    /// verschillen in wie mag hervatten: een gebruikerspauze wordt NOOIT
    /// automatisch hervat door het einde van een onderbreking.
    enum PauseReason { case user, interruption }

    private(set) var pauseReason: PauseReason?

    /// True zolang de capture gepauzeerd is (om welke reden dan ook).
    var isPaused: Bool { pauseReason != nil }

    /// Pauze-bewuste opnameklok: telt alleen echte opnametijd (fixt en passant
    /// dat de teller vroeger doorliep tijdens een onderbreking).
    private var stopwatch = RecordingStopwatch()

    /// Elapsed capture time in seconds (exclusief pauzes), or 0 when not recording.
    var elapsed: Double {
        stopwatch.elapsed(at: Self.nowUptime())
    }

    // MARK: - Permission

    /// Requests microphone permission, throwing when denied.
    static func ensureMicrophonePermission() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw IOSAudioEngineError.microphonePermissionDenied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { throw IOSAudioEngineError.microphonePermissionDenied }
        @unknown default:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { throw IOSAudioEngineError.microphonePermissionDenied }
        }
    }

    // MARK: - Lifecycle

    /// Requests permission, activates the session and starts capture converting
    /// every buffer to `format`, returning the stream of converted buffers.
    func start(convertingTo format: AVAudioFormat) async throws -> AsyncStream<AudioBufferBox> {
        try await Self.ensureMicrophonePermission()
        try configureSession()
        return try startCapture(convertingTo: format)
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.measurement` gives the flattest, least-processed mic path — best
            // for downstream ASR (no AGC/EQ colouring the samples).
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true, options: [])
        } catch {
            throw IOSAudioEngineError.sessionConfigFailed(error.localizedDescription)
        }
        installInterruptionObserver()
    }

    private func installInterruptionObserver() {
        removeInterruptionObserver()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }

            switch type {
            case .began:
                Task { @MainActor [weak self] in self?.handleInterruptionBegan() }
            case .ended:
                // shouldResume: mag de audio weer opstarten?
                let options: AVAudioSession.InterruptionOptions
                if let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                    options = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                } else {
                    options = []
                }
                let shouldResume = options.contains(.shouldResume)
                Task { @MainActor [weak self] in self?.handleInterruptionEnded(shouldResume: shouldResume) }
            @unknown default:
                break
            }
        }

        // Defensief: bij een media-services-reset is de hele audiostack weg —
        // hervatten kan niet, dus we vallen terug op stop-and-transcribe.
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.onInterruption?()
            }
        }
    }

    private func removeInterruptionObserver() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let mediaResetObserver {
            NotificationCenter.default.removeObserver(mediaResetObserver)
            self.mediaResetObserver = nil
        }
    }

    // MARK: - Pause / resume (gebruiker + onderbreking)

    /// Gebruikerspauze (de pauzeknop): capture stopt ONMIDDELLIJK — de tap gaat
    /// eraf, dus niets van ná de druk kan de opname in. Sessie en stream blijven
    /// leven; hervatten gaat naadloos verder in dezelfde opname.
    func pauseByUser() {
        performPause(reason: .user)
    }

    /// Hervatten na een gebruikerspauze. Geeft `false` bij falen — de aanroeper
    /// rondt de opname dan af met alles tot het pauzemoment.
    func resumeByUser() -> Bool {
        guard isRunning, pauseReason == .user else { return false }
        guard resumeCapture() else { return false }
        pauseReason = nil
        stopwatch.resume(at: Self.nowUptime())
        return true
    }

    /// Gedeeld pauzepad: stop de `AVAudioEngine` maar houd de audiosessie én de
    /// streaming-transcriptiesessie levend (niet deactiveren, niet finaliseren).
    private func performPause(reason: PauseReason) {
        guard isRunning, !isPaused else { return }
        pauseReason = reason
        engine.inputNode.removeTap(onBus: 0)
        engine.pause()
        stopwatch.pause(at: Self.nowUptime())
        levelMeter.reset()
        if reason == .interruption {
            onPause?()
        }
    }

    /// Onderbreking begonnen: pauzeer via het gedeelde pad. Was de gebruiker al
    /// zelf aan het pauzeren, dan blijft dat zo (de tap is toch al weg) en houdt
    /// de gebruikerspauze voorrang — het einde van de onderbreking mag hem niet
    /// zelf hervatten.
    private func handleInterruptionBegan() {
        performPause(reason: .interruption)
    }

    /// Onderbreking klaar: hervat de capture als dat mag én lukt; anders val terug
    /// op stop-and-transcribe. Een GEBRUIKERSpauze wordt hier bewust nooit
    /// hervat — alleen de gebruiker heft die op.
    private func handleInterruptionEnded(shouldResume: Bool) {
        guard isRunning, pauseReason == .interruption else { return }
        guard shouldResume, resumeCapture() else {
            // Kan niet hervatten → finaliseer wat we hebben.
            onInterruption?()
            return
        }
        pauseReason = nil
        stopwatch.resume(at: Self.nowUptime())
        onResume?()
    }

    /// Herinstalleert de tap en herstart de engine op dezelfde stream. Geeft
    /// `false` bij falen (dan valt de aanroeper terug op stoppen).
    private func resumeCapture() -> Bool {
        guard let tapHandler, let nativeFormat else { return false }
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat, block: tapHandler)
            engine.prepare()
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    private func startCapture(convertingTo format: AVAudioFormat) throws -> AsyncStream<AudioBufferBox> {
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        outputFormat = format
        if format != nativeFormat {
            guard let converter = AVAudioConverter(from: nativeFormat, to: format) else {
                throw IOSAudioEngineError.converterUnavailable
            }
            self.converter = converter
        } else {
            converter = nil
        }

        let (stream, continuation) = AsyncStream<AudioBufferBox>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation

        // CoreAudio invokes this on its own realtime thread. Typed `@Sendable` so
        // the compiler doesn't infer main-actor isolation (which would trap when
        // CoreAudio calls it off-thread).
        let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, _ in
            guard let copied = buffer.deepCopy() else { return }
            let boxed = AudioBufferBox(copied)
            Task { @MainActor [weak self] in
                self?.handle(buffer: boxed.buffer)
            }
        }
        // Bewaar tap + formaat zodat we na een onderbreking kunnen hervatten.
        self.tapHandler = tapHandler
        self.nativeFormat = nativeFormat
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat, block: tapHandler)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.continuation = nil
            throw IOSAudioEngineError.engineStartFailed(error.localizedDescription)
        }

        isRunning = true
        pauseReason = nil
        stopwatch.start(at: Self.nowUptime())
        levelMeter.reset()
        return stream
    }

    /// Stops capture, finishes the stream and deactivates the session.
    func stop() { teardown() }

    private func teardown() {
        guard isRunning else { return }
        isRunning = false
        pauseReason = nil
        // removeTap is onschadelijk wanneer de tap er al af is (stop-tijdens-pauze).
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stopwatch.stopAndReset()
        tapHandler = nil
        nativeFormat = nil
        levelMeter.reset()
        continuation?.finish()
        continuation = nil
        converter = nil
        removeInterruptionObserver()
        // Release the session so other apps regain audio.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Buffer handling

    private func handle(buffer: AVAudioPCMBuffer) {
        guard isRunning, let continuation else { return }
        levelMeter.update(rawLevel: Self.rms(of: buffer))

        if let converter, let outputFormat {
            guard let converted = Self.convert(buffer, using: converter, to: outputFormat) else { return }
            continuation.yield(AudioBufferBox(converted))
        } else {
            continuation.yield(AudioBufferBox(buffer))
        }
    }

    // MARK: - Helpers

    private static func nowUptime() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
            if consumed {
                statusPointer.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPointer.pointee = .haveData
            return input
        }

        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            return nil
        }
        return output
    }

    /// Root-mean-square amplitude of the first channel, mapped roughly to 0…1.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        let samples = channelData[0]
        var sum: Float = 0
        for index in 0..<frameLength {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = (db + 50) / 50
        return Double(min(max(normalized, 0), 1))
    }
}

private extension AVAudioPCMBuffer {
    /// Deep-copies the buffer so it survives past the tap callback's reuse.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength

        let channels = Int(format.channelCount)
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: Int(frameLength))
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: Int(frameLength))
            }
        } else if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for channel in 0..<channels {
                dst[channel].update(from: src[channel], count: Int(frameLength))
            }
        } else {
            return nil
        }
        return copy
    }
}
