import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Errors surfaced by ``SystemAudioTap``, in Dutch.
enum SystemAudioTapError: LocalizedError {
    /// The TCC "System Audio Recording Only" permission was denied. There is no
    /// public status API for this permission, so we infer denial when the tap or
    /// aggregate device cannot be created (the first attempt triggers the prompt).
    case permissionDenied
    case tapCreationFailed(OSStatus)
    case noAudioDevice
    case aggregateDeviceFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case formatUnavailable
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Geen toegang tot systeemaudio. Sta 'Whisper Clipboard' toe in Systeeminstellingen › Privacy en beveiliging › Schermopname en systeemaudio."
        case .tapCreationFailed(let status):
            return "De systeemaudio-tap kon niet worden gemaakt (foutcode \(status))."
        case .noAudioDevice:
            return "Geen audio-uitvoerapparaat gevonden om systeemaudio van op te nemen."
        case .aggregateDeviceFailed(let status):
            return "Het opname-apparaat voor systeemaudio kon niet worden aangemaakt (foutcode \(status))."
        case .ioProcFailed(let status):
            return "De systeemaudio kon niet worden gestart (foutcode \(status))."
        case .formatUnavailable:
            return "Het formaat van de systeemaudio kon niet worden bepaald."
        case .converterUnavailable:
            return "Systeemaudio kon niet naar het juiste formaat worden omgezet."
        }
    }
}

/// Wraps a Core Audio **process tap** (macOS 14.4+) that captures *all* system
/// audio — everything the Mac plays — as a global mono mixdown, and yields it as
/// 16 kHz mono Float32 buffers ready for the Parakeet model.
///
/// ## How it works
/// A `CATapDescription(monoGlobalTapButExcludeProcesses: [])` produces a system-
/// wide mono mixdown (excluding no processes = everything). We create the tap,
/// wrap it in a private aggregate device whose main sub-device is the current
/// default output device, install an IO proc block on that aggregate to receive
/// buffers, and convert each buffer from the tap's native format to 16 kHz mono
/// Float32 via `AVAudioConverter`.
///
/// ## Permission
/// System-audio capture is gated by the TCC "System Audio Recording Only"
/// category. There is **no** public status API: the first `start()` triggers the
/// system prompt, and if the user denies (or has denied before) the tap/aggregate
/// creation fails. We map those failures to ``SystemAudioTapError/permissionDenied``
/// so the UI can show a Dutch explainer.
///
/// ## Threading (SIGTRAP pitfall)
/// Core Audio invokes the IO proc block on its own realtime thread — never the
/// main thread. As in ``AudioEngine``, the block is typed explicitly as a bare
/// C-block-compatible closure with **no** actor isolation so Swift 6 doesn't
/// insert a main-actor isolation check that would trap the instant Core Audio
/// calls it off-thread. All the block does is copy samples out and hop to the
/// (non-isolated) conversion + yield path.
final class SystemAudioTap: @unchecked Sendable {

    // MARK: - Core Audio object handles

    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// The tap's native stream format (read from the tap once created).
    private var tapFormat: AVAudioFormat?
    /// Converts the tap format → 16 kHz mono Float32.
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<AudioBufferBox>.Continuation?

    /// Serializes start/stop against the realtime IO block's teardown check.
    private let lock = NSLock()
    private var isRunning = false

    /// The target format the Parakeet model consumes.
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    // MARK: - Lifecycle

    /// Starts the system-audio tap, returning a stream of 16 kHz mono Float32
    /// buffers. Throws a typed ``SystemAudioTapError`` on failure; a permission
    /// denial surfaces as ``SystemAudioTapError/permissionDenied``.
    func start() throws -> AsyncStream<AudioBufferBox> {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else {
            // Already running: hand back a finished stream so callers don't hang.
            let (stream, cont) = AsyncStream<AudioBufferBox>.makeStream()
            cont.finish()
            return stream
        }

        // 1. Create a system-wide mono mixdown tap (exclude nothing = everything).
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted          // capture without silencing playback
        description.isPrivate = true

        var newTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            // Tap creation is the first TCC-gated call; a failure here is almost
            // always a denied/undetermined-then-denied permission.
            throw SystemAudioTapError.permissionDenied
        }
        tapID = newTapID

        // 2. Read the tap's native stream format.
        guard let format = Self.readTapFormat(tapID) else {
            teardownLocked()
            throw SystemAudioTapError.formatUnavailable
        }
        tapFormat = format

        // 3. Build a private aggregate device with the tap, backed by the system
        //    default output device as the main sub-device.
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            teardownLocked()
            throw SystemAudioTapError.noAudioDevice
        }

        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WhisperClipboard-Captions",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]

        var newAggregate: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &newAggregate
        )
        guard aggStatus == noErr, newAggregate != kAudioObjectUnknown else {
            teardownLocked()
            throw SystemAudioTapError.aggregateDeviceFailed(aggStatus)
        }
        aggregateDeviceID = newAggregate

        // 4. Build the converter tap-format → 16 kHz mono Float32.
        guard let converter = AVAudioConverter(from: format, to: Self.outputFormat) else {
            teardownLocked()
            throw SystemAudioTapError.converterUnavailable
        }
        self.converter = converter

        // 5. Install the realtime IO proc. The block runs on Core Audio's realtime
        //    thread; keep it isolation-free (see class doc) and non-blocking.
        let (stream, cont) = AsyncStream<AudioBufferBox>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont

        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, _, _, _ in
            self?.handleIO(inInputData)
        }

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            aggregateDeviceID,
            nil,           // nil dispatch queue → Core Audio's own realtime thread
            ioBlock
        )
        guard procStatus == noErr, let procID = newProcID else {
            continuation = nil
            teardownLocked()
            throw SystemAudioTapError.ioProcFailed(procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            continuation = nil
            teardownLocked()
            throw SystemAudioTapError.ioProcFailed(startStatus)
        }

        isRunning = true
        return stream
    }

    /// Stops capture and tears down the IO proc, aggregate device and tap in the
    /// correct order, finishing the stream.
    ///
    /// Order matters for the realtime-thread race: `teardownLocked()` runs
    /// `AudioDeviceStop` **first**, so no further `handleIO` invocations can begin
    /// once it returns; only then do we finish/nil the continuation. `handleIO`
    /// itself snapshots `converter`/`tapFormat`/`continuation` under the same
    /// `lock`, so a torn read across this teardown is impossible.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        isRunning = false
        teardownLocked()          // AudioDeviceStop runs before we touch the
        continuation?.finish()    // continuation, so no in-flight handleIO can be
        continuation = nil        // reading it concurrently (handleIO also locks).
    }

    /// Tears down all Core Audio objects (idempotent). Must be called with `lock`
    /// held. Order: stop IO → destroy IO proc → destroy aggregate → destroy tap.
    private func teardownLocked() {
        if let procID = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        ioProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        converter = nil
        tapFormat = nil
    }

    // MARK: - Realtime IO handling

    /// Called on Core Audio's realtime thread. Wraps the incoming buffer list in
    /// an `AVAudioPCMBuffer` over the tap format, converts to 16 kHz mono Float32,
    /// and yields a deep-copied box. Non-blocking; drops on any anomaly.
    private func handleIO(_ inInputData: UnsafePointer<AudioBufferList>) {
        // Snapshot converter/format/continuation under `lock` so the read can't
        // tear against stop()'s teardownLocked() niling them out. The critical
        // section is three pointer reads only — the heavy conversion + yield work
        // happens OUTSIDE the lock, so realtime-thread priority-inversion risk is
        // negligible. `stop()` runs AudioDeviceStop before touching these, so once
        // stop() has returned no further handleIO call can begin; while stop() is
        // mid-flight the lock serializes us against it.
        lock.lock()
        guard isRunning,
              let converter = self.converter,
              let tapFormat = self.tapFormat,
              let continuation = self.continuation
        else {
            lock.unlock()
            return
        }
        lock.unlock()

        let bufferList = inInputData.pointee
        guard bufferList.mNumberBuffers > 0 else { return }

        // Wrap the input buffer list as an AVAudioPCMBuffer over the tap format.
        guard let inputBuffer = Self.pcmBuffer(from: inInputData, format: tapFormat) else { return }

        guard let converted = Self.convert(inputBuffer, using: converter, to: Self.outputFormat) else {
            return
        }
        // yield-after-finish is a documented no-op on AsyncStream; combined with
        // the locked snapshot above the continuation reference itself is never
        // read torn against stop()'s reassignment.
        continuation.yield(AudioBufferBox(converted))
    }

    // MARK: - Core Audio helpers

    /// Reads the tap's stream format via `kAudioTapPropertyFormat`.
    private static func readTapFormat(_ tapID: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// UID string of the current system default output device.
    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let uidStatus = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        guard uidStatus == noErr else { return nil }
        return uid as String
    }

    /// Builds an `AVAudioPCMBuffer` referencing the samples in `inInputData` for
    /// the given `format`. Deep-copies so the buffer survives past the callback.
    private static func pcmBuffer(
        from inInputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard let first = abl.first else { return nil }
        let bytesPerFrame = max(Int(format.streamDescription.pointee.mBytesPerFrame), 1)
        let frameCount = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard frameCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        // Copy each channel's bytes from the incoming ABL into the fresh buffer.
        guard let dstABL = buffer.mutableAudioBufferList as UnsafeMutablePointer? else { return nil }
        let dst = UnsafeMutableAudioBufferListPointer(dstABL)
        for i in 0..<min(abl.count, dst.count) {
            if let srcData = abl[i].mData, let dstData = dst[i].mData {
                let copyBytes = Int(min(abl[i].mDataByteSize, dst[i].mDataByteSize))
                memcpy(dstData, srcData, copyBytes)
            }
        }
        return buffer
    }

    /// Converts one buffer to `format` via `converter` (mirrors AudioEngine).
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
}
