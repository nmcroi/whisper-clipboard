import Foundation
import Testing
@testable import Core

@Suite struct TransientResultPolicyTests {

    private let shownAt = Date(timeIntervalSince1970: 1_000_000)

    @Test func nietVerlopenBinnenVijfMinuten() {
        let now = shownAt.addingTimeInterval(299)
        #expect(!TransientResultPolicy.isExpired(shownAt: shownAt, now: now))
    }

    @Test func verlopenOpExactVijfMinuten() {
        let now = shownAt.addingTimeInterval(300)
        #expect(TransientResultPolicy.isExpired(shownAt: shownAt, now: now))
    }

    @Test func verlopenNaVijfMinuten() {
        let now = shownAt.addingTimeInterval(301)
        #expect(TransientResultPolicy.isExpired(shownAt: shownAt, now: now))
    }

    @Test func directNaTonenNietVerlopen() {
        #expect(!TransientResultPolicy.isExpired(shownAt: shownAt, now: shownAt))
    }

    @Test func teruggelopenKlokTeltAlsNietVerlopen() {
        // Klok-skew: `now` vóór `shownAt` mag nooit tot wissen leiden.
        let now = shownAt.addingTimeInterval(-3600)
        #expect(!TransientResultPolicy.isExpired(shownAt: shownAt, now: now))
    }

    @Test func aangepasteLevensduur() {
        let now = shownAt.addingTimeInterval(10)
        #expect(TransientResultPolicy.isExpired(shownAt: shownAt, now: now, lifetime: 10))
        #expect(!TransientResultPolicy.isExpired(shownAt: shownAt, now: now, lifetime: 11))
    }
}
