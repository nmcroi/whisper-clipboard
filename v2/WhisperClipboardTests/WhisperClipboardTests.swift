import XCTest
@testable import WhisperClipboard

final class WhisperClipboardTests: XCTestCase {
    /// Smoke test: the app state exposes Dutch status text and sensible defaults.
    func testAppStateStatusText() {
        XCTAssertEqual(AppState.ready.statusText, "Klaar voor opname")
        XCTAssertEqual(AppState.recording.statusText, "Opname loopt")
        XCTAssertEqual(AppState.transcribing.statusText, "Transcriptie maken…")
        XCTAssertTrue(AppState.recording.isRecording)
        XCTAssertFalse(AppState.ready.isRecording)
        XCTAssertEqual(AppState.error("boom").statusText, "Fout: boom")
    }
}
