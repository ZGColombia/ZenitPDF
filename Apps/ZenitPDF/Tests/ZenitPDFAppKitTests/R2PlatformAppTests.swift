import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFExtensions
import ZPDFPersistence
import ZPDFSpreadsheet
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
import ZPDFVectorExtraction
@testable import ZenitPDFAppKit

/// Round 2, platform unit: the app tier of NL-PLAT-03/10/13/15/16/20/22/23 and NL-COLLAB-05.
/// Every panel, alert and share picker is answered by injection; nothing reaches the screen.
@MainActor
@Suite("r2-platform app tier", .appTierSerialised)
struct R2PlatformAppTests {

    static func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("r2-platform-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Job templates and export profiles in a scratch folder for the duration of `body`.
    static func withScratchStores<T>(_ body: (URL) async throws -> T) async throws -> T {
        let folder = try scratch("stores")
        let previousStore = ProjectWindowController.jobTemplateStore
        let previousProfiles = ExportProfileLibrary.standardDirectory
        // The person's tool library too: a template or pack applied here writes container-scoped presets,
        // and in the process-wide test container they leaked into every later suite's fresh library
        // (ToolPresetAndRevealWiringTests saw 14 presets where the 12 shipped ones were expected).
        let previousContainer = ZenitPDFProjectDocument.toolPresetContainerOverride
        ProjectWindowController.jobTemplateStore = { JobTemplateStore(directory: folder.appendingPathComponent("templates", isDirectory: true)) }
        ExportProfileLibrary.standardDirectory = { folder.appendingPathComponent("profiles", isDirectory: true) }
        ZenitPDFProjectDocument.toolPresetContainerOverride = ToolPresetContainerStore(
            directory: folder.appendingPathComponent("tools", isDirectory: true)
        )
        defer {
            ProjectWindowController.jobTemplateStore = previousStore
            ExportProfileLibrary.standardDirectory = previousProfiles
            ZenitPDFProjectDocument.toolPresetContainerOverride = previousContainer
            try? FileManager.default.removeItem(at: folder)
        }
        return try await body(folder)
    }

    static func toolSetData(name: String, presets: [ToolPresetSummary]) throws -> Data {
        try ToolSetDocument(name: name, author: "Office", exportedAt: Date(timeIntervalSince1970: 1_790_000_000), exporting: presets).jsonData()
    }

    static func preset(_ name: String, id: UUID = UUID()) -> ToolPresetSummary {
        ToolPresetSummary(id: id, name: name, category: "Finishes", panel: .myTools, markupKind: .measurement,
                          measurementKind: .area, colorRGBA: ColorRGBA.Zenit.Dark.cyan, defaultSubject: name)
    }

    // MARK: - NL-PLAT-03: Zenit's data files from Finder

    @Test("Every data file is recognised, and one opened with nothing in front says what to do — except a ledger export, which is reviewed alone")
    func dataFileRouting() async throws {
        for (name, kind) in [("a.zpdfoverlay", ZenitDataFileKind.overlay), ("b.zpdfprofile", .exportProfile), ("c.ZPDFTOOLS", .toolSet),
                             ("d.zpdftemplate", .jobTemplate), ("e.zpdfjson", .ledgerJSON), ("f.zpdfpack", .pack)] {
            #expect(ZenitDataFileKind.of(URL(fileURLWithPath: "/tmp/\(name)")) == kind)
        }
        #expect(ZenitDataFileKind.of(URL(fileURLWithPath: "/tmp/g.pdf")) == nil)
        #expect(ZenitDocumentController.openPanelContentTypes.count >= ZenitDataFileKind.allCases.count + 2)

        let previous = ZenitDocumentController.dataFileRouter
        defer { ZenitDocumentController.dataFileRouter = previous }
        var routed: [(ZenitDataFileKind, ZenitPDFProjectDocument?)] = []
        ZenitDocumentController.dataFileRouter = { kind, _, document in routed.append((kind, document)) }
        let controller = ZenitDocumentController()
        guard controller.documents.isEmpty, controller.currentDocument == nil else { return }
        var failure: NSError?
        controller.openDataFile(URL(fileURLWithPath: "/tmp/c.zpdftools"), release: nil) { _, _, error in failure = error as NSError? }
        #expect(failure?.localizedDescription == "“c.zpdftools” belongs to a drawing or project.")
        controller.openDataFile(URL(fileURLWithPath: "/tmp/e.zpdfjson"), release: nil) { _, _, _ in }
        #expect(await AppTestSupport.wait { routed.count == 1 })
        #expect(routed.first?.0 == .ledgerJSON && routed.first?.1 == nil)
    }

    @Test("A .zpdftools opened from Finder lands on the Tool Library's import review")
    func toolSetRoute() async throws {
        let harness = try await Fix2Harness.make("Tools.pdf")
        defer { harness.tearDown() }
        let url = harness.directory.appendingPathComponent("Office.zpdftools")
        try Self.toolSetData(name: "Office", presets: [Self.preset("Floor finish"), Self.preset("Wall paint")]).write(to: url)
        let model = try #require(await ZenitDataFileRoutes.reviewToolSet(url, document: harness.document))
        let review = try #require(model.importReview)
        #expect(review.setName == "Office")
        #expect(review.presets.map(\.name) == ["Floor finish", "Wall paint"])
    }

    @Test("A .zpdftemplate opened from Finder goes through the template import, same-name question and all")
    func templateRoute() async throws {
        try await Self.withScratchStores { _ in
            let harness = try await Fix2Harness.make("Template.pdf")
            defer { harness.tearDown() }
            let url = harness.directory.appendingPathComponent("Flooring.zpdftemplate")
            try JobTemplateFile.export(StarterJobTemplates.all[0]).write(to: url)
            await ZenitDataFileRoutes.importJobTemplate(url, document: harness.document)
            let stored = try await ProjectWindowController.jobTemplateStore().read() ?? []
            #expect(stored.map(\.name) == [StarterJobTemplates.all[0].name])
            // The same file again asks, and Keep Both keeps both.
            let previous = ProjectWindowController.templateImportConflictPrompt
            defer { ProjectWindowController.templateImportConflictPrompt = previous }
            var asked = false
            ProjectWindowController.templateImportConflictPrompt = { _, _ in asked = true; return .keepBoth }
            await ZenitDataFileRoutes.importJobTemplate(url, document: harness.document)
            #expect(asked)
            #expect(try await ProjectWindowController.jobTemplateStore().read()?.count == 2)
        }
    }

    @Test("A .zpdfjson opened from Finder is reviewed and reconciled against the ledger in front")
    func ledgerJSONRoute() async throws {
        let harness = try await Fix2Harness.make("Ledger.pdf")
        defer { harness.tearDown() }
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 125, y: 10)])
        }, subject: "Wall")
        await harness.settle()
        let ledger = try await ProjectWindowController.interchange(core: harness.core, documentName: "Ledger",
                                                                   scaleDescription: nil, request: harness.core.ledger.request)
        let url = harness.directory.appendingPathComponent("Ledger.zpdfjson")
        try ZenitJSONExporter().encode(ledger).write(to: url)
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }
        let outcome = try #require(await ZenitDataFileRoutes.reviewLedgerJSON(url, document: harness.document))
        #expect(outcome.reconciliation != nil, "held against the ledger on screen")
        #expect(ZenitModalPresenter.didRequest(ZenitJSONImport.reviewModalIdentifier))
    }

    // MARK: - NL-PLAT-10: Share Last Export…

    @Test("Share Last Export hands the exported file to the share picker, and says so when there is none or it moved")
    func shareLastExport() async throws {
        let harness = try await Fix2Harness.make("Share.pdf")
        defer { harness.tearDown() }
        let previous = ShareExport.sharingPresenter
        defer { ShareExport.sharingPresenter = previous }
        var shared: URL?
        ShareExport.sharingPresenter = { url, _ in shared = url }

        ShareExport.share(document: harness.document, window: nil)
        #expect(shared == nil)
        #expect(harness.core.document.warnings.contains { $0.id == ShareExport.noteID && $0.title == "Nothing exported yet" })

        let file = harness.directory.appendingPathComponent("Ledger.csv")
        try Data("a,b\n".utf8).write(to: file)
        harness.document.lastExportURL = file
        ShareExport.share(document: harness.document, window: nil)
        #expect(shared == file)

        try FileManager.default.removeItem(at: file)
        shared = nil
        ShareExport.share(document: harness.document, window: nil)
        #expect(shared == nil)
        #expect(ShareExport.target(for: harness.document) == .fileGone("Ledger.csv"))
    }

    // MARK: - NL-PLAT-22 and NL-PLAT-08: templates, starters, profiles inside them

    @Test("New from Template sets up tools, subjects and units from a starter, installs its export profiles, and never sets a scale")
    func newFromTemplate() async throws {
        try await Self.withScratchStores { _ in
            let harness = try await Fix2Harness.make("New.pdf", calibrate: false)
            defer { harness.tearDown() }
            var template = StarterJobTemplates.all[1]
            let profile = LedgerExportProfile(name: "Cost codes", columns: [.init(key: "subject")])
            template.exportProfiles = [JobTemplateAttachedFile(name: profile.name, json: String(decoding: try profile.encoded(), as: UTF8.self))]
            let receipt = try #require(await NewFromTemplate.apply(template, to: harness.document))
            #expect(receipt.appliedPresetCount == template.presets.count)
            #expect(harness.core.toolLibrary.presets.contains { $0.name == template.presets.first?.name })
            #expect(await harness.core.session.scale(onPage: try #require(await harness.core.session.firstPageID)) == nil, "a template never carries a scale")
            #expect(ExportProfileLibrary.standard().profiles().profiles.map(\.name) == ["Cost codes"])
            #expect(harness.core.document.warnings.contains { $0.id == NewFromTemplate.noteID })
            // The menu offers the starters after the person's own.
            #expect(await NewFromTemplate.templates().suffix(StarterJobTemplates.all.count).map(\.name) == StarterJobTemplates.all.map(\.name))
        }
    }

    @Test("Export with Profile offers the installed profiles by name; a template round trip carries them")
    func installedProfiles() async throws {
        try await Self.withScratchStores { _ in
            let library = ExportProfileLibrary.standard()
            var profile = LedgerExportProfile(name: "Estimating", columns: [.init(key: "subject"), .init(key: "planLength", decimals: 2, unit: "mm")])
            profile.grouping = .init(key: "subject")
            #expect(try library.install(profile) == false)
            #expect(try library.install(profile) == true, "the same name replaces")
            let attachments = ExportProfiles.templateAttachments(library: library)
            var template = JobTemplate(name: "Rig")
            template.exportProfiles = attachments
            let read = try JobTemplateFile.read(try JobTemplateFile.export(template))
            try FileManager.default.removeItem(at: library.directory)
            #expect(ExportProfiles.installProfiles(from: read, library: library).installed == ["Estimating"])
            #expect(library.profiles().profiles == [profile])
        }
    }

    // MARK: - NL-PLAT-23: packs

    @Test("A pack of a tool set, a template and a profile is reviewed, then installs each through its own importer")
    func packInstall() async throws {
        try await Self.withScratchStores { _ in
            let harness = try await Fix2Harness.make("Pack.pdf")
            defer { harness.tearDown() }
            let profile = LedgerExportProfile(name: "Office CSV", columns: [.init(key: "subject")])
            let data = try ZenitPack.write(manifest: .init(name: "Office", version: "2", author: "Estimating", items: [
                .init(path: "tools/Office.zpdftools", kind: .toolSet),
                .init(path: "templates/Flooring.zpdftemplate", kind: .jobTemplate),
                .init(path: "profiles/Office CSV.zpdfprofile", kind: .exportProfile),
            ]), files: [
                "tools/Office.zpdftools": try Self.toolSetData(name: "Office", presets: [Self.preset("Floor finish")]),
                "templates/Flooring.zpdftemplate": try JobTemplateFile.export(StarterJobTemplates.all[0]),
                "profiles/Office CSV.zpdfprofile": try profile.encoded(),
            ])
            let plan = try ZenitPackFlow.plan(data)
            let text = ZenitPackFlow.reviewText(plan)
            #expect(text.title == "Install the pack “Office” (version 2)?")
            #expect(text.body.contains("Nothing in it runs"))

            let url = harness.directory.appendingPathComponent("Office.zpdfpack")
            try data.write(to: url)
            ZenitModalPresenter.reset()
            defer { ZenitModalPresenter.reset() }
            ZenitModalPresenter.handler = { request in request.identifier == ZenitPackFlow.reviewIdentifier ? .button(0) : .dismissed }
            let installed = try #require(await ZenitPackFlow.review(url, window: nil, document: harness.document))
            #expect(installed.templates == [StarterJobTemplates.all[0].name])
            #expect(installed.profiles == ["Office CSV"])
            #expect(installed.toolSetsReviewed == 1)
            #expect(ToolChestPanel.open[ObjectIdentifier(harness.document)]?.model.importReview?.presets.map(\.name) == ["Floor finish"])
            ToolChestPanel.open[ObjectIdentifier(harness.document)]?.close()
        }
    }

    @Test("A pack with a script in it is refused whole, naming the file")
    func packWithScriptRefused() throws {
        var writer = ZipStoredWriter()
        try writer.add("pack.json", data: Data(#"{"format":"zenit-pack","formatVersion":1,"name":"X","version":"1","items":[{"path":"a.zpdftools","kind":"toolSet"}]}"#.utf8))
        try writer.add("a.zpdftools", data: Data("{}".utf8))
        try writer.add("run.command", data: Data("echo hi".utf8))
        #expect(throws: ZenitPackFlow.PlanError.pack(.notADataFile("run.command"))) { try ZenitPackFlow.plan(try writer.archive()) }
    }

    // MARK: - NL-PLAT-15: the office tool library

    @Test("A subscribed folder lists Office read-only; v2 of the file updates it in place with a change note; placed markups are untouched")
    func subscribedLibrary() async throws {
        let harness = try await Fix2Harness.make("Subscribed.pdf")
        defer { harness.tearDown() }
        let folder = try Self.scratch("office")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SubscribedToolLibrary()
        library.defaults = ZenitScratchDefaults()
        let floorID = UUID(), paintID = UUID()
        let file = folder.appendingPathComponent("Office.zpdftools")
        try Self.toolSetData(name: "Office", presets: [Self.preset("Floor finish", id: floorID), Self.preset("Wall paint", id: paintID)]).write(to: file)
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 125, y: 10)])
        }, subject: "Wall")
        await harness.settle()
        let placed = await harness.records()

        library.subscribe(to: folder)
        let first = try #require(library.refresh(harness.document))
        let subscribed = harness.core.toolLibrary.presets.filter(SubscribedToolLibrary.isSubscribed)
        #expect(subscribed.map(\.name).sorted() == ["Floor finish", "Wall paint"])
        #expect(subscribed.allSatisfy { $0.isReadOnly && $0.panel == .importedLibraries && $0.category == "Office (read-only)" })
        #expect(first.added.sorted() == ["Floor finish", "Wall paint"])
        let floorBefore = try #require(subscribed.first { $0.name == "Floor finish" }?.id)

        // v2: the paint tool is gone, a ceiling tool arrives, the floor tool keeps its identity.
        try Self.toolSetData(name: "Office", presets: [Self.preset("Floor finish", id: floorID), Self.preset("Ceiling")]).write(to: file)
        let second = try #require(library.refresh(harness.document))
        #expect(second.updated == ["Office"])
        #expect(second.added == ["Ceiling"])
        #expect(second.removed == ["Wall paint"])
        let now = harness.core.toolLibrary.presets.filter(SubscribedToolLibrary.isSubscribed)
        #expect(now.map(\.name).sorted() == ["Ceiling", "Floor finish"])
        #expect(now.first { $0.name == "Floor finish" }?.id == floorBefore, "an updated set replaces its own tools")
        #expect(harness.core.document.warnings.contains { $0.id == SubscribedToolLibrary.noteID })
        #expect(await harness.records() == placed, "placed markups never change")

        library.unsubscribe()
        library.refresh(harness.document)
        #expect(!harness.core.toolLibrary.presets.contains(where: SubscribedToolLibrary.isSubscribed))
    }

    // MARK: - NL-COLLAB-05 and NL-PLAT-13: Settings

    @Test("Settings ▸ Identity keeps the company and colour; the author directory signs replies with the company; the CLI line names the helper")
    func identitySettings() async throws {
        let folder = try Self.scratch("identity")
        let scratch = try #require(UserDefaults(suiteName: folder.appendingPathComponent("author").path))
        let previous = AuthorIdentity.defaults
        AuthorIdentity.defaults = scratch
        defer {
            AuthorIdentity.defaults = previous
            try? FileManager.default.removeItem(at: folder)
        }
        let panel = PlatformSettingsPanel()
        _ = panel.identityViews()
        panel.companyField.stringValue = "  North Build AB  "
        panel.companyCommitted(nil)
        #expect(AuthorIdentity.company() == "North Build AB")
        panel.colorPopUp.selectItem(at: 2)
        panel.colorChosen(nil)
        #expect(AuthorIdentity.colorHex() == PlatformSettingsPanel.colorChoices[1].hex)
        let id = AuthorIdentity.authorID()
        #expect(AuthorIdentity.authorID() == id, "made once and kept")

        let harness = try await Fix2Harness.make("Identity.pdf")
        defer { harness.tearDown() }
        let review = harness.core.review
        review.localAuthorProvider = { AppReviewPresenter.LocalAuthor(id: id, company: AuthorIdentity.company()) }
        guard review.isAttached else { return }   // a Quick PDF with no database keeps no directory
        let markup = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 125, y: 10)])
        })
        review.addReply("Checked", to: markup.id.rawValue)
        await review.settle()
        #expect(review.company(of: review.currentAuthor) == "North Build AB")
        #expect(review.signature(of: review.currentAuthor).hasSuffix(", North Build AB"))

        #expect(PlatformSettingsPanel.installCommand(appURL: URL(fileURLWithPath: "/Applications/Zenit PDF.app"))
                == "sudo ln -sf '/Applications/Zenit PDF.app/Contents/Helpers/zenit' /usr/local/bin/zenit")
    }

    // MARK: - NL-PLAT-20: the canvas to VoiceOver

    @Test("VoiceOver reads subject, label, quantity and sheet for every markup, and a press selects it")
    func canvasAccessibility() async throws {
        let harness = try await Fix2Harness.make("Voice.pdf")
        defer { harness.tearDown() }
        let markup = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 125, y: 10)])
        }, subject: "Wall")
        await harness.settle()
        harness.canvas.installMarkupAccessibility()
        harness.canvas.refresh()
        let elements = harness.canvas.pageViewForTesting.markupAccessibilityElements()
        let element = try #require(elements.first as? CanvasMarkupAccessibilityElement)
        let label = element.accessibilityLabel() ?? ""
        #expect(label.hasPrefix("Wall, "), "\(label)")
        // The quantity is written in the person's number format: a point or a comma.
        #expect(label.contains("1.25 m") || label.contains("1,25 m"), "the quantity: 125 pt at 100 pt/m is 1.25 m — \(label)")
        #expect(label.contains("sheet "), "\(label)")
        #expect(element.accessibilityPerformPress())
        #expect(harness.core.canvas.selectedMarkups.map(\.id) == [markup.id.rawValue])
    }

    // MARK: - NL-PLAT-11: AppleScript

    @Test("The dictionary is valid and names classes and handlers that exist; get totals and export ledger answer through the export path")
    func appleScript() async throws {
        let sdef = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Bundle/ZenitPDF.sdef")
        let xml = try XMLDocument(contentsOf: sdef, options: [])
        let classes = try xml.nodes(forXPath: "//cocoa/@class").compactMap(\.stringValue)
        #expect(classes.contains("ZenitPDFAppKit.ZenitPDFProjectDocument"))
        for name in classes { #expect(NSClassFromString(name) != nil, "no class \(name)") }
        for method in try xml.nodes(forXPath: "//responds-to/cocoa/@method").compactMap(\.stringValue) {
            #expect(ZenitPDFProjectDocument.instancesRespond(to: NSSelectorFromString(method)), "no handler \(method)")
        }
        for key in try xml.nodes(forXPath: "//class-extension//cocoa/@key").compactMap(\.stringValue) {
            #expect(ZenitPDFProjectDocument.instancesRespond(to: NSSelectorFromString(key)), "no property \(key)")
        }

        let harness = try await Fix2Harness.make("Script.pdf")
        defer { harness.tearDown() }
        _ = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 10), PDFPoint(x: 125, y: 10)])
        }, subject: "Wall")
        await harness.settle()
        #expect(harness.document.scriptPageCount == 1)
        #expect(harness.document.scriptLedgerRows.map(\.subject) == ["Wall"])
        #expect(harness.document.scriptLedgerRows.first?.quantity.replacingOccurrences(of: ",", with: ".") == "1.25")
        let totals = try await ZenitScripting.totals(document: harness.document)
        #expect(totals.replacingOccurrences(of: ",", with: ".").contains("1.25"), "\(totals)")
        let url = harness.directory.appendingPathComponent("Script.csv")
        _ = try await ZenitScripting.export(document: harness.document, to: url, format: .csv)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("Wall"))
        #expect(ZenitScripting.format(fromCode: ZenitScripting.fourCharCode("ZNfj")) == .json)
        await #expect(throws: ZenitScripting.ScriptError.self) { _ = try await ZenitScripting.applyTemplate(named: "No such rig", document: harness.document) }
    }

    // MARK: - NL-PLAT-16: synced folders

    @Test("Evicted members are downloaded before the open, one coordinated read each, with progress")
    func evictedMembers() async throws {
        let package = try Self.scratch("evicted").appendingPathComponent("Synced.zpdfproj", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("documents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        for member in ["manifest.json", "project.sqlite", "documents/working.pdf", "documents/original.pdf"] {
            try Data("x".utf8).write(to: package.appendingPathComponent(member))
        }
        let evicted: Set<String> = ["working.pdf", "project.sqlite"]
        let previous = SyncedFolderSafety.download
        defer { SyncedFolderSafety.download = previous }
        let downloads = ManagedCounter()
        SyncedFolderSafety.download = { url in await downloads.add(url.lastPathComponent); return true }
        var progress: [(Int, Int)] = []
        let failed = await SyncedFolderSafety.materialize(package, isEvicted: { evicted.contains($0.lastPathComponent) }, progress: { progress.append(($0, $1)) })
        #expect(failed.isEmpty)
        #expect(await downloads.names.sorted() == ["project.sqlite", "working.pdf"])
        #expect(progress.map(\.0) == [0, 1, 2] && progress.allSatisfy { $0.1 == 2 })
        #expect(!SyncedFolderSafety.isEvicted(package.appendingPathComponent("manifest.json")), "a real local file is not a placeholder")
    }

    @Test("A sync conflict offers the other copy as a separate copy to compare, never a merge")
    func conflictChoice() async throws {
        let folder = try Self.scratch("conflict")
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = folder.appendingPathComponent("Block C.zpdfproj", isDirectory: true)
        let sibling = folder.appendingPathComponent("Block C (Mac-B's conflicted copy).zpdfproj", isDirectory: true)
        for url in [package, sibling] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(url.lastPathComponent.utf8).write(to: url.appendingPathComponent("manifest.json"))
        }
        let copies = folder.appendingPathComponent("copies", isDirectory: true)
        let previousFolder = SyncedFolderSafety.otherCopiesFolder, previousOpener = SyncedFolderSafety.opener
        defer { SyncedFolderSafety.otherCopiesFolder = previousFolder; SyncedFolderSafety.opener = previousOpener }
        SyncedFolderSafety.otherCopiesFolder = { copies }
        var opened: URL?
        SyncedFolderSafety.opener = { opened = $0 }
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }
        ZenitModalPresenter.handler = { _ in .button(0) }
        let names = SyncConflictScannerNames.of(package)
        let choice = SharedStoragePrompt.offerConflictChoice(url: package, copyNames: names, unresolvedVersions: 0, packageName: package.lastPathComponent)
        #expect(choice == .openOtherCopy)
        let copy = try #require(opened)
        #expect(copy.lastPathComponent == "Block C (other version).zpdfproj")
        #expect(String(decoding: try Data(contentsOf: copy.appendingPathComponent("manifest.json")), as: UTF8.self) == sibling.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: sibling.path), "the sibling copy is never touched")
    }

    // MARK: - NL-AUTO-21: the layer a room was traced on

    @Test("The layer most of a ring's edges run along is the room's layer")
    func dominantLayer() {
        func line(_ id: UInt64, _ a: CGPoint, _ b: CGPoint, _ layer: String) -> VectorPrimitive {
            VectorPrimitive(id: id, parentID: nil, kind: .lineSegment, geometry: .line(VectorLine(start: a, end: b)),
                            bounds: VectorBounds(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y)),
                            sourceObjectID: id, subpathIndex: 0, nestingDepth: 0, paint: .stroked, strokeWidth: 1,
                            strokeIsDashed: false, clipRelation: .unclipped, clipBounds: nil, confidence: 1, layerID: layer)
        }
        let primitives = [
            line(1, CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), "A-FLOOR-FINI"),
            line(2, CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 200), "A-FLOOR-FINI"),
            line(3, CGPoint(x: 300, y: 200), CGPoint(x: 0, y: 200), "A-FLOOR-FINI"),
            line(4, CGPoint(x: 0, y: 200), CGPoint(x: 0, y: 0), "A-WALL"),
        ]
        let ring = [PDFPoint(x: 0, y: 0), PDFPoint(x: 300, y: 0), PDFPoint(x: 300, y: 200), PDFPoint(x: 0, y: 200)]
        #expect(ZenitPDFProjectDocument.dominantLayer(of: ring, in: primitives) == "A-FLOOR-FINI")
    }
}

/// Counts downloads across the `@Sendable` closure boundary.
actor ManagedCounter {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

/// The conflict copy names the open would report, through the persistence scanner.
enum SyncConflictScannerNames {
    static func of(_ url: URL) -> [String] {
        if case .copies(let names) = SyncConflictScanner.conflictCopies(besides: url) { return names }
        return []
    }
}
