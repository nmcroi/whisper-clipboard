import XCTest
@testable import WhisperClipboard

/// Finding #7: `trimAudio` replaced the original recording with a delete-then-move
/// when the source was already `.m4a` (finalURL == sourceURL), so a move failure
/// left the recording lost. The fix swaps in `FileManager.replaceItemAt`, which
/// only removes the original once the replacement is safely in place.
///
/// The full `trimAudio` path needs a real AVFoundation export against a file in
/// the fixed on-disk recordings directory, which isn't cleanly injectable here, so
/// these tests pin the exact file-replacement semantics the fix now relies on: an
/// atomic replace never destroys the destination before the new item lands.
final class TranscriptAudioStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// `replaceItemAt` swaps the destination for a freshly-written temp file — the
    /// same-path (already-.m4a) case that previously used delete-then-move.
    func testAtomicReplaceSwapsInNewContentAtSamePath() throws {
        let fm = FileManager.default
        let final = dir.appendingPathComponent("rec.m4a")
        let temp = dir.appendingPathComponent("trim.m4a")
        try Data("ORIGINAL".utf8).write(to: final)
        try Data("TRIMMED".utf8).write(to: temp)

        XCTAssertTrue(fm.fileExists(atPath: final.path))
        _ = try fm.replaceItemAt(final, withItemAt: temp)

        // The destination now holds the trimmed bytes and the temp is consumed.
        XCTAssertEqual(try Data(contentsOf: final), Data("TRIMMED".utf8))
        XCTAssertFalse(fm.fileExists(atPath: temp.path))
    }

    /// The load-bearing safety property: if the replacement source is invalid, the
    /// original is NOT destroyed. The old delete-then-move deleted the original
    /// first, so a move failure lost it; an atomic replace leaves it intact.
    func testFailedReplaceLeavesOriginalIntact() throws {
        let fm = FileManager.default
        let final = dir.appendingPathComponent("rec.m4a")
        try Data("ORIGINAL".utf8).write(to: final)
        let missingTemp = dir.appendingPathComponent("does-not-exist.m4a")

        XCTAssertThrowsError(try fm.replaceItemAt(final, withItemAt: missingTemp))
        // Crucially, the original recording still exists with its content.
        XCTAssertTrue(fm.fileExists(atPath: final.path))
        XCTAssertEqual(try Data(contentsOf: final), Data("ORIGINAL".utf8))
    }
}
