import AppKit
import Foundation
import ImageIO
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// nl-ux proposals at the app tier. Nothing here orders a window, a panel or a sheet on screen:
/// every host checks `ZenitModalPresenter.canPresentModally`, which is false in a test process.
@MainActor
@Suite("nl-ux app proposals", .appTierSerialised)
struct NLUXAppProposalTests {

    // MARK: - NL-UX-05 command palette

    @Test("The palette over a real window lists shell and application commands, validated like the menu")
    func paletteRowsAreValidated() async throws {
        let harness = try await Fix2Harness.make("NLUX Palette.pdf")
        defer { harness.tearDown() }
        let model = try #require(harness.controller.makeCommandPaletteModel(for: harness.document))
        let ids = Set(harness.shell.commandPaletteItems().map(\.id))
        #expect(ids.contains("app:\(ZenitAppCommand.exportFlattenedPDF.rawValue)"))
        #expect(!ids.contains("app:\(ZenitAppCommand.commandPalette.rawValue)"), "the palette does not list itself")
        // Copy Snippet needs a selection: listed, and off.
        let snippet = try #require(harness.shell.commandPaletteItems().first { $0.id == "app:\(ZenitAppCommand.copySnippet.rawValue)" })
        #expect(!snippet.isEnabled)
        // Typing and Return arms the tool through the shell, as the menu would.
        model.query = "Area"
        #expect(model.performSelected())
        #expect(harness.shell.toolbar.activeTool == .area)
        // Presenting in a test process draws nothing.
        harness.controller.presentCommandPalette(for: harness.document)
        #expect(CommandPaletteHost.shared.panel?.isVisible != true)
        CommandPaletteHost.shared.dismiss()
    }

    // MARK: - NL-UX-11 shortcuts

    @Test("Application chords are reserved against rebinding, and a rebinding reaches the menu bar and reference")
    func shortcutsReachTheMenuBar() throws {
        let reserved = ZenitShortcutSettings.reservedChords
        #expect(reserved[ZPDFKeyBinding.character("p", [.command, .shift]).chord] != nil, "⇧⌘P is the palette's")
        let model = ZenitShortcutSettings.makeModel()
        defer {
            model.restoreAll()
            ZPDFCommandTable.effective = .standard
        }
        #expect(!model.assign(.character("p", [.command, .shift]), to: .toggleCoverageMap))
        #expect(model.assign(.character("j", [.command, .option]), to: .toggleCoverageMap))
        #expect(ZPDFCommandTable.effective.command(.toggleCoverageMap)?.binding?.displayString == "⌥⌘J")
        let bar = ZenitMenuBar.make()
        let row = bar.items.compactMap(\.submenu).flatMap(\.items).first {
            ($0.representedObject as? String) == ZPDFCommandID.toggleCoverageMap.rawValue
        }
        #expect(row?.keyEquivalent == "j")
        #expect(row?.keyEquivalentModifierMask == [.command, .option])
        let reference = KeyboardShortcutsReference.sections().flatMap(\.entries)
        #expect(reference.contains { $0.shortcut == "⌥⌘J" })
    }

    // MARK: - NL-UX-10 workspaces

    @Test("View ▸ Workspaces lists the saved workspaces on ⌃1–⌃4 and recalls one into a window")
    func workspaceMenu() async throws {
        let harness = try await Fix2Harness.make("NLUX Workspaces.pdf")
        defer { harness.tearDown() }
        let menuModel = ZenitWorkspaceMenu.shared.model
        for workspace in menuModel.workspaces { menuModel.delete(id: workspace.id) }
        defer { for workspace in menuModel.workspaces { menuModel.delete(id: workspace.id) } }

        let item = ZenitWorkspaceMenu.shared.makeMenuItem()
        let menu = try #require(item.submenu)
        let slots = (0..<4).compactMap { menu.item(withTag: ZenitWorkspaceMenu.slotTagBase + $0) }
        #expect(slots.map(\.keyEquivalent) == ["1", "2", "3", "4"])
        #expect(slots.allSatisfy { $0.keyEquivalentModifierMask == [.control] })
        #expect(!ZenitWorkspaceMenu.shared.validateMenuItem(slots[0]), "an empty slot is off")

        let layout = try #require(harness.shell.currentWorkspaceLayout())
        var review = layout
        review.isNavigatorCollapsed = true
        menuModel.save(name: "Review", layout: review)
        ZenitWorkspaceMenu.shared.refresh(menu)
        #expect(slots[0].title == "Review")
        #expect(ZenitWorkspaceMenu.shared.recall(slot: 0, in: harness.controller))
        #expect(!harness.shell.isSurfaceVisible(.navigator))
        // Save Current Workspace… in a process with no user saves nothing.
        ZenitWorkspaceMenu.shared.promptAndSave(in: harness.controller)
        #expect(menuModel.workspaces.count == 1)
        #expect(ZenitModalPresenter.didRequest(ZenitWorkspaceMenu.identifier))
    }

    // MARK: - NL-UX-13 onboarding

    @Test("Onboarding steps complete from real document events, and each step's button acts")
    func onboardingIsWired() async throws {
        let harness = try await Fix2Harness.make("NLUX Onboarding.pdf", calibrate: false)
        defer { harness.tearDown() }
        let controller = ZenitOnboardingController(store: InMemoryOnboardingProgressStore())
        controller.attach(document: harness.document, controller: harness.controller)
        #expect(controller.model.isComplete(.openDrawing), "a drawing is open")
        #expect(!controller.model.isComplete(.calibrateScale))
        #expect(controller.model.onPerformStep != nil, "the step buttons are wired")
        #expect(controller.panel == nil, "a test process never draws the card")

        // The Calibrate step's button runs Measure ▸ Calibrate Scale…, whatever that command
        // opens (the two-point pick, or the scale sheet since NL-MEASURE-01).
        controller.model.show(.calibrateScale)
        controller.model.performCurrentStep()
        #expect(harness.canvas.isCalibrating || harness.controller.window?.attachedSheet != nil
                || ZenitModalPresenter.recorded.contains { $0.identifier.lowercased().contains("scale") })
        if harness.canvas.isCalibrating { harness.canvas.endCalibration() }
        if let sheet = harness.controller.window?.attachedSheet { harness.controller.window?.endSheet(sheet) }

        _ = try await harness.core.commands.calibrate(
            page: try #require(await harness.core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        await harness.core.refresh()
        #expect(await AppTestSupport.wait { controller.model.isComplete(.calibrateScale) })

        // The Area step arms Area.
        controller.model.show(.firstMeasurement)
        controller.model.performCurrentStep()
        #expect(harness.shell.toolbar.activeTool == .area)

        #expect(ZenitOnboardingController.completedSteps(hasDrawing: true, hasScale: true, hasMeasurement: true, ledgerShowsRows: false)
                == [.openDrawing, .calibrateScale, .firstMeasurement])
    }

    // MARK: - NL-UX-04 drawing annotations

    /// A one-page drawing carrying two annotations of its own: a red Square and a blue Circle.
    static func annotatedPDF() -> Data {
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Annots [5 0 R 6 0 R] >>")
        let content = "2 w 50 50 m 550 50 l S"
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        objects.append("<< /Type /Annot /Subtype /Square /Rect [100 100 300 200] /C [1 0 0] /BS << /W 3 >> /T (Consultant) /Contents (Check this wall) >>")
        objects.append("<< /Type /Annot /Subtype /Circle /Rect [350 400 450 500] /C [0 0 1] /T (Consultant) >>")
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// NL-UX-04 acceptance: the drawing's annotations become selectable markups with their
    /// colour and width; the originals are hidden, not deleted; Undo restores the original state.
    /// Old output: nothing could select them — no command read the drawing's annotations at all.
    @Test("Make Drawing Annotations Editable adopts the drawing's marks as one undoable step")
    func adoptDrawingAnnotations() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-nlux-adopt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Consultant Markup.pdf")
        try Self.annotatedPDF().write(to: url)
        let harness = try await Fix2Harness.make("unused", calibrate: false, fixture: url)
        defer { harness.tearDown() }

        var reviewed: AnnotationImportPlan?
        let outcome = await DrawingAnnotationAdoption.run(document: harness.document, window: nil) { plan in
            reviewed = plan
            return true
        }
        #expect(outcome == .adopted(markups: 2))
        let plan = try #require(reviewed)
        #expect(Set(plan.newMarkups.map(\.kind)) == [.rectangle, .ellipse])
        let text = DrawingAnnotationAdoption.reviewText(plan)
        #expect(text.title.contains("2"))

        let markups = harness.core.snapshot.markups
        #expect(markups.count == 2)
        let square = try #require(markups.first { $0.kind == .rectangle })
        #expect(square.colorRGBA.red > 0.9 && square.colorRGBA.blue < 0.1)
        #expect(harness.document.adoptionTouchedIDs.count == 2)
        #expect(harness.document.undoManager?.undoActionName == "Make Annotations Editable")

        // The originals are bound to the hidden layer while their markups exist…
        let reading = try #require(harness.document.adoptionReading)
        let hidden = DrawingAnnotationAdoption.adoptedBindings(
            reading: reading, markupIDs: Set(markups.map(\.id)), touched: harness.document.adoptionTouchedIDs
        )
        #expect(hidden.count == 2)
        #expect(hidden.allSatisfy { $0.layerID == DrawingAnnotationAdoption.adoptedLayer })

        // …and released by the undo that removes them.
        harness.document.undoManager?.undo()
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.isEmpty })
        let released = DrawingAnnotationAdoption.adoptedBindings(
            reading: reading, markupIDs: [], touched: harness.document.adoptionTouchedIDs
        )
        #expect(released.allSatisfy { $0.layerID == DrawingAnnotationAdoption.releasedLayer })

        // Cancel in the review changes nothing.
        let cancelled = await DrawingAnnotationAdoption.run(document: harness.document, window: nil) { _ in false }
        #expect(cancelled == .cancelled)
        #expect(harness.core.snapshot.markups.isEmpty)
    }

    // MARK: - NL-UX-16 smart zoom

    @Test("Smart zoom: from fit to the smart level, from anywhere else back to fit")
    func smartZoomRule() {
        #expect(CanvasSmartZoom.step(currentZoom: 0.50, fitZoom: 0.50, target: 2) == .zoomIn(to: 2))
        #expect(CanvasSmartZoom.step(currentZoom: 0.505, fitZoom: 0.50, target: 2) == .zoomIn(to: 2))
        #expect(CanvasSmartZoom.step(currentZoom: 2.0, fitZoom: 0.50, target: 2) == .fit)
        // A fit already above the target still zooms in, by half again.
        #expect(CanvasSmartZoom.step(currentZoom: 3.0, fitZoom: 3.0, target: 2) == .zoomIn(to: 4.5))
    }

    // MARK: - NL-UX-18 services

    @Test("The Services entry opens the PDFs it is handed and refuses anything else")
    func servicesProvider() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-nlux-services-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("Sheet.pdf")
        let text = directory.appendingPathComponent("Notes.txt")
        try Self.annotatedPDF().write(to: pdf)
        try Data("x".utf8).write(to: text)

        // A privately named board, released at the end — never the general clipboard, which is
        // the user's (SharedTestStateTests).
        let servicesBoard = NSPasteboard.withUniqueName()
        defer { servicesBoard.releaseGlobally() }
        servicesBoard.clearContents()
        servicesBoard.writeObjects([pdf as NSURL, text as NSURL])

        let provider = ZenitServicesProvider()
        var opened: [URL] = []
        provider.openURLs = { opened.append(contentsOf: $0) }
        var error: NSString?
        provider.openAsQuickTakeoff(servicesBoard, userData: nil, error: &error)
        #expect(opened.map(\.lastPathComponent) == ["Sheet.pdf"])
        #expect(error == nil)

        servicesBoard.clearContents()
        servicesBoard.writeObjects([text as NSURL])
        opened = []
        provider.openAsQuickTakeoff(servicesBoard, userData: nil, error: &error)
        #expect(opened.isEmpty)
        #expect(error != nil)
    }

    @Test("Info.plist declares the Services entry the provider answers")
    func servicesDeclared() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Bundle/Info.plist.in")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let services = try #require(plist["NSServices"] as? [[String: Any]])
        #expect(services.first?["NSMessage"] as? String == "openAsQuickTakeoff")
        #expect(ZenitServicesProvider.instancesRespond(to: NSSelectorFromString("openAsQuickTakeoff:userData:error:")))
    }

    // MARK: - NL-UX-19 units

    @Test("The Unit menu's choices map onto consistent display units")
    func unitMenuMapping() {
        let metric = DisplayUnitSelection.metric
        let imperial = OutputUnitsMenu.units(applying: .imperial, to: metric)
        #expect(imperial.length == .foot && imperial.area == .squareFoot)
        let mm = OutputUnitsMenu.units(applying: .length(.millimetre), to: metric)
        #expect(mm.length == .millimetre && mm.area == .squareMetre)
        let feetFromMetric = OutputUnitsMenu.units(applying: .length(.foot), to: metric)
        #expect(feetFromMetric.area == .squareFoot, "no ft beside m²")
        #expect(OutputUnitsMenu.units(applying: .metric, to: imperial).length == .metre)
    }

    // MARK: - NL-UX-07 selection power

    @Test("Select Same Subject / Kind stay on the page and skip hidden markups; Select All in Document spans pages")
    func selectSimilar() throws {
        var markups = ZenitSampleProject.shared.markups.map { markup -> MarkupSummary in
            var copy = markup
            copy.hidden = false
            return copy
        }
        try #require(markups.count >= 3)
        let first = markups[0]
        markups[0].subject = markups[0].subject.isEmpty ? "Door" : markups[0].subject
        let subject = markups[0].subject
        // A hidden markup with the same subject on the same page, and one on another page.
        markups[1].subject = subject
        markups[1].pageID = first.pageID
        markups[1].hidden = true
        markups[2].subject = subject
        markups[2].pageID = UUID()
        let hiddenTwin = markups[1]
        let otherPageTwin = markups[2]

        let sameSubject = SelectSimilar.matches(in: markups, selected: [first.id], criterion: .subject, scope: .page(first.pageID), filterHidden: [])
        #expect(sameSubject.contains(first.id))
        #expect(!sameSubject.contains(hiddenTwin.id))
        #expect(!sameSubject.contains(otherPageTwin.id))
        #expect(sameSubject.allSatisfy { id in markups.first { $0.id == id }?.subject == subject })

        let everywhere = SelectSimilar.matches(in: markups, selected: [], criterion: .any, scope: .document, filterHidden: [])
        #expect(everywhere.contains(otherPageTwin.id))
        #expect(!everywhere.contains(hiddenTwin.id))
    }

    // MARK: - NL-UX-08 copy and paste style

    @Test("Copy Style from one markup and Paste Style onto another: one undo step, the look carried whole")
    func copyAndPasteStyle() async throws {
        let harness = try await Fix2Harness.make("NLUX Style.pdf")
        defer { harness.tearDown() }
        let source = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }
        let target = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 300), PDFPoint(x: 300, y: 300)])
        }
        // Give the source a distinctive look.
        let red = ColorRGBA(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        _ = await harness.core.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [source.id.rawValue], style: MarkupStyleEdit(color: red, lineWidth: 4, opacity: 0.5)
        ))
        await harness.core.refresh()

        harness.core.canvas.select(markupIDs: [source.id.rawValue], additive: false)
        #expect(StyleClipboard.copy(from: harness.core))
        harness.core.canvas.select(markupIDs: [target.id.rawValue], additive: false)
        let receipt = try #require(await StyleClipboard.paste(into: harness.core))
        #expect(!receipt.didFail, "\(receipt.failureDescription ?? "")")
        await harness.core.refresh()
        let pasted = try #require(harness.core.snapshot.markups.first { $0.id == target.id.rawValue })
        #expect(abs(pasted.colorRGBA.red - 0.9) < 0.01)
        #expect(pasted.lineWidth == 4)
        #expect(pasted.opacity == 0.5)
        // nl-markup (NL-MARKUP-09): the step is named for the verb, "Paste Style".
        #expect(harness.document.undoManager?.undoActionName == "Paste Style")
        // Copy needs exactly one markup.
        harness.core.canvas.select(markupIDs: [source.id.rawValue, target.id.rawValue], additive: false)
        #expect(!StyleClipboard.copy(from: harness.core))
    }

    // MARK: - NL-UX-17 Finder thumbnail

    @Test("The package thumbnail is written where Finder and Quick Look look for it")
    func finderThumbnail() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-nlux-ql-\(UUID().uuidString).zpdfproj", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let context = try #require(CGContext(
            data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(context.makeImage())
        #expect(ZenitPDFProjectDocument.writeThumbnail(image, into: package))
        let written = package.appendingPathComponent("QuickLook/Thumbnail.png")
        let source = try #require(CGImageSourceCreateWithURL(written as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 64 && decoded.height == 48)
    }

    // MARK: - A palette that knows the quantities

    /// Two 2 m lengths filed as "Kerb" (calibrated 100 pt = 1 m, so 200 pt = 2 m each; 4 m in
    /// all, derived by hand). The palette row carries the ledger's own subtotal and selects both.
    @Test("Typing a subject finds its ledger subtotal, and Return selects every markup of it")
    func paletteKnowsTheQuantities() async throws {
        let harness = try await Fix2Harness.make("NLUX Quantities.pdf")
        defer { harness.tearDown() }
        let a = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }, subject: "Kerb")
        let b = try await harness.addMarkup(tool: .length, geometry: { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 300), PDFPoint(x: 300, y: 300)])
        }, subject: "Kerb")
        let totals = await PaletteQuantities.subjectTotals(core: harness.core)
        let kerb = try #require(totals.first { $0.subject == "Kerb" })
        #expect(kerb.markupCount == 2)
        let text = try #require(kerb.totalText)
        #expect(text.contains("4"), "the subtotal reads 4 m, got \(text)")

        let row = try #require(PaletteQuantities.rows(totals, core: harness.core).first { $0.title == "Kerb" })
        #expect(row.detail.contains(text))
        row.perform()
        #expect(harness.core.canvas.selectedMarkupIDs == [a.id.rawValue, b.id.rawValue])
    }
}
