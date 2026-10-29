import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Three joins a wiring review found open: a page-text search hit that did not scroll, the
/// `ToolPreset` seam, and the Split Canvas panes.
///
/// Every test here drives the **shipping** objects — `ZenitPDFProjectDocument`,
/// `ProjectWindowController`, the real `AppToolLibraryPresenter`, the real
/// `ToolLibraryEditingModel` the panel builds, the real `tool_preset` table. That is not
/// ceremony: all three defects were *hooks nobody assigned*, and a test that assigns the hook
/// itself and then checks the hook fired would have passed happily against every one of them.
/// So each test below reaches the hook only through the object the product builds.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct ToolPresetAndRevealWiringTests {

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    // MARK: - Fixtures

    /// A one-page PDF with a real text layer, so the search index has something true to find.
    ///
    /// Written here rather than borrowed from `SearchAndOCRWiringTests`: that file may be
    /// edited by another workstream at the same time, and two workstreams editing one file is
    /// exactly the hazard to avoid.
    private func writeTextFixturePDF(
        text: String = "PARAPET FLASHING RUN 12",
        named name: String = "Reveal R-301.pdf"
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-reveal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)

        // The word sits low on a tall page, so a reveal that works is unmistakable: the canvas
        // opens fitted to the whole sheet and has to zoom in on a line of 18 pt type.
        let content = Data("BT /F1 18 Tf 72 120 Td (\(text)) Tj ET\n".utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("""
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R \
            /Resources << /Font << /F1 5 0 R >> >> >>
            """.utf8)
        ]
        var streamData = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        streamData.append(content)
        streamData.append(Data("\nendstream".utf8))
        objects.append(streamData)
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8))

        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data("""
        trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n
        """.utf8))
        try bytes.write(to: url)
        return url
    }

    /// A scratch container for the search index, so no test writes into the real container.
    private func withScratchIndexRoot<T>(_ body: () async throws -> T) async rethrows -> T {
        let previous = ZenitPDFProjectDocument.searchIndexRootOverride
        ZenitPDFProjectDocument.searchIndexRootOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-reveal-index-\(UUID().uuidString)", isDirectory: true)
        defer { ZenitPDFProjectDocument.searchIndexRootOverride = previous }
        return try await body()
    }

    /// One preset with everything a preset can carry, so a round trip that drops a field fails.
    private func concreteSlabPreset(
        id: UUID = UUID(),
        panel: ToolLibraryPanel = .projectTools,
        name: String = "Concrete Slab 150"
    ) -> ToolPresetSummary {
        ToolPresetSummary(
            id: id,
            schemaVersion: 1,
            name: name,
            category: "Concrete",
            panel: panel,
            markupKind: .measurement,
            measurementKind: .volume,
            colorRGBA: ColorRGBA(red: 0.9, green: 0.4, blue: 0.1, alpha: 1),
            defaultSubject: "Slab on grade",
            defaultDepth: .metres(Decimal(string: "0.15") ?? 0),
            displayLengthUnit: .metre,
            customDefaults: ["cost-code": "03-30-00"],
            isFavorite: true,
            shortcutDisplayString: "⌥1",
            sortIndex: 3
        )
    }

    private func saveAsProject(_ document: ZenitPDFProjectDocument, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(
                to: destination,
                ofType: ZenitAppInfo.projectTypeIdentifier,
                for: .saveAsOperation
            ) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// Opens a document into a real `ProjectWindowController` and waits for the layout.
    @discardableResult
    private func openWindow(
        on url: URL
    ) async throws -> (document: ZenitPDFProjectDocument, controller: ProjectWindowController) {
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await wait { controller.contentViewController is ProjectWindowLayoutController })
        #expect(await wait { document.core != nil && document.shell != nil })
        // The canvas needs a laid-out scroll view before "fit this rectangle" means anything.
        controller.window?.layoutIfNeeded()
        return (document, controller)
    }

    // MARK: - 1. A page-text hit scrolls the canvas

    @Test("A search hit that is page text, not a markup, moves the canvas to the word")
    func pageTextSearchHitRevealsTheWord() async throws {
        try await withScratchIndexRoot {
            let url = try writeTextFixturePDF()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let (document, _) = try await openWindow(on: url)
            defer { document.close() }

            let core = try #require(document.core)
            #expect(await wait { document.searchIndex != nil })
            await document.settleTextIndexing()

            // The join itself. `AppCanvasPresenter` calls this property from two places and
            // nothing in the repository assigned it, so both calls were no-ops.
            #expect(core.canvas.onScrollTo != nil, "nothing installed onScrollTo")

            let presenter = try #require(document.searchPresenter as? AppSearchPresenter)
            presenter.debounce = .milliseconds(1)
            presenter.query = "PARAPET"
            presenter.runSearch()
            #expect(await wait(upTo: 20) { !presenter.isSearching && !presenter.hits.isEmpty })

            let hit = try #require(presenter.hits.first)
            #expect(hit.markupID == nil, "this test is about the page-text branch")
            let bounds = try #require(hit.boundsInPageSpace)

            let zoomBefore = core.canvas.viewport.zoom
            // Through the shipping reveal closure the document installs on the presenter —
            // the same call the Search panel makes when a result is clicked.
            let reveal = try #require(presenter.onReveal)
            reveal(hit)

            // Revealing a word must **not** touch the zoom. A search hit on a short word used to
            // magnify the canvas to roughly 500 %, because fitting a word-sized rect to a viewport is an enormous zoom. This
            // test previously asserted the opposite — `zoom > zoomBefore` — and so pinned the
            // defect in place. Zoom belongs to the reader; a search result does not take it.
            #expect(
                core.canvas.viewport.zoom == zoomBefore,
                "revealing a word changed the zoom: \(zoomBefore) → \(core.canvas.viewport.zoom)"
            )
            // And it landed on the word rather than on some other part of the sheet.
            let visible = core.canvas.viewport.visiblePageRect
            let centreY = bounds.minY + bounds.size.height / 2
            #expect(
                visible.size.height == 0 || (centreY >= visible.minY && centreY <= visible.minY + visible.size.height),
                "the hit at y=\(centreY) is outside the visible rect \(visible)"
            )
            // …and it is marked out, which is what replaced the zoom as the way a reader is
            // shown where the word is.
            let canvasController = try #require(
                document.windowControllers
                    .compactMap { $0 as? ProjectWindowController }
                    .compactMap { $0.canvasController(for: document) }
                    .first,
                "no canvas controller"
            )
            #expect(
                canvasController.searchHighlightsForTesting.count == 1,
                "the found word was not highlighted"
            )
        }
    }

    /// The presets a person made, with the shipped set filtered out by identity.
    ///
    /// By identity rather than by name, because an estimator is free to rename a built-in and a
    /// test that filtered by name would then stop seeing it.
    static func userPresets(_ presets: [ToolPresetSummary]) -> [ToolPresetSummary] {
        let builtIn = Set(DefaultToolSet.shipped.map(\.id))
        return presets.filter { !builtIn.contains($0.id) }
    }

    // MARK: - 2. A preset is real, persistent and armable

    @Test("A preset written into a project package comes back out of it whole")
    func aPresetSurvivesSaveAndReopen() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Presets P.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)
        // A fresh library is not empty any more: it opens with the six shipped presets
        // (`DefaultToolSet`). What this test is about is a preset the
        // *person* made, so the built-ins are filtered out rather than asserted away.
        #expect(Self.userPresets(core.toolLibrary.presets).isEmpty)
        #expect(core.toolLibrary.presets.count == DefaultToolSet.shipped.count)

        let preset = concreteSlabPreset()
        document.applyToolPresets([preset])
        #expect(Self.userPresets(core.toolLibrary.presets).count == 1)

        let destination = directory.appendingPathComponent("Presets.zpdfproj")
        try await saveAsProject(document, to: destination)
        document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()

        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: destination, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        #expect(await wait { reopened.core != nil && !reopened.isLoading })
        defer { reopened.close() }
        let restored = try #require(reopened.core)
        #expect(reopened.loadFailure == nil)

        // Every field, not just the name: `defaults_json` is where a silent drop would hide.
        let stored = try #require(Self.userPresets(restored.toolLibrary.presets).first)
        #expect(Self.userPresets(restored.toolLibrary.presets).count == 1)
        #expect(stored == preset, "the round trip changed the preset: \(stored)")
    }

    /// The shipped set must not make a drawing dirty before anybody draws.
    ///
    /// Seeding writes six presets into the *person's* container at open. When that write also
    /// called `updateChangeCount(.changeDone)`, a freshly opened PDF was already edited, so
    /// closing it asked "save your takeoff?" for a takeoff that did not exist — and in a test
    /// process that question is `NSAlert.runModal` with nobody to answer, which hung
    /// `build-app-package.sh` for ever in `TabbedWindowTests.closingATabKeepsTheWindow`.
    ///
    /// The three assertions are the whole rule: a container write is not a document change, a
    /// project write is, and a container write after a project write is still not.
    @Test("Seeding the shipped set leaves the document clean; only a project preset dirties it")
    func seedingTheShippedSetDoesNotDirtyTheDocument() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-seed-clean-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let container = ToolPresetContainerStore(directory: scratch)
        ZenitPDFProjectDocument.toolPresetContainerOverride = container
        defer { ZenitPDFProjectDocument.toolPresetContainerOverride = nil }

        let url = try AppTestSupport.writeFixturePDF(named: "Clean C.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)

        // The container really was empty, so the seeding write really did happen — otherwise
        // this test would pass by never exercising the path it is about.
        #expect(core.toolLibrary.presets.count == DefaultToolSet.shipped.count)
        var seededOnDisk: [ToolPresetSummary] = []
        for _ in 0..<200 {
            seededOnDisk = ((try? await container.read()) ?? [])?.map { $0 } ?? []
            if seededOnDisk.count == DefaultToolSet.shipped.count { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            seededOnDisk.count == DefaultToolSet.shipped.count,
            "the seeding write never happened, so this test proves nothing"
        )

        #expect(
            document.isDocumentEdited == false,
            "seeding the person's library marked the drawing edited"
        )

        // A preset that travels inside the `.zpdfproj` is a change to the project, and must say so.
        let projectPreset = concreteSlabPreset(panel: .projectTools, name: "Cost code 03-30-00")
        document.applyToolPresets(core.toolLibrary.presets + [projectPreset])
        #expect(document.isDocumentEdited, "a project-scoped preset is a document change")

        // And a personal one, added afterwards, still is not.
        document.updateChangeCount(.changeCleared)
        let personalPreset = concreteSlabPreset(panel: .myTools, name: "Discipline standard")
        document.applyToolPresets(core.toolLibrary.presets + [personalPreset])
        #expect(
            document.isDocumentEdited == false,
            "starring or adding a personal preset marked the drawing edited"
        )
    }

    @Test("The Tool Library panel's edits reach the presenter and the package")
    func theToolLibraryPanelPersistsWhatItEdits() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Presets Q.pdf")
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        let (document, controller) = try await openWindow(on: url)
        let core = try #require(document.core)

        // Save as a project first, so there is a package for the panel's edit to land in.
        let destination = directory.appendingPathComponent("Panel.zpdfproj")
        try await saveAsProject(document, to: destination)

        // The shipping panel, built by the shipping window controller.
        let sheet = try #require(controller.presentToolLibrary(for: document))
        defer {
            controller.window?.endSheet(sheet.window)
            document.close()
        }
        #expect(sheet.model.onChange != nil, "the panel's change stream is still unassigned")

        // Create a preset the way the panel does: open a draft, fill it, save it.
        sheet.model.beginCreating(in: .projectTools, category: "Steel")
        sheet.model.draft?.name = "Steel Stud Run"
        sheet.model.draft?.measurementKind = .polylength
        sheet.model.draft?.defaultSubject = "Stud track"
        sheet.model.commitDraft()

        // The presenter — the object that arms the canvas — has it immediately.
        #expect(Self.userPresets(core.toolLibrary.presets).map(\.name) == ["Steel Stud Run"])

        // And so does the package, read back through the archive rather than through the
        // presenter that just wrote it.
        let package = try #require(document.projectPackage)
        var storedNames: [String] = []
        for _ in 0..<200 {
            storedNames = (try? await ToolPresetArchive.read(from: package))?.map(\.name) ?? []
            if !storedNames.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(storedNames == ["Steel Stud Run"], "the tool_preset table never saw the edit")

        // A delete goes the same way, and does not leave the row behind.
        let created = try #require(Self.userPresets(core.toolLibrary.presets).first)
        sheet.model.delete(id: created.id)
        #expect(Self.userPresets(core.toolLibrary.presets).isEmpty)
        var remaining = ["placeholder"]
        for _ in 0..<200 {
            remaining = (try? await ToolPresetArchive.read(from: package))?.map(\.name) ?? []
            if remaining.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(remaining.isEmpty, "the deleted preset is still in the package: \(remaining)")
    }

    @Test("Selecting a preset arms the canvas with its tool, its ink and its saved depth")
    func armingAPresetArmsTheMeasurementTool() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Presets R.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)

        let preset = concreteSlabPreset()
        document.applyToolPresets([preset])
        core.toolLibrary.activatePreset(id: preset.id)

        #expect(core.measurement.activeKind == .volume)
        #expect(core.markup.activeKind == nil)
        #expect(core.measurement.defaultSubject == "Slab on grade")
        #expect(core.measurement.color == RGBAColor(shown: preset.colorRGBA))
        // The point of carrying the depth: Volume refuses to commit without one, so
        // a preset that armed the tool and dropped its depth armed a tool that
        // could not be used.
        #expect(core.measurement.parameterValue == Decimal(string: "0.15"))
        #expect(core.measurement.isMissingRequiredParameter == false)
        #expect(core.measurement.parameterText == "0.15")

        // Disarming puts both families down.
        core.toolLibrary.clearActivePreset()
        #expect(core.measurement.activeKind == nil)
        #expect(core.markup.activeKind == nil)
    }

    @Test("A non-measuring preset arms the markup tool, with the preset's ink")
    func armingAMarkupPresetArmsTheMarkupTool() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Presets S.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await wait { document.core != nil })
        let core = try #require(document.core)

        let ink = ColorRGBA(red: 0.1, green: 0.8, blue: 0.3, alpha: 1)
        let preset = ToolPresetSummary(
            id: UUID(),
            name: "RFI Callout",
            category: "Queries",
            panel: .myTools,
            markupKind: .callout,
            measurementKind: nil,
            colorRGBA: ink,
            defaultSubject: "RFI"
        )
        document.applyToolPresets([preset])
        core.toolLibrary.activatePreset(id: preset.id)

        #expect(core.markup.activeKind == .callout)
        #expect(core.measurement.activeKind == nil)
        #expect(core.markup.style.stroke == ink)
        #expect(core.markup.defaultSubject == "RFI")
    }

    // MARK: - 3. The Split Canvas panes carry the document

    @Test("Split Canvas shows the real document, page and zoom, and Escape gives the view back")
    func splitCanvasPanesCarryTheDocument() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Split T.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (document, _) = try await openWindow(on: url)
        defer { document.close() }
        let core = try #require(document.core)
        let shell = try #require(document.shell)

        // A viewport worth restoring: a zoom nobody would land on by accident.
        core.canvas.setZoom(2.75)
        let zoomBefore = core.canvas.viewport.zoom
        let rectBefore = core.canvas.viewport.visiblePageRect

        shell.perform(.splitCanvas)
        #expect(shell.canvasModes.activeMode == .splitCanvas)
        // The fill is deferred onto the main actor so it runs after the mode finished opening.
        #expect(
            await wait(upTo: 20) { !shell.splitCanvas.pane(.first).isEmpty },
            "pane 1 is still the placeholder"
        )

        let pane = shell.splitCanvas.pane(.first)
        #expect(pane.documentID == document.documentIdentity)
        #expect(pane.documentTitle == (document.displayName ?? ""))
        #expect(pane.documentTitle.isEmpty == false)
        #expect(pane.pageID == core.canvas.viewport.pageID)
        #expect(pane.zoom == zoomBefore)

        // The sync toggles are real state on the controller the pane header switches.
        shell.splitCanvas.setLayout(.twoColumns)
        shell.splitCanvas.syncOptions = .locked
        shell.splitCanvas.setZoom(1.5, in: .first)
        #expect(shell.splitCanvas.pane(.second).zoom == 1.5, "zoom sync did not mirror")
        shell.splitCanvas.syncOptions = .independent
        shell.splitCanvas.setZoom(3.0, in: .first)
        #expect(shell.splitCanvas.pane(.second).zoom == 1.5, "independent panes still mirrored")

        // Moving the focused pane moved the canvas behind it — which is what makes the
        // restore below a real assertion rather than a tautology about an untouched view.
        #expect(core.canvas.viewport.zoom == 3.0)

        // No dead ends: Escape leaves, and the canvas comes back exactly as it was.
        shell.perform(.cancelTool)
        #expect(shell.canvasModes.activeMode == nil)
        #expect(core.canvas.viewport.zoom == zoomBefore, "Escape did not restore the zoom")
        _ = rectBefore
    }
}
