import AppKit
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation

/// File ▸ Export Measurements Overlay… and File ▸ Import Measurements Overlay….
///
/// The menu route to `ZenitOverlayExporter` and `ZenitOverlayImporter`: the measurements of one
/// drawing, carried as a `.zpdfoverlay` to another copy of **the same drawing** — the same bytes,
/// whatever the file is called — and redrawn there as ordinary, undoable markups. A different
/// drawing is refused naming both files, and nothing is added.
@MainActor
enum MeasurementOverlayTransfer {

    static let exportPanelIdentifier = "overlay.exportPanel"
    static let importPanelIdentifier = "overlay.importPanel"
    static let refusalIdentifier = "overlay.importRefused"
    static let resultNoteID = UUID(uuidString: "3F0A7C1E-8B2D-4E6F-9A1B-5C4D3E2F1A10")!

    // MARK: - Pure parts

    /// The overlay's description of a drawing: the name a person recognises, its page count and
    /// the digest that decides.
    nonisolated static func source(fileName: String, pageCount: Int, digestSHA256: String, byteCount: Int) -> ZenitOverlayDocument.Source {
        ZenitOverlayDocument.Source(fileName: fileName, pageCount: pageCount, digestSHA256: digestSHA256, digestByteCount: byteCount)
    }

    /// Geometry and placement for every markup that has geometry on one of `pages`.
    nonisolated static func drawingData(
        for records: [MarkupRecord],
        pages: [ZPDFContracts.PageDescriptor]
    ) -> (geometry: [String: MeasurementGeometry], placements: [String: ZenitOverlayDocument.Placement]) {
        var geometry: [String: MeasurementGeometry] = [:]
        var placements: [String: ZenitOverlayDocument.Placement] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for record in records {
            guard let shape = record.geometry, let pageIndex = pages.firstIndex(where: { $0.id == record.pageID }) else { continue }
            let key = record.id.rawValue.uuidString
            geometry[key] = shape
            let parameters = record.parameters.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            // L-47: the style travels too, so the area drawn in blue arrives in blue.
            let style = (try? encoder.encode(record.style)).map { String(decoding: $0, as: UTF8.self) }
            placements[key] = .init(pageIndex: pageIndex, tool: record.tool?.rawValue, parametersJSON: parameters, styleJSON: style)
        }
        return (geometry, placements)
    }

    /// Why one measurement in an overlay was not redrawn.
    enum SkipReason: Equatable, Sendable {
        /// The row travelled without geometry.
        case noGeometry
        /// No page index, and the drawing has more than one page.
        case noPage
        /// The page index is beyond the drawing.
        case pageOutOfRange(Int)
        /// No tool recorded and the shape does not say which one.
        case unknownTool
    }

    /// What importing an overlay onto a drawing would do.
    struct ImportPlan: Sendable {
        var records: [MarkupRecord]
        var skipped: [(markupID: String, reason: SkipReason)]
        var match: OverlaySourceMatch
    }

    /// The markups an accepted overlay becomes on the target drawing. Pure.
    ///
    /// Every record is new (a fresh id), measured (`kind .measurement` with its tool and geometry,
    /// so the session measures it under the target page's own scale), and placed on the target
    /// page by index — page IDs are minted per session, so the geometry's own page id is replaced.
    /// Subject and label come from the row's cells when the overlay carries those columns.
    nonisolated static func plan(
        _ overlay: OverlayImport,
        pages: [ZPDFContracts.PageDescriptor],
        documentID: DocumentID,
        now: Date = Date(),
        newID: () -> UUID = { UUID() }
    ) -> ImportPlan {
        let columns = overlay.document.columns.map(\.key)
        func text(_ row: ZenitInterchangeDocument.Row, _ key: String) -> String {
            guard let index = columns.firstIndex(of: key), row.cells.indices.contains(index),
                  case let .text(value) = row.cells[index] else { return "" }
            return value
        }
        var records: [MarkupRecord] = []
        var skipped: [(String, SkipReason)] = []
        let decoder = JSONDecoder()
        for measurement in overlay.document.measurements {
            let id = measurement.row.markupID
            guard var geometry = measurement.geometry, !geometry.isEmpty, geometry.isFinite else {
                skipped.append((id, .noGeometry)); continue
            }
            let pageIndex: Int
            if let placed = measurement.placement?.pageIndex {
                pageIndex = placed
            } else if pages.count == 1 {
                pageIndex = 0
            } else {
                skipped.append((id, .noPage)); continue
            }
            guard pages.indices.contains(pageIndex) else { skipped.append((id, .pageOutOfRange(pageIndex))); continue }
            let tool = measurement.placement?.tool.flatMap(MeasurementTool.init(rawValue:)) ?? inferredTool(for: geometry)
            guard let tool else { skipped.append((id, .unknownTool)); continue }
            let page = pages[pageIndex]
            geometry.pageID = page.id
            let parameters = measurement.placement?.parametersJSON
                .flatMap { try? decoder.decode(MeasurementParameters.self, from: Data($0.utf8)) }
            var record = MarkupRecord(
                id: MarkupID(newID()),
                documentID: documentID,
                pageID: page.id,
                kind: .measurement,
                tool: tool,
                subject: text(measurement.row, "subject"),
                geometry: geometry,
                createdAt: now,
                modifiedAt: now
            )
            record.label = text(measurement.row, "label")
            record.parameters = parameters
            // L-47: the measurement keeps the colour, fill and line it was drawn with. It used to
            // land in the record's default style — black, unfilled — and read as grey with no
            // outline on the sheet, where the source drew it in blue.
            record.style = style(of: measurement, tool: tool, colorHex: text(measurement.row, "color"), decoder: decoder)
            // An overlay written by a build before X-042 can carry an Arc Length at four points,
            // which today's engine refuses — and one refusal turned the whole file away. Opened
            // as a saved record is, it lands as the three points it was measured on.
            records.append(SavedMarkupRepair.opened(record))
        }
        return ImportPlan(records: records, skipped: skipped.map { (markupID: $0.0, reason: $0.1) }, match: overlay.match)
    }

    /// The style an imported measurement is drawn with (L-47): the one the overlay carries; for
    /// an overlay written before styles travelled, the row's Colour cell (`#1A55CF`) as the stroke,
    /// with the measurement tools' own area fill for a tool whose outline closes; and with neither,
    /// the style a new measurement of that tool takes in the application's default ink.
    nonisolated static func style(
        of measurement: ZenitOverlayDocument.Measurement,
        tool: MeasurementTool,
        colorHex: String,
        decoder: JSONDecoder = JSONDecoder()
    ) -> MarkupStyle {
        if let json = measurement.placement?.styleJSON,
           let carried = try? decoder.decode(MarkupStyle.self, from: Data(json.utf8)),
           carried.opacity.isFinite, carried.lineWidth.isFinite, carried.lineWidth >= 0 {
            return carried
        }
        let ink = ToolStyleSelection.zenitInk.stroke
        let stroke = color(hex: colorHex) ?? RGBAColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: ink.alpha)
        let closes: Bool
        switch tool {
        case .area, .rectangleArea, .ellipseArea, .trueSlopedArea, .volume, .wallArea, .perimeter,
             .polygonCutout, .ellipseCutout:
            closes = true
        default:
            closes = false
        }
        // The measurement tools' own area fill: the stroke at the shared 20 % alpha
        // (`AppMeasurementToolPresenter.measurementFill`).
        let fill = RGBAColor(red: stroke.red, green: stroke.green, blue: stroke.blue, alpha: MarkupFillDefaults.derivedAreaFillAlpha)
        return MarkupStyle(color: stroke, fill: closes ? fill : nil)
    }

    /// `#RRGGBB` or `#RRGGBBAA`, as the ledger's Colour cell spells a markup's colour, or `nil`.
    nonisolated static func color(hex text: String) -> RGBAColor? {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        func byte(_ shift: UInt64) -> Double { Double((value >> shift) & 0xFF) / 255.0 }
        return hasAlpha
            ? RGBAColor(red: byte(24), green: byte(16), blue: byte(8), alpha: byte(0))
            : RGBAColor(red: byte(16), green: byte(8), blue: byte(0))
    }

    /// The tool a shape unambiguously implies, for overlays written before placements existed.
    /// Anything a parameter could change (volume, wall area, slope) is never guessed.
    nonisolated static func inferredTool(for geometry: MeasurementGeometry) -> MeasurementTool? {
        let kinds = [!geometry.points.isEmpty, !geometry.segments.isEmpty, !geometry.polygons.isEmpty,
                     !geometry.arcs.isEmpty, !geometry.circles.isEmpty, !geometry.countPoints.isEmpty]
        guard kinds.filter({ $0 }).count == 1 else { return nil }
        if !geometry.countPoints.isEmpty { return .count }
        if geometry.polygons.count == 1 { return .area }
        if geometry.points.count == 2 { return .length }
        if geometry.points.count > 2 { return .polylength }
        if !geometry.segments.isEmpty { return .dimension }
        if geometry.arcs.count == 1 { return .arcLength }
        return nil
    }

    /// The status note after an import: how many arrived, and why any did not.
    static func resultNote(for plan: ImportPlan, fileName: String, now: Date = Date()) -> AppWarning {
        var parts: [String] = []
        if case let .renamed(from, to) = plan.match {
            parts.append(String(
                format: NSLocalizedString(
                    "It was measured on “%1$@”, the same drawing as “%2$@” under another name.",
                    comment: "Overlay import note when the drawing was renamed; overlay file name, this drawing's name"
                ),
                from, to
            ))
        }
        if !plan.skipped.isEmpty {
            parts.append(LocalizedPlural.string(
                "%lld could not be redrawn: they carry no drawing, no page, or no tool.",
                count: plan.skipped.count,
                one: NSLocalizedString(
                    "%lld could not be redrawn: it carries no drawing, no page, or no tool.",
                    comment: "Overlay import note; one measurement that was not redrawn"
                ),
                other: NSLocalizedString(
                    "%lld could not be redrawn: they carry no drawing, no page, or no tool.",
                    comment: "Overlay import note; number of measurements that were not redrawn"
                )
            ))
        }
        parts.append(plan.records.count == 1
            ? NSLocalizedString(
                "It is measured under this drawing’s own scale. Undo removes it.",
                comment: "Overlay import note: how one imported measurement is measured and undone"
            )
            : NSLocalizedString(
                "Each is measured under this drawing’s own scale. Undo removes them all.",
                comment: "Overlay import note: how imported measurements are measured and undone"
            ))
        return AppWarning(
            id: resultNoteID,
            severity: plan.skipped.isEmpty ? .info : .warning,
            // L-48: "Imported 1 measurement", not "Imported 1 measurements".
            title: LocalizedPlural.string(
                "Imported %1$lld measurements from “%2$@”",
                count: plan.records.count,
                one: NSLocalizedString(
                    "Imported %1$lld measurement from “%2$@”",
                    comment: "Overlay import headline, one measurement; count, overlay file name"
                ),
                other: NSLocalizedString(
                    "Imported %1$lld measurements from “%2$@”",
                    comment: "Overlay import headline; count, overlay file name"
                ),
                arguments: [fileName]
            ),
            message: parts.joined(separator: " "),
            source: NSLocalizedString("Overlay", comment: "Status note source for measurement overlays"),
            isDismissible: true,
            timestamp: now
        )
    }

    // MARK: - The drawing in front

    /// The source identity of the document's drawing, or `nil` before it has loaded.
    static func source(of document: ZenitPDFProjectDocument) -> ZenitOverlayDocument.Source? {
        guard let drawing = document.drawing else { return nil }
        let name = document.mode == .project
            ? (document.displayName ?? drawing.url.deletingPathExtension().lastPathComponent) + ".pdf"
            : drawing.url.lastPathComponent
        return source(fileName: name, pageCount: drawing.pages.count,
                      digestSHA256: drawing.digest.sha256, byteCount: drawing.digest.byteCount)
    }

    // MARK: - Export

    /// Builds the overlay bytes for the document in front: the ledger on screen, through the same
    /// projection every export uses, plus each markup's geometry and placement.
    ///
    /// The overlay is one drawing's — the primary drawing's fingerprint, pages and geometry — so
    /// in a project of several drawings its rows are that drawing's too (W-022). The rows used
    /// to cover the whole set, and every markup on another drawing's sheet travelled as a row
    /// without geometry, under the wrong fingerprint, for an import to skip.
    static func overlayData(for document: ZenitPDFProjectDocument) async throws -> Data? {
        guard let core = document.core, let drawing = document.drawing, let source = source(of: document) else { return nil }
        let records = await core.session.orderedMarkups
        let projection = try await ProjectWindowController.projection(
            core: core,
            documentName: document.displayName ?? "Takeoff",
            scaleDescription: core.snapshot.documentScaleDescription,
            request: request(core.ledger.request, onDrawing: drawing, of: document, records: records)
        )
        let data = drawingData(for: records, pages: drawing.pages)
        return ZenitOverlayExporter().export(projection, source: source, geometry: data.geometry, placements: data.placements)
    }

    /// `request` narrowed to the markups on `drawing` in a project of several drawings; as it is
    /// in a project of one (W-022).
    static func request(
        _ request: LedgerRequest,
        onDrawing drawing: LoadedDrawing,
        of document: ZenitPDFProjectDocument,
        records: [MarkupRecord]
    ) -> LedgerRequest {
        guard document.drawingSet?.isMultiDrawing == true else { return request }
        let onDrawing = Set(drawing.pages.map(\.id))
        let ids = Set(records.filter { onDrawing.contains($0.pageID) }.map(\.id.rawValue))
        var narrowed = request
        narrowed.markupScope = request.markupScope.map { $0.intersection(ids) } ?? ids
        return narrowed
    }

    /// The export panel's message; in a project of several drawings it names the one drawing the
    /// overlay carries (W-022).
    static func exportPanelMessage(for document: ZenitPDFProjectDocument) -> String {
        let base = NSLocalizedString(
            "The measurements travel with the drawing's fingerprint and open only on the same drawing.",
            comment: "Save panel message for exporting a measurement overlay"
        )
        return document.primaryDrawingOnlySentence().map { base + " " + $0 } ?? base
    }

    static func export(document: ZenitPDFProjectDocument, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ZenitAppInfo.overlayType]
        panel.nameFieldStringValue = "\(document.displayName ?? "Measurements").\(ZenitAppInfo.overlayExtension)"
        panel.message = exportPanelMessage(for: document)
        ZenitModalPresenter.runSavePanel(panel, identifier: exportPanelIdentifier, sheetedOn: window) { answer in
            guard case let .urls(urls) = answer, let url = urls.first else { return }
            Task { @MainActor in
                do {
                    try await write(document: document, to: url)
                } catch {
                    ZenitErrorPresenter.present(error)
                }
            }
        }
    }

    /// Writes the overlay and posts the result note: the half of Export after the panel.
    static func write(document: ZenitPDFProjectDocument, to url: URL) async throws {
        guard let data = try await overlayData(for: document) else { return }
        try data.write(to: url, options: .atomic)
        ExportCompletion.remember(url, document: document)   // R-028
        document.core?.document.post(exportNote(for: document, fileName: url.lastPathComponent))
    }

    /// The note after an export; in a project of several drawings it says which drawing's
    /// measurements the file holds (W-022).
    static func exportNote(for document: ZenitPDFProjectDocument, fileName: String, now: Date = Date()) -> AppWarning {
        var message = NSLocalizedString(
            "Import it onto the same drawing in another project with File ▸ Import Measurements Overlay….",
            comment: "Overlay export confirmation detail"
        )
        if let leftOut = document.primaryDrawingOnlySentence() { message += " " + leftOut }
        return AppWarning(
            id: resultNoteID,
            severity: .info,
            title: String(format: NSLocalizedString("Exported “%@”", comment: "Export confirmation headline; the file name"), fileName),
            message: message,
            source: NSLocalizedString("Overlay", comment: "Status note source for measurement overlays"),
            isDismissible: true,
            timestamp: now
        )
    }

    // MARK: - Import

    /// Reads, checks and applies one overlay file: nothing is added unless the drawing matches,
    /// and everything that is added lands in one undoable step.
    ///
    /// - Returns: the plan that was applied, or `nil` when the file was refused (the refusal has
    ///   been presented).
    @discardableResult
    static func importOverlay(from url: URL, into document: ZenitPDFProjectDocument) async -> ImportPlan? {
        guard let core = document.core, let drawing = document.drawing, let target = source(of: document) else { return nil }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let accepted = try ZenitOverlayImporter().import(data, onto: target)
            let plan = plan(accepted, pages: drawing.pages, documentID: drawing.documentID)
            if !plan.records.isEmpty {
                try await core.commands.performBatch(
                    plan.records.map { .addMarkup($0) },
                    actionName: NSLocalizedString("Import Measurements Overlay", comment: "Undo action name for an overlay import")
                )
            }
            core.document.post(resultNote(for: plan, fileName: url.lastPathComponent))
            return plan
        } catch {
            let alert = NSAlert()
            alert.messageText = String(
                format: NSLocalizedString("“%@” was not imported", comment: "Overlay import refusal headline; the file name"),
                url.lastPathComponent
            )
            alert.informativeText = (error as? ExportError).map { String(describing: $0) } ?? error.localizedDescription
            alert.alertStyle = .warning
            ZenitModalPresenter.runAlert(alert, identifier: refusalIdentifier, answerWithoutAUser: .button(0))
            return nil
        }
    }

    static func importOverlay(document: ZenitPDFProjectDocument, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ZenitAppInfo.overlayType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = NSLocalizedString(
            "Choose a measurements overlay made on this drawing.",
            comment: "Open panel message for importing a measurement overlay"
        )
        ZenitModalPresenter.runOpenPanel(panel, identifier: importPanelIdentifier, sheetedOn: window) { answer in
            guard case let .urls(urls) = answer, let url = urls.first else { return }
            Task { @MainActor in _ = await importOverlay(from: url, into: document) }
        }
    }
}
