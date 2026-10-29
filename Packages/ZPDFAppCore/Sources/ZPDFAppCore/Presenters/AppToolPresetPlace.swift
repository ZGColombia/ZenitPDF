import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// What one Place-mode click did.
public struct ToolPresetPlaceReceipt: Hashable, Sendable {

    /// The markup that was created, or `nil` when nothing was.
    public var markupID: UUID?
    /// Why nothing was placed, when nothing was.
    public var failureMessage: String?
    /// The preset's custom column defaults the placed markup could not take — a column the
    /// document does not have, or text a number or choice column cannot hold. Reported rather
    /// than dropped in silence (BH-116).
    public var skippedCustomColumns: [String]

    /// Creates a receipt.
    public init(markupID: UUID? = nil, failureMessage: String? = nil, skippedCustomColumns: [String] = []) {
        self.markupID = markupID
        self.failureMessage = failureMessage
        self.skippedCustomColumns = skippedCustomColumns
    }

    /// A refusal with a stated reason.
    public static func failure(_ reason: String) -> ToolPresetPlaceReceipt {
        ToolPresetPlaceReceipt(failureMessage: reason)
    }
}

/// The shape a Place-mode click drops, before it becomes a record.
///
/// Separate from the placement itself and free of any actor, so the geometry rule is testable
/// on its own: "a click at (100, 100) with a Rectangle preset produces these four corners" is a
/// property of the tool, not of a document.
public enum ToolPresetPlacement {

    /// The width of the box a Place-mode click drops, in PDF points.
    ///
    /// A placed markup has no drag to take its size from, so it has to start somewhere. This is
    /// a starting size the estimator immediately drags — not a layout measurement of anything,
    /// and not copied from any product.
    public static let defaultBoxWidth: Double = 96
    /// The height of that box, in PDF points.
    public static let defaultBoxHeight: Double = 48

    /// The markup families a single click can complete.
    ///
    /// The test is not "does it look like a stamp" but "is there one sensible shape a click can
    /// make". A Polygon fails it: a polygon placed with a default outline is a rectangle that
    /// lies about what it is, and the estimator would have to redraw it anyway.
    public static let placeableMarkupKinds: Set<Shown.Markup> = [
        .stamp, .note, .text, .callout, .rectangle, .ellipse, .cloud, .revisionCloud, .image, .issue
    ]

    /// The points a click at `origin` places for one markup family.
    ///
    /// Deliberately expressed as the same point list a *drawn* markup would have produced, so
    /// the record goes on to be built by the same geometry function the Draw path uses. That is
    /// what makes a placed markup an ordinary markup rather than a lookalike: there is one
    /// storage schema, and Place feeds it the corners a drag would have produced.
    public static func points(for kind: Shown.Markup, at origin: PDFPointValue) -> [PDFPointValue] {
        let halfWidth = defaultBoxWidth / 2
        let halfHeight = defaultBoxHeight / 2
        let topLeft = PDFPointValue(x: origin.x - halfWidth, y: origin.y - halfHeight)
        let bottomRight = PDFPointValue(x: origin.x + halfWidth, y: origin.y + halfHeight)
        switch kind {
        case .note, .stamp, .image, .issue:
            // Anchored at the click. A stamp's artwork sizes itself from the preset, and the
            // handle the estimator drags is the markup's own.
            return [origin]
        case .callout:
            // Target first, then the box, which is `ZenitMarkupGeometry`'s schema for a callout.
            // The box is offset so the leader is visible rather than folded under the text.
            return [
                origin,
                PDFPointValue(x: origin.x + defaultBoxWidth / 2, y: origin.y - defaultBoxHeight),
                PDFPointValue(x: origin.x + defaultBoxWidth * 1.5, y: origin.y - defaultBoxHeight * 2)
            ]
        default:
            return [topLeft, bottomRight]
        }
    }
}

/// Place mode: one click drops a complete copy of the preset's markup.
///
/// The rule this file keeps is that **a place-mode markup is a markup
/// like any other**: undoable, in History, saved and reopened, and in the Quantity Ledger when
/// it carries a subject. That is not a promise made by resemblance — it is a consequence of
/// going out through ``AppCoreEnvironment/commit(_:family:)``, the same door a drawn markup
/// uses, so there is no second creation path that could get any of the four wrong.
///
/// Stamps and count marks ride on this. A stamp's artwork and a count's symbol
/// are properties of the preset; what Place contributes is the click that turns a preset into a
/// record without a drawing gesture.
extension AppCoreEnvironment {

    /// Drops one copy of a preset's markup at a page point.
    ///
    /// - Parameters:
    ///   - preset: the armed preset.
    ///   - point: where the click landed, in page space.
    ///   - pageID: the page it landed on.
    /// - Returns: a receipt naming the new markup, or the reason there is none.
    @discardableResult
    public func placePreset(
        _ preset: ToolPresetSummary,
        at point: PDFPointValue,
        pageID: UUID
    ) async -> ToolPresetPlaceReceipt {
        await placePreset(preset, at: point, pageID: pageID, promptedText: "", promptedTexts: [:], now: Date())
    }

    /// Drops one copy of a preset's markup, resolving and freezing a stamp preset's fields.
    ///
    /// The one Place door, for stamps too. The canvas's Place click calls
    /// ``placePreset(_:at:pageID:)``, and that used to build a stamp record with no
    /// `StampInstance` on it — no artwork, no resolved date, author or page fields, no audit
    /// note — so a single-click stamp drew nothing at all (BH-013). A stamp preset now gets its
    /// instance here, whichever of the two entry points was called.
    func placePreset(
        _ preset: ToolPresetSummary,
        at point: PDFPointValue,
        pageID: UUID,
        promptedText: String,
        promptedTexts: [Int: String] = [:],
        now: Date
    ) async -> ToolPresetPlaceReceipt {
        // The preset's ledger identity includes its custom column values, and a column key is
        // only meaningful against the document's own column set — so it is resolved here rather
        // than stored resolved on the preset, where a project with different columns would
        // silently drop them.
        let resolved = Self.resolvedCustomValues(
            preset.customDefaults, columns: await session.ledgerColumns, currencyCode: ledger.defaultCurrencyCode
        )
        let stampContext = preset.stamp.map { _ in
            stampContext(pageID: pageID, now: now, promptedText: promptedText, promptedTexts: promptedTexts)
        }

        guard var record = Self.placementRecord(
            for: preset,
            at: point,
            pageID: PageID(pageID),
            documentID: DocumentID(snapshot.documentID),
            author: stampContext?.author ?? AuthorIdentity.current(),
            customValues: resolved.values,
            now: now,
            identifier: UUID()
        ) else {
            return .failure(String(
                format: NSLocalizedString(
                    "“%@” has to be drawn: Place drops a complete markup, and this tool has no shape of its own.",
                    comment: "Place-mode refusal. %@ is the preset name"
                ),
                preset.name
            ))
        }
        if let template = preset.stamp, let stampContext {
            record.stamp = StampBridge.instance(of: template, named: preset.name, in: stampContext)
        }
        await commit(record, family: record.tool == nil ? .markup : .measurement)
        return ToolPresetPlaceReceipt(markupID: record.id.rawValue, skippedCustomColumns: resolved.skipped)
    }

    /// The record a Place-mode click produces, or `nil` when the preset cannot be placed.
    ///
    /// `static` and pure — every input is a parameter, including the clock, the author and the
    /// identifier — so the whole of Place mode's record construction is testable without a
    /// session, a database or a window.
    static func placementRecord(
        for preset: ToolPresetSummary,
        at point: PDFPointValue,
        pageID: PageID,
        documentID: DocumentID,
        author: String,
        customValues: [ColumnID: Domain.CellValue] = [:],
        now: Date,
        identifier: UUID
    ) -> MarkupRecord? {
        let geometry: MeasurementGeometry
        let kind: Domain.Kind
        let tool: MeasurementTool?

        if let measurementKind = preset.measurementKind {
            // Count is the one measurement a single click completes: its geometry is the marks
            // themselves, and one mark is a valid count of one. Every other measurement needs an
            // outline or a run, and a default one would be a number nobody measured.
            guard measurementKind == .count else { return nil }
            // In `countPoints`, as the Count tool writes it (V-031). The mark in `points` counted
            // as one, but Continue preloaded only `countPoints` and dropped it, Number Marks
            // skipped the count, and the save stored it as a polyline.
            geometry = MeasurementGeometry(
                pageID: pageID,
                countPoints: [CountPoint(id: CountPointID(identifier), position: PDFPoint(x: point.x, y: point.y))]
            )
            kind = .count
            tool = .count
        } else {
            guard ToolPresetPlacement.placeableMarkupKinds.contains(preset.markupKind) else {
                return nil
            }
            geometry = AppMarkupToolPresenter.geometry(
                kind: preset.markupKind,
                points: ToolPresetPlacement.points(for: preset.markupKind, at: point),
                pageID: pageID
            )
            kind = Domain.Kind(shown: preset.markupKind)
            tool = nil
        }

        // The measurement parameters ride along even for a Count, which needs none today: a
        // preset's parameters are what it *is*, and dropping them at the one moment a markup is
        // created would lose them for good. `nil` when the preset carries nothing, so an
        // ordinary stamp does not acquire an empty parameter block.
        let parameters: MeasurementParameters? = preset.measurementDefaults.carriesAnyValue
            ? ToolPresetParameterBridge.parameters(applying: preset.measurementDefaults)
            : nil

        return MarkupRecord(
            id: MarkupID(identifier),
            documentID: documentID,
            pageID: pageID,
            kind: kind,
            tool: tool,
            subject: preset.defaultSubject,
            label: preset.labelPattern,
            author: author,
            status: Domain.Status(shown: preset.defaultStatus),
            style: AppMarkupToolPresenter.markupStyle(
                kind: preset.markupKind,
                style: preset.placementStyle  // NL-MARKUP-15
            ),
            geometry: geometry,
            parameters: parameters,
            customValues: customValues,
            // The chosen symbol travels with the mark, not with the tool (spec 12.13,
            // ADR-0011 §2.1). A Place click on "Door Count" drops a mark that knows it is a
            // door, and stays a door after the preset is renamed, re-symbolised or deleted.
            symbol: kind == .count ? CountSymbolCatalogue.symbol(for: preset) : nil,
            createdAt: now,
            modifiedAt: now
        )
    }
}
