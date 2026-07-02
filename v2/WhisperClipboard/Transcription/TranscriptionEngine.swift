import AVFoundation
import Core
import Foundation

/// A volatile or finalized partial surfaced while streaming.
struct StreamingPartial: Sendable, Equatable {
    /// The full finalized text accumulated so far.
    var finalizedText: String
    /// The current volatile tail (may be empty), shown dimmed in the HUD.
    var volatileText: String

    /// Convenience: everything the user should currently see.
    var displayText: String {
        volatileText.isEmpty ? finalizedText : finalizedText + volatileText
    }
}

/// Transfers an `AVAudioPCMBuffer` across an actor boundary. Safe because each
/// buffer handed to ``TranscriptionEngine/feed(_:)`` is a fresh deep copy from
/// ``AudioEngine`` with a single owner — it is never mutated after capture.
struct AudioBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// The finished transcript for a run.
struct TranscriptionResult: Sendable, Equatable {
    var text: String
    var segments: [Core.TranscriptSegment]

    static let empty = TranscriptionResult(text: "", segments: [])
}

/// Availability of the on-device speech model for a locale.
enum ModelAssetStatus: Equatable, Sendable {
    case unknown
    case installed
    case needsDownload(progress: Double)
    case downloading(progress: Double)
    case unsupported

    var isReady: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// Abstraction over a streaming speech-to-text backend so alternate engines
/// (Apple Speech now, Parakeet later) can be swapped without touching the
/// orchestration layer.
protocol TranscriptionEngine: AnyObject, Sendable {
    /// Asset check / download + model pre-warm. Idempotent.
    func prepare() async throws

    /// Current model asset status for the configured locale.
    func assetStatus(for locale: Locale) async -> ModelAssetStatus

    /// Drives the asset download, reporting progress via `assetStatus`.
    func downloadAssets(for locale: Locale) async throws

    /// The audio format the engine wants buffers converted to.
    func bestAudioFormat() async -> AVAudioFormat?

    /// Begins a streaming session for `locale`.
    func startStreaming(locale: Locale) async throws

    /// Feeds one captured buffer into the running session.
    func feed(_ buffer: AudioBufferBox) async

    /// Ends the session, returning the accumulated final transcript.
    func finalize() async throws -> TranscriptionResult

    /// Cancels an in-flight session without producing a result.
    func cancel() async

    /// Live partials for the current session.
    var partials: AsyncStream<StreamingPartial> { get }

    /// Transcribes a media file (M3). Stubbed for M1.
    func transcribeFile(at url: URL, locale: Locale) async throws -> TranscriptionResult
}
