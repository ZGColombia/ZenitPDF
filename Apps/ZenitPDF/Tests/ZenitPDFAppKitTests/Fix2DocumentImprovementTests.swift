import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Improvements 2, document and window: save state, the recovery prompt's words, the load
/// pipeline's concurrency and moving between tabs.
@MainActor
@Suite(.appTierSerialised)
struct Fix2DocumentImprovementTests {

    private func save(_ document: ZenitPDFProjectDocument, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // MARK: - IM-177

    @Test("IM-177: a save says it is saving, then when it saved; it never overwrites another note")
    func saveStateIsVisible() async throws {
        let harness = try await Fix2Harness.make("IM177.pdf")
        defer { harness.tearDown() }
        let status = harness.core.status
        status.setActiveToolNote(nil)
        let package = harness.directory.appendingPathComponent("Saved.zpdfproj")
        var notes: [String?] = []
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            harness.document.save(to: package, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            // The synchronous half has run: the phase is already on the status bar.
            notes.append(status.snapshot.activeToolNote)
        }
        notes.append(status.snapshot.activeToolNote)
        // Old: nothing — a long Create Project looked like a hung window.
        #expect(notes.first??.hasPrefix("Creating project") == true, "\(notes)")
        #expect(notes.last??.hasPrefix("Saved ") == true, "\(notes)")
        #expect(ZenitPDFProjectDocument.savedNote(autosave: true, at: Date()).hasPrefix("Autosaved "))
        status.setActiveToolNote("Template applied")
        harness.document.publishSaveNote("Saving…")
        #expect(status.snapshot.activeToolNote == "Template applied")
    }

    // MARK: - IM-178

    @Test("IM-178: the recovery prompt says when the last save was and what each button keeps")
    func recoveryPromptUsesTheAssessment() throws {
        let manifest = ProjectManifest(
            projectId: "p", displayName: "Tower", createdAt: "2026-09-20T08:00:00Z",
            modifiedAt: "2026-09-23T09:30:00Z", appVersion: "1", databaseSchema: 1,
            originalPdfSha256: "a", workingPdfSha256: "a", minimumReaderVersion: "1"
        )
        let assessment = RecoveryAssessment(crashMarkerPresent: true, lastGoodManifest: manifest)
        let now = try #require(RecoveryPrompt.parseManifestDate("2026-09-23T11:30:00Z"))
        let text = RecoveryPrompt.informativeText(for: assessment, now: now)
        // Old: one fixed sentence for every crash, and the assessment unread.
        #expect(text.contains("Last saved"))
        #expect(text.contains("Recover keeps the edits made after that save."))
        #expect(text.contains("Discard returns to the version saved"))
        #expect(!text.contains("A save was in progress"))
        #expect(RecoveryPrompt.parseManifestDate("2026-09-23T09:30:00.123Z") != nil)
        let interrupted = RecoveryAssessment(crashMarkerPresent: true)
        let bare = RecoveryPrompt.informativeText(for: interrupted, now: now)
        #expect(bare.contains("Discard returns to the last saved version."))
    }

    // MARK: - IM-179

    @Test("IM-179: the search index starts opening before the stored takeoff hydrates")
    func searchIndexOpensBesideHydration() async throws {
        let harness = try await Fix2Harness.make("IM179.pdf")
        _ = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 90, y: 10)])
        }
        let package = harness.directory.appendingPathComponent("Indexed.zpdfproj")
        try await save(harness.document, to: package)
        harness.document.close()
        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: package, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        defer {
            reopened.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }
        #expect(await AppTestSupport.wait { reopened.core != nil && reopened.searchIndex != nil })
        let opened = try #require(reopened.searchIndexOpenStartedAt)
        let hydrated = try #require(reopened.hydrationStartedAt)
        // Old: the index was opened after hydration, the tool library and the compare
        // presenter, serially on the load path.
        #expect(opened <= hydrated)
        #expect(reopened.searchIndex != nil)
    }

    // MARK: - IM-182 / BH-905

    @Test("IM-182: Show Next / Previous Tab cycle the tabs, and the Window menu lists them")
    func tabsCanBeSwitchedFromTheKeyboard() async throws {
        let harness = try await Fix2Harness.make("IM182.pdf", calibrate: false)
        defer { harness.tearDown() }
        let otherURL = try AppTestSupport.writeFixturePDF(named: "Second.pdf")
        defer { try? FileManager.default.removeItem(at: otherURL.deletingLastPathComponent()) }
        let second = try AppTestSupport.makeDocument(opening: otherURL)
        defer { second.close() }
        #expect(await AppTestSupport.wait { second.core != nil })
        harness.controller.attach(document: second)
        harness.controller.activateTab(id: harness.document.documentIdentity)
        let next = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
        next.representedObject = ZenitAppCommand.showNextTab.rawValue
        // Old: no command existed; tabs could only be clicked.
        #expect(harness.controller.validateMenuItem(next))
        harness.controller.performZenitCommand(next)
        #expect(harness.controller.activeDocument === second)
        harness.controller.performZenitCommand(next)
        #expect(harness.controller.activeDocument === harness.document, "wraps at the end")
        harness.controller.activateAdjacentTab(offset: -1)
        #expect(harness.controller.activeDocument === second, "wraps at the start")

        let menu = NSMenu()
        second.updateChangeCount(.changeDone)
        WindowMenuTabLister.appendTabItems(for: harness.controller, to: menu)
        let rows = menu.items.filter { $0.action == #selector(ProjectWindowController.activateTabFromMenu(_:)) }
        #expect(rows.count == 2)
        #expect(rows.first { $0.state == .on }?.representedObject as? UUID == second.documentIdentity)
        #expect(rows.contains { $0.title.hasSuffix("— Edited") })
        second.updateChangeCount(.changeCleared)

        // The bar carries the four tab-switching items, two of them hidden twins.
        let bar = ZenitMenuBar.make()
        let windowMenu = try #require(ZenitMenuBar.specialMenu(.windows, in: bar))
        let tabItems = windowMenu.items.filter {
            ($0.representedObject as? String).flatMap(ZenitAppCommand.init(rawValue:)).map { [.showNextTab, .showPreviousTab].contains($0) } ?? false
        }
        #expect(tabItems.count == 4)
        let hidden = tabItems.filter { $0.isHidden }
        #expect(hidden.count == 2)
        #expect(hidden.allSatisfy { $0.allowsKeyEquivalentWhenHidden })
    }

    @Test("BH-905: the × on an edited background tab brings it to the front before asking")
    func closingABackgroundTabFrontsIt() async throws {
        let harness = try await Fix2Harness.make("BH905.pdf", calibrate: false)
        defer { harness.tearDown() }
        let otherURL = try AppTestSupport.writeFixturePDF(named: "Background.pdf")
        defer { try? FileManager.default.removeItem(at: otherURL.deletingLastPathComponent()) }
        let background = try AppTestSupport.makeDocument(opening: otherURL)
        #expect(await AppTestSupport.wait { background.core != nil })
        harness.controller.attach(document: background)
        harness.controller.activateTab(id: harness.document.documentIdentity)
        background.updateChangeCount(.changeDone)
        var frontAtReview: ZenitPDFProjectDocument?
        background.unsavedTakeoffReview = { [weak controller = harness.controller] _, answer in
            frontAtReview = controller?.activeDocument
            answer(.cancel)
        }
        defer {
            background.updateChangeCount(.changeCleared)
            background.close()
        }
        harness.controller.requestCloseTab(id: background.documentIdentity)
        // Old: canClose ran with the other tab in front, so the sheet hung over its drawing.
        #expect(await AppTestSupport.wait { frontAtReview != nil })
        #expect(frontAtReview === background)
    }
}
