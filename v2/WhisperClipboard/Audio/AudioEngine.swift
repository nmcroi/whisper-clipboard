import AVFoundation
import Combine
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
    private var isRunning = false

    /// Monotonic seconds since the current capture started (nil when stopped).
    private var startUptime: Double?

    /// Elapsed capture time in seconds, or 0 when not recording.
    var elapsed: Double {
        guard let startUptime else { return 0 }
        return Self.nowUptime() - startUptime
    }

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
        startUptime = Self.nowUptime()
        levelMeter.reset()
        return stream
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        startUptime = nil
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

        // Map RMS (~ -50 dB … 0 dB) onto 0…1 for the meter.
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
