import AppKit
import Foundation
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFUIPresentation
import ZPDFUIWorkflows
import ZPDFVectorExtraction

/// NL-AUTO-08: every room on the page, proposed at once — traced with the same rules as ⌥-click,
/// named from the label printed inside, and landed as named areas in one undoable step after a
/// person has reviewed them.
extension ProjectWindowController {

    /// How the review reaches the screen, returning its dismissal. A test injects a capture.
    static var roomReviewPresenter: (@MainActor (RoomDetectionReviewModel, NSWindow?) -> () -> Void) = { model, window in
        guard let window else { return {} }
        let host = NSHostingController(rootView: RoomDetectionReviewView(model: model))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled, .resizable]
        // Through the one modal door: recorded, and refused on a visible window in a
        // process with no user (R-039).
        ZenitModalPresenter.beginSheet(panel, on: window, identifier: "automation.roomReview") {}
        return { [weak window, weak panel] in
            guard let window, let panel else { return }
            window.endSheet(panel)
        }
    }

    /// The room band and minimum width, from the page scale: 1 to 400 m², at least 0.6 m wide;
    /// on an uncalibrated page, in points.
    static func roomOptions(metresPerPoint: Double?) -> RoomDetector.Options {
        guard let m = metresPerPoint else {
            return RoomDetector.Options(minimumArea: 2_000, maximumArea: 1_000_000, minimumWidth: 20,
                                        maximumClosureWidth: AutoTraceService.uncalibratedClosurePoints)
        }
        let perSquareMetre = 1 / (m * m)
        return RoomDetector.Options(
            minimumArea: 1 * perSquareMetre,
            maximumArea: 400 * perSquareMetre,
            minimumWidth: 0.6 / m,
            maximumClosureWidth: AutoTraceService.maximumClosureWidth(metresPerPoint: m)
        )
    }

    func detectRooms(for document: ZenitPDFProjectDocument) {
        Task { @MainActor in
            guard let core = document.core, let drawing = document.currentPageDrawing,
                  let currentID = core.document.currentPageID,
                  let page = drawing.pages.first(where: { $0.id.rawValue == currentID }) else { return }
            let extraction: VectorPageExtraction
            do {
                extraction = try await self.automationExtraction(for: document, page: page)
            } catch {
                core.status.setActiveToolNote(Self.symbolScheduleExtractionFailureNote(error))
                return
            }
            var metresPerPoint: Double?
            if let scale = await core.session.scale(onPage: page.id) {
                let value = scale.matrix.map(PDFPoint(x: 0, y: 0)).distance(to: scale.matrix.map(PDFPoint(x: 1, y: 0)))
                if value.isFinite, value > 0 { metresPerPoint = value }
            }
            // What the person can measure on, and what they told tracing to leave out.
            var filter = document.automation.traceChoices
            filter.hiddenLayerIDs = document.hiddenLayerNames(for: page, snap: true)
            let options = Self.roomOptions(metresPerPoint: metresPerPoint)
            core.status.setActiveToolNote(NSLocalizedString(
                "Looking for rooms on this page…", comment: "Status note while rooms are detected"
            ))
            let primitives = extraction.primitives
            let chosen = filter
            let result = await Task.detached(priority: .userInitiated) {
                RoomDetector.detect(RegionTracer.prepare(primitives: primitives, filter: chosen), options: options)
            }.value
            let rooms: [RoomDetector.Room]
            var caveat: String?
            switch result {
            case .tooComplex:
                // Only when no part of the sheet could be read (L-73b): a sheet over a cap as a
                // whole is read in tiles. ⌥-click is no way out of this one — it reads the same
                // prepared page — so the advice is what thins the page.
                core.status.setActiveToolNote(NSLocalizedString(
                    "This sheet is too dense to read rooms from. Hide layers to thin it out, or draw the rooms by hand.",
                    comment: "Room detection refusal: no part of the sheet is under the work limits"
                ))
                return
            case .rooms(let found, let truncated):
                rooms = found
                if truncated {
                    caveat = NSLocalizedString(
                        "The search stopped at its limit; the sheet may hold more rooms.",
                        comment: "Room detection caveat when the face cap applied"
                    )
                }
            }
            guard !rooms.isEmpty else {
                core.status.setActiveToolNote(NSLocalizedString(
                    "No closed rooms were found on this page.", comment: "Room detection found nothing"
                ))
                return
            }
            let lines = await PageTextLoader.embeddedLines(source: drawing.rasterSource, pageIndex: page.index)
            let rows = rooms.enumerated().map { index, room in
                Self.roomRow(index: index, room: room, lines: lines, metresPerPoint: metresPerPoint)
            }
            var overlay = CanvasAutomationOverlay()
            overlay.rings = rooms.map { $0.region.ring.map { PDFPointValue(x: $0.x, y: $0.y) } }
            overlay.closures = rooms.flatMap(\.closures).map {
                CanvasAutomationOverlay.Segment(start: PDFPointValue(x: $0.start.x, y: $0.start.y), end: PDFPointValue(x: $0.end.x, y: $0.end.y))
            }
            self.canvasController(for: document)?.setAutomationOverlay(overlay)
            let box = SheetDismissBox()
            let model = RoomDetectionReviewModel(
                rows: rows,
                caveat: caveat,
                onAccept: { [weak self, weak document] outcome in
                    box.dismiss()
                    guard let self, let document else { return }
                    self.canvasController(for: document)?.setAutomationOverlay(nil)
                    Task { @MainActor in
                        await self.landRooms(rooms, names: outcome.names, pageID: page.id, core: core)
                    }
                },
                onCancel: { [weak self, weak document] in
                    box.dismiss()
                    guard let self, let document else { return }
                    self.canvasController(for: document)?.setAutomationOverlay(nil)
                },
                onReveal: { [weak self, weak document] row in
                    guard let self, let document else { return }
                    self.canvasController(for: document)?.revealPageRect(row.bounds, highlight: true)
                }
            )
            box.dismiss = Self.roomReviewPresenter(model, self.window)
        }
    }

    static func roomRow(index: Int, room: RoomDetector.Room, lines: [RecognisedTextLine], metresPerPoint: Double?) -> RoomDetectionReviewRow {
        let label = RoomLabelPairing.label(for: room.region.ring, lines: lines)
        var notes: [String] = []
        if !room.closures.isEmpty {
            notes.append(String(
                format: NSLocalizedString("closes %d opening(s)", comment: "Room review note: openings closed"),
                room.closures.count
            ))
        }
        let areaText: String
        if let m = metresPerPoint {
            let squareMetres = room.region.area * m * m
            areaText = String(format: NSLocalizedString("%.2f m²", comment: "An area in square metres"), squareMetres)
            if let printed = label.printedSquareMetres {
                let printedValue = NSDecimalNumber(decimal: printed).doubleValue
                if printedValue > 0, abs(squareMetres - printedValue) / printedValue > NSDecimalNumber(decimal: PrintedAreaCheck.defaultTolerance).doubleValue {
                    notes.append(String(
                        format: NSLocalizedString("printed %@ m² differs", comment: "Room review note: the printed area disagrees; the printed value"),
                        "\(printed)"
                    ))
                }
            }
        } else {
            areaText = String(format: NSLocalizedString("%.0f pt²", comment: "Difference area in square PDF points"), room.region.area)
        }
        let xs = room.region.ring.map(\.x), ys = room.region.ring.map(\.y)
        return RoomDetectionReviewRow(
            id: index,
            name: label.name ?? "",
            areaText: areaText,
            notes: notes,
            bounds: PDFRectValue(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        )
    }

    /// The accepted rooms as area markups, named, one batch, one ⌘Z.
    func landRooms(_ rooms: [RoomDetector.Room], names: [Int: String], pageID: PageID, core: AppCoreEnvironment) async {
        let documentID = await core.session.documentID
        let now = Date()
        let commands: [DocumentCommand] = names.keys.sorted().compactMap { index in
            guard rooms.indices.contains(index) else { return nil }
            let name = names[index] ?? ""
            // r2-platform, ADR-0031: each room records that the detector found it.
            return .addMarkup(CaptureStamp.stamped(MarkupRecord(
                id: MarkupID(UUID()), documentID: documentID, pageID: pageID,
                kind: .measurement, tool: .area,
                subject: name.isEmpty ? NSLocalizedString("Area", comment: "Nameless area in the printed-area check") : name,
                geometry: MeasurementGeometry(
                    pageID: pageID,
                    polygons: [PolygonGeometry(outer: PolygonRing(points: rooms[index].region.ring, isClosed: true))]
                ),
                createdAt: now, modifiedAt: now
            ), method: CaptureMethod(kind: .roomDetected)))
        }
        guard !commands.isEmpty else { return }
        do {
            try await core.commands.performBatch(
                commands,
                actionName: NSLocalizedString("Detect Rooms", comment: "Undo action name for landing detected rooms")
            )
            await core.commands.settle()
            await core.refresh()
            core.status.setActiveToolNote(String(
                format: NSLocalizedString("%d rooms added as areas.", comment: "Status note after landing detected rooms"),
                commands.count
            ))
        } catch {
            core.status.setActiveToolNote(String(describing: error))
        }
    }
}
