import XCTest
@testable import WhisperClipboard

/// Unit tests for the hand-rolled SSE parser and HTTP/URL error mapping in
/// ``ClaudeClient``. These are pure functions, so no network is touched.
final class ClaudeClientTests: XCTestCase {

    // MARK: - SSE line parsing

    func testTextDeltaLine() {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hallo"}}"#
        XCTAssertEqual(ClaudeClient.parseSSELine(line), .text("Hallo"))
    }

    func testMessageStopLine() {
        XCTAssertEqual(ClaudeClient.parseSSELine(#"data: {"type":"message_stop"}"#), .stop)
    }

    func testEventHeaderLineIsIgnored() {
        XCTAssertEqual(ClaudeClient.parseSSELine("event: content_block_delta"), .ignore)
    }

    func testBlankAndEmptyDataLinesIgnored() {
        XCTAssertEqual(ClaudeClient.parseSSELine(""), .ignore)
        XCTAssertEqual(ClaudeClient.parseSSELine("data:"), .ignore)
        XCTAssertEqual(ClaudeClient.parseSSELine("data: "), .ignore)
    }

    func testMessageStartAndPingIgnored() {
        XCTAssertEqual(ClaudeClient.parseSSELine(#"data: {"type":"message_start","message":{}}"#), .ignore)
        XCTAssertEqual(ClaudeClient.parseSSELine(#"data: {"type":"ping"}"#), .ignore)
    }

    func testMessageDeltaIgnored() {
        let line = #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#
        XCTAssertEqual(ClaudeClient.parseSSELine(line), .ignore)
    }

    func testErrorEventCarriesMessage() {
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertEqual(ClaudeClient.parseSSELine(line), .error("Overloaded"))
    }

    func testNonTextDeltaIgnored() {
        // e.g. an input_json_delta from a tool call — not text.
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#
        XCTAssertEqual(ClaudeClient.parseSSELine(line), .ignore)
    }

    func testMalformedJSONIgnored() {
        XCTAssertEqual(ClaudeClient.parseSSELine("data: not-json"), .ignore)
    }

    /// Feeds a full canned event stream and verifies the accumulated text and
    /// the stop signal (mirrors how `run(...)` consumes the stream).
    func testFullCannedStream() {
        let lines = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1"}}"#,
            "",
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hallo "}}"#,
            "",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"wereld"}}"#,
            "",
            "event: content_block_stop",
            #"data: {"type":"content_block_stop","index":0}"#,
            "",
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            "",
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
        ]

        var text = ""
        var stopped = false
        for line in lines {
            switch ClaudeClient.parseSSELine(line) {
            case .text(let chunk): text += chunk
            case .stop: stopped = true
            case .error: XCTFail("unexpected error event")
            case .ignore: break
            }
        }
        XCTAssertEqual(text, "Hallo wereld")
        XCTAssertTrue(stopped)
    }

    // MARK: - HTTP error mapping

    func testHTTPUnauthorizedMapsToInvalidKey() {
        XCTAssertEqual(ClaudeClient.mapHTTPError(status: 401, body: Data()), .invalidKey)
        XCTAssertEqual(ClaudeClient.mapHTTPError(status: 403, body: Data()), .invalidKey)
    }

    func testHTTPRateLimitAndOverloadMapToOverloaded() {
        XCTAssertEqual(ClaudeClient.mapHTTPError(status: 429, body: Data()), .overloaded)
        XCTAssertEqual(ClaudeClient.mapHTTPError(status: 529, body: Data()), .overloaded)
    }

    func testHTTPOtherStatusExtractsMessage() {
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"bad model"}}"#.data(using: .utf8)!
        XCTAssertEqual(ClaudeClient.mapHTTPError(status: 400, body: body), .server("bad model"))
    }

    func testHTTPOtherStatusWithoutBodyFallsBack() {
        XCTAssertEqual(ClaudeClient.mapHTTPError(status: 500, body: Data()), .server("HTTP 500"))
    }

    // MARK: - URL error mapping

    func testOfflineMapsToNetwork() {
        XCTAssertEqual(ClaudeClient.mapURLError(URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(ClaudeClient.mapURLError(URLError(.timedOut)), .network)
    }

    // MARK: - Dutch error messages

    func testDutchErrorMessages() {
        XCTAssertTrue(ClaudeError.invalidKey.localizedDescription.contains("ongeldig"))
        XCTAssertTrue(ClaudeError.overloaded.localizedDescription.contains("overbelast"))
        XCTAssertTrue(ClaudeError.network.localizedDescription.contains("internetverbinding"))
        XCTAssertTrue(ClaudeError.missingKey.localizedDescription.contains("API-key"))
    }
}
