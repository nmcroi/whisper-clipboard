import Testing
import Foundation
@testable import Core

@Suite struct MigrationTests {

    private func loadFixture() throws -> HistoryV3Migrator.Result {
        let url = try Fixtures.golden("history_v3_fixture.json")
        return try HistoryV3Migrator.migrate(contentsOf: url)
    }

    @Test func migratesGoodEntriesAndSkipsMalformedOnes() throws {
        let result = try loadFixture()

        // The fixture was built with exactly 3 well-formed entries and 5
        // malformed ones (missing fields, wrong types, non-object rows).
        #expect(result.entries.count == 3)
        #expect(result.skippedCount == 5)
    }

    @Test func segmentsRoundTripFromRealEntry() throws {
        let result = try loadFixture()
        let withSegments = try #require(result.entries.first { $0.id == "a516804f-66d4-4ad7-ac37-332a6547fd7f" })

        #expect(withSegments.segments.count == 16)
        #expect(abs(withSegments.duration - 91.15476812492125) < 1e-9)
        #expect(withSegments.createdAt == "2026-06-21T10:27:04+02:00")
        #expect(!withSegments.pinned)

        let firstSegment = try #require(withSegments.segments.first)
        #expect(abs(firstSegment.start - 0.78) < 1e-9)
        #expect(abs(firstSegment.end - 7.78) < 1e-9)
        #expect(firstSegment.text.hasPrefix("Twee dingen."))
    }

    @Test func pinnedFlagRoundTrips() throws {
        let result = try loadFixture()
        let pinned = try #require(result.entries.first { $0.id == "fixture-pinned-entry" })

        #expect(pinned.pinned)
        #expect(pinned.name == "Vastgezet gesprek")
        #expect(pinned.segments.count == 0)
        #expect(pinned.duration == 0.0)
    }

    @Test func segmentlessEntryRoundTrips() throws {
        let result = try loadFixture()
        let noSegments = try #require(result.entries.first { $0.id == "a4b1d4a3-249e-4eb2-a815-274bef29d6cc" })

        #expect(noSegments.segments.count == 0)
        #expect(noSegments.duration == 0.0)
        #expect(noSegments.createdAt == "2026-06-21T10:07:46+02:00")
    }

    @Test func createdAtParsesToTimestamp() throws {
        let result = try loadFixture()
        let entry = try #require(result.entries.first { $0.id == "fixture-pinned-entry" })
        let timestamp = try #require(entry.timestamp)

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        // 2026-06-21T10:07:46+02:00 == 2026-06-21T08:07:46Z
        let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: timestamp)
        #expect(components.year == 2026)
        #expect(components.month == 6)
        #expect(components.day == 21)
        #expect(components.hour == 8)
        #expect(components.minute == 7)
        #expect(components.second == 46)
    }

    @Test func migratingTopLevelNonObjectThrows() {
        let data = Data("[1, 2, 3]".utf8)
        #expect(throws: (any Error).self) {
            try HistoryV3Migrator.migrate(data: data)
        }
    }

    @Test func migratingMissingEntriesKeyThrows() {
        let data = Data("{\"version\": 3}".utf8)
        #expect(throws: (any Error).self) {
            try HistoryV3Migrator.migrate(data: data)
        }
    }

    @Test func emptyEntriesArrayYieldsNoEntriesNoSkips() throws {
        let data = Data("{\"version\": 3, \"entries\": []}".utf8)
        let result = try HistoryV3Migrator.migrate(data: data)
        #expect(result.entries.count == 0)
        #expect(result.skippedCount == 0)
    }
}
