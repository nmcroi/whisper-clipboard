import Testing
import Foundation
@testable import Core

@Suite struct TranscriptSegmentCodingTests {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    @Test func nilSpeakerIsOmittedFromEncoding() throws {
        let segment = TranscriptSegment(start: 0, end: 1.5, text: "Hallo")
        let data = try encoder.encode(segment)
        let json = String(decoding: data, as: UTF8.self)
        // No "speaker" key at all → byte-stable with pre-diarization encoding.
        #expect(!json.contains("speaker"))
        #expect(json == #"{"end":1.5,"start":0,"text":"Hallo"}"#)
    }

    @Test func speakerRoundTrips() throws {
        let segment = TranscriptSegment(start: 0, end: 1.5, text: "Hallo", speaker: "Spreker 2")
        let data = try encoder.encode(segment)
        let decoded = try decoder.decode(TranscriptSegment.self, from: data)
        #expect(decoded == segment)
        #expect(decoded.speaker == "Spreker 2")
    }

    @Test func missingSpeakerKeyDecodesToNil() throws {
        let json = #"{"start":0.0,"end":1.5,"text":"Hallo"}"#
        let decoded = try decoder.decode(TranscriptSegment.self, from: Data(json.utf8))
        #expect(decoded.speaker == nil)
        #expect(decoded.text == "Hallo")
    }

    @Test func presentSpeakerKeyDecodes() throws {
        let json = #"{"start":0.0,"end":1.5,"text":"Hallo","speaker":"Spreker 1"}"#
        let decoded = try decoder.decode(TranscriptSegment.self, from: Data(json.utf8))
        #expect(decoded.speaker == "Spreker 1")
    }
}
