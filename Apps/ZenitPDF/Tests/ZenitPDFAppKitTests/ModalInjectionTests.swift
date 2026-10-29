import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFPersistence
@testable import ZenitPDFAppKit

/// Modals must be injectable, and a test never presents one.
///
/// An **app-tier test** that kills the application to arm the crash marker makes the reopen a
/// few lines later ask *"StampRotation.zpdfproj was not closed properly — There is unsaved work
/// from the last session"*, with Recover / Open Read-Only / Discard. Run through
/// `NSAlert.runModal()`, that dialogue would wait for a person in a process with no user. The
/// fixture is in the right place, in the temporary directory; the modal is the leak.
///
/// The paths that must be injectable are the recovery prompt, the unsaved-changes review,
/// error presentation, the save panel and the import chooser. This suite drives all five
/// **through the shipping objects** and asserts
/// two things of each: that a process with no user gets the safe answer without anything
/// being drawn, and that an injected answer reaches the code under it.
///
/// ### The structural half matters more than any of these tests
///
/// Error presentation and set-mode defaults were fixed the same way, for the same reason: an
/// opt-in seam is a rule somebody has to remember, and this is the same rule enforced by
/// construction. ``ZenitModalPresenter`` refuses
/// to draw unless `Bundle.main.bundleIdentifier` is the application's, which a `swift test`
/// process can never be — so a test that forgets everything in this file still cannot reach
/// the screen. ``theTestProcessCannotDrawAnything`` is the assertion that says so, and
/// it is the most important test here.
///
/// Serialized on top of the target-wide gate because ``ZenitModalPresenter`` is process-wide
/// state, as the thing it guards necessarily is. Every test resets it on the way in *and* on
/// the way out; that `defer` is the whole lesson of process-wide test state.
@MainActor
@Suite("Modal injection", .appTierSerialised, .serialized)
struct ModalInjectionTests {

    /// Installs an answer, runs the body, and puts every process-wide field back.
    private func answering(
        _ answer: @escaping @MainActor (ZenitModalRequest) -> ZenitModalAnswer,
        _ body: @MainActor () throws -> Void
    ) rethrows -> [ZenitModalRequest] {
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }
        var seen: [ZenitModalRequest] = []
        ZenitModalPresenter.handler = { request in
            seen.append(request)
            return answer(request)
        }
        try body()
        return seen
    }

    /// Runs the body with nothing injected — the case a forgetful test is in.
    private func withNobodyThere(_ body: @MainActor () throws -> Void) rethrows -> [ZenitModalRequest] {
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }
        try body()
        return ZenitModalPresenter.recorded
    }

    /// A window that is never ordered front, for the paths that want one to sheet onto.
    private func offscreenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        #expect(!window.isVisible, "a test window must never be on screen")
        return window
    }

    // MARK: - 0. The structural guarantee

    @Test("A test process cannot draw a dialogue, injected answer or not")
    func theTestProcessCannotDrawAnything() {
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }
        #expect(!ZenitModalPresenter.canPresentModally,
                "a swift-test process must not be able to reach NSAlert.runModal")
        #expect(Bundle.main.bundleIdentifier != ZenitAppInfo.bundleIdentifier)
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
    }

    @Test("Nothing this suite drives is ever really presented")
    func nothingIsEverDrawn() {
        // The counter only advances past the bundle check, so this is a second reading of
        // the same guarantee taken after the whole file has run at least once in this
        // process. It costs nothing and it states the guarantee directly.
        #expect(ZenitModalPresenter.presentedForReal.isEmpty,
                "something drew a dialogue: \(ZenitModalPresenter.presentedForReal)")
    }

    // MARK: - 1. The recovery prompt

    @Test("The recovery prompt answers Recover with nobody there, and draws nothing")
    func theRecoveryPromptAnswersWithoutAUser() async throws {
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }
        let decision = await RecoveryPrompt.ask(
            assessment: RecoveryAssessment(crashMarkerPresent: true),
            packageName: "StampRotation.zpdfproj"
        )
        #expect(decision == .recover,
                "the branch that loses no work is the one a process with no user takes")
        #expect(ZenitModalPresenter.didRequest(RecoveryPrompt.modalIdentifier))
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
        // The exact sentence, asserted rather than described, so this test is anchored to that
        // dialogue and not to a similar one.
        #expect(ZenitModalPresenter.lastRecorded?.title.contains("StampRotation.zpdfproj") == true)
        #expect(ZenitModalPresenter.lastRecorded?.buttons.count == 3)
    }

    @Test("Each of the recovery prompt's three branches can be injected")
    func theRecoveryPromptTakesAnInjectedAnswer() async {
        for (index, expected) in [(0, RecoveryDecision.recover),
                                  (1, .openReadOnly),
                                  (2, .discard)] {
            ZenitModalPresenter.reset()
            ZenitModalPresenter.handler = { _ in .button(index) }
            let decision = await RecoveryPrompt.ask(
                assessment: RecoveryAssessment(crashMarkerPresent: true),
                packageName: "Injected.zpdfproj"
            )
            #expect(decision == expected, "button \(index) must mean \(expected)")
            ZenitModalPresenter.reset()
        }
    }

    @Test("The older decisionOverride seam still short-circuits before anything is built")
    func theRecoveryOverrideStillWins() async {
        ZenitModalPresenter.reset()
        RecoveryPrompt.decisionOverride = .discard
        defer {
            RecoveryPrompt.decisionOverride = nil
            ZenitModalPresenter.reset()
        }
        let decision = await RecoveryPrompt.ask(
            assessment: RecoveryAssessment(crashMarkerPresent: true),
            packageName: "Overridden.zpdfproj"
        )
        #expect(decision == .discard)
        #expect(ZenitModalPresenter.recorded.isEmpty,
                "the override answers before an NSAlert is even constructed")
    }

    // MARK: - 2. The unsaved-changes review

    @Test("The close review asks through the presenter and discards with nobody there")
    func theUnsavedTakeoffReviewAnswersWithoutAUser() throws {
        let document = ZenitPDFProjectDocument()
        defer { document.close() }
        var decision: ZenitPDFProjectDocument.UnsavedTakeoffDecision?
        let requests = withNobodyThere {
            ZenitPDFProjectDocument.presentUnsavedTakeoffAlert(for: document) { decision = $0 }
        }
        #expect(decision == .discard,
                """
                a process with no user has no work worth keeping, and a review that cannot \
                be answered must not wedge close()
                """)
        #expect(requests.map(\.identifier)
            == [ZenitPDFProjectDocument.unsavedTakeoffModalIdentifier])
        #expect(requests.first?.buttons.count == 3)
    }

    @Test("The close review's Save, Cancel and Don't Save are all injectable")
    func theUnsavedTakeoffReviewTakesAnInjectedAnswer() throws {
        let document = ZenitPDFProjectDocument()
        defer { document.close() }
        let review = ZenitPDFProjectDocument.presentUnsavedTakeoffAlert(for:completion:)
        for (index, expected) in [(1, ZenitPDFProjectDocument.UnsavedTakeoffDecision.cancel),
                                  (2, .discard)] {
            var decision: ZenitPDFProjectDocument.UnsavedTakeoffDecision?
            _ = answering({ _ in .button(index) }) {
                review(document) { decision = $0 }
            }
            #expect(decision == expected, "button \(index) must mean \(expected)")
        }
    }

    // MARK: - 3. Error presentation — already sealed in 15.8, re-asserted beside its siblings

    @Test("Error presentation is the same door and is still shut")
    func errorPresentationIsStillDiverted() {
        ZenitErrorPresenter.reset()
        defer { ZenitErrorPresenter.reset() }
        #expect(!ZenitErrorPresenter.canPresentModally)
        ZenitErrorPresenter.present(ZenitDocumentError.documentNotReady)
        #expect(ZenitErrorPresenter.recorded.count == 1)
    }

    // MARK: - 4. The save panel — ours and AppKit's

    @Test("A save panel answers nothing chosen, and never opens")
    func theSavePanelIsAnsweredWithoutOpening() {
        let panel = NSSavePanel()
        panel.message = "Export the Quantity Ledger as it is on screen."
        panel.nameFieldStringValue = "Takeoff.csv"
        var answer: ZenitModalAnswer?
        let requests = withNobodyThere {
            ZenitModalPresenter.runSavePanel(
                panel,
                identifier: ProjectWindowController.exportLedgerModalIdentifier,
                sheetedOn: nil
            ) { answer = $0 }
        }
        #expect(answer == .dismissed, "nothing chosen means nothing written")
        #expect(requests.map(\.identifier) == [ProjectWindowController.exportLedgerModalIdentifier])
        #expect(ZenitModalPresenter.presentedForReal.isEmpty)
    }

    @Test("An injected destination reaches the caller of a save panel")
    func theSavePanelTakesAnInjectedDestination() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-modal-\(UUID().uuidString).csv")
        var answer: ZenitModalAnswer?
        _ = answering({ _ in .urls([destination]) }) {
            ZenitModalPresenter.runSavePanel(
                NSSavePanel(),
                identifier: ProjectWindowController.exportLedgerModalIdentifier,
                sheetedOn: nil
            ) { answer = $0 }
        }
        #expect(answer?.firstURL == destination)
    }

    @Test("AppKit's own Save-As panel is diverted and reports honestly that nothing was saved")
    func appKitsSavePanelIsDiverted() throws {
        final class SaveVerdictRecorder: NSObject {
            var verdict: Bool?
            @objc func document(
                _ document: NSDocument,
                didSave: Bool,
                contextInfo: UnsafeMutableRawPointer?
            ) { verdict = didSave }
        }
        let recorder = SaveVerdictRecorder()
        let document = ZenitPDFProjectDocument()
        defer { document.close() }
        let requests = withNobodyThere {
            document.runModalSavePanel(
                for: .saveAsOperation,
                delegate: recorder,
                didSave: #selector(SaveVerdictRecorder.document(_:didSave:contextInfo:)),
                contextInfo: nil
            )
        }
        #expect(recorder.verdict == false,
                "claiming a save that never happened would let AppKit close an unsaved document")
        #expect(requests.map(\.identifier)
            == [ZenitPDFProjectDocument.appKitSavePanelModalIdentifier])
    }

    @Test("AppKit's own print panel is diverted the same way")
    func appKitsPrintPanelIsDiverted() {
        let document = ZenitPDFProjectDocument()
        defer { document.close() }
        let requests = withNobodyThere {
            document.runModalPrintOperation(
                NSPrintOperation(view: NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))),
                delegate: nil,
                didRun: nil,
                contextInfo: nil
            )
        }
        #expect(requests.map(\.identifier)
            == [ZenitPDFProjectDocument.appKitPrintPanelModalIdentifier])
    }

    // MARK: - 5. The import chooser

    @Test("File ▸ Open answers Cancel in a process with no user")
    func appKitsOpenPanelIsDiverted() {
        let controller = ZenitDocumentController()
        let requests = withNobodyThere {
            let response = controller.runModalOpenPanel(NSOpenPanel(), forTypes: nil)
            #expect(response == NSApplication.ModalResponse.cancel.rawValue)
        }
        #expect(requests.map(\.identifier) == [ZenitDocumentController.openPanelModalIdentifier])
    }

    @Test("The ledger import chooser reads nothing when nobody chooses")
    func theImportChooserReadsNothingWithoutAUser() {
        let window = offscreenWindow()
        ZenitErrorPresenter.reset()
        defer { ZenitErrorPresenter.reset() }
        let requests = withNobodyThere {
            ZenitJSONImport.present(in: window, against: nil)
        }
        #expect(requests.map(\.identifier) == [ZenitJSONImport.chooserModalIdentifier])
        #expect(ZenitErrorPresenter.recorded.isEmpty, "nothing was opened, so nothing failed")
    }

    @Test("An injected file reaches the ledger import reader")
    func theImportChooserTakesAnInjectedFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Not a ledger.zpdfjson")
        try Data("{ this is not interchange JSON }".utf8).write(to: file)

        let window = offscreenWindow()
        ZenitErrorPresenter.reset()
        defer { ZenitErrorPresenter.reset() }
        _ = answering({ request in
            request.identifier == ZenitJSONImport.chooserModalIdentifier ? .urls([file]) : .dismissed
        }) {
            ZenitJSONImport.present(in: window, against: nil)
        }
        // The reader ran on the injected file — the proof that the answer was consumed rather
        // than the panel being skipped. It is unreadable on purpose: a fabricated interchange
        // document would be asserting the reader, which `ImportScopeAndWaveMarkerTests`
        // already does, rather than the seam.
        // The read and decode run off the main thread since BH-924, so the refusal lands a
        // moment later rather than inside `present`.
        #expect(await AppTestSupport.wait { ZenitErrorPresenter.recorded.count == 1 },
                "the injected file never reached the reader")
    }

    // MARK: - 6. The other two on-screen affordances

    @Test("The calibration prompt sets no scale when nobody answers")
    func theCalibrationPromptRefusesWithoutAUser() {
        let window = offscreenWindow()
        var entry: CalibrationPrompt.Entry?
        let requests = withNobodyThere {
            entry = CalibrationPrompt.ask(in: window)
        }
        #expect(entry == nil, """
            a scale invented by a headless process is the wrong number under every quantity \
            in the project
            """)
        #expect(requests.map(\.identifier) == [CalibrationPrompt.modalIdentifier])
    }

    @Test("Set Scale on an empty field raises the parse-failure dialogue and still sets nothing")
    func theCalibrationParseFailureIsAlsoRouted() {
        let window = offscreenWindow()
        var entry: CalibrationPrompt.Entry?
        let requests = answering({ _ in .button(0) }) {
            entry = CalibrationPrompt.ask(in: window)
        }
        #expect(entry == nil)
        #expect(requests.map(\.identifier) == [
            CalibrationPrompt.modalIdentifier,
            CalibrationPrompt.parseFailureModalIdentifier
        ], "both halves of this prompt go through the door, not just the first")
    }

    @Test("The quit progress panel is not ordered onto a screen that has a person in front of it")
    func theQuitAffordanceDrawsNothing() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.title = "Quitting Zenit PDF"
        var shown: Bool?
        let requests = withNobodyThere {
            shown = ZenitModalPresenter.presentPanel(
                panel,
                identifier: ZenitApplicationDelegate.quitProgressModalIdentifier
            )
        }
        #expect(shown == false)
        #expect(!panel.isVisible, "orderFrontRegardless() in a test process is the user's screen")
        #expect(requests.map(\.identifier) == [ZenitApplicationDelegate.quitProgressModalIdentifier])
    }

    // MARK: - 7. The seam is a test seam, and it restores itself

    @Test("The shipping application never assigns the modal test seam")
    func theModalSeamIsTestOnly() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Apps/ZenitPDF/Sources")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        var scanned = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            guard file.lastPathComponent != "ZenitModalPresenter.swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("ZenitModalPresenter.handler") else { continue }
                guard !trimmed.hasPrefix("///"), !trimmed.hasPrefix("//") else { continue }
                // `handler == nil` is the diversion reading the seam, not setting it.
                guard !trimmed.contains("handler == nil") else { continue }
                guard trimmed.contains("=") else { continue }
                offenders.append("\(file.lastPathComponent):\(number + 1): \(trimmed)")
            }
        }
        #expect(scanned > 20, "the scan examined \(scanned) files")
        #expect(offenders.isEmpty, "the app assigns the modal test seam: \(offenders)")
    }

    @Test("Nothing in the shipping application or the tests runs a dialogue outside the door")
    func nothingRunsADialogueOutsideThePresenter() throws {
        // The same rule `Scripts/verify-no-uninjected-modals.sh` enforces — group A and the
        // direct `.beginSheet(` its exemption 3 no longer allows (R-039) — asserted inside the
        // suite as well so `swift test` alone bites. The shell gate is the authority on the
        // exemptions; this is the tripwire that fires without it.
        let roots = [
            Self.repositoryRoot.appendingPathComponent("Apps/ZenitPDF/Sources"),
            Self.repositoryRoot.appendingPathComponent("Apps/ZenitPDF/Tests")
        ]
        // Assembled at run time rather than written out, so this file does not match its own
        // scan — and so it needs no exemption from it. An exempt scanner is a hole.
        let running = ["." + "runModal(", "." + "beginSheetModal(", "." + "orderFrontRegardless("]
        // A workflow sheet hung straight from its window skipped the door's record and its
        // refusal on a visible window (R-039); only the door itself may call it. The door's
        // own calls are struck out of a line before it is judged, as the script does, so a
        // direct call cannot hide on a line that also calls the door.
        let directSheet = "." + "beginSheet("
        let door = "ZenitModalPresenter" + directSheet
        var offenders: [String] = []
        var scanned = 0
        for root in roots {
            let enumerator = try #require(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            )
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                scanned += 1
                guard file.lastPathComponent != "ZenitModalPresenter.swift" else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("///"), !trimmed.hasPrefix("//") else { continue }
                    let sheetsDirectly = trimmed.replacingOccurrences(of: door, with: "").contains(directSheet)
                    guard running.contains(where: trimmed.contains) || sheetsDirectly else { continue }
                    offenders.append("\(file.lastPathComponent):\(number + 1): \(trimmed)")
                }
            }
        }
        #expect(scanned > 40, "the scan examined \(scanned) files")
        #expect(offenders.isEmpty, """
            these run a dialogue outside ZenitModalPresenter: \(offenders)
            """)
    }

    @Test("The gate script that enforces this exists and is executable")
    func theModalGateScriptIsPresent() throws {
        let script = Self.repositoryRoot
            .appendingPathComponent("Scripts/verify-no-uninjected-modals.sh")
        #expect(FileManager.default.isExecutableFile(atPath: script.path),
                "deleting the gate must not go unnoticed")
        let gate = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Scripts/build-app-package.sh"),
            encoding: .utf8
        )
        #expect(gate.contains("verify-no-uninjected-modals.sh"),
                "the app gate must call the modal gate, or nothing runs it")
        let markerGate = Self.repositoryRoot
            .appendingPathComponent("Scripts/verify-no-armed-recovery-markers.sh")
        #expect(FileManager.default.isExecutableFile(atPath: markerGate.path),
                "the armed-recovery-marker rule needs its gate")
        #expect(gate.contains("verify-no-armed-recovery-markers.sh"),
                "the app gate must call the armed-marker gate, or nothing runs it")
    }

    @Test("The injection helper puts every process-wide field back, including the recorder")
    func theInjectionHelperRestoresItself() {
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }
        // Something already in flight before the scoped injection.
        ZenitModalPresenter.handler = { _ in .button(1) }
        _ = ZenitModalPresenter.runAlert(NSAlert(), identifier: "outer")
        #expect(ZenitModalPresenter.recorded.map(\.identifier) == ["outer"])

        ZenitModalPresenter.answering({ _ in .button(2) }) {
            _ = ZenitModalPresenter.runAlert(NSAlert(), identifier: "inner")
            #expect(ZenitModalPresenter.recorded.map(\.identifier) == ["inner"])
        }

        // Gate unreliability of this kind is one shared resource left changed.
        #expect(ZenitModalPresenter.recorded.map(\.identifier) == ["outer"],
                "the scoped injection kept the outer recorder")
        #expect(ZenitModalPresenter.runAlert(NSAlert(), identifier: "after") == .button(1),
                "the outer handler was not restored")
    }

    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ZenitPDFAppKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ZenitPDF
        .deletingLastPathComponent()   // Apps
        .deletingLastPathComponent()   // repository root
}
