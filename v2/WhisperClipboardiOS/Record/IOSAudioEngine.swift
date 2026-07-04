import AVFoundation
import Combine
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

    /// Called (on the main actor) when the OS interrupts capture, so the record
    /// controller can finalize what was captured so far.
    var onInterruption: (() -> Void)?

    private var startUptime: Double?

    /// Elapsed capture time in seconds, or 0 when not recording.
    var elapsed: Double {
        guard let startUptime else { return 0 }
        return Self.nowUptime() - startUptime
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
                let type = AVAudioSession.InterruptionType(rawValue: raw),
                type == .began
            else { return }
            // Hop to the main actor (the observer queue is .main but the closure
            // is nonisolated) and let the controller finalize the capture.
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
        startUptime = Self.nowUptime()
        levelMeter.reset()
        return stream
    }

    /// Stops capture, finishes the stream and deactivates the session.
    func stop() { teardown() }

    private func teardown() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        startUptime = nil
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
