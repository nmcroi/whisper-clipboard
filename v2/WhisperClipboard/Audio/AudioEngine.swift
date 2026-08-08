import AppKit
import AVFoundation
import Combine
import Core
import Foundation
import WhisperShared

/// Errors surfaced by ``AudioEngine``.
enum AudioEngineError: LocalizedError {
    case microphonePermissionDenied
    case engineStartFailed(String)
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Geen toegang tot de microfoon. Sta toegang toe in Systeeminstellingen › Privacy."
        case .engineStartFailed(let detail):
            return "Microfoon kon niet starten: \(detail)"
        case .converterUnavailable:
            return "Audioformaat kon niet worden omgezet."
        }
    }
}

/// Publishes a smoothed microphone level (0…1) for the HUD meter.
///
/// Updated on the main actor from each captured buffer. Uses exponential
/// smoothing so the bars glide rather than flicker.
@MainActor
final class AudioLevelMeter: ObservableObject {
    /// Smoothed level in the range 0…1.
    @Published private(set) var level: Double = 0

    private let smoothing = 0.3

    func update(rawLevel: Double) {
        let clamped = min(max(rawLevel, 0), 1)
        level = level * (1 - smoothing) + clamped * smoothing
    }

    func reset() {
        level = 0
    }
}

/// Wraps `AVAudioEngine`, capturing the microphone and yielding buffers as an
/// `AsyncStream`, optionally converted to a consumer-requested format.
///
/// Confined to the main actor: `AVAudioEngine` and its tap callbacks are not
/// `Sendable`, and the sole consumer (the transcription engine feed) is driven
/// from the `@MainActor` ``DictationController``. The tap callback hops back to
/// the main actor to convert and yield, keeping everything actor-clean.
@MainActor
final class AudioEngine {
    let levelMeter = AudioLevelMeter()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var continuation: AsyncStream<AudioBufferBox>.Continuation?
    private(set) var isRunning = false
    /// True tijdens een gebruikerspauze: de tap is eraf (er wordt niets meer
    /// gevangen), maar stream/continuation leven door zodat hervatten naadloos
    /// in dezelfde opname verdergaat.
    private(set) var isPaused = false

    /// De actieve tap-handler + het formaat waarop de tap is geïnstalleerd,
    /// bewaard zodat ``resume()`` dezelfde tap opnieuw kan installeren en kan
    /// zien of het formaat intussen veranderd is.
    private var tapHandler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var nativeFormat: AVAudioFormat?

    /// Pauze-bewuste opnameklok: telt alleen echte opnametijd.
    private var stopwatch = RecordingStopwatch()

    /// Elapsed capture time in seconds (exclusief pauzes), or 0 when not recording.
    var elapsed: Double {
        stopwatch.elapsed(at: Self.nowUptime())
    }

    /// De wérkelijke toestand van de onderliggende `AVAudioEngine`. ``isRunning``
    /// is de sessievlag (die blijft `true` tijdens een pauze); deze zegt of er
    /// ook echt hardware draait.
    var isEngineRunning: Bool { engine.isRunning }

    // MARK: - Onderbrekingsmelding (bevinding 2026-08-03)

    /// Waarom de capture onderbroken raakte. Puur beschrijvend: de engine voert
    /// hier geen beleid uit, de controller beslist wat er moet gebeuren.
    enum InterruptionReason: Sendable, Equatable {
        /// `AVAudioEngineConfigurationChange`: de audiohardware is
        /// geherconfigureerd (ander invoerapparaat, andere samplerate, HAL-reset).
        /// De engine kan zichzelf hierbij stoppen en de tap kwijtraken.
        case configurationChanged
        /// De Mac gaat slapen; CoreAudio levert vanaf nu niets meer.
        case systemWillSleep
        /// De Mac is wakker en de engine bleek niet meer te lopen.
        case systemDidWake
        /// De `AVAudioEngine` is uit zichzelf gestopt terwijl de sessievlag nog
        /// "opname loopt" zei — de vlag liep uit de pas met `engine.isRunning`.
        case engineStopped
        /// Er kwamen `seconds` lang geen buffers meer binnen terwijl de opname
        /// wél hoorde te lopen.
        case noBuffers(seconds: Double)
    }

    /// Wordt (op de main actor) éénmaal per incident aangeroepen zodra de capture
    /// onderbroken raakt: apparaatwissel, slaap/waak, of een tap die stilvalt.
    /// Spiegelt `IOSAudioEngine.onInterruption`. De engine stopt zichzelf hier
    /// NIET en rondt niets af — de aanroeper beslist. Na een geslaagde
    /// ``resume()`` of een nieuwe start staat de melder weer scherp.
    ///
    /// bevinding 2026-08-03: hiervoor keek niets naar
    /// `AVAudioEngineConfigurationChange` of naar slaap/waak, en ``isRunning``
    /// werd nooit verzoend met `engine.isRunning`. Viel de tap midden in een
    /// opname stil, dan bevroor de meter op zijn laatste waarde, liep de
    /// wandklok gewoon door en merkte niemand iets — vandaar lange opnames die
    /// stil werden afgekapt.
    var onInterruption: ((InterruptionReason) -> Void)?

    private var configChangeObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?

    /// Uptime-seconde waarop de laatste buffer binnenkwam.
    private var lastBufferAt: Double?
    /// Latch: maximaal één melding per incident.
    private var interruptionReported = false
    private var watchdogTask: Task<Void, Never>?

    /// Watchdogritme en -tolerantie. Een tap van 4096 frames komt op 48 kHz elke
    /// ~85 ms langs, dus 5 s stilte is onmiskenbaar kapot, terwijl het ruim
    /// genoeg is om een kortstondig geblokkeerde main thread niet vals te
    /// beschuldigen.
    private static let watchdogTick: Double = 1
    private static let watchdogSilenceLimit: Double = 5

    // MARK: - Permission

    /// Requests microphone permission, throwing ``AudioEngineError`` when denied.
    static func ensureMicrophonePermission() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw AudioEngineError.microphonePermissionDenied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { throw AudioEngineError.microphonePermissionDenied }
        @unknown default:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { throw AudioEngineError.microphonePermissionDenied }
        }
    }

    // MARK: - Lifecycle

    /// Haalt de audiohardware alvast op en laat `AVAudioEngine` zijn buffers
    /// klaarzetten, zodat de eerste opname daar niet meer op hoeft te wachten.
    ///
    /// De eerste aanraking van `inputNode` initialiseert het invoerapparaat en
    /// `prepare()` alloceert de renderketen; samen was dat het merendeel van de
    /// anderhalve seconde tussen de sneltoets en een lopende opname
    /// (bevinding 2026-08-04). Er wordt hier bewust géén tap geïnstalleerd en
    /// niets gestart: er wordt dus niets opgenomen en geen andere audio
    /// onderbroken.
    func warmUp() {
        guard !isRunning else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        if ms > 100 {
            NSLog("AudioEngine: klaarzetten kostte %.0f ms (nu vooraf, niet meer bij de eerste opname)", ms)
        }
    }

    /// Starts capture, converting each buffer to `format`, returning a stream of
    /// converted buffers. Requests mic permission first.
    func start(convertingTo format: AVAudioFormat) async throws -> AsyncStream<AudioBufferBox> {
        try await Self.ensureMicrophonePermission()
        return try startCapture(convertingTo: format)
    }

    /// Starts capture yielding the input node's native format unchanged.
    func start() async throws -> AsyncStream<AudioBufferBox> {
        try await Self.ensureMicrophonePermission()
        return try startCapture(convertingTo: nil)
    }

    private func startCapture(convertingTo format: AVAudioFormat?) throws -> AsyncStream<AudioBufferBox> {
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        outputFormat = format
        if let format, format != nativeFormat {
            guard let converter = AVAudioConverter(from: nativeFormat, to: format) else {
                throw AudioEngineError.converterUnavailable
            }
            self.converter = converter
        } else {
            converter = nil
        }

        let (stream, continuation) = AsyncStream<AudioBufferBox>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation

        // CoreAudio invokes this block on its own realtime thread, never the
        // main thread. Typing it explicitly as `@Sendable` (rather than a bare
        // closure literal inside this `@MainActor` method) stops the compiler
        // from inferring main-actor isolation for it — without this, Swift 6
        // inserts a runtime isolation check that traps (SIGTRAP) the instant
        // CoreAudio calls the tap off the main thread.
        let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, _ in
            // Copy out of the tap's reused buffer, then box it (AVAudioPCMBuffer
            // isn't Sendable) before hopping actors.
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
            throw AudioEngineError.engineStartFailed(error.localizedDescription)
        }

        isRunning = true
        isPaused = false
        self.tapHandler = tapHandler
        self.nativeFormat = nativeFormat
        stopwatch.start(at: Self.nowUptime())
        levelMeter.reset()
        // Bewaking van de lopende capture (bevinding 2026-08-03).
        interruptionReported = false
        lastBufferAt = Self.nowUptime()
        installCaptureObservers()
        startWatchdog()
        return stream
    }

    // MARK: - Pauze

    /// Pauzeert de opname: de tap gaat er ONMIDDELLIJK af, dus niets van ná dit
    /// moment kan de opname in. Buffers die vóór de druk al gevangen waren mogen
    /// nog gewoon doorstromen (dat is pre-pauze-audio — die hoort erbij). Stream
    /// en continuation blijven leven zodat ``resume()`` naadloos verdergaat in
    /// dezelfde opname; de engine-samples blijven staan en het vervolg plakt er
    /// automatisch achteraan (één opname, één transcript).
    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        engine.inputNode.removeTap(onBus: 0)
        engine.pause()
        stopwatch.pause(at: Self.nowUptime())
        levelMeter.reset()
    }

    /// Hervat na ``pause()`` met dezelfde tap op dezelfde stream. Geeft `false`
    /// terug wanneer de audio-engine niet opnieuw wil starten (bijv. de input is
    /// intussen verdwenen) — de aanroeper rondt de opname dan af.
    ///
    /// bevinding 2026-08-03: hier werd het formaat hergebruikt dat bij
    /// ``startCapture(convertingTo:)`` was vastgelegd. Wisselt het
    /// invoerapparaat tijdens de pauze (koptelefoon inpluggen, ander apparaat
    /// kiezen), dan past dat oude formaat niet meer bij het huidige formaat van
    /// de node en gooit `installTap` een `NSInternalInconsistencyException` — een
    /// ObjC-exceptie die Swift niet kan vangen, en die buiten de `do/catch` om
    /// het proces hard neerhaalt. We lezen het formaat nu opnieuw uit de node en
    /// bouwen zo nodig de converter opnieuw, zodat een gewijzigd formaat via het
    /// bestaande foutpad (`false`) wordt afgehandeld in plaats van met een crash.
    func resume() -> Bool {
        guard isRunning, isPaused, let tapHandler, let previousFormat = nativeFormat else { return false }

        let inputNode = engine.inputNode
        let currentFormat = inputNode.outputFormat(forBus: 0)
        // Een verdwenen invoerapparaat levert een leeg formaat op; daar kan geen
        // tap op en installTap zou er alsnog op exploderen.
        guard currentFormat.channelCount > 0, currentFormat.sampleRate > 0 else { return false }

        if currentFormat != previousFormat {
            guard let outputFormat else {
                // Ongeconverteerd pad: we zouden midden in één opname ineens een
                // ander formaat gaan leveren. Netjes falen is beter.
                return false
            }
            if currentFormat == outputFormat {
                converter = nil
            } else {
                guard let rebuilt = AVAudioConverter(from: currentFormat, to: outputFormat) else {
                    return false
                }
                converter = rebuilt
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: currentFormat, block: tapHandler)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            return false
        }
        nativeFormat = currentFormat
        isPaused = false
        stopwatch.resume(at: Self.nowUptime())
        // Nieuw incidentvenster: de watchdog mag weer melden.
        interruptionReported = false
        lastBufferAt = Self.nowUptime()
        return true
    }

    /// Stops capture and finishes the stream (consumer sees the end).
    func stop() {
        teardown(finishStream: true)
    }

    /// Cancels capture and finishes the stream without yielding pending buffers.
    func cancel() {
        teardown(finishStream: true)
    }

    private func teardown(finishStream: Bool) {
        guard isRunning else { return }
        isRunning = false
        isPaused = false
        stopWatchdog()
        removeCaptureObservers()
        lastBufferAt = nil
        interruptionReported = false
        // removeTap is onschadelijk wanneer de tap er al af is (stop-tijdens-pauze).
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapHandler = nil
        nativeFormat = nil
        stopwatch.stopAndReset()
        levelMeter.reset()
        if finishStream {
            continuation?.finish()
        }
        continuation = nil
        converter = nil
    }

    // MARK: - Buffer handling

    private func handle(buffer: AVAudioPCMBuffer) {
        guard isRunning, let continuation else { return }

        // Levensteken voor de watchdog (bevinding 2026-08-03).
        lastBufferAt = Self.nowUptime()
        levelMeter.update(rawLevel: Self.rms(of: buffer))

        if let converter, let outputFormat {
            guard let converted = Self.convert(buffer, using: converter, to: outputFormat) else { return }
            continuation.yield(AudioBufferBox(converted))
        } else {
            continuation.yield(AudioBufferBox(buffer))
        }
    }

    // MARK: - Bewaking van een lopende capture (bevinding 2026-08-03)

    /// Luistert mee met de audiohardware en met slaap/waak, zolang er een opname
    /// loopt. Spiegelt de sessie-observers van `IOSAudioEngine`, alleen dan met de
    /// macOS-signalen: `AVAudioEngineConfigurationChange` en `NSWorkspace`.
    private func installCaptureObservers() {
        removeCaptureObservers()

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleConfigurationChange() }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        willSleepObserver = workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleWillSleep() }
        }
        didWakeObserver = workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleDidWake() }
        }
    }

    private func removeCaptureObservers() {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        let workspace = NSWorkspace.shared.notificationCenter
        if let willSleepObserver {
            workspace.removeObserver(willSleepObserver)
            self.willSleepObserver = nil
        }
        if let didWakeObserver {
            workspace.removeObserver(didWakeObserver)
            self.didWakeObserver = nil
        }
    }

    /// De audiohardware herconfigureerde. AVAudioEngine kan zichzelf hierbij
    /// stoppen en de tap kwijtraken; het formaat van de invoernode kan bovendien
    /// veranderd zijn, waardoor de converter niet meer klopt. We melden het en
    /// laten de aanroeper beslissen — die kan ``isEngineRunning`` raadplegen.
    private func handleConfigurationChange() {
        guard isRunning, !isPaused else { return }
        report(.configurationChanged)
    }

    private func handleWillSleep() {
        guard isRunning, !isPaused else { return }
        report(.systemWillSleep)
    }

    /// Na het wakker worden alleen melden wanneer de engine er echt mee gestopt
    /// is; draait hij nog, dan is er niets aan de hand.
    private func handleDidWake() {
        guard isRunning, !isPaused, !engine.isRunning else { return }
        report(.systemDidWake)
    }

    /// Meldt hooguit één keer per incident, zodat een controller niet bij elke
    /// watchdogtik opnieuw wordt aangetikt.
    private func report(_ reason: InterruptionReason) {
        guard !interruptionReported else { return }
        interruptionReported = true
        onInterruption?(reason)
    }

    /// Kijkt periodiek of er nog écht wordt opgenomen: verzoent de sessievlag met
    /// `engine.isRunning` en slaat alarm wanneer er te lang geen buffers meer
    /// binnenkwamen. Draait als main-actor-taak (niet als `Timer`) zodat hij niet
    /// stilvalt in andere runloop-modi, bijv. tijdens menu-tracking.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.watchdogTick * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.checkCaptureAlive()
            }
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func checkCaptureAlive() {
        guard isRunning, !isPaused else { return }

        // Verzoening: de sessievlag zei "opname loopt", maar de engine is weg.
        guard engine.isRunning else {
            report(.engineStopped)
            return
        }

        let now = Self.nowUptime()
        let silence = now - (lastBufferAt ?? now)
        if silence >= Self.watchdogSilenceLimit {
            report(.noBuffers(seconds: silence))
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

        // Map RMS (~ -50 dB … 0 dB) onto 0…1 for the meter.
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = (db + 50) / 50
        return Double(min(max(normalized, 0), 1))
    }
}

private extension AVAudioPCMBuffer {
    /// Deep-copies the buffer so it survives past the tap callback's reuse.
    ///
    /// bevinding 2026-08-03: deze functie liep over `0..<format.channelCount` en
    /// kopieerde per kanaal `frameLength` aaneengesloten elementen. Dat klopt
    /// alleen voor een DEINTERLEAVED formaat. `floatChannelData` levert één
    /// pointer per buffer in de `AudioBufferList`; bij een interleaved formaat is
    /// dat er precies één, met alle kanalen door elkaar (`stride ==
    /// channelCount`). De lus indexeerde dan meer pointers dan er buffers zijn en
    /// kopieerde bovendien het verkeerde aantal elementen — kanaal 1 schreef over
    /// kanaal 0 heen en de laatste kanalen lazen langs het einde van het blok.
    /// Draait op de CoreAudio-realtimethread voor élke buffer van élke opname.
    ///
    /// Nu leiden we het aantal buffers af uit de werkelijke `AudioBufferList` van
    /// bron én kopie, en het aantal elementen per buffer uit
    /// `format.isInterleaved`. Blijft allocatievrij en realtime-veilig: geen
    /// logging, geen locks, geen Foundation-aanroepen.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength

        let frames = Int(frameLength)
        let channels = Int(format.channelCount)
        guard channels > 0 else { return nil }

        // Interleaved: één buffer met alle kanalen erin. Deinterleaved: één
        // buffer per kanaal. Nooit verder indexeren dan bron én kopie allebei
        // werkelijk hebben.
        let sourceBuffers = Int(audioBufferList.pointee.mNumberBuffers)
        let copyBuffers = Int(copy.audioBufferList.pointee.mNumberBuffers)
        let bufferCount = min(sourceBuffers, copyBuffers, format.isInterleaved ? 1 : channels)
        guard bufferCount > 0 else { return nil }

        // Elementen per buffer: interleaved staan er frames * channels in dat ene
        // blok, deinterleaved precies frames per kanaalbuffer.
        let elements = format.isInterleaved ? frames * channels : frames
        guard elements > 0 else { return copy }   // lege buffer: niets te kopiëren

        if let src = floatChannelData, let dst = copy.floatChannelData {
            for buffer in 0..<bufferCount {
                dst[buffer].update(from: src[buffer], count: elements)
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for buffer in 0..<bufferCount {
                dst[buffer].update(from: src[buffer], count: elements)
            }
        } else if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for buffer in 0..<bufferCount {
                dst[buffer].update(from: src[buffer], count: elements)
            }
        } else {
            return nil
        }
        return copy
    }
}
