import Foundation
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFSnapEngine
import ZPDFUIPresentation

/// The project-level names a `MarkupRecord`'s identifiers stand for.
///
/// A record stores a `ZoneID`, not the word "Basement". Handing the whole table to the
/// bridge once is what keeps building a scroll window from becoming a scroll window's worth
/// of lookups into a database — the same argument `LedgerNameCatalog` makes on the engine
/// side, and the two are kept in step by ``ProjectNameTable/ledgerCatalog``.
public struct ProjectNameTable: Hashable, Sendable {

    /// Page label and zero-based index per page.
    public var pages: [PageID: LedgerPageInfo]
    /// Project Zone names.
    public var zones: [ZoneID: String]
    /// Layer names.
    public var layers: [LayerID: String]
    /// ADR-0032: the hidden and the locked markup layers, which the summaries fold into each
    /// markup's own flags. Not part of ``ledgerCatalog``: a layer flag never touches the ledger.
    public var hiddenLayers: Set<LayerID> = []
    public var lockedLayers: Set<LayerID> = []
    /// Scale Region names.
    public var scaleRegions: [ScaleRegionID: String]
    /// Scale names, for example `"1:50"`.
    public var scales: [ScaleID: String]

    /// Creates a name table.
    public init(
        pages: [PageID: LedgerPageInfo] = [:],
        zones: [ZoneID: String] = [:],
        layers: [LayerID: String] = [:],
        scaleRegions: [ScaleRegionID: String] = [:],
        scales: [ScaleID: String] = [:]
    ) {
        self.pages = pages
        self.zones = zones
        self.layers = layers
        self.scaleRegions = scaleRegions
        self.scales = scales
    }

    /// An empty table.
    public static let empty = ProjectNameTable()

    /// The same names in the shape ``LedgerStore`` takes.
    public var ledgerCatalog: LedgerNameCatalog {
        LedgerNameCatalog(
            pages: pages,
            zones: zones,
            layers: layers,
            scaleRegions: scaleRegions,
            scales: scales
        )
    }

    /// Builds a table from a page list, keeping label and index together.
    public static func pages(_ descriptors: [ZPDFContracts.PageDescriptor]) -> ProjectNameTable {
        var table = ProjectNameTable()
        // The position in the set, not the page's index in its PDF (ADR-0022): the ledger
        // orders sheets as the set does.
        for (position, page) in descriptors.enumerated() {
            table.pages[page.id] = LedgerPageInfo(label: page.label, index: position)
        }
        return table
    }
}

// MARK: - Measurement results

extension MeasurementFieldSummary {

    /// One field of a measurement result, already formatted.
    ///
    /// The raw quantity travels with the text, so a view can re-format for a unit change
    /// without asking the engine to recompute, and an export can read the unrounded value.
    init(
        field: Shown.Field,
        quantity: Domain.Quantity,
        formatter: QuantityFormatter,
        isDerived: Bool,
        warning: MeasurementWarningSummary?
    ) {
        let shown = Shown.Quantity(domain: quantity)
        let text: String
        if field == .slopeRatio {
            text = formatter.slopeText(ratio: shown.value)
        } else {
            text = formatter.text(shown)
        }
        self.init(
            field: field,
            quantity: shown,
            displayText: text,
            displayUnitSymbol: field == .slopeRatio ? "" : formatter.symbol(shown),
            isDerived: isDerived,
            warning: warning
        )
    }
}

/// Turns engine results into the values the UI renders.
public enum MarkupBridge {

    /// The fields of a measurement result, in the palette's declared field order so that a
    /// row of readouts does not reshuffle itself between two measurements.
    ///
    /// - Parameters:
    ///   - result: what the measurement engine produced, in SI base units.
    ///   - tool: the tool that produced it, used to decide which field is the headline.
    ///   - formatter: units and precision in force.
    public static func fields(
        of result: MeasurementResult,
        tool: Domain.Tool?,
        formatter: QuantityFormatter
    ) -> [MeasurementFieldSummary] {
        let primary = tool.map { Shown.Kind(domain: $0).primaryField }
        let warningsByField = Dictionary(
            result.warnings.compactMap { warning -> (Shown.Field, MeasurementWarningSummary)? in
                guard let field = warning.field.flatMap({ Shown.Field(domain: $0) }),
                      let summary = MeasurementWarningSummary(domain: warning.code)
                else { return nil }
                return (field, summary)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var summaries: [MeasurementFieldSummary] = []
        for shownField in Shown.Field.allCases {
            let domainField = Domain.Field(shown: shownField)
            guard let quantity = result.values[domainField] else { continue }
            summaries.append(
                MeasurementFieldSummary(
                    field: shownField,
                    quantity: quantity,
                    formatter: formatter,
                    isDerived: shownField != primary,
                    warning: warningsByField[shownField]
                )
            )
        }
        return summaries
    }

    /// The warnings of a measurement result that the UI has copy for, deduplicated and in
    /// the order the engine raised them.
    public static func warnings(of result: MeasurementResult) -> [MeasurementWarningSummary] {
        var seen: Set<MeasurementWarningSummary> = []
        var ordered: [MeasurementWarningSummary] = []
        for warning in result.warnings {
            guard let summary = MeasurementWarningSummary(domain: warning.code) else { continue }
            guard seen.insert(summary).inserted else { continue }
            ordered.append(summary)
        }
        return ordered
    }

    /// One markup, as the canvas and the inspector see it.
    public static func summary(
        of record: MarkupRecord,
        names: ProjectNameTable,
        formatter: QuantityFormatter
    ) -> MarkupSummary {
        let page = names.pages[record.pageID]
        let measurement = record.measurement ?? .empty
        var summary = MarkupSummary(
            id: record.id.rawValue,
            kind: Shown.Markup(domain: record.kind),
            measurementKind: record.tool.map { Shown.Kind(domain: $0) },
            subject: record.subject,
            label: record.label,
            comment: record.comment,
            pageLabel: page?.label ?? "",
            pageID: record.pageID.rawValue,
            pageIndex: page?.index ?? 0,
            zone: record.zoneID.flatMap { names.zones[$0] },
            zoneID: record.zoneID?.rawValue,
            scaleRegionName: record.scaleRegionID.flatMap { names.scaleRegions[$0] },
            status: Shown.Status(domain: record.status),
            author: record.author,
            locked: record.locked,
            hidden: record.hidden,
            colorRGBA: ColorRGBA(domain: record.style.color),
            lineWidth: record.style.lineWidth,
            opacity: record.style.opacity,
            lineStyle: MarkupLineStyle(domain: record.style.lineStyle),
            fontSize: record.style.fontSize,
            measurementFields: fields(of: measurement, tool: record.tool, formatter: formatter),
            layer: names.layers[record.effectiveLayerID] ?? names.layers[MarkupLayer.defaultID],
            created: record.createdAt,
            modified: record.modifiedAt,
            boundsInPageSpace: bounds(of: record),
            parentID: record.parentMarkupID?.rawValue,
            // Carried so "make this a tool" can capture the maths and not only the ink. The
            // Tool Library never sees a `MarkupRecord`, so without this line the parameters
            // were unreachable at exactly the moment a preset is created from a selection —
            // an omission that would make a tool library useless.
            measurementDefaults: record.parameters.map(ToolPresetParameterBridge.defaults(of:)),
            // Identity only. The batch planner asks "does this page already carry the same
            // stamp?" once per markup on a 1 000-page set, and the answer is the template
            // id; the resolved field text stays on the record where it was frozen.
            stampTemplateID: record.stamp?.templateID,
            // Feature 11's multiplier, lifted out of the reserved `Repeat ×` cell so that the
            // canvas, the inspector and every list can show it without learning what a custom
            // column is. `nil` when the markup carries no repeat cell — which reads as once.
            repeatCount: RepetitionColumn.repeatCount(of: record),
            // The fill the canvas already draws, so the Inspector's Fill Colour row shows and
            // edits the stored value rather than guessing from the stroke.
            fillRGBA: record.style.fill.map { ColorRGBA(domain: $0) }
        )
        // NL-COLLAB-18: the words a Text or Callout draws, apart from its note.
        if MarkupVisibleText.carriesVisibleText(record) {
            summary.drawnText = MarkupVisibleText.text(of: record)
        }
        // Line ends, font and alignment, so the Inspector and the style strip can
        // show and edit them (`MarkupStyleBridge.swift`).
        MarkupStyleBridge.carry(record.style, into: &summary)
        MarkupStyleBridge.carry(recordFieldsOf: record, into: &summary)
        // ADR-0032: the layer, resolved (an id the project no longer holds is the default layer),
        // and its flags folded into the markup's own so every list and the canvas presenter read
        // "hidden" and "locked" once. The layer's own share is kept apart for the Inspector.
        let layerID = names.layers[record.effectiveLayerID] != nil ? record.effectiveLayerID : MarkupLayer.defaultID
        summary.layerID = layerID.rawValue
        if names.hiddenLayers.contains(layerID) {
            summary.hidden = true
            summary.layerHidden = true
        }
        if names.lockedLayers.contains(layerID) {
            summary.locked = true
            summary.layerLocked = true
        }
        return summary
    }

    /// The page-space bounding box of a markup's geometry, or an empty box at the origin
    /// for a markup that has none.
    public static func bounds(of record: MarkupRecord) -> PDFRectValue {
        guard let box = record.geometry?.bounds else { return .zero }
        return PDFRectValue(domain: box)
    }

    /// The snap geometry a committed markup contributes to the page index, or `nil` when
    /// the markup has nothing snappable on it. `unprojectedCutouts` are the record's cutouts
    /// that project nothing themselves — hidden, or on a hidden layer — whose holes the parent
    /// still draws (V-085).
    public static func snapGeometry(of record: MarkupRecord, unprojectedCutouts: [MarkupRecord] = []) -> SnapMarkupGeometry? {
        SnapMarkupGeometry.from(record, unprojectedCutouts: unprojectedCutouts)
    }
}

extension MarkupLineStyle {

    /// The presentation mirror of the contract's `LineStyle`.
    public init(domain: ZPDFContracts.LineStyle) {
        switch domain {
        case .solid: self = .solid
        case .dashed: self = .dashed
        case .dotted: self = .dotted
        case .dashDot: self = .dashDot
        case .cloud: self = .cloud
        }
    }

    /// Back to the domain, for a style edit on its way to the command bus.
    public var domain: ZPDFContracts.LineStyle {
        switch self {
        case .solid: return .solid
        case .dashed: return .dashed
        case .dotted: return .dotted
        case .dashDot: return .dashDot
        case .cloud: return .cloud
        }
    }
}
