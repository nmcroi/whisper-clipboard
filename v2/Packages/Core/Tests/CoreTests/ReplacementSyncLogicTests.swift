import Foundation
import Testing
@testable import Core

@Suite struct ReplacementSyncLogicTests {

    private let rules = [
        Replacement(find: "klot code", replace: "Claude Code"),
        Replacement(find: "G-A-X", replace: "GHX"),
    ]

    // MARK: - Codec

    @Test func encodeDecodeRoundTrip() throws {
        let data = try #require(ReplacementSyncLogic.encode(rules, updatedAt: Date(timeIntervalSince1970: 1234)))
        let payload = try #require(ReplacementSyncLogic.decode(data))
        #expect(payload.version == 1)
        #expect(payload.updatedAt == 1234)
        #expect(payload.replacements == rules)
    }

    @Test func decodeCorrupteDataGeeftNil() {
        #expect(ReplacementSyncLogic.decode(Data("rommel".utf8)) == nil)
        #expect(ReplacementSyncLogic.decode(Data()) == nil)
        #expect(ReplacementSyncLogic.decode(Data("{\"version\":1}".utf8)) == nil)
    }

    @Test func legeLijstCodeertGewoon() throws {
        let data = try #require(ReplacementSyncLogic.encode([], updatedAt: Date(timeIntervalSince1970: 99)))
        let payload = try #require(ReplacementSyncLogic.decode(data))
        #expect(payload.replacements.isEmpty)
    }

    // MARK: - Resolve (last-writer-wins)

    private func payload(_ at: Double, _ list: [Replacement]) -> ReplacementsPayload {
        ReplacementsPayload(updatedAt: at, replacements: list)
    }

    @Test func nieuwereRemoteWint() {
        let winner = ReplacementSyncLogic.resolve(
            local: payload(100, rules),
            remote: payload(200, [])
        )
        // Ook een lege, nieuwere lijst wint: alles wissen op één apparaat moet
        // doorkomen op het andere.
        #expect(winner == payload(200, []))
    }

    @Test func nieuwereLocalWint() {
        let winner = ReplacementSyncLogic.resolve(
            local: payload(300, rules),
            remote: payload(200, [])
        )
        #expect(winner == payload(300, rules))
    }

    @Test func gelijkeTimestampLangsteLijstWint() {
        let short = [rules[0]]
        #expect(ReplacementSyncLogic.resolve(local: payload(100, short), remote: payload(100, rules))
                == payload(100, rules))
        #expect(ReplacementSyncLogic.resolve(local: payload(100, rules), remote: payload(100, short))
                == payload(100, rules))
    }

    @Test func ontbrekendeKantenVallenTerug() {
        #expect(ReplacementSyncLogic.resolve(local: nil, remote: nil) == nil)
        #expect(ReplacementSyncLogic.resolve(local: payload(1, rules), remote: nil) == payload(1, rules))
        #expect(ReplacementSyncLogic.resolve(local: nil, remote: payload(1, rules)) == payload(1, rules))
    }

    // MARK: - shouldApplyRemote

    @Test func striktNieuwereRemoteWordtToegepast() {
        #expect(ReplacementSyncLogic.shouldApplyRemote(remote: payload(200, rules), localUpdatedAt: 100))
    }

    @Test func oudereOfGelijkeRemoteWordtGenegeerd() {
        // Gelijk = de echo van onze eigen publish: negeren (geen sync-lus).
        #expect(!ReplacementSyncLogic.shouldApplyRemote(remote: payload(100, rules), localUpdatedAt: 100))
        #expect(!ReplacementSyncLogic.shouldApplyRemote(remote: payload(50, rules), localUpdatedAt: 100))
    }
}
