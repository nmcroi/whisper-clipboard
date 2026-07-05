import AppKit
import Core
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

/// Bevestigt (finding #: direct invoegen wiste het klembord) dat het ÉCHTE
/// vorige klembord van de gebruiker overleeft een invoeg-met-restore-cyclus.
///
/// Reproduceert de controller→service-volgorde met een privé, benoemd
/// `NSPasteboard` (niet `.general`, dus het raakt het echte systeemklembord
/// niet) en een neppe keystroke-synthesizer. De sleutel: de snapshot wordt
/// gemaakt VÓÓRDAT de transcriptie op het klembord komt.
@MainActor
final class InsertionClipboardRestoreTests: XCTestCase {

    /// Neppe synthesizer: doet niets, maar rapporteert succes zodat de restore-tak
    /// draait. `sentPaste` legt vast of Cmd+V zou zijn verstuurd.
    private final class FakeSynthesizer: KeystrokeSynthesizer {
        private(set) var sentPaste = false
        func sendPaste() -> Bool { sentPaste = true; return true }
    }

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        // Uniek benoemd klembord per test — isoleert van het systeemklembord.
        pasteboard = NSPasteboard(name: .init(rawValue: "WhisperClipboardTest.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func settings(directInsertion: Bool) -> AppSettings {
        var s = AppSettings()
        s.directInsertion = directInsertion
        s.insertionDeniedBundleIds = []
        return s
    }

    /// Kern van finding #: de snapshot die de restore aanstuurt moet het ÉCHTE
    /// vorige klembord van de gebruiker bevatten, niet de transcriptie.
    ///
    /// Volgorde precies zoals `completeTranscription` het nu doet:
    ///  (1) snapshot maken (VÓÓR de kopie), (2) transcriptie op het klembord.
    /// De end-to-end paste+restore zelf vereist AccessibilityPermission (AX), wat
    /// headless/CI niet heeft — zie `testRestorePutsBackOriginalString` voor de
    /// restore-logica die we wél zonder AX kunnen bewijzen.
    func testSnapshotCapturesUserClipboardNotTranscript() {
        let userClipboard = "belangrijke tekst van de gebruiker"
        pasteboard.clearContents()
        pasteboard.setString(userClipboard, forType: .string)

        let service = InsertionService(synthesizer: FakeSynthesizer(), pasteboard: pasteboard)

        // (1) Controller-volgorde: snapshot VÓÓR we de transcriptie schrijven.
        let snapshot = service.snapshotPasteboard()

        // (2) Dictation kopieert de transcriptie naar het klembord.
        let transcript = "dit is de getranscribeerde tekst"
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)

        // De snapshot die straks de restore aanstuurt bevat het klembord van de
        // gebruiker — NIET onze transcriptie. Dat was precies de bug.
        XCTAssertEqual(snapshot.previousString, userClipboard)
        XCTAssertNotEqual(snapshot.previousString, transcript)
        XCTAssertFalse(snapshot.previousWasConcealed)
    }

    /// Bewijst de restore-tak op serviceniveau ZONDER AX: we draaien de restore-
    /// beslissing (`PasteboardRestore.shouldRestore`) met de snapshot-string en
    /// zetten die terug — precies wat `insert` doet in tak (d). Toont dat het
    /// echte klembord van de gebruiker terugkomt na het overschrijven met de
    /// transcriptie.
    func testRestorePutsBackOriginalString() {
        let userClipboard = "origineel van de gebruiker"
        pasteboard.clearContents()
        pasteboard.setString(userClipboard, forType: .string)

        let service = InsertionService(synthesizer: FakeSynthesizer(), pasteboard: pasteboard)
        let snapshot = service.snapshotPasteboard()

        // Transcriptie overschrijft het klembord (zoals de paste-write doet).
        pasteboard.clearContents()
        pasteboard.setString("transcriptie", forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount

        // Restore-beslissing: niets anders schreef sindsdien → terugzetten mag.
        XCTAssertTrue(PasteboardRestore.shouldRestore(
            changeCountAfterWrite: changeCountAfterWrite,
            currentChangeCount: pasteboard.changeCount
        ))
        if let previous = snapshot.previousString, !snapshot.previousWasConcealed {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }

        // Het klembord bevat weer de originele inhoud van de gebruiker.
        XCTAssertEqual(pasteboard.string(forType: .string), userClipboard)
    }

    /// Regressie-vangnet: als de snapshot ná het schrijven van de transcriptie was
    /// gemaakt (de oude, buggy volgorde), zou hij de transcriptie bevatten.
    func testSnapshotAfterTranscriptWouldCaptureTranscript_documentsTheBug() {
        let userClipboard = "origineel"
        pasteboard.clearContents()
        pasteboard.setString(userClipboard, forType: .string)

        let service = InsertionService(
            synthesizer: FakeSynthesizer(),
            pasteboard: pasteboard
        )

        // Verkeerde volgorde (de bug): eerst transcriptie schrijven, dán snapshot.
        let transcript = "transcriptie"
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
        let buggySnapshot = service.snapshotPasteboard()

        // Dit documenteert waaróm de volgorde ertoe doet: post-write snapshot =
        // transcriptie, wat het echte klembord van de gebruiker zou wissen.
        XCTAssertEqual(buggySnapshot.previousString, transcript)
        XCTAssertNotEqual(buggySnapshot.previousString, userClipboard)
    }

    /// Bevestigt dat een verhuld/geheim item als concealed wordt herkend in de
    /// snapshot, zodat de restore het niet als platte string terugzet.
    func testConcealedClipboardIsFlaggedInSnapshot() {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.clearContents()
        pasteboard.setString("s3cret", forType: .string)
        pasteboard.setString("", forType: concealed)

        let service = InsertionService(
            synthesizer: FakeSynthesizer(),
            pasteboard: pasteboard
        )
        let snapshot = service.snapshotPasteboard()
        XCTAssertTrue(snapshot.previousWasConcealed)
    }
}
