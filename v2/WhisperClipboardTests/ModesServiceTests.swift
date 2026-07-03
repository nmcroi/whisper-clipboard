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
        XCTAssertEqual(AIMode.builtins.count, 4)
        // allModes starts as just the 4 builtins.
        XCTAssertEqual(service.allModes.count, 4)
        XCTAssertTrue(service.allModes.allSatisfy(\.isBuiltin))
        XCTAssertEqual(Set(service.allModes.map(\.name)),
                       ["Samenvatting", "Actiepunten", "E-mail", "LinkedIn-post"])
    }

    // MARK: - Custom mode CRUD

    func testAddCustomModePersists() throws {
        let url = tempModesURL()
        let service = makeService(history: try makeHistory(), modesURL: url)
        let mode = try service.addMode(name: "Blog", systemPrompt: "Schrijf een blog.", icon: "doc.text")

        XCTAssertFalse(mode.isBuiltin)
        XCTAssertEqual(service.customModes.count, 1)
        XCTAssertEqual(service.allModes.count, 5)

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
        XCTAssertEqual(service.allModes.count, 4)
    }

    func testCannotDeleteBuiltin() throws {
        let service = makeService(history: try makeHistory(), modesURL: tempModesURL())
        try service.deleteMode(id: "builtin.samenvatting")
        XCTAssertEqual(service.allModes.count, 4) // unchanged
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
}
