import AVFoundation
import Core
import Foundation

/// Locates and (optionally) trims the saved audio file associated with a
/// transcript.
///
/// ## Where audio lives
/// When `AppSettings.saveRecordings` is enabled, a recording is expected under
/// `~/Library/Application Support/Whisper Clipboard v2/Recordings/<id>.<ext>`,
/// keyed by the transcript's id. Most microphone dictations have **no** saved
/// audio (the setting defaults off), and this type is deliberately defensive:
/// ``audioURL(for:)`` returns `nil` when nothing is on disk, and every trim
/// operation is a no-op (never a crash) when the source file is absent.
enum TranscriptAudioStore {

    /// Candidate audio container extensions a saved recording might use.
    static let candidateExtensions = ["wav", "m4a", "caf", "mp3", "aac", "aiff", "mp4", "mov"]

    /// The recordings directory (created lazily by whoever writes recordings).
    static func recordingsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return base
            .appendingPathComponent("Whisper Clipboard v2", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// The on-disk audio file for a transcript id, or `nil` when none exists.
    /// Checks each candidate extension; returns the first that exists.
    static func audioURL(forTranscriptId id: String) -> URL? {
        guard let dir = try? recordingsDirectory() else { return nil }
        for ext in candidateExtensions {
            let url = dir.appendingPathComponent("\(id).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Convenience over an entry.
    static func audioURL(for entry: TranscriptEntry) -> URL? {
        audioURL(forTranscriptId: entry.id)
    }

    /// Whether a saved audio file exists for this entry (drives whether the UI
    /// offers "trim audio too").
    static func hasAudio(for entry: TranscriptEntry) -> Bool {
        audioURL(for: entry) != nil
    }

    // MARK: - Trimming

    /// Errors surfaced by ``trimAudio(for:keeping:)``.
    enum AudioTrimError: LocalizedError {
        case noAudio
        case exportFailed(String)
        case unsupported

        var errorDescription: String? {
            switch self {
            case .noAudio: return "Er is geen opgeslagen audio voor deze transcriptie."
            case .exportFailed(let detail): return "Audio bijsnijden mislukte: \(detail)"
            case .unsupported: return "Dit audioformaat kan niet worden bijgesneden."
            }
        }
    }

    /// Trims the entry's saved audio down to `keptRanges` (in seconds), splicing
    /// the kept spans together in order and replacing the original file in place.
    ///
    /// Defensive: when no audio exists this **throws `.noAudio`** rather than
    /// doing anything destructive — callers that only want best-effort trimming
    /// should check ``hasAudio(for:)`` first and simply skip the call.
    ///
    /// - Parameters:
    ///   - entry: the transcript whose audio to trim.
    ///   - keptRanges: the time spans (seconds) to keep, in playback order.
    static func trimAudio(for entry: TranscriptEntry, keeping keptRanges: [ClosedRange<Double>]) async throws {
        guard let sourceURL = audioURL(for: entry) else { throw AudioTrimError.noAudio }
        guard !keptRanges.isEmpty else { throw AudioTrimError.noAudio }

        let asset = AVURLAsset(url: sourceURL)
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioTrimError.unsupported
        }

        let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let sourceTrack = sourceTracks.first else { throw AudioTrimError.unsupported }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))

        var cursor = CMTime.zero
        let timescale: CMTimeScale = 44_100
        for range in keptRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let startSec = max(0, range.lowerBound)
            let endSec = min(duration, range.upperBound)
            guard endSec > startSec else { continue }
            let start = CMTime(seconds: startSec, preferredTimescale: timescale)
            let len = CMTime(seconds: endSec - startSec, preferredTimescale: timescale)
            let cmRange = CMTimeRange(start: start, duration: len)
            try compTrack.insertTimeRange(cmRange, of: sourceTrack, at: cursor)
            cursor = cursor + len
        }

        // Export the spliced composition to a temp m4a, then atomically replace.
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioTrimError.exportFailed("Kon de export niet starten.")
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc_trim_\(UUID().uuidString).m4a")
        export.outputURL = tempURL
        export.outputFileType = .m4a

        await export.export()
        if export.status == .failed {
            try? FileManager.default.removeItem(at: tempURL)
            throw AudioTrimError.exportFailed(export.error?.localizedDescription ?? "onbekende fout")
        }

        // Replace the original recording with the trimmed .m4a. If the original
        // had a different extension, we swap to .m4a and remove the old file.
        let finalURL = sourceURL.deletingPathExtension().appendingPathExtension("m4a")
        _ = try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
        if finalURL != sourceURL {
            try? FileManager.default.removeItem(at: sourceURL)
        }
    }
}
