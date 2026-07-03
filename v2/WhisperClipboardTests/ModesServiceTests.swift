import Core
import Foundation
import GRDB
import XCTest
@testable import WhisperClipboard

@MainActor
final class ModesServiceTests: XCTestCase {

    // MARK: - Helpers

    private func makeHistory() throws -> HistoryStore {
        let queue = try DatabaseQueue()
        return try HistoryStore(dbQueue: queue, retentionProvider: { nil })
    }

    private func tempModesURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wc-modes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("modes.json")
    }

    private func makeService(
        history: HistoryStore,
        modesURL: URL,
        apiKey: String? = "sk-ant-test"
    ) -> ModesService {
        ModesService(
            history: history,
            modesURL: modesURL,
            apiKeyProvider: { apiKey },
            clientFactory: { ClaudeClient(apiKey: $0) }
        )
    }

    // MARK: - Built-in modes

    func testBuiltinsPresent() throws {
        let service = makeService(history: try makeHistory(), modesURL: tempModesURL())
        // The library expanded from the original 4 to a richer Dutch set.
        XCTAssertEqual(AIMode.builtins.count, 10)
        XCTAssertEqual(service.allModes.count, AIMode.builtins.count)
        XCTAssertTrue(service.allModes.allSatisfy(\.isBuiltin))
        // The original four must still be present (stable ids/names).
        let names = Set(service.allModes.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["Samenvatting", "Actiepunten", "E-mail", "LinkedIn-post"]))
        // A few of the new additions.
        XCTAssertTrue(names.isSuperset(of: [
            "Korte samenvatting", "Uitgebreide samenvatting", "Notulen",
            "Doktersafspraak", "Belangrijkste punten", "Verbeterde transcriptie",
        ]))
    }

    func testBuiltinIdsAreStableAndUnique() throws {
        // Stable, prefixed ids so existing stored results still resolve.
        XCTAssertTrue(AIMode.builtins.allSatisfy { $0.id.hasPrefix("builtin.") })
        let ids = AIMode.builtins.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "builtin ids must be unique")
        // The original four ids are preserved.
        XCTAssertTrue(ids.contains("builtin.samenvatting"))
        XCTAssertTrue(ids.contains("builtin.actiepunten"))
        XCTAssertTrue(ids.contains("builtin.email"))
        XCTAssertTrue(ids.contains("builtin.linkedin"))
    }

    func testBuiltinPromptsNonEmpty() throws {
        for mode in AIMode.builtins {
            XCTAssertFalse(
                mode.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(mode.name) has an empty prompt"
            )
            XCTAssertFalse(mode.name.isEmpty)
            XCTAssertFalse(mode.icon.isEmpty)
        }
    }

    func testBuiltinCategoriesCoverAllGroups() throws {
        // Every category is represented at least once.
        let categories = Set(AIMode.builtins.map(\.category))
        XCTAssertEqual(categories, Set(AIModeCategory.allCases))
        // Grouping preserves category order and includes every builtin.
        let grouped = AIMode.grouped(AIMode.builtins)
        XCTAssertEqual(grouped.map(\.category), AIModeCategory.allCases)
        XCTAssertEqual(grouped.reduce(0) { $0 + $1.modes.count }, AIMode.builtins.count)
    }

    func testGroupedDropsEmptyCategories() throws {
        let onlyOne = AIMode.builtins.filter { $0.category == .schrijven }
        let grouped = AIMode.grouped(onlyOne)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped.first?.category, .schrijven)
    }

    func testOlderModesJSONWithoutCategoryDefaultsToSchrijven() throws {
        // A custom mode encoded before `category` existed must still decode.
        let legacy = """
        [{"id":"x1","name":"Legacy","systemPrompt":"Doe iets.","icon":"doc.text","isBuiltin":false}]
        """
        let url = tempModesURL()
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let service = makeService(history: try makeHistory(), modesURL: url)
        XCTAssertEqual(service.customModes.count, 1)
        XCTAssertEqual(service.customModes.first?.category, .schrijven)
        XCTAssertEqual(service.customModes.first?.name, "Legacy")
    }

    // MARK: - Custom mode CRUD

    func testAddCustomModePersists() throws {
        let url = tempModesURL()
        let service = makeService(history: try makeHistory(), modesURL: url)
        let mode = try service.addMode(name: "Blog", systemPrompt: "Schrijf een blog.", icon: "doc.text")

        XCTAssertFalse(mode.isBuiltin)
        XCTAssertEqual(service.customModes.count, 1)
        XCTAssertEqual(service.allModes.count, AIMode.builtins.count + 1)

        // A fresh service over the same file reloads the custom mode.
        let reloaded = makeService(history: try makeHistory(), modesURL: url)
        XCTAssertEqual(reloaded.customModes.count, 1)
        XCTAssertEqual(reloaded.customModes.first?.name, "Blog")
    }

    func testUpdateCustomMode() throws {
        let service = makeService(history: try makeHistory(), modesURL: tempModesURL())
        var mode = try service.addMode(name: "Blog", systemPrompt: "x", icon: "doc.text")
        mode.name = "Nieuwsbrief"
        mode.systemPrompt = "Schrijf een nieuwsbrief."
        try service.updateMode(mode)
        XCTAssertEqual(service.customModes.first?.name, "Nieuwsbrief")
        XCTAssertEqual(service.customModes.first?.systemPrompt, "Schrijf een nieuwsbrief.")
    }

    func testDeleteCustomMode() throws {
        let service = makeService(history: try makeHistory(), modesURL: tempModesURL())
        let mode = try service.addMode(name: "Blog", systemPrompt: "x", icon: "doc.text")
        try service.deleteMode(id: mode.id)
        XCTAssertTrue(service.customModes.isEmpty)
        XCTAssertEqual(service.allModes.count, AIMode.builtins.count)
    }

    func testCannotDeleteBuiltin() throws {
        let service = makeService(history: try makeHistory(), modesURL: tempModesURL())
        try service.deleteMode(id: "builtin.samenvatting")
        XCTAssertEqual(service.allModes.count, AIMode.builtins.count) // unchanged
    }

    func testDuplicateBuiltinCreatesEditableCopy() throws {
        let service = makeService(history: try makeHistory(), modesURL: tempModesURL())
        let builtin = AIMode.builtins[0]
        let copy = try service.duplicate(builtin)
        XCTAssertFalse(copy.isBuiltin)
        XCTAssertNotEqual(copy.id, builtin.id)
        XCTAssertEqual(copy.systemPrompt, builtin.systemPrompt)
        XCTAssertTrue(copy.name.contains("kopie"))
        XCTAssertEqual(service.customModes.count, 1)
    }

    func testCorruptModesFileYieldsEmpty() throws {
        let url = tempModesURL()
        try "not valid json".write(to: url, atomically: true, encoding: .utf8)
        let service = makeService(history: try makeHistory(), modesURL: url)
        XCTAssertTrue(service.customModes.isEmpty)
    }

    // MARK: - hasAPIKey

    func testHasAPIKeyReflectsProvider() throws {
        let history = try makeHistory()
        let withKey = makeService(history: history, modesURL: tempModesURL(), apiKey: "sk-ant-x")
        XCTAssertTrue(withKey.hasAPIKey)

        let noKey = makeService(history: history, modesURL: tempModesURL(), apiKey: nil)
        XCTAssertFalse(noKey.hasAPIKey)

        let blank = makeService(history: history, modesURL: tempModesURL(), apiKey: "   ")
        XCTAssertFalse(blank.hasAPIKey)
    }

    // MARK: - Running with no key surfaces an error on the run

    func testRunWithoutKeyFailsOnRun() throws {
        let service = makeService(history: try makeHistory(), modesURL: tempModesURL(), apiKey: nil)
        let entry = TranscriptEntry(
            id: "t1", text: "Hallo", createdAt: "2026-06-21T10:00:00+02:00",
            name: "", pinned: false, language: "nl", model: "m", source: "mic",
            duration: 0, segments: []
        )
        let run = service.run(mode: AIMode.builtins[0], on: entry)
        XCTAssertFalse(run.isRunning)
        XCTAssertNotNil(run.errorMessage)
        XCTAssertTrue(run.errorMessage?.contains("API-key") ?? false)
    }

    // MARK: - Free-form one-off instruction

    func testFreeInstructionPromptBuild() throws {
        let prompt = ModesService.freeInstructionSystemPrompt("  Maak een verslag voor de huisarts  ")
        // Framing rules present.
        XCTAssertTrue(prompt.contains("opdracht uitvoert op een transcriptie"))
        XCTAssertTrue(prompt.contains("Antwoord in de taal van het transcript"))
        XCTAssertTrue(prompt.contains("zonder inleiding"))
        // Instruction trimmed and embedded.
        XCTAssertTrue(prompt.contains("Opdracht: Maak een verslag voor de huisarts"))
        XCTAssertFalse(prompt.contains("Opdracht:  "))
    }

    func testFreePromptLabelShortAndLong() throws {
        XCTAssertEqual(ModesService.freePromptLabel(for: "Haal de afspraken eruit"),
                       "Eigen prompt: Haal de afspraken eruit")
        // Newlines/extra spaces are collapsed.
        XCTAssertEqual(ModesService.freePromptLabel(for: "Haal\n  de   afspraken eruit"),
                       "Eigen prompt: Haal de afspraken eruit")
        // Long instructions are clipped with an ellipsis.
        let long = String(repeating: "woord ", count: 40)
        let label = ModesService.freePromptLabel(for: long)
        XCTAssertTrue(label.hasPrefix("Eigen prompt: "))
        XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertLessThanOrEqual(label.count, "Eigen prompt: ".count + 61)
    }

    func testFreeInstructionModeIsSyntheticNonBuiltin() throws {
        let mode = ModesService.freeInstructionMode("Vat samen in één zin")
        XCTAssertFalse(mode.isBuiltin)
        XCTAssertEqual(mode.id, ModesService.freePromptModeId)
        XCTAssertEqual(mode.name, "Eigen prompt: Vat samen in één zin")
        XCTAssertEqual(mode.systemPrompt, ModesService.freeInstructionSystemPrompt("Vat samen in één zin"))
    }

    func testFreeInstructionRunPersistsResultWithInstructionLabel() throws {
        StubURLProtocol.reset()
        StubURLProtocol.responseBody = Self.cannedSSE("Verslag voor de huisarts.")

        let history = try makeHistory()
        let service = ModesService(
            history: history,
            modesURL: tempModesURL(),
            apiKeyProvider: { "sk-ant-test" },
            clientFactory: { ClaudeClient(apiKey: $0, session: StubURLProtocol.session()) }
        )
        let entry = TranscriptEntry(
            id: "t1", text: "Patiënt meldt hoofdpijn.", createdAt: "2026-06-21T10:00:00+02:00",
            name: "", pinned: false, language: "nl", model: "m", source: "mic",
            duration: 0, segments: []
        )
        // The result's FK references the transcript row (ON DELETE CASCADE), so
        // the transcript must exist for persistence to succeed.
        try history.add(entry)

        let run = service.run(instruction: "maak een verslag voor de huisarts", on: entry)

        // Wait for the async streaming task to finish, persist, and clear the
        // active run (persist + removeActive both run after `finish()`).
        let done = expectation(description: "run finished")
        Task { @MainActor in
            for _ in 0..<300 where run.isRunning || service.activeRuns.contains(where: { $0.id == run.id }) {
                try? await Task.sleep(for: .milliseconds(10))
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 6)

        XCTAssertNil(run.errorMessage)
        XCTAssertEqual(run.output, "Verslag voor de huisarts.")

        let results = service.results(for: "t1")
        XCTAssertEqual(results.count, 1)
        let stored = try XCTUnwrap(results.first)
        XCTAssertEqual(stored.modeId, ModesService.freePromptModeId)
        XCTAssertTrue(stored.modeName.hasPrefix("Eigen prompt: "))
        XCTAssertTrue(stored.modeName.contains("maak een verslag voor de huisarts"))
        XCTAssertEqual(stored.output, "Verslag voor de huisarts.")

        // The stub received the framed system prompt, not a raw instruction.
        let sentBody = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        let system = try XCTUnwrap(json["system"] as? String)
        XCTAssertTrue(system.contains("opdracht uitvoert op een transcriptie"))
        XCTAssertTrue(system.contains("maak een verslag voor de huisarts"))
    }

    // MARK: - SSE stub helpers

    /// Builds a minimal canned SSE stream that yields `text` in one delta then stops.
    private static func cannedSSE(_ text: String) -> Data {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let lines = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1"}}"#,
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(escaped)\"}}",
            "",
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
            "",
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }
}

/// A `URLProtocol` that returns a canned 200 SSE response and captures the request
/// body, so `ModesService`'s streaming/persistence path can be tested offline.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var lastRequestBody: Data?
    nonisolated(unsafe) static var statusCode = 200

    static func reset() {
        responseBody = Data()
        lastRequestBody = nil
        statusCode = 200
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Capture the body (URLSession moves httpBody into a stream).
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            Self.lastRequestBody = data
        } else {
            Self.lastRequestBody = request.httpBody
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
