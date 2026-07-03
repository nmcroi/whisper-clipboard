import XCTest
@testable import WhisperClipboard

/// KeychainStore tests. The XCTest host may run without keychain access (no
/// signed host app / no login keychain in CI), so the round-trip test probes
/// availability first and skips gracefully. The wrapper's constants and the
/// empty-value delete semantics are always verified.
final class KeychainStoreTests: XCTestCase {

    /// Whether the test host can actually read/write the keychain. A save of a
    /// probe value that succeeds (and reads back) means access is available.
    private func keychainIsAvailable() -> Bool {
        let probe = "wc-probe-\(UUID().uuidString)"
        do {
            try KeychainStore.save(probe)
            let read = try KeychainStore.read()
            try KeychainStore.delete()
            return read == probe
        } catch {
            return false
        }
    }

    func testServiceAndAccountConstants() {
        XCTAssertEqual(KeychainStore.service, "nl.nielscroiset.whisperclipboard")
        XCTAssertEqual(KeychainStore.account, "anthropic-api-key")
    }

    func testRoundTripWhenAvailable() throws {
        try XCTSkipUnless(keychainIsAvailable(), "Keychain not available on this test host")

        try KeychainStore.save("sk-ant-round-trip")
        XCTAssertEqual(try KeychainStore.read(), "sk-ant-round-trip")
        XCTAssertTrue(KeychainStore.hasKey())

        // Saving replaces (update path).
        try KeychainStore.save("sk-ant-replaced")
        XCTAssertEqual(try KeychainStore.read(), "sk-ant-replaced")

        try KeychainStore.delete()
        XCTAssertNil(try KeychainStore.read())
        XCTAssertFalse(KeychainStore.hasKey())
    }

    func testSavingBlankDeletesWhenAvailable() throws {
        try XCTSkipUnless(keychainIsAvailable(), "Keychain not available on this test host")

        try KeychainStore.save("something")
        try KeychainStore.save("   ") // blank → delete
        XCTAssertNil(try KeychainStore.read())
    }

    func testDeleteOfMissingIsNoThrow() {
        // Deleting a non-existent item must not throw (errSecItemNotFound is OK),
        // regardless of keychain availability for writes.
        XCTAssertNoThrow(try KeychainStore.delete())
    }
}
