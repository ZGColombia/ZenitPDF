import AppKit
import Foundation
import Testing
@testable import ZenitPDFAppKit

/// The process-wide state an app-tier test can reach, enumerated instead of remembered.
///
/// Two resources are guarded by construction — the preset container and the set-mode
/// defaults — and the rest (`NSDocumentController.shared`, the launch marker,
/// `RecoveryPrompt.decisionOverride`, `NSUserDefaults` under any other key any package writes)
/// would otherwise be guarded only by care. Several of this gate's past unreliabilities were
/// one shared, process-wide resource each, and the state *need not even be inside the
/// process*: three runs of one suite agreed perfectly with
/// each other and were all wrong, because the thing deciding the result was a file in
/// `~/Library/Preferences`.
///
/// This suite is the enumeration. Each test is a rule about one shared resource, expressed as
/// a scan of the test tier so that a *new* offender fails on the run that introduces it rather
/// than on some later run that happens to interleave badly.
///
/// **What was measured on a development machine, 2026-08-25.** `ls ~/Library/Preferences | grep -ci '^zenit'`
/// returned **2 547** — one empty plist per scratch `UserDefaults` suite any Zenit test has
/// ever created, 1 108 of them from the author suites, 609 from the ledger power tools and 348
/// from the drop-bookmark test. They carry no data; `removePersistentDomain(forName:)` had
/// emptied the ones that called it. It empties the domain and leaves the file, which nobody
/// had noticed because nobody had looked. ``ScratchDefaults`` now removes both, and
/// ``aScratchDefaultsSuiteLeavesNoFileBehind`` proves the removal instead of trusting it.
@MainActor
@Suite("Shared test state", .appTierSerialised)
struct SharedTestStateTests {

    private static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    private static func swiftFiles() throws -> [(name: String, text: String)] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: testsDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map {
            ($0, try String(contentsOf: testsDirectory.appendingPathComponent($0), encoding: .utf8))
        }
    }

    private static func offenders(
        matching predicate: (String) -> Bool,
        allowing exempt: Set<String> = []
    ) throws -> (offenders: [String], scanned: Int) {
        let files = try swiftFiles()
        var found: [String] = []
        for file in files where !exempt.contains(file.name) {
            for (number, line) in file.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("///"), !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
                guard predicate(trimmed) else { continue }
                found.append("\(file.name):\(number + 1): \(trimmed)")
            }
        }
        return (found, files.count)
    }

    // MARK: - 1. Real preferences

    @Test("A scratch defaults suite is empty on both sides and adds no new file")
    func aScratchDefaultsSuiteIsCleanAndAddsNoNewFile() throws {
        // The prefix's one file is created the first time it is ever used, on this machine,
        // for good. What must not grow is the count across *repeated* use, so the first use is
        // the warm-up and the measurement spans the second.
        try ScratchDefaults.with(prefix: "zenit-scratch-proof") { defaults, _ in
            defaults.set("warm-up", forKey: "zenit.proof")
            defaults.synchronize()
        }
        let before = ScratchDefaults.zenitSuiteFileCount()
        #expect(before > 0, "the count read nothing, so it proves nothing")

        var seenInside: String?
        try ScratchDefaults.with(prefix: "zenit-scratch-proof") { defaults, name in
            // Empty on entry: a previous run that died before its `defer` must not be
            // inherited. That inheritance is the preference leak in miniature.
            #expect(defaults.string(forKey: "zenit.proof") == nil,
                    "the suite came in carrying a value from an earlier run")
            defaults.set("written by a test", forKey: "zenit.proof")
            defaults.synchronize()
            seenInside = defaults.string(forKey: "zenit.proof")
            #expect(name.hasSuffix(".scratch"), "the suite name must not carry a UUID: \(name)")
        }
        #expect(seenInside == "written by a test", "the body could not write its own suite")

        // Empty on exit …
        let reopened = try #require(
            UserDefaults(suiteName: ScratchDefaults.suiteName(for: "zenit-scratch-proof"))
        )
        #expect(reopened.string(forKey: "zenit.proof") == nil, "the domain still holds the value")

        // … and — the half that failed the first time this was written — the machine gained
        // no new file. Deleting the plist does not work: `cfprefsd` owns the domain and writes
        // it out again afterwards, which is why the fix is one fixed suite name per prefix
        // rather than a UUID and a delete. Measured: 2 547 before that lesson, 2 586 after the
        // delete-based attempt, seven of the new ones from this very test.
        #expect(ScratchDefaults.zenitSuiteFileCount() == before,
                """
                the scratch suite added a file: \(before) → \(ScratchDefaults.zenitSuiteFileCount()). \
                A new plist per test run is how a development machine's Preferences folder reached 2 547.
                """)
    }

    @Test("No application-tier test writes the real UserDefaults")
    func noTestWritesTheRealDefaults() throws {
        // Needles are assembled at run time so this file does not match its own scan, which
        // is why it needs no exemption from it. An exempt scanner is a hole.
        let realDefaults = "UserDefaults" + ".standard"
        let passedIn = "defaults: " + ".standard"
        let fallback = "?? " + ".standard"
        let (found, scanned) = try Self.offenders(matching: { line in
            guard line.contains(realDefaults) || line.contains(passedIn) else { return false }
            // Reading is how `ImportScopeAndWaveMarkerTests` proves the real domain is clean;
            // the offence is a write, and the `??` fallback is a write waiting to happen.
            return line.contains(".set(")
                || line.contains(".removeObject(")
                || line.contains(".removePersistentDomain(")
                || line.contains(fallback)
                || line.contains(passedIn)
        })
        #expect(scanned > 20, "the scan examined \(scanned) files")
        #expect(found.isEmpty, """
            A test once wrote the user's real preferences and reddened this \
            gate three times: \(found)
            """)
    }

    @Test("Every scratch defaults suite is created through ScratchDefaults, which deletes its file")
    func everyScratchSuiteIsDisposedOf() throws {
        let files = try Self.swiftFiles()
        var found: [String] = []
        for file in files where file.name != "AppTestSupport.swift" {
            guard file.text.contains("UserDefaults(suiteName") else { continue }
            guard !file.text.contains("ScratchDefaults") else { continue }
            found.append(file.name)
        }
        #expect(files.count > 20, "the scan examined \(files.count) files")
        #expect(found.isEmpty, """
            these name a defaults suite without ScratchDefaults, so the plist they write stays \
            in the user's Preferences folder for ever: \(found)
            """)
    }

    // MARK: - 2. The pasteboard

    @Test("No application-tier test writes the general pasteboard")
    func noTestWritesThePasteboard() throws {
        let writes = [".clearContents(", ".setData(", ".setString(", ".setPropertyList(", ".writeObjects("]
        let (found, scanned) = try Self.offenders(matching: { line in
            guard line.contains("NSPasteboard.general") || line.contains("pasteboard") else { return false }
            return writes.contains(where: line.contains)
        })
        #expect(scanned > 20, "the scan examined \(scanned) files")
        #expect(found.isEmpty, """
            the general pasteboard is the user's clipboard, not a test fixture: \(found)
            """)
    }

    // MARK: - 3. NSWorkspace

    @Test("No application-tier test opens anything through NSWorkspace")
    func noTestDrivesTheWorkspace() throws {
        let (found, scanned) = try Self.offenders(matching: { line in
            line.contains("NSWorkspace.shared") &&
                (line.contains(".open(") || line.contains(".launchApplication") || line.contains(".selectFile("))
        })
        #expect(scanned > 20, "the scan examined \(scanned) files")
        #expect(found.isEmpty, """
            opening a file through NSWorkspace puts an application on the user's screen: \(found)
            """)
    }

    // MARK: - 4. The shared document controller

    @Test("Every document registered with the shared controller is removed again")
    func documentControllerRegistrationsAreBalanced() throws {
        let files = try Self.swiftFiles()
        var found: [String] = []
        var registrations = 0
        for file in files {
            let adds = file.text.components(separatedBy: "NSDocumentController.shared.addDocument").count - 1
            let removes = file.text.components(separatedBy: "NSDocumentController.shared.removeDocument").count - 1
            registrations += adds
            guard adds > 0 else { continue }
            if removes < adds {
                found.append("\(file.name): \(adds) addDocument, \(removes) removeDocument")
            }
        }
        // A gate that scans zero items must fail.
        #expect(registrations > 0, "the scan found no registrations at all, so it proved nothing")
        #expect(found.isEmpty, """
            A document left in NSDocumentController.shared is reviewed and \
            closed by the next suite's quit test: \(found)
            """)
    }

    // MARK: - 5. Nothing is written outside a temporary directory

    @Test("No application-tier test writes into the user's home outside Preferences scratch")
    func noTestWritesIntoTheUsersHome() throws {
        let (found, scanned) = try Self.offenders(matching: { line in
            guard line.contains("NSHomeDirectory()")
                || line.contains(".documentDirectory")
                || line.contains(".applicationSupportDirectory")
                || line.contains(".desktopDirectory")
                || line.contains(".downloadsDirectory") else { return false }
            return true
        }, allowing: ["AppTestSupport.swift", "SharedTestStateTests.swift"])
        #expect(scanned > 20, "the scan examined \(scanned) files")
        #expect(found.isEmpty, """
            a fixture belongs in FileManager.default.temporaryDirectory. An earlier fixture was in \
            the right place and only the modal leaked; these would not be: \(found)
            """)
    }

    // MARK: - 6. The seams that are process-wide statics

    @Test("Every process-wide test seam is left as it was found")
    func theProcessWideSeamsAreClear() {
        // Read at the end of whichever position the runner gives this test. The serial gate
        // means no other test is in flight, so a seam still installed here was abandoned.
        #expect(RecoveryPrompt.decisionOverride == nil,
                "a test left the recovery answer installed; the next one inherits it")
        #expect(ZenitModalPresenter.handler == nil,
                "a test left a modal answer installed")
        #expect(ZenitErrorPresenter.handler == nil,
                "a test left an error presenter installed")
        #expect(ZenitPDFProjectDocument.toolSetModeDefaultsOverride == nil,
                "the set-mode defaults seam, left installed")
        #expect(ZenitPDFProjectDocument.toolPresetContainerOverride == nil)
        #expect(ZenitPDFProjectDocument.quickPDFAutosaveRootOverride == nil)
        #expect(ZenitPDFProjectDocument.searchIndexRootOverride == nil)
        #expect(DamagedDrawingRepair.repairedCopiesRootOverride == nil)
        #expect(DamagedDrawingRepair.clientOverride == nil)
    }
}
