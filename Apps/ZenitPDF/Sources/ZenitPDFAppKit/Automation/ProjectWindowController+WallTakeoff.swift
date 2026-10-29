import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// Measure ▸ Find Walls… (NL-AUTO-20): the sheet's wall classes by thickness and their
/// centrelines, **proposed** — highlighted on the sheet and listed with their lengths and the
/// openings left out — and committed only for the classes the person ticks, as polylengths named
/// "Wall 150 mm", each recording that it was chained from a parallel pair (ADR-0031). Nothing is
/// measured silently: the command refuses an uncalibrated sheet, because a wall class is a
/// thickness in millimetres.
///
/// Every class starts unticked (L-74). Any two parallel lines a plausible thickness apart form a
/// class, and on a real roof plan that was two dozen "wall" classes across the whole thickness
/// band, every one ticked: one click on Add Walls put hatching and outlines into the ledger as
/// walls. A class that repeats like a pattern is listed last and says so.
extension ProjectWindowController {

    /// One class as the review shows it.
    struct WallProposal: Equatable {
        let thicknessMillimetres: Int
        let lengthMetres: Double
        let centrelines: [[PDFPoint]]
        let openingWidthsMetres: [Double]
        let thicknessMetres: Decimal
        /// Whether the pair search behind this class stopped at its limit, so walls of the class
        /// may be missing and ``lengthMetres`` short (S-098).
        var mayBeIncomplete = false
        /// Whether the class's faces repeat on both sides like hatching or a tile pattern rather
        /// than bounding a band of wall (L-74, `WallCentrelineEngine.WallClass.isLikelyWall`).
        var repeatsLikeAPattern = false
        var subject: String {
            String(format: NSLocalizedString("Wall %d mm", comment: "Subject of a proposed wall class; thickness in millimetres"), thicknessMillimetres)
        }
    }

    static let wallReviewIdentifier = "automation.wallReview"

    /// How the proposal is decided: the classes to add, or `nil` for Cancel. Injectable; the
    /// shipping value is an alert with one checkbox per class through ``ZenitModalPresenter``.
    static var wallReviewDecision: (@MainActor ([WallProposal], NSWindow?) async -> Set<Int>?) = { proposals, window in
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Add these walls as lengths?", comment: "Wall review title")
            alert.informativeText = wallReviewMessage(for: proposals)
            let boxes = wallReviewCheckboxes(for: proposals)
            let stack = NSStackView(views: boxes)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(24 * boxes.count))
            alert.accessoryView = stack
            alert.addButton(withTitle: NSLocalizedString("Add Walls", comment: "Wall review: add"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Wall review: cancel"))
            ZenitModalPresenter.runAlert(alert, identifier: wallReviewIdentifier, sheetedOn: window) { answer in
                guard answer.buttonIndex == 0 else { return continuation.resume(returning: nil) }
                continuation.resume(returning: Set(boxes.indices.filter { boxes[$0].state == .on }))
            }
        }
    }

    /// The review's checkboxes, one per class in list order, every one unticked (L-74): any two
    /// parallel lines a plausible thickness apart form a class, so which classes are walls is the
    /// person's call, never a default.
    static func wallReviewCheckboxes(for proposals: [WallProposal]) -> [NSButton] {
        proposals.map { proposal in
            let box = NSButton(checkboxWithTitle: wallReviewRowTitle(proposal), target: nil, action: nil)
            box.state = .off
            box.setAccessibilityLabel(wallReviewRowTitle(proposal))
            return box
        }
    }

    /// The review's body: the rule, and a warning when the search did not cover the whole sheet.
    static func wallReviewMessage(for proposals: [WallProposal]) -> String {
        var message = NSLocalizedString(
            "Each class is measured on its centreline; where walls meet at a corner they join, and a wall that stops against another stops at its face. Openings are left out and listed. Hatching and outlines form parallel pairs too, so no class is ticked: tick the classes that are walls.",
            comment: "Wall review body")
        if proposals.contains(where: \.repeatsLikeAPattern) {
            message += "\n\n" + NSLocalizedString(
                "Classes marked “repeats like hatching” are evenly spaced runs of parallel lines, such as hatching, roof covering or stair treads, and are listed last.",
                comment: "Wall review: some classes look like a repeating pattern")
        }
        if proposals.contains(where: \.mayBeIncomplete) {
            message += "\n\n" + NSLocalizedString(
                "This sheet has more parallel lines than the search examines, so some walls may be missing and the marked lengths may be short. Check the highlighted walls against the sheet before adding them, or hide hatching and dimension layers and search again.",
                comment: "Wall review: the parallel-pair search stopped at its limit")
        }
        return message
    }

    /// One class's checkbox title.
    static func wallReviewRowTitle(_ proposal: WallProposal) -> String {
        var title = String(format: NSLocalizedString("%1$@: %2$@ m", comment: "Wall review row: subject, length"),
                           proposal.subject, String(format: "%.2f", proposal.lengthMetres))
        if proposal.openingWidthsMetres.count == 1 {
            title += " " + NSLocalizedString("(1 opening left out)", comment: "Wall review row: one opening excluded")
        } else if !proposal.openingWidthsMetres.isEmpty {
            title += " " + String(format: NSLocalizedString("(%d openings left out)", comment: "Wall review row: openings excluded"), proposal.openingWidthsMetres.count)
        }
        if proposal.repeatsLikeAPattern {
            title += " " + NSLocalizedString("(repeats like hatching)", comment: "Wall review row: the class looks like a repeating pattern, not walls")
        }
        if proposal.mayBeIncomplete {
            title += " " + NSLocalizedString("(may be incomplete)", comment: "Wall review row: the search for this class stopped at its limit")
        }
        return title
    }

    /// The note after Add Walls, each count with its own singular or plural (L-74): one ticked
    /// class with one run and one opening read "1 wall lengths added in 1 classes; 1 openings left
    /// out." Each count is its own phrase, as in ``wallReviewRowTitle(_:)``.
    static func wallsAddedNote(lengths: Int, classes: Int, openings: Int) -> String {
        let lengthPhrase = lengths == 1
            ? NSLocalizedString("1 wall length", comment: "Find Walls result: one polylength added")
            : String(format: NSLocalizedString("%d wall lengths", comment: "Find Walls result: polylengths added; count"), lengths)
        let classPhrase = classes == 1
            ? NSLocalizedString("1 class", comment: "Find Walls result: one wall class ticked")
            : String(format: NSLocalizedString("%d classes", comment: "Find Walls result: wall classes ticked; count"), classes)
        let openingPhrase = openings == 1
            ? NSLocalizedString("1 opening", comment: "Find Walls result: one opening excluded")
            : String(format: NSLocalizedString("%d openings", comment: "Find Walls result: openings excluded; count"), openings)
        return String(
            format: NSLocalizedString("%1$@ added in %2$@; %3$@ left out.", comment: "Find Walls result: '2 wall lengths', '1 class', '1 opening'"),
            lengthPhrase, classPhrase, openingPhrase)
    }

    /// The proposals for one extraction on a calibrated page, and whether the search stopped at
    /// its limit anywhere. Pure over its inputs. Classes that look like walls come first, then
    /// those that repeat like a pattern (L-74); thinnest first within each.
    nonisolated static func wallProposals(extraction: VectorPageExtraction, metresPerPoint: Double,
                                          hiddenLayers: Set<String>) -> (proposals: [WallProposal], isTruncated: Bool) {
        let engine = WallCentrelineEngine(page: extraction, options: .calibrated(pointsPerMetre: 1 / metresPerPoint),
                                          layerFilter: VectorLayerVisibilityFilter(hiddenLayerIDs: hiddenLayers))
        let takeoff = engine.takeoff()
        let proposals = takeoff.classes.map { wall in wallProposal(wall, metresPerPoint: metresPerPoint) }
        let walls = proposals.filter { !$0.repeatsLikeAPattern }, patterns = proposals.filter(\.repeatsLikeAPattern)
        return (walls + patterns, takeoff.isTruncated)
    }

    /// One engine class as the review shows it.
    nonisolated static func wallProposal(_ wall: WallCentrelineEngine.WallClass, metresPerPoint: Double) -> WallProposal {
        let millimetres = Int((wall.thicknessPoints * metresPerPoint * 1000).rounded())
        return WallProposal(
            thicknessMillimetres: millimetres,
            lengthMetres: wall.lengthPoints * metresPerPoint,
            centrelines: wall.centrelines.map { $0.map { PDFPoint(x: $0.x, y: $0.y) } },
            openingWidthsMetres: wall.openings.map { $0.widthPoints * metresPerPoint },
            thicknessMetres: Decimal(millimetres) / 1000,
            mayBeIncomplete: wall.isTruncated,
            repeatsLikeAPattern: !wall.isLikelyWall)
    }

    /// The note when no class was found. A search that stopped at its limit found nothing *in the
    /// part it examined*, which is not the same as a sheet without walls (S-098).
    static func noWallsNote(searchTruncated: Bool) -> String {
        searchTruncated
            ? NSLocalizedString(
                "No complete wall class found: this sheet has more parallel lines than the search examines. Hide hatching and dimension layers and search again.",
                comment: "Find Walls found nothing because the parallel-pair search stopped at its limit")
            : NSLocalizedString(
                "No wall classes found on this sheet: no pairs of parallel lines run far enough at one thickness.",
                comment: "Find Walls found nothing")
    }

    func findWalls(for document: ZenitPDFProjectDocument) {
        Task { @MainActor in _ = await self.runWallTakeoff(for: document) }
    }

    /// The whole command. Returns how many polylengths were added, for tests.
    @discardableResult
    func runWallTakeoff(for document: ZenitPDFProjectDocument) async -> Int {
        guard let core = document.core, let drawing = document.currentPageDrawing,
              let currentID = core.document.currentPageID,
              let page = drawing.pages.first(where: { $0.id.rawValue == currentID }) else { return 0 }
        guard let scale = await core.session.scale(onPage: page.id) else {
            core.status.setActiveToolNote(NSLocalizedString(
                "Calibrate this sheet first: walls are found by their thickness in millimetres.",
                comment: "Find Walls on an uncalibrated sheet"))
            return 0
        }
        let metresPerPoint = scale.matrix.map(PDFPoint(x: 0, y: 0)).distance(to: scale.matrix.map(PDFPoint(x: 1, y: 0)))
        guard metresPerPoint.isFinite, metresPerPoint > 0 else { return 0 }
        let extraction: VectorPageExtraction
        do {
            extraction = try await automationExtraction(for: document, page: page)
        } catch {
            core.status.setActiveToolNote(Self.symbolScheduleExtractionFailureNote(error))
            return 0
        }
        let hidden = document.hiddenLayerNames(for: page, snap: false)
        let (proposals, searchTruncated) = await Task.detached(priority: .userInitiated) {
            Self.wallProposals(extraction: extraction, metresPerPoint: metresPerPoint, hiddenLayers: hidden)
        }.value
        guard !proposals.isEmpty else {
            core.status.setActiveToolNote(Self.noWallsNote(searchTruncated: searchTruncated))
            return 0
        }
        // The proposal on the sheet while the person decides.
        var overlay = CanvasAutomationOverlay()
        overlay.hits = proposals.flatMap(\.centrelines).map { line in
            let xs = line.map(\.x), ys = line.map(\.y)
            return PDFRectValue(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }
        canvasController(for: document)?.setAutomationOverlay(overlay)
        defer { canvasController(for: document)?.setAutomationOverlay(nil) }
        guard let chosen = await Self.wallReviewDecision(proposals, window) else { return 0 }
        guard !chosen.isEmpty else {
            core.status.setActiveToolNote(NSLocalizedString(
                "No wall class was ticked, so nothing was added.",
                comment: "Find Walls: Add Walls pressed with every class unticked"))
            return 0
        }

        let documentID = await core.session.documentID
        let now = Date()
        var commands: [DocumentCommand] = []
        for index in chosen.sorted() where proposals.indices.contains(index) {
            let proposal = proposals[index]
            for line in proposal.centrelines where line.count >= 2 {
                commands.append(.addMarkup(CaptureStamp.stamped(MarkupRecord(
                    id: MarkupID(UUID()), documentID: documentID, pageID: page.id,
                    kind: .measurement, tool: .polylength, subject: proposal.subject,
                    geometry: MeasurementGeometry(pageID: page.id, points: line),
                    createdAt: now, modifiedAt: now
                ), method: CaptureMethod(kind: .wallCentreline, wallThicknessMetres: proposal.thicknessMetres))))
            }
        }
        guard !commands.isEmpty else { return 0 }
        do {
            try await core.commands.performBatch(commands, actionName: NSLocalizedString("Find Walls", comment: "Undo action name for adding proposed walls"))
            await core.commands.settle()
            await core.refresh()
            let openings = chosen.reduce(0) { $0 + (proposals.indices.contains($1) ? proposals[$1].openingWidthsMetres.count : 0) }
            core.status.setActiveToolNote(Self.wallsAddedNote(lengths: commands.count, classes: chosen.count, openings: openings))
        } catch {
            core.status.setActiveToolNote(String(describing: error))
            return 0
        }
        return commands.count
    }
}
