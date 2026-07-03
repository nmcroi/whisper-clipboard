import XCTest
@testable import WhisperClipboard

/// Tests for the generalized `KeychainStore` (second account) and the
/// `PlaudCredentials` JSON codec + Keychain round-trip.
///
/// The keychain round-trips probe availability first and skip gracefully when
/// the test host has no keychain access (unsigned host / CI). The pure JSON
/// codec always runs. A test-specific account is used so the user's real PLAUD
/// item is never touched.
final class PlaudKeychainTests: XCTestCase {

    /// A throwaway account so these tests never clobber the real
    /// `plaud-credentials` item.
    private let testStore = KeychainStore(account: "plaud-credentials-test-\(UUID().uuidString)")

    private func keychainIsAvailable() -> Bool {
        do {
            let probe = "probe-\(UUID().uuidString)"
            try testStore.save(probe)
            let read = try testStore.read()
            try testStore.delete()
            return read == probe
        } catch {
            return false
        }
    }

    override func tearDown() {
        try? testStore.delete()
        super.tearDown()
    }

    // MARK: - Account constants

    func testPlaudAccountIsDistinctFromApiKey() {
        XCTAssertEqual(KeychainStore.service, "nl.nielscroiset.whisperclipboard")
        XCTAssertEqual(KeychainStore.plaudAccount, "plaud-credentials")
        // Distinct from the Claude API key account, so the two secrets coexist.
        XCTAssertNotEqual(KeychainStore.plaudAccount, KeychainStore.account)
    }

    // MARK: - Generalized store round-trip

    func testInstanceStoreRoundTrip() throws {
        try XCTSkipUnless(keychainIsAvailable(), "Keychain not available on this test host")

        try testStore.save("hello")
        XCTAssertEqual(try testStore.read(), "hello")
        XCTAssertTrue(testStore.hasValue())

        try testStore.save("replaced")
        XCTAssertEqual(try testStore.read(), "replaced")

        try testStore.save("   ") // blank → delete
        XCTAssertNil(try testStore.read())
        XCTAssertFalse(testStore.hasValue())
    }

    /// The static API key store and an instance store are independent items:
    /// writing one must not affect the other.
    func testApiKeyAndPlaudItemsAreIndependent() throws {
        try XCTSkipUnless(keychainIsAvailable(), "Keychain not available on this test host")

        let apiStore = KeychainStore(account: KeychainStore.account)
        let existingApiKey = try apiStore.read() // preserve whatever is there

        try testStore.save("plaud-secret")
        // The (separate) API-key item is unaffected by the PLAUD write.
        XCTAssertEqual(try apiStore.read(), existingApiKey)

        try testStore.delete()
    }

    // MARK: - PlaudCredentials JSON codec (pure, always runs)

    func testCredentialsCodableRoundTrip() throws {
        let creds = PlaudCredentials(email: "a@b.com", password: "pw", token: "")
        let data = try JSONEncoder().encode(creds)
        let decoded = try JSONDecoder().decode(PlaudCredentials.self, from: data)
        XCTAssertEqual(decoded, creds)
    }

    func testIsConfiguredWithEmailAndPassword() {
        XCTAssertTrue(PlaudCredentials(email: "a@b.com", password: "pw").isConfigured)
    }

    func testIsConfiguredWithTokenOnly() {
        XCTAssertTrue(PlaudCredentials(email: "", password: "", token: "jwt").isConfigured)
    }

    func testNotConfiguredWhenEmpty() {
        XCTAssertFalse(PlaudCredentials().isConfigured)
        XCTAssertFalse(PlaudCredentials(email: "a@b.com", password: "").isConfigured) // email alone
    }

    // MARK: - PlaudCredentials Keychain round-trip

    func testCredentialsSaveLoadRoundTrip() throws {
        try XCTSkipUnless(keychainIsAvailable(), "Keychain not available on this test host")

        let creds = PlaudCredentials(email: "niels@example.com", password: "s3cr3t", token: "")
        try creds.save(to: testStore)

        let loaded = PlaudCredentials.load(from: testStore)
        XCTAssertEqual(loaded, creds)

        // Loading round-trips email+password out of the single Keychain blob.
        XCTAssertEqual(loaded?.email, "niels@example.com")
        XCTAssertEqual(loaded?.password, "s3cr3t")
    }

    func testEmptyCredentialsDeleteTheItem() throws {
        try XCTSkipUnless(keychainIsAvailable(), "Keychain not available on this test host")

        try PlaudCredentials(email: "x@y.com", password: "pw").save(to: testStore)
        XCTAssertNotNil(PlaudCredentials.load(from: testStore))

        // Saving a fully-empty credential clears the stored item.
        try PlaudCredentials().save(to: testStore)
        XCTAssertNil(PlaudCredentials.load(from: testStore))
    }

    /// Finding #9b: clearing the password while keeping the email must NOT leave a
    /// useless email-only blob in the Keychain — the item is deleted, since the
    /// email is already mirrored into `AppSettings.plaudEmail` for display.
    func testClearingPasswordButKeepingEmailDeletesTheItem() throws {
        try XCTSkipUnless(keychainIsAvailable(), "Keychain not available on this test host")

        try PlaudCredentials(email: "x@y.com", password: "pw").save(to: testStore)
        XCTAssertNotNil(PlaudCredentials.load(from: testStore))

        // Password cleared, email kept → no secret left → item removed.
        try PlaudCredentials(email: "x@y.com", password: "").save(to: testStore)
        XCTAssertNil(PlaudCredentials.load(from: testStore))
    }

    /// A token-only credential (no email/password) is still a secret and persists.
    func testTokenOnlyCredentialPersists() throws {
        try XCTSkipUnless(keychainIsAvailable(), "Keychain not available on this test host")

        try PlaudCredentials(email: "", password: "", token: "jwt-xyz").save(to: testStore)
        let loaded = PlaudCredentials.load(from: testStore)
        XCTAssertEqual(loaded?.token, "jwt-xyz")
    }
}
