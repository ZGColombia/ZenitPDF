import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Split Canvas: the layout, the focus path, and the rule that a follower never re-broadcasts.
@Suite("Split Canvas", .workflowsTierSerialised)
@MainActor
struct SplitCanvasControllerTests {

    private func page(_ index: Int, label: String) -> PageDescriptor {
        PageDescriptor(
            id: UUID(),
            index: index,
            label: label,
            mediaBox: PDFRectValue(x: 0, y: 0, width: 842, height: 595),
            cropBox: PDFRectValue(x: 0, y: 0, width: 842, height: 595),
            rotation: .degrees0
        )
    }

    @Test("Each layout shows the number of panes its name promises")
    func paneCounts() {
        #expect(SplitCanvasLayout.single.paneCount == 1)
        #expect(SplitCanvasLayout.twoColumns.paneCount == 2)
        #expect(SplitCanvasLayout.twoRows.paneCount == 2)
        #expect(SplitCanvasLayout.grid.paneCount == 4)
        #expect(SplitCanvasLayout.twoColumns.columnCount == 2)
        #expect(SplitCanvasLayout.twoRows.columnCount == 1)
    }

    @Test("Focus never disappears when the layout shrinks")
    func focusFollowsTheLayout() {
        let controller = SplitCanvasController(layout: .grid)
        controller.focusPane(.fourth)
        #expect(controller.focusedPaneID == .fourth)
        controller.setLayout(.twoColumns)
        #expect(controller.focusedPaneID == .first)
    }

    @Test("Keyboard pane switching wraps within the visible panes only")
    func focusWraps() {
        let controller = SplitCanvasController(layout: .twoColumns)
        controller.focusNextPane()
        #expect(controller.focusedPaneID == .second)
        controller.focusNextPane()
        #expect(controller.focusedPaneID == .first)
        controller.focusPreviousPane()
        #expect(controller.focusedPaneID == .second)
    }

    @Test("Zoom sync mirrors from the pane being touched and nowhere else")
    func zoomSyncIsOneDirectional() {
        var notified: [SplitCanvasPaneID] = []
        let controller = SplitCanvasController(layout: .grid, syncOptions: .locked)
        controller.onPaneChange = { notified.append($0.id) }
        controller.setZoom(2.5, in: .second)
        #expect(controller.pane(.first).zoom == 2.5)
        #expect(controller.pane(.fourth).zoom == 2.5)
        // Four panes changed exactly once each: no follower re-broadcast.
        #expect(notified.count == 4)
    }

    @Test("Turning sync off leaves the other panes alone")
    func independentPanes() {
        let controller = SplitCanvasController(layout: .twoColumns, syncOptions: .independent)
        controller.setZoom(3, in: .first)
        #expect(controller.pane(.first).zoom == 3)
        #expect(controller.pane(.second).zoom == 1)
    }

    @Test("Zoom is clamped to what the canvas can actually draw")
    func zoomIsClamped() {
        let controller = SplitCanvasController(layout: .single)
        controller.setZoom(10_000, in: .first)
        #expect(controller.pane(.first).zoom == ViewportSnapshot.maximumZoom)
        controller.setZoom(0, in: .first)
        #expect(controller.pane(.first).zoom == ViewportSnapshot.minimumZoom)
    }

    @Test("Page sync mirrors position, and identity only within the same document")
    func pageSyncRespectsDocumentIdentity() {
        let documentA = UUID()
        let documentB = UUID()
        let controller = SplitCanvasController(layout: .twoColumns, syncOptions: .locked)
        let pageA = page(3, label: "A-104")
        controller.setContent(documentID: documentA, documentTitle: "Rev A", page: pageA, in: .first)
        controller.setContent(documentID: documentB, documentTitle: "Rev B", page: page(0, label: "B-101"), in: .second)

        // BH-311: a follower on another document moves to its own page at that position, found
        // through the host's lookup — never to the other document's label over its own page.
        let pageB4 = page(3, label: "B-104")
        controller.pageAtIndex = { document, index in document == documentB && index == 3 ? pageB4 : nil }
        controller.setPage(pageA, in: .first)
        #expect(controller.pane(.second).pageIndex == 3)
        #expect(controller.pane(.second).pageID != pageA.id)
        #expect(controller.pane(.second).pageID == pageB4.id)
        #expect(controller.pane(.second).pageLabel == "B-104")
    }
}

/// Manual alignment: the arithmetic, and the refusal to pretend an exact fit means anything.
@Suite("Revision alignment", .workflowsTierSerialised)
struct RevisionAlignmentTests {

    private func pair(_ bx: Double, _ by: Double, _ cx: Double, _ cy: Double) -> RevisionAlignmentPointPair {
        RevisionAlignmentPointPair(
            baselinePoint: PDFPointValue(x: bx, y: by),
            comparisonPoint: PDFPointValue(x: cx, y: cy)
        )
    }

    @Test("Two points determine a similarity exactly")
    func twoPointFitIsExact() throws {
        // Comparison space is the baseline scaled by 2 and shifted by (10, 5).
        let pairs = [pair(10, 5, 0, 0), pair(210, 5, 100, 0)]
        let fit = try RevisionAlignmentSolver.fit(pairs: pairs, mode: .twoPoint).get()
        #expect(abs(fit.transform.scale - 2) < 1e-9)
        #expect(abs(fit.transform.tx - 10) < 1e-9)
        #expect(abs(fit.transform.ty - 5) < 1e-9)
        #expect(fit.residualRMSPoints < 1e-9)
        #expect(fit.isExactlyDetermined)
        #expect(fit.residualSummary.contains("Exact"))
    }

    @Test("A rotation is recovered as a rotation")
    func twoPointFitRecoversRotation() throws {
        // 90° turn: (x, y) becomes (-y, x).
        let pairs = [pair(0, 0, 0, 0), pair(0, 100, 100, 0)]
        let fit = try RevisionAlignmentSolver.fit(pairs: pairs, mode: .twoPoint).get()
        #expect(abs(fit.transform.rotationDegrees - 90) < 1e-6)
        #expect(abs(fit.transform.scale - 1) < 1e-9)
    }

    @Test("An extra point turns the residual into a real measurement")
    func extraPointProducesARealResidual() throws {
        let pairs = [
            pair(0, 0, 0, 0),
            pair(100, 0, 100, 0),
            pair(50, 3, 50, 0)
        ]
        let fit = try RevisionAlignmentSolver.fit(pairs: pairs, mode: .twoPoint).get()
        #expect(!fit.isExactlyDetermined)
        #expect(fit.residualRMSPoints > 0)
        #expect(fit.maximumResidualPoints >= fit.residualRMSPoints)
        #expect(fit.residualSummary.contains("Typical error"))
    }

    @Test("Three points determine an affine map, including different scales per axis")
    func threePointFitHandlesAnisotropicScale() throws {
        let pairs = [
            pair(0, 0, 0, 0),
            pair(200, 0, 100, 0),
            pair(0, 300, 0, 100)
        ]
        let fit = try RevisionAlignmentSolver.fit(pairs: pairs, mode: .threePoint).get()
        #expect(abs(fit.transform.a - 2) < 1e-9)
        #expect(abs(fit.transform.d - 3) < 1e-9)
        #expect(fit.residualRMSPoints < 1e-9)
    }

    @Test("Not enough points is a refusal with an instruction, not a wrong answer")
    func notEnoughPointsIsRefused() {
        switch RevisionAlignmentSolver.fit(pairs: [], mode: .twoPoint) {
        case .success: Issue.record("An empty point list produced a fit")
        case let .failure(problem):
            #expect(problem == .notEnoughPoints(needed: 2, given: 0))
            #expect(!problem.message.isEmpty)
        }
    }

    @Test("Three points on one line cannot make an affine map, and Zenit says why")
    func collinearPointsAreRefused() {
        let pairs = [pair(0, 0, 0, 0), pair(50, 0, 50, 0), pair(100, 0, 100, 0)]
        switch RevisionAlignmentSolver.fit(pairs: pairs, mode: .threePoint) {
        case .success: Issue.record("Collinear points produced an affine fit")
        case let .failure(problem):
            #expect(problem == .pointsCollinear)
            #expect(problem.message.contains("straight line"))
        }
    }

    @Test("Points all in the same spot cannot make a similarity either")
    func coincidentPointsAreRefused() {
        let pairs = [pair(0, 0, 7, 7), pair(0, 0, 7, 7)]
        switch RevisionAlignmentSolver.similarity(pairs: pairs) {
        case .success: Issue.record("Coincident points produced a fit")
        case let .failure(problem): #expect(problem == .pointsCoincide)
        }
    }

    @Test("Collinearity is a property of the points, not of how many there are")
    func collinearityDetection() {
        let line = [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 1, y: 1), PDFPointValue(x: 5, y: 5)]
        let triangle = [PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 0), PDFPointValue(x: 0, y: 100)]
        #expect(RevisionAlignmentSolver.isCollinear(line))
        #expect(!RevisionAlignmentSolver.isCollinear(triangle))
    }
}

/// The overlay model: layers, colours with names, and Reduce Motion.
@Suite("Revision overlay", .workflowsTierSerialised)
@MainActor
struct RevisionOverlayModelTests {

    private func revision(_ name: String) -> RevisionSummary {
        RevisionSummary(
            id: UUID(),
            documentID: UUID(),
            name: name,
            revisionLabel: "Rev A",
            author: "A. Surveyor",
            pageCount: 1,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            fileName: "\(name).pdf"
        )
    }

    @Test("Each stacked revision gets its own named colour")
    func layersGetDistinctNamedColours() {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B"), revision("C")])
        let names = model.layers.map(\.colorName)
        #expect(Set(names).count == 3)
        #expect(names.allSatisfy { !$0.isEmpty })
    }

    @Test("An overlay of one layer says there is nothing to compare")
    func oneLayerIsNotAnOverlay() {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        #expect(model.hasEnoughLayers)
        model.setVisible(false, forLayer: model.layers[1].id)
        #expect(!model.hasEnoughLayers)
    }

    @Test("Blinking refuses to start under Reduce Motion")
    func blinkingRespectsReduceMotion() {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        model.setBlinking(true, reduceMotion: true)
        #expect(!model.isBlinking)
        model.setBlinking(true, reduceMotion: false)
        #expect(model.isBlinking)
    }

    @Test("Marking points re-fits, and the state says how well")
    func capturingPointsUpdatesTheFit() {
        let model = RevisionOverlayModel(revisions: [revision("A"), revision("B")])
        #expect(model.fit == nil)
        #expect(model.pointPairs.isEmpty)
        #expect(model.alignmentMode.minimumPairCount == 2)
        model.capturePair(baseline: PDFPointValue(x: 0, y: 0), comparison: PDFPointValue(x: 0, y: 0))
        #expect(model.fit == nil)
        model.capturePair(baseline: PDFPointValue(x: 100, y: 0), comparison: PDFPointValue(x: 50, y: 0))
        #expect(model.fit != nil)
        #expect(model.pointPairs.count == model.alignmentMode.minimumPairCount)
        if case .manualTwoPoint = model.alignmentState {} else {
            Issue.record("Expected a two-point alignment state")
        }
    }

    @Test("Opacity cannot be pushed outside what a layer can be")
    func opacityIsClamped() {
        let model = RevisionOverlayModel(revisions: [revision("A")])
        let id = model.layers[0].id
        model.setOpacity(4, forLayer: id)
        #expect(model.layers[0].opacity == 1)
        model.setOpacity(-1, forLayer: id)
        #expect(model.layers[0].opacity == 0)
    }
}

/// Onboarding: skippable from anywhere, resumable, and never finished on the user's behalf.
@Suite("Onboarding", .workflowsTierSerialised)
@MainActor
struct OnboardingModelTests {

    @Test("The path starts at the first step and shows itself")
    func freshStart() {
        let model = OnboardingModel(store: InMemoryOnboardingProgressStore())
        #expect(model.isVisible)
        #expect(model.currentStep == .openDrawing)
        #expect(model.progressFraction == 0)
        #expect(model.positionSummary.contains("1"))
    }

    @Test("Completing a step moves to the next one that is not done")
    func completionAdvances() {
        let model = OnboardingModel(store: InMemoryOnboardingProgressStore())
        model.complete(.openDrawing)
        #expect(model.currentStep == .calibrateScale)
        #expect(model.isComplete(.openDrawing))
        #expect(model.isVisible)
    }

    @Test("Finishing the last step puts the guide away by itself")
    func completingEverythingDismisses() {
        let model = OnboardingModel(store: InMemoryOnboardingProgressStore())
        for step in OnboardingStep.allCases {
            model.complete(step)
        }
        #expect(model.nextIncompleteStep == nil)
        #expect(model.completedSteps.count == model.steps.count)
        #expect(!model.isVisible)
        #expect(model.progressFraction == 1)
    }

    @Test("Skipping keeps progress and never blocks anything")
    func skipKeepsProgress() {
        let store = InMemoryOnboardingProgressStore()
        let model = OnboardingModel(store: store)
        model.complete(.openDrawing)
        model.skip()
        #expect(!model.isVisible)
        #expect(store.loadProgress().isDismissed)
        #expect(store.loadProgress().completedSteps.contains(.openDrawing))
    }

    @Test("A guide put away on one day comes back where it was left")
    func progressIsResumable() {
        let store = InMemoryOnboardingProgressStore()
        let first = OnboardingModel(store: store)
        first.complete(.openDrawing)
        first.complete(.calibrateScale)
        first.skip()

        let second = OnboardingModel(store: store)
        #expect(!second.isVisible)
        #expect(second.currentStep == .firstMeasurement)
        second.resume()
        #expect(second.isVisible)
        #expect(second.currentStep == .firstMeasurement)
    }

    @Test("The action button asks the host to act; it does not tick the step off")
    func actionDoesNotCompleteTheStep() {
        let model = OnboardingModel(store: InMemoryOnboardingProgressStore())
        var performed: OnboardingStep?
        model.onPerformStep = { performed = $0 }
        model.performCurrentStep()
        #expect(performed == .openDrawing)
        #expect(!model.isComplete(.openDrawing))
    }

    @Test("Every step says what to do and why")
    func everyStepHasCopy() {
        for step in OnboardingStep.allCases {
            #expect(!step.title.isEmpty)
            #expect(!step.detail.isEmpty)
            #expect(!step.actionTitle.isEmpty)
        }
    }
}

/// The page-range grammar the recognition sheet accepts.
@Suite("OCR page ranges", .workflowsTierSerialised)
struct OCRPageRangeTests {

    @Test("A typed list reads the way people write it")
    func customListParses() {
        let indices = OCRPageRangeSelection.custom("1-4, 7, 12-14").resolvedIndices(pageCount: 20, currentPageIndex: 0)
        #expect(indices == IndexSet([0, 1, 2, 3, 6, 11, 12, 13]))
    }

    /// CR-193: this used to test only `"1, 99, 200-300"` — fragments that fall entirely outside
    /// the document, which the clamp happened to reject anyway because the clamped bounds came
    /// out crossed. It therefore passed against the CR-185 defect. A fragment that *straddles*
    /// the edge is the case the clamp got wrong, and it is now the case this test is about.
    @Test("Anything outside the document is dropped, not clamped")
    func outOfRangeIsDropped() {
        let wholly = OCRPageRangeSelection.custom("1, 99, 200-300")
            .resolvedIndices(pageCount: 5, currentPageIndex: 0)
        #expect(wholly == IndexSet(integer: 0))

        // Old output: IndexSet(0...2) — "0-3" was clamped up to 1-3 and read three pages the
        // person had not asked for, from an entry the help text says is ignored.
        let belowTheStart = OCRPageRangeSelection.custom("0-3")
            .resolvedIndices(pageCount: 5, currentPageIndex: 0)
        #expect(belowTheStart.isEmpty)

        // Old output: IndexSet(0...4) — "1-99" was clamped down to the whole document.
        let pastTheEnd = OCRPageRangeSelection.custom("1-99")
            .resolvedIndices(pageCount: 5, currentPageIndex: 0)
        #expect(pastTheEnd.isEmpty)

        // A dropped fragment does not take its neighbours with it.
        let mixed = OCRPageRangeSelection.custom("2-3, 1-99, 5")
            .resolvedIndices(pageCount: 5, currentPageIndex: 0)
        #expect(mixed == IndexSet([1, 2, 4]))

        // The stepper-driven range obeys the same rule, from the same helper.
        #expect(
            OCRPageRangeSelection.range(lowerBound: 1, upperBound: 99)
                .resolvedIndices(pageCount: 5, currentPageIndex: 0)
                .isEmpty
        )
        #expect(
            OCRPageRangeSelection.range(lowerBound: 0, upperBound: 3)
                .resolvedIndices(pageCount: 5, currentPageIndex: 0)
                .isEmpty
        )
    }

    @Test("A reversed range still means the pages between the two numbers")
    func reversedRangeIsReadCharitably() {
        let indices = OCRPageRangeSelection.range(lowerBound: 5, upperBound: 2)
            .resolvedIndices(pageCount: 10, currentPageIndex: 0)
        #expect(indices == IndexSet(1...4))
    }

    @Test("Nonsense produces nothing rather than something arbitrary")
    func nonsenseProducesNothing() {
        let indices = OCRPageRangeSelection.custom("banana, -, ,").resolvedIndices(pageCount: 10, currentPageIndex: 0)
        #expect(indices.isEmpty)
    }

    @Test("Every recognition state says what it means for search")
    func statusesExplainThemselves() {
        for status in OCRPageStatus.allCases {
            #expect(!status.displayName.isEmpty)
            #expect(!status.explanation.isEmpty)
        }
        #expect(!OCRDisclosure.localOnly.isEmpty)
        #expect(!OCRDisclosure.searchAidOnly.isEmpty)
    }

    @Test("Confidence becomes a band a person can act on")
    func confidenceBands() {
        #expect(OCRConfidenceBand(confidence: 0.95) == .high)
        #expect(OCRConfidenceBand(confidence: 0.7) == .medium)
        #expect(OCRConfidenceBand(confidence: 0.2) == .low)
    }
}

/// The Tool Library's editing rules, including the one destructive action.
@Suite("Tool Library editing", .workflowsTierSerialised)
@MainActor
struct ToolLibraryEditingModelTests {

    private func preset(_ name: String, category: String = "Concrete", panel: ToolLibraryPanel = .myTools, sortIndex: Int = 0) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: name,
            category: category,
            panel: panel,
            markupKind: .measurement,
            measurementKind: .area,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            defaultSubject: name,
            sortIndex: sortIndex
        )
    }

    @Test("Deleting leaves an undo affordance that really puts it back")
    func deleteIsUndoable() {
        let first = preset("A", sortIndex: 0)
        let model = ToolLibraryEditingModel(presets: [first, preset("B", sortIndex: 1)])
        model.delete(id: first.id)
        #expect(model.presets.count == 1)
        #expect(model.pendingDeletion?.preset.id == first.id)
        model.undoDelete()
        #expect(model.presets.count == 2)
        #expect(model.presets[0].id == first.id)
        #expect(model.pendingDeletion == nil)
    }

    /// CR-193: this used to assert identity, the two flags and a count, over a fixture with no
    /// artwork and no measurement parameters on it — so it passed against CR-167, where the
    /// duplicate's explicit initialiser never passed `stamp:` and silently dropped the picture
    /// the preset exists to place. Every field that travels with a copy is now named.
    @Test("Duplicating makes a new, editable, unstarred copy next to the original")
    func duplicateIsIndependent() {
        let artwork = StampArtworkDescriptor(
            kind: .vector,
            digest: String(repeating: "a", count: 64),
            byteCount: 2048,
            sourceName: "Seal.pdf",
            sourcePageIndex: 0
        )
        let stamp = StampTemplate(
            id: UUID(),
            widthPoints: 160,
            heightPoints: 60,
            artwork: artwork,
            fields: []
        )
        let source = ToolPresetSummary(
            id: UUID(),
            name: "Concrete Area",
            category: "Concrete",
            panel: .myTools,
            markupKind: .stamp,
            measurementKind: .area,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            defaultSubject: "Concrete",
            measurementDefaults: ToolPresetMeasurementDefaults(
                depth: DecimalQuantity(value: Decimal(string: "0.2")!, dimension: .length)
            ),
            labelPattern: "C#",
            displayLengthUnit: .foot,
            customDefaults: ["Material": "C30/37"],
            countSymbolName: "circle",
            stamp: stamp,
            isFavorite: true,
            sortIndex: 0
        )
        let model = ToolLibraryEditingModel(presets: [source])
        let copy = model.duplicate(id: source.id)

        #expect(copy != nil)
        #expect(copy?.id != source.id)
        #expect(copy?.isFavorite == false)
        #expect(copy?.isReadOnly == false)
        #expect(model.presets.count == 2)
        #expect(model.presets[1].id == copy?.id, "the copy sits next to the original")

        // Old output: `copy?.stamp` was nil. A duplicated stamp placed nothing.
        // The template travels whole, under the copy's own identity: a copy that kept the
        // original's template id made a batch of the copy skip pages carrying the original
        // (BH-847).
        #expect(copy?.stamp != nil, "the artwork did not travel with the copy")
        #expect(copy?.stamp?.id == copy?.id)
        #expect(copy?.stamp?.fields == stamp.fields)
        #expect(copy?.stamp?.widthPoints == stamp.widthPoints)
        #expect(copy?.stamp?.artwork == artwork)

        // The rest of what a duplicate is supposed to be the same preset in every way but name.
        #expect(copy?.measurementDefaults == source.measurementDefaults)
        #expect(copy?.markupKind == source.markupKind)
        #expect(copy?.measurementKind == source.measurementKind)
        #expect(copy?.colorRGBA == source.colorRGBA)
        #expect(copy?.labelPattern == source.labelPattern)
        #expect(copy?.displayLengthUnit == source.displayLengthUnit)
        #expect(copy?.customDefaults == source.customDefaults)
        #expect(copy?.countSymbolName == source.countSymbolName)
        #expect(copy?.defaultSubject == source.defaultSubject)
        #expect(copy?.provenance.origin == .duplicated)
        #expect(copy?.shortcutDisplayString == nil, "a copy does not inherit the ⌥ slot")
    }

    @Test("Reordering moves one tool inside its own category and renumbers the rest")
    func reorderWithinCategory() {
        let a = preset("A", sortIndex: 0)
        let b = preset("B", sortIndex: 1)
        let c = preset("C", sortIndex: 2)
        let model = ToolLibraryEditingModel(presets: [a, b, c])
        model.move(id: c.id, to: 0)
        #expect(model.presets(in: .myTools).map(\.name) == ["C", "A", "B"])
    }

    @Test("A tool saved from a selection starts from what was drawn")
    func createFromSelection() {
        let markup = MarkupSummary(
            id: UUID(),
            kind: .measurement,
            measurementKind: .area,
            subject: "Screed",
            label: "S1",
            comment: "",
            pageLabel: "A-101",
            pageID: UUID(),
            pageIndex: 0,
            status: .none,
            author: "A. Surveyor",
            colorRGBA: ColorRGBA.Zenit.Dark.green,
            created: Date(),
            modified: Date(),
            boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 10, height: 10)
        )
        let model = ToolLibraryEditingModel()
        model.beginCreating(from: markup)
        #expect(model.draft?.name == "Screed")
        #expect(model.draft?.measurementKind == .area)
        #expect(model.draft?.colorRGBA == ColorRGBA.Zenit.Dark.green)
        model.commitDraft()
        #expect(model.presets.count == 1)
        #expect(model.draft == nil)
    }

    @Test("A draft with no name cannot be saved")
    func emptyDraftIsRejected() {
        let model = ToolLibraryEditingModel()
        model.beginCreating()
        #expect(model.draft?.isValid == false)
        model.commitDraft()
        #expect(model.presets.isEmpty)
    }

    @Test("Read-only tools cannot be edited")
    func readOnlyPresetsAreNotEditable() {
        var locked = preset("Shared", panel: .importedLibraries)
        locked = ToolPresetSummary(
            id: locked.id,
            name: locked.name,
            category: locked.category,
            panel: .importedLibraries,
            markupKind: locked.markupKind,
            measurementKind: locked.measurementKind,
            colorRGBA: locked.colorRGBA,
            defaultSubject: locked.defaultSubject,
            isReadOnly: true
        )
        let model = ToolLibraryEditingModel(presets: [locked])
        model.beginEditing(id: locked.id)
        #expect(model.draft == nil)
    }

    @Test("An unsafe import cannot be confirmed")
    func unsafeImportCannotBeConfirmed() {
        let model = ToolLibraryEditingModel()
        model.beginImport(
            data: Data(#"{"schemaVersion": 99, "name": "X", "presets": []}"#.utf8),
            fileName: "X.zpdftools"
        )
        #expect(model.importReview != nil)
        #expect(model.importReview?.isSafeToImport == false)
        model.confirmImport()
        #expect(model.presets.isEmpty)
        #expect(model.importReview != nil)
    }

    @Test("A file that is not a tool set at all reports as a failure, not an empty review")
    func unreadableImportReportsFailure() {
        let model = ToolLibraryEditingModel()
        var reported: ZPDFUserFacingError?
        model.onImportFailure = { reported = $0 }
        model.beginImport(data: Data("nope".utf8), fileName: "X.zpdftools")
        #expect(model.importReview == nil)
        #expect(reported?.kind == .toolSetFileUnreadable)
    }
}

/// The compare review: filtering, counting, and stepping through candidates.
@Suite("Revision compare review", .workflowsTierSerialised)
@MainActor
struct RevisionCompareModelTests {

    private func diff(_ kind: CompareChangeKind, area: Double, accepted: Bool = false) -> CompareDiffSummary {
        CompareDiffSummary(
            id: UUID(),
            changeKind: kind,
            pageLabel: "A-101",
            areaInSquarePoints: area,
            confidence: 0.9,
            isAccepted: accepted
        )
    }

    @Test("Hiding a change type takes it off the canvas; the legend still counts it")
    func filteringAffectsCounts() {
        let model = RevisionCompareModel()
        let diffs = [diff(.added, area: 10), diff(.removed, area: 20), diff(.modified, area: 5)]
        #expect(model.visibleDiffs(from: diffs).count == 3)
        model.visibleChangeKinds = [.added]
        #expect(model.visibleDiffs(from: diffs).count == 1)
        #expect(model.counts(from: diffs)[.added] == 1)
        // BH-837: the legend badge for a hidden type reports how many exist, not 0.
        #expect(model.counts(from: diffs)[.removed] == 1)
    }

    @Test("Candidates are ordered biggest first, because that is the review order")
    func biggestCandidatesComeFirst() {
        let model = RevisionCompareModel()
        let diffs = [diff(.added, area: 10), diff(.removed, area: 200), diff(.modified, area: 50)]
        #expect(model.visibleDiffs(from: diffs).map(\.areaInSquarePoints) == [200, 50, 10])
    }

    @Test("Jump-to-next walks every candidate and wraps")
    func jumpWraps() {
        let model = RevisionCompareModel()
        let diffs = [diff(.added, area: 30), diff(.removed, area: 20), diff(.modified, area: 10)]
        model.focusNextDifference(in: diffs)
        #expect(model.focusedPosition(in: diffs) == 1)
        model.focusNextDifference(in: diffs)
        model.focusNextDifference(in: diffs)
        #expect(model.focusedPosition(in: diffs) == 3)
        model.focusNextDifference(in: diffs)
        #expect(model.focusedPosition(in: diffs) == 1)
    }

    @Test("The header separates candidates from what a person has accepted")
    func headerSeparatesAcceptedCandidates() {
        let model = RevisionCompareModel()
        let run = RevisionCompareRun(
            baselineRevisionID: UUID(),
            comparisonRevisionID: UUID(),
            settings: model.settings
        )
        let diffs = [diff(.added, area: 10), diff(.removed, area: 20, accepted: true)]
        #expect(model.countSummary(for: run, diffs: diffs).contains("1"))
        #expect(!model.countSummary(for: run, diffs: []).isEmpty)
    }

    @Test("Tolerance is bounded and always explains itself")
    func toleranceIsBoundedAndExplained() {
        let model = RevisionCompareModel()
        var seen: RevisionCompareSettings?
        model.onSettingsChange = { seen = $0 }
        model.setTolerance(5)
        #expect(model.settings.tolerance == 1)
        #expect(seen?.tolerance == 1)
        model.setTolerance(-1)
        #expect(model.settings.tolerance == 0)
        for value in [0.0, 0.35, 1.0] {
            model.setTolerance(value)
            #expect(!model.settings.toleranceExplanation.isEmpty)
        }
    }

    @Test("Every change type is legible as a shape and a word, not only a colour")
    func changeTypesAreShapeCoded() {
        for kind in CompareChangeKind.allCases {
            #expect(!kind.displayName.isEmpty)
            #expect(!kind.symbolName.isEmpty)
            let path = CompareChangeShape(kind).path(in: CGRect(x: 0, y: 0, width: 12, height: 12))
            #expect(!path.isEmpty)
        }
    }
}
