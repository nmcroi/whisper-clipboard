import XCTest
@testable import WhisperClipboard

final class InsertionPolicyDecisionTests: XCTestCase {

    private let ownId = "nl.nielscroiset.whisperclipboard"
    private let targetApp = InsertionTarget(bundleId: "com.apple.TextEdit", processIdentifier: 100)

    // MARK: - Disabled

    func testDisabledYieldsClipboardOnly() {
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: false,
            accessibilityGranted: true,
            capturedTarget: targetApp,
            currentFrontmost: targetApp,
            deniedBundleIds: [],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .clipboardOnly(reason: .disabled))
    }

    /// Disabled is checked first, before accessibility/target — it should win
    /// even when every other condition would also fail.
    func testDisabledTakesPriorityOverOtherFailures() {
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: false,
            accessibilityGranted: false,
            capturedTarget: nil,
            currentFrontmost: nil,
            deniedBundleIds: [],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .clipboardOnly(reason: .disabled))
    }

    // MARK: - No accessibility

    func testNoAccessibilityYieldsClipboardOnly() {
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: false,
            capturedTarget: targetApp,
            currentFrontmost: targetApp,
            deniedBundleIds: [],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .clipboardOnly(reason: .noAccessibility))
    }

    // MARK: - No target captured

    func testNoTargetYieldsClipboardOnly() {
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: true,
            capturedTarget: nil,
            currentFrontmost: targetApp,
            deniedBundleIds: [],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .clipboardOnly(reason: .noTarget))
    }

    // MARK: - Own app

    func testCapturedTargetIsOwnAppYieldsClipboardOnly() {
        let own = InsertionTarget(bundleId: ownId, processIdentifier: 1)
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: true,
            capturedTarget: own,
            currentFrontmost: own,
            deniedBundleIds: [],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .clipboardOnly(reason: .ownApp))
    }

    func testOwnAppComparisonIsCaseInsensitive() {
        let own = InsertionTarget(bundleId: ownId.uppercased(), processIdentifier: 1)
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: true,
            capturedTarget: own,
            currentFrontmost: own,
            deniedBundleIds: [],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .clipboardOnly(reason: .ownApp))
    }

    // MARK: - Frontmost changed

    func testFrontmostDriftedToOwnAppYieldsFrontmostChanged() {
        let ownFrontmost = InsertionTarget(bundleId: ownId, processIdentifier: 2)
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: true,
            capturedTarget: targetApp,
            currentFrontmost: ownFrontmost,
            deniedBundleIds: [],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .clipboardOnly(reason: .frontmostChanged))
    }

    func testFrontmostChangedToDifferentProcessYieldsFrontmostChanged() {
        let otherApp = InsertionTarget(bundleId: "com.apple.Notes", processIdentifier: 200)
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: true,
            capturedTarget: targetApp,
            currentFrontmost: otherApp,
            deniedBundleIds: [],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .clipboardOnly(reason: .frontmostChanged))
    }

    func testFrontmostNilDoesNotTriggerFrontmostChanged() {
        // No live frontmost sample (e.g. couldn't resolve `frontmostApplication`)
        // should not by itself block insertion; it just skips that guard.
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: true,
            capturedTarget: targetApp,
            currentFrontmost: nil,
            deniedBundleIds: [],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .insert)
    }

    func testSameProcessDifferentBundleCaseIsNotFrontmostChanged() {
        // Same process id as captured target: frontmost hasn't actually moved,
        // even if bundle id casing differs.
        let sameProcessDifferentCase = InsertionTarget(bundleId: "com.apple.TEXTEDIT", processIdentifier: 100)
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: true,
            capturedTarget: targetApp,
            currentFrontmost: sameProcessDifferentCase,
            deniedBundleIds: [],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .insert)
    }

    // MARK: - Denied app

    func testDeniedAppYieldsClipboardOnly() {
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: true,
            capturedTarget: targetApp,
            currentFrontmost: targetApp,
            deniedBundleIds: ["com.apple.TextEdit"],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .clipboardOnly(reason: .deniedApp))
    }

    func testDeniedAppMatchIsCaseInsensitive() {
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: true,
            capturedTarget: targetApp,
            currentFrontmost: targetApp,
            deniedBundleIds: ["COM.APPLE.TEXTEDIT"],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .clipboardOnly(reason: .deniedApp))
    }

    func testUnrelatedDeniedEntriesDoNotBlock() {
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: true,
            capturedTarget: targetApp,
            currentFrontmost: targetApp,
            deniedBundleIds: ["com.apple.Notes", "com.apple.Terminal"],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .insert)
    }

    // MARK: - Happy path

    func testHappyPathYieldsInsert() {
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: true,
            capturedTarget: targetApp,
            currentFrontmost: targetApp,
            deniedBundleIds: [],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .insert)
    }

    // MARK: - Priority ordering (guards fire in `decide`'s declared order)

    func testNoAccessibilityTakesPriorityOverDeniedApp() {
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: false,
            capturedTarget: targetApp,
            currentFrontmost: targetApp,
            deniedBundleIds: ["com.apple.TextEdit"],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .clipboardOnly(reason: .noAccessibility))
    }

    func testNoTargetTakesPriorityOverFrontmostChanged() {
        let decision = InsertionPolicy.decide(
            directInsertionEnabled: true,
            accessibilityGranted: true,
            capturedTarget: nil,
            currentFrontmost: InsertionTarget(bundleId: ownId, processIdentifier: 1),
            deniedBundleIds: [],
            ownBundleId: ownId
        )
        XCTAssertEqual(decision, .clipboardOnly(reason: .noTarget))
    }
}

final class InsertionPolicyIsDeniedTests: XCTestCase {

    func testNilBundleIdIsNeverDenied() {
        XCTAssertFalse(InsertionPolicy.isDenied(bundleId: nil, deniedBundleIds: ["com.apple.TextEdit"]))
    }

    func testEmptyBundleIdIsNeverDenied() {
        XCTAssertFalse(InsertionPolicy.isDenied(bundleId: "", deniedBundleIds: ["com.apple.TextEdit"]))
    }

    func testEmptyDenyListNeverDenies() {
        XCTAssertFalse(InsertionPolicy.isDenied(bundleId: "com.apple.TextEdit", deniedBundleIds: []))
    }

    func testExactMatchIsDenied() {
        XCTAssertTrue(InsertionPolicy.isDenied(bundleId: "com.apple.TextEdit", deniedBundleIds: ["com.apple.TextEdit"]))
    }

    func testCaseInsensitiveMatchIsDenied() {
        XCTAssertTrue(InsertionPolicy.isDenied(bundleId: "Com.Apple.TextEdit", deniedBundleIds: ["com.apple.textedit"]))
    }

    func testNonMatchingBundleIdIsNotDenied() {
        XCTAssertFalse(InsertionPolicy.isDenied(bundleId: "com.apple.Notes", deniedBundleIds: ["com.apple.TextEdit"]))
    }

    func testMultipleEntriesMatchAnyCaseInsensitively() {
        let denyList = ["com.apple.Notes", "COM.APPLE.TEXTEDIT", "com.apple.Terminal"]
        XCTAssertTrue(InsertionPolicy.isDenied(bundleId: "com.apple.textedit", deniedBundleIds: denyList))
    }
}

final class PasteboardRestoreTests: XCTestCase {

    func testRestoreWhenChangeCountUnchanged() {
        XCTAssertTrue(PasteboardRestore.shouldRestore(changeCountAfterWrite: 5, currentChangeCount: 5))
    }

    func testNoRestoreWhenSomethingElseWroteToPasteboard() {
        XCTAssertFalse(PasteboardRestore.shouldRestore(changeCountAfterWrite: 5, currentChangeCount: 6))
    }

    func testNoRestoreWhenChangeCountDecreased() {
        // Shouldn't happen in practice (changeCount is monotonic), but the
        // logic should still refuse to restore on any mismatch.
        XCTAssertFalse(PasteboardRestore.shouldRestore(changeCountAfterWrite: 5, currentChangeCount: 4))
    }

    // MARK: - Concealed / transient markers (finding #12)

    func testConcealedTypeIsDetected() {
        XCTAssertTrue(PasteboardRestore.isConcealed(
            typeNames: ["org.nspasteboard.ConcealedType", "public.utf8-plain-text"]
        ))
    }

    func testTransientAndAutoGeneratedTypesAreDetected() {
        XCTAssertTrue(PasteboardRestore.isConcealed(typeNames: ["org.nspasteboard.TransientType"]))
        XCTAssertTrue(PasteboardRestore.isConcealed(typeNames: ["org.nspasteboard.AutoGeneratedType"]))
    }

    func testOrdinaryPlainTextIsNotConcealed() {
        XCTAssertFalse(PasteboardRestore.isConcealed(typeNames: ["public.utf8-plain-text"]))
        XCTAssertFalse(PasteboardRestore.isConcealed(typeNames: []))
    }
}
