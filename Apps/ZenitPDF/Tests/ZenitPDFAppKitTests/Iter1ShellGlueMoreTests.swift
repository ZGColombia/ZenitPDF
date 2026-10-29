import AppKit
import Foundation
import ImageIO
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Loop iteration 1, area app-shell-glue: R-032 … R-045 and K-05. Every test states the old
/// output it fails with.
@MainActor
@Suite("Iteration 1 — app shell glue (2)", .appTierSerialised)
struct Iter1ShellGlueMoreTests {

    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ZenitPDFAppKit")
    }

    // MARK: - R-032 / R-033

    @Test("R-032: Save as Job Template asks before replacing a template of the same name")
    func savingOverATakenNameAsks() async throws {
        let harness = try await Fix2Harness.make("R032.pdf", calibrate: false)
        defer { harness.tearDown() }
        let storeDirectory = harness.directory.appendingPathComponent("templates", isDirectory: true)
        let store = JobTemplateStore(directory: storeDirectory)
        let existing = JobTemplate(name: "Villa", presets: [])
        try await store.write([existing])
        let previousStore = ProjectWindowController.jobTemplateStore
        let previousName = ProjectWindowController.templateNamePrompt
        let previousConflict = ProjectWindowController.templateImportConflictPrompt
        defer {
            ProjectWindowController.jobTemplateStore = previousStore
            ProjectWindowController.templateNamePrompt = previousName
            ProjectWindowController.templateImportConflictPrompt = previousConflict
        }
        ProjectWindowController.jobTemplateStore = { JobTemplateStore(directory: storeDirectory) }
        ProjectWindowController.templateNamePrompt = { _ in "Villa" }
        var asked: [String] = []
        ProjectWindowController.templateImportConflictPrompt = { name, _ in asked.append(name); return nil }

        harness.controller.saveJobTemplate(for: harness.document)
        #expect(await AppTestSupport.wait { !asked.isEmpty }, "old: the stored template was replaced without a question")
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await store.read()?.map(\.id) == [existing.id], "Cancel keeps the stored template")

        ProjectWindowController.templateImportConflictPrompt = { name, _ in asked.append(name); return .keepBoth }
        harness.controller.saveJobTemplate(for: harness.document)
        var stored: [JobTemplate] = []
        for _ in 0..<100 {
            stored = (try? await store.read()) ?? []
            if stored.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(stored.count == 2)
        let names = try await store.read()?.map(\.name) ?? []
        #expect(names.sorted() == ["Villa", "Villa (2)"])
        #expect(asked == ["Villa", "Villa"])
    }

    @Test("R-033: Keep Both on an import with a colliding id keeps the template's export profiles")
    func keepBothKeepsExportProfiles() {
        let existing = JobTemplate(name: "Roofing")
        var imported = existing
        imported.exportProfiles = [JobTemplateAttachedFile(name: "Estimator.zpdfprofile", json: "{}")]
        let merged = ProjectWindowController.mergeImportedTemplate(&imported, into: [existing], choice: .keepBoth)
        #expect(merged.count == 2)
        let copy = merged[1]
        #expect(copy.id != existing.id)
        #expect(copy.name == "Roofing (2)")
        // Old: [] — the new-identity copy was built with an initializer that has no profiles.
        #expect(copy.exportProfiles == imported.exportProfiles)
    }

    // MARK: - R-034

    @Test("R-034: refusals name menu items that exist")
    func refusalsNameRealMenuItems() async throws {
        let harness = try await Fix2Harness.make("R034.pdf", calibrate: false)
        defer { harness.tearDown() }
        let createProject = ZenitAppCommandTable.spec(for: .createProject).title
        SendProject.send(document: harness.document, window: nil)
        let note = try #require(harness.core.document.warnings.first { $0.id == SendProject.noteID })
        // Old: "(File ▸ Save As Project…)", a row that does not exist.
        #expect(note.message.contains("File ▸ \(createProject)"))
        #expect(SharedReviewCommands.needsProjectMessage.contains(createProject))
        let bar = ZenitMenuBar.make()
        func titles(_ menu: NSMenu) -> [String] { menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) } }
        let all = titles(bar)
        #expect(all.contains(createProject))
        #expect(all.contains(ZenitAppCommandTable.spec(for: .connectSharedReview).title))
        for file in ["Platform/SendProject.swift", "Review/SharedReviewCommands.swift", "Review/SharedReviewAutoSync.swift"] {
            let text = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("Save As Project…") && !text.contains("Shared Review ▸"), "\(file)")
        }
    }

    // MARK: - R-035

    static func toolSet(_ names: [String]) throws -> Data {
        let presets = names.map { name in
            ToolPresetSummary(id: UUID(), name: name, category: "Finishes", panel: .myTools, markupKind: .measurement,
                              measurementKind: .area, colorRGBA: ColorRGBA.Zenit.Dark.cyan, defaultSubject: name)
        }
        return try ToolSetDocument(name: "Office", author: "Office", exportedAt: Date(timeIntervalSince1970: 1_790_000_000), exporting: presets).jsonData()
    }

    @Test("R-035: one read of the office folder serves every open project, each is told what changed, and an unchanged folder is not read again")
    func officeLibraryReadOnceForAllProjects() async throws {
        let first = try await Fix2Harness.make("R035a.pdf", calibrate: false)
        defer { first.tearDown() }
        let second = try await Fix2Harness.make("R035b.pdf", calibrate: false)
        defer { second.tearDown() }
        let folder = first.directory.appendingPathComponent("office", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.toolSet(["Floor finish", "Wall paint"]).write(to: folder.appendingPathComponent("Office.zpdftools"))
        let library = SubscribedToolLibrary()
        library.defaults = ZenitScratchDefaults()
        library.subscribe(to: folder)

        let outcomes = library.refresh([first.document, second.document])
        #expect(outcomes.count == 2)
        #expect(library.readCount == 1, "one read for both projects")
        for harness in [first, second] {
            #expect(harness.core.toolLibrary.presets.filter(SubscribedToolLibrary.isSubscribed).map(\.name).sorted() == ["Floor finish", "Wall paint"])
            // Old: only the first project got the note; the seen state it wrote told the second
            // that nothing had changed.
            #expect(harness.core.document.warnings.contains { $0.id == SubscribedToolLibrary.noteID }, "\(harness.document.displayName ?? "")")
        }
        // Returning to the front with the folder unchanged reads nothing, off the main thread or on it.
        await library.refreshInBackground([first.document, second.document])
        library.refresh([first.document])
        #expect(library.readCount == 1, "old: every activation re-read, re-validated and re-hashed every file, once per project")
        // A changed file is read again, once, in the background.
        try await Task.sleep(for: .milliseconds(20))
        try Self.toolSet(["Floor finish", "Ceiling", "Skirting"]).write(to: folder.appendingPathComponent("Office.zpdftools"))
        await library.refreshInBackground([first.document, second.document])
        #expect(library.readCount == 2)
        for harness in [first, second] {
            #expect(harness.core.toolLibrary.presets.filter(SubscribedToolLibrary.isSubscribed).map(\.name).sorted() == ["Ceiling", "Floor finish", "Skirting"])
        }
    }

    // MARK: - R-037

    @Test("R-037: session restore ends every security scope it starts")
    func sessionRestoreBalancesItsScope() {
        var begun: [String] = []
        var ended: [URL] = []
        let moved = URL(fileURLWithPath: "/Volumes/Share/Moved/Plan.pdf")
        let found = ProjectWindowController.restorableURL(
            forPath: "/Users/x/Plan.pdf",
            begin: { begun.append($0); return moved },
            end: { ended.append($0) },
            exists: { $0 == moved.path }
        )
        // Old: the access was started and kept; nothing ever ended it.
        #expect(found == moved)
        #expect(begun == ["/Users/x/Plan.pdf"])
        #expect(ended == [moved])
        let gone = ProjectWindowController.restorableURL(
            forPath: "/Users/x/Gone.pdf", begin: { _ in moved }, end: { ended.append($0) }, exists: { _ in false }
        )
        #expect(gone == nil)
        #expect(ended.count == 2, "ended on the missing-file path too")
        let plain = ProjectWindowController.restorableURL(
            forPath: "/Users/x/Local.pdf", begin: { _ in nil }, end: { ended.append($0) }, exists: { _ in true }
        )
        #expect(plain == URL(fileURLWithPath: "/Users/x/Local.pdf"))
        #expect(ended.count == 2, "no scope, nothing to end")
    }

    // MARK: - R-040

    @Test("R-040: a .zpdfjson opened from Finder gets the menu's review, against the menu's comparison ledger")
    func jsonReviewIsOneImplementation() async throws {
        let harness = try await Fix2Harness.make("R040.pdf")
        defer { harness.tearDown() }
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 250, y: 10)])
        }, subject: "Wall")
        let url = harness.directory.appendingPathComponent("Ledger.zpdfjson")
        _ = try await ZenitScripting.export(document: harness.document, to: url, format: .json)
        var viaFinder: ZenitJSONImport.Outcome?
        var viaMenu: ZenitJSONImport.Outcome?
        let recorded = await ZenitModalPresenter.answeringAsync { _ in .button(0) } perform: {
            viaFinder = await ZenitDataFileRoutes.reviewLedgerJSON(url, document: harness.document)
            viaMenu = await ZenitJSONImport.review(
                url, against: await ProjectWindowController.comparisonLedger(for: harness.document), window: nil
            )
        }
        let finder = try #require(viaFinder)
        let menu = try #require(viaMenu)
        #expect(ZenitJSONImport.text(for: finder).title == ZenitJSONImport.text(for: menu).title)
        #expect(ZenitJSONImport.text(for: finder).body == ZenitJSONImport.text(for: menu).body)
        #expect(finder.reconciliation != nil, "held against the ledger on screen")
        #expect(recorded.filter { $0.identifier == ZenitJSONImport.reviewModalIdentifier }.count == 2)
    }

    // MARK: - R-041

    @Test("R-041: the Inspector's Lock and Hide and Edit ▸ Lock and Hide run one implementation")
    func lockAndHideShareOneImplementation() async throws {
        let harness = try await Fix2Harness.make("R041.pdf")
        defer { harness.tearDown() }
        let markup = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 250, y: 10)])
        })
        harness.core.canvas.select(markupIDs: [markup.id.rawValue], additive: false)
        // The Inspector's Lock.
        let setLocked = try #require(harness.shell.inspectorEditing.onSetLocked)
        setLocked([markup.id.rawValue], true)
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.first?.locked == true })
        await ZenitPDFProjectDocument.performLockHide(ids: [markup.id.rawValue], lock: false, hide: nil, core: harness.core)
        await harness.core.refresh()
        #expect(harness.core.snapshot.markups.first?.locked == false)
        // Edit ▸ Hide, through the same helper: hidden, and out of the selection.
        harness.controller.applyLockOrHide(for: harness.document, hide: true)
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.first?.hidden == true })
        #expect(await AppTestSupport.wait { harness.core.canvas.selectedMarkupIDs.isEmpty })
        let wiring = try String(contentsOf: Self.sourcesRoot.appendingPathComponent("Workflows/ProjectStructureWiring.swift"), encoding: .utf8)
        let window = try String(contentsOf: Self.sourcesRoot.appendingPathComponent("Window/ProjectWindowController.swift"), encoding: .utf8)
        // Old: each file performed .setLocked/.setHidden itself.
        #expect(wiring.components(separatedBy: ".setHidden(ids:").count == 2, "only the helper performs it")
        #expect(!window.contains(".setHidden(ids: ids, hidden: hide)"))
    }

    // MARK: - R-042

    @Test("R-042: the Measure menu has one row called Calibrate, and the scale sheet's row says what it is")
    func measureMenuHasNoCalibrateTwins() throws {
        let bar = ZenitMenuBar.make()
        let measure = try #require(bar.items.compactMap(\.submenu).first { $0.title == ZPDFCommandGroup.measure.displayName })
        let titles = measure.items.filter { !$0.isHidden }.map(\.title)
        // Old: "Calibrate" and "Calibrate Scale…" side by side.
        #expect(titles.filter { $0.hasPrefix("Calibrate") }.count == 1, "\(titles)")
        #expect(titles.contains("Set Scale…"))
        let row = try #require(measure.items.first { $0.title == "Set Scale…" })
        #expect(row.keyEquivalent == "k")
        #expect(row.keyEquivalentModifierMask.contains([.command, .option]))
    }

    // MARK: - R-043

    @Test("R-043: a CSV of the selected rows announces their count, and a template CSV carries the ticked audit trail")
    func csvCountsAndTrail() async throws {
        let harness = try await Fix2Harness.make("R043.pdf")
        defer { harness.tearDown() }
        let first = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 250, y: 10)])
        }, subject: "Wall")
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 60), PDFPoint(x: 150, y: 60)])
        }, subject: "Wall")
        #expect(harness.core.ledger.rowCount == 2)
        let url = harness.directory.appendingPathComponent("Selected.csv")
        try await ProjectWindowController.writeOnScreenCSV(
            for: harness.document, core: harness.core, includeTrail: false, includeTrace: false,
            selection: [first.id.rawValue], formatName: "CSV", to: url
        )
        let confirmation = try #require(harness.core.document.warnings.first { $0.id == ExportCompletion.warningID })
        // Old: "2 rows as CSV." — the whole ledger's count for a one-row file.
        #expect(confirmation.message == ExportCompletion.message(rowCount: 1, formatName: "CSV"))

        let templated = harness.directory.appendingPathComponent("Template.csv")
        await harness.controller.writeProjectedExport(
            format: .csv, for: harness.document, core: harness.core, includeTrail: true,
            requestOverride: harness.core.ledger.request, to: templated
        ).value
        let text = try String(contentsOf: templated, encoding: .utf8)
        // Old: no trail section — the projected CSV writer never wrote one.
        #expect(text.contains("Audit Trail"), "\(text.prefix(400))")
        #expect(text.contains("Wall"))
    }

    // MARK: - R-045

    @Test("R-045: a second ⌘P while a print is being prepared is refused; the door opens again when the panel is answered")
    func onePrintAtATime() async throws {
        let harness = try await Fix2Harness.make("R045.pdf")
        defer { harness.tearDown() }
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { _ in .dismissed }
        defer { ZenitModalPresenter.reset() }
        harness.document.printDocument(nil)
        #expect(harness.document.isSaveActivityBusy, "the print holds the door from ⌘P on")
        harness.document.printDocument(nil)
        #expect(await AppTestSupport.wait { !harness.document.printActivityInFlight })
        let prints = ZenitModalPresenter.recorded.filter { $0.identifier == ZenitPDFProjectDocument.appKitPrintPanelModalIdentifier }
        // Old: 2 — the second ⌘P prepared and ran a second print operation.
        #expect(prints.count == 1)
        harness.document.printDocument(nil)
        #expect(await AppTestSupport.wait { !harness.document.printActivityInFlight })
        #expect(ZenitModalPresenter.recorded.filter { $0.identifier == ZenitPDFProjectDocument.appKitPrintPanelModalIdentifier }.count == 2,
                "a later ⌘P prints")
    }

    // MARK: - K-05

    @Test("K-05: a save writes thumbnails/package.png — the member the Quick Look extension reads — with the first sheet and its markups")
    func saveWritesThePackageThumbnail() async throws {
        let harness = try await Fix2Harness.make("K05.pdf")
        defer { harness.tearDown() }
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 72, y: 400), PDFPoint(x: 500, y: 400)])
        })
        let package = try await Iter1ShellGlueTests.saveAsProject(harness)
        let thumbnail = package.appendingPathComponent(ZenitPDFProjectDocument.packageThumbnailMember)
        // A test process does not write it by default (package-format tests list exact members).
        #expect(!FileManager.default.fileExists(atPath: thumbnail.path))
        let previous = ZenitPDFProjectDocument.writesPackageThumbnail
        ZenitPDFProjectDocument.writesPackageThumbnail = true
        defer { ZenitPDFProjectDocument.writesPackageThumbnail = previous }
        harness.document.updateChangeCount(.changeDone)
        try await Iter1ShellGlueTests.save(harness.document, to: package, .saveOperation)
        // Old: never written, so the extension always parsed the drawing and showed no markups.
        #expect(await AppTestSupport.wait { FileManager.default.fileExists(atPath: thumbnail.path) })
        let source = try #require(CGImageSourceCreateWithURL(thumbnail as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // 595 × 842 pt at 512 / 842 px per pt: 362 × 512.
        #expect(image.height == 512)
        #expect(image.width == 362)

        // The writer and the extension's reader name the same member.
        let reader = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("QuickLookThumbnail/Sources/ZenitQuickLookCore/PackageThumbnail.swift"),
            encoding: .utf8
        )
        #expect(reader.contains("storedImageMember = \"\(ZenitPDFProjectDocument.packageThumbnailMember)\""))
    }
}
