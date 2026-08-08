import AVFoundation
import Core
import Foundation

/// A volatile or finalized partial surfaced while streaming.
public struct StreamingPartial: Sendable, Equatable {
    /// The full finalized text accumulated so far.
    public var finalizedText: String
    /// The current volatile tail (may be empty), shown dimmed in the HUD.
    public var volatileText: String

    public init(finalizedText: String, volatileText: String) {
        self.finalizedText = finalizedText
        self.volatileText = volatileText
    }

    /// Convenience: everything the user should currently see.
    public var displayText: String {
        volatileText.isEmpty ? finalizedText : finalizedText + volatileText
    }
}

/// Transfers an `AVAudioPCMBuffer` across an actor boundary. Safe because each
/// buffer handed to ``TranscriptionEngine/feed(_:)`` is a fresh deep copy from
/// the platform audio engine with a single owner — it is never mutated after
/// capture.
public struct AudioBufferBox: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

/// The finished transcript for a run.
public struct TranscriptionResult: Sendable, Equatable {
    public var text: String
    public var segments: [Core.TranscriptSegment]

    /// De werkelijk opgenomen audioduur in seconden, gemeten aan het aantal
    /// weggeschreven samples. Dit is iets anders dan de klok op het scherm: die
    /// loopt door zolang de opname "aan" staat, ook als de microfoon geen
    /// buffers meer levert. Een gat tussen die twee betekent verloren audio
    /// (bevinding 2026-08-03). `0` wanneer onbekend.
    public var audioDuration: Double

    /// Niet-fatale storing tijdens de opname: een deel van de audio is verloren
    /// gegaan (bijvoorbeeld een mislukte schrijfactie naar het tijdelijke
    /// bestand), maar wat wél op schijf stond is gewoon getranscribeerd. De
    /// aanroeper meldt dit náást het resultaat in plaats van het bruikbare deel
    /// weg te gooien (bevinding 2026-08-03). `nil` wanneer de opname vlekkeloos
    /// verliep.
    public var partialFailure: String?

    /// Het tijdelijke opnamebestand dat bewust is blijven staan omdat de
    /// aanroeper een kopie wil bewaren. De aanroeper is er daarna eigenaar van:
    /// verplaatsen als het bewaren lukt, anders zelf opruimen. `nil` wanneer de
    /// opname is weggegooid, wat de standaard blijft.
    public var preservedAudioURL: URL?

    public init(
        text: String,
        segments: [Core.TranscriptSegment],
        audioDuration: Double = 0,
        partialFailure: String? = nil,
        preservedAudioURL: URL? = nil
    ) {
        self.text = text
        self.segments = segments
        self.audioDuration = audioDuration
        self.partialFailure = partialFailure
        self.preservedAudioURL = preservedAudioURL
    }

    public static let empty = TranscriptionResult(text: "", segments: [])
}

/// Availability of the on-device speech model for a locale.
public enum ModelAssetStatus: Equatable, Sendable {
    case unknown
    case installed
    case needsDownload(progress: Double)
    case downloading(progress: Double)
    case unsupported

    public var isReady: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// Abstraction over a streaming speech-to-text backend so alternate engines
/// (Apple Speech now, Parakeet later) can be swapped without touching the
/// orchestration layer.
public protocol TranscriptionEngine: AnyObject, Sendable {
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
