// Debug and test builds only (R-142): a plain release build of ZPDFUIPresentation ships no
// mock. A release build that compiles tests passes -DZPDF_MOCKS (verify-viewer-budgets.sh).
#if DEBUG || ZPDF_MOCKS
import Foundation

extension ZenitSampleProject {

    // MARK: - Small helpers

    /// The palette colour the sample uses for a dimension, so the canvas legend is
    /// readable at a glance. Colour is never the only cue; the ledger always shows text.
    static func color(for dimension: QuantityDimension) -> ColorRGBA {
        switch dimension.lengthPower {
        case 1: return ColorRGBA.Zenit.Dark.cyan
        case 2: return ColorRGBA.Zenit.Dark.blue
        case 3: return ColorRGBA.Zenit.Dark.warning
        default: return ColorRGBA.Zenit.Dark.green
        }
    }

    /// The ledger column that carries a measurement field's value.
    static func column(for field: MeasurementField) -> LedgerColumnID {
        switch field {
        case .count: return .count
        case .planLength: return .planLength
        case .trueLength: return .trueLength
        case .perimeter: return .perimeter
        case .planArea, .netArea: return .planArea
        case .trueArea: return .trueArea
        case .wallArea: return .wallArea
        case .volume: return .volume
        case .rise: return .rise
        case .run: return .run
        case .slopeRatio: return .slopeRatio
        case .slopePercent: return .slopePercent
        case .slopeAngle: return .slopeAngle
        case .depth: return .depth
        case .height: return .height
        case .radius: return .radius
        case .diameter: return .diameter
        // BH-781: no dedicated sample column exists for these; each gets its own identity
        // rather than overwriting Diameter, Plan Length or Slope Angle.
        case .circumference, .arcLength, .angle: return LedgerColumnID(field.rawValue)
        }
    }

    /// The display unit symbol the sample uses for a dimension.
    static func unitSymbol(for dimension: QuantityDimension) -> String {
        if let code = dimension.currencyCode { return code }
        if dimension.angle { return AngleDisplayUnit.degrees.symbol }
        switch dimension.lengthPower {
        case 1: return LengthUnit.metre.symbol
        case 2: return AreaUnit.squareMetre.symbol
        case 3: return VolumeUnit.cubicMetre.symbol
        default: return ""
        }
    }

    /// Builds a formatted measurement field summary from a raw quantity.
    static func fieldSummary(
        _ field: MeasurementField,
        _ quantity: DecimalQuantity,
        isDerived: Bool = false,
        warning: MeasurementWarningSummary? = nil
    ) -> MeasurementFieldSummary {
        MeasurementFieldSummary(
            field: field,
            quantity: quantity,
            displayText: SampleFormatting.string(quantity),
            displayUnitSymbol: unitSymbol(for: quantity.dimension),
            isDerived: isDerived,
            warning: warning
        )
    }

    /// A stable `YYYY-MM-DD` rendering, independent of the host locale.
    static func dateText(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The Footing Detail Scale Region's outline, inside the Foundation zone (BH-783).
    static let footingRegionBoundary: [PDFPointValue] = [
        PDFPointValue(x: 1260, y: 980),
        PDFPointValue(x: 1880, y: 980),
        PDFPointValue(x: 1880, y: 1500),
        PDFPointValue(x: 1260, y: 1500)
    ]

    /// The `index`th 220 × 130 pt markup box of a grid laid inside a rectangular outline.
    static func slot(_ index: Int, in outline: [PDFPointValue], columns: Int) -> PDFRectValue {
        let minX = outline.map(\.x).min() ?? 0
        let minY = outline.map(\.y).min() ?? 0
        let column = index % max(1, columns)
        let row = index / max(1, columns)
        return PDFRectValue(
            x: minX + 20 + Double(column) * 260,
            y: minY + 20 + Double(row) * 170,
            width: 220,
            height: 130
        )
    }

    /// A simple rectangular zone outline in page space.
    static func zoneBoundary(index: Int) -> [PDFPointValue] {
        let x = 120.0 + Double(index % 2) * 1120
        let y = 140.0 + Double(index / 2) * 760
        return [
            PDFPointValue(x: x, y: y),
            PDFPointValue(x: x + 1060, y: y),
            PDFPointValue(x: x + 1060, y: y + 700),
            PDFPointValue(x: x, y: y + 700)
        ]
    }

    // MARK: - Takeoff seeds

    /// The forty hand-authored takeoff items: nine lengths, four perimeters, thirteen
    /// areas, eleven counts and five volumes, across three sheets and four zones.
    static func takeoffSeeds(footingRegionName: String) -> [TakeoffSeed] {
        TakeoffSeedList.all(footingRegionName: footingRegionName)
    }

    // MARK: - Ledger columns

    /// Builds the sample ledger: fifteen standard columns plus four custom columns, one
    /// of which is a formula column.
    static func makeColumns(zoneNames: [String], currencyCode: String) -> [LedgerColumn] {
        let zoneChoices = zoneNames.enumerated().map { index, name in
            LedgerChoiceOption(
                id: SampleFormatting.sampleID(500 + index),
                value: name,
                title: name,
                colorRGBA: ColorRGBA.Zenit.Dark.cyan,
                order: index
            )
        }
        let statusChoices = MarkupStatus.allCases.enumerated().map { index, status in
            LedgerChoiceOption(
                id: SampleFormatting.sampleID(520 + index),
                value: status.rawValue,
                title: status.displayName,
                colorRGBA: status.indicatorColor,
                order: index
            )
        }
        let materials = ["Gypsum", "Concrete", "Screed", "Mineral Fibre", "Carpet", "Ceramic", "Steel", "Glass", "Timber", "Electrical"]
        let materialChoices = materials.enumerated().map { index, name in
            LedgerChoiceOption(
                id: SampleFormatting.sampleID(540 + index),
                value: name,
                title: name,
                colorRGBA: ColorRGBA.Zenit.Dark.secondary,
                order: index
            )
        }
        let trades = ["Carpentry", "Concrete", "Flooring", "Ceilings", "Electrical", "Mechanical", "Glazing", "Reinforcement"]
        let tradeChoices = trades.enumerated().map { index, name in
            LedgerChoiceOption(
                id: SampleFormatting.sampleID(560 + index),
                value: name,
                title: name,
                colorRGBA: ColorRGBA.Zenit.Dark.secondary,
                order: index
            )
        }

        return [
            LedgerColumn(
                id: .icon,
                title: NSLocalizedString("Type", comment: "Ledger column header"),
                kind: .text, width: 32, pinned: true, alignment: .center
            ),
            LedgerColumn(
                id: .subject,
                title: NSLocalizedString("Subject", comment: "Ledger column header"),
                kind: .text, width: 200, pinned: true, isEditable: true
            ),
            LedgerColumn(
                id: .label,
                title: NSLocalizedString("Label", comment: "Ledger column header"),
                kind: .text, width: 180, isEditable: true
            ),
            LedgerColumn(
                id: .pageLabel,
                title: NSLocalizedString("Page", comment: "Ledger column header"),
                kind: .text, width: 80
            ),
            LedgerColumn(
                id: .pageIndex,
                title: NSLocalizedString("Page Index", comment: "Ledger column header"),
                kind: .number, width: 80, visible: false, alignment: .trailing
            ),
            LedgerColumn(
                id: .projectZone,
                title: NSLocalizedString("Project Zone", comment: "Ledger column header"),
                kind: .choice, width: 200, isEditable: true, choices: zoneChoices
            ),
            LedgerColumn(
                id: .scaleRegion,
                title: NSLocalizedString("Scale Region", comment: "Ledger column header"),
                kind: .text, width: 160, visible: false
            ),
            LedgerColumn(
                id: .status,
                title: NSLocalizedString("Status", comment: "Ledger column header"),
                kind: .choice, width: 120, isEditable: true, choices: statusChoices
            ),
            LedgerColumn(
                id: .author,
                title: NSLocalizedString("Author", comment: "Ledger column header"),
                kind: .text, width: 130
            ),
            LedgerColumn(
                id: .created,
                title: NSLocalizedString("Created", comment: "Ledger column header"),
                kind: .date, width: 110, visible: false
            ),
            LedgerColumn(
                id: .modified,
                title: NSLocalizedString("Modified", comment: "Ledger column header"),
                kind: .date, width: 110, visible: false
            ),
            LedgerColumn(
                id: .count,
                title: NSLocalizedString("Count", comment: "Ledger column header"),
                kind: .number, dimension: .count, width: 80,
                alignment: .trailing, aggregate: .sum
            ),
            LedgerColumn(
                id: .planLength,
                title: NSLocalizedString("Plan Length", comment: "Ledger column header"),
                kind: .number, dimension: .length, width: 110,
                alignment: .trailing, aggregate: .sum,
                displayUnitSymbol: LengthUnit.metre.symbol
            ),
            LedgerColumn(
                id: .perimeter,
                title: NSLocalizedString("Perimeter", comment: "Ledger column header"),
                kind: .number, dimension: .length, width: 110,
                alignment: .trailing, aggregate: .sum,
                displayUnitSymbol: LengthUnit.metre.symbol
            ),
            LedgerColumn(
                id: .planArea,
                title: NSLocalizedString("Plan Area", comment: "Ledger column header"),
                kind: .number, dimension: .area, width: 110,
                alignment: .trailing, aggregate: .sum,
                displayUnitSymbol: AreaUnit.squareMetre.symbol
            ),
            LedgerColumn(
                id: .trueLength,
                title: NSLocalizedString("True Length", comment: "Ledger column header"),
                kind: .number, dimension: .length, width: 110, visible: false,
                alignment: .trailing, aggregate: .sum,
                displayUnitSymbol: LengthUnit.metre.symbol
            ),
            LedgerColumn(
                id: .trueArea,
                title: NSLocalizedString("True Area", comment: "Ledger column header"),
                kind: .number, dimension: .area, width: 110, visible: false,
                alignment: .trailing, aggregate: .sum,
                displayUnitSymbol: AreaUnit.squareMetre.symbol
            ),
            LedgerColumn(
                id: .volume,
                title: NSLocalizedString("Volume", comment: "Ledger column header"),
                kind: .number, dimension: .volume, width: 110,
                alignment: .trailing, aggregate: .sum,
                displayUnitSymbol: VolumeUnit.cubicMetre.symbol
            ),
            LedgerColumn(
                id: .depth,
                title: NSLocalizedString("Depth", comment: "Ledger column header"),
                kind: .number, dimension: .length, width: 90, visible: false,
                alignment: .trailing,
                displayUnitSymbol: LengthUnit.metre.symbol
            ),
            LedgerColumn(
                id: .material,
                title: NSLocalizedString("Material", comment: "Ledger column header"),
                kind: .choice, width: 140, isEditable: true, choices: materialChoices
            ),
            LedgerColumn(
                id: .trade,
                title: NSLocalizedString("Trade", comment: "Ledger column header"),
                kind: .choice, width: 140, isEditable: true, choices: tradeChoices
            ),
            LedgerColumn(
                id: .comment,
                title: NSLocalizedString("Comment", comment: "Ledger column header"),
                kind: .text, width: 220, visible: false, isEditable: true
            ),
            LedgerColumn(
                id: .unitCost,
                title: NSLocalizedString("Unit Cost", comment: "Ledger column header"),
                kind: .currency, dimension: .currency(currencyCode), width: 110,
                alignment: .trailing, isEditable: true,
                displayUnitSymbol: currencyCode
            ),
            LedgerColumn(
                id: .totalCost,
                title: NSLocalizedString("Total Cost", comment: "Ledger column header"),
                kind: .currency, dimension: .currency(currencyCode), width: 130,
                alignment: .trailing, aggregate: .sum,
                displayUnitSymbol: currencyCode
            ),
            LedgerColumn(
                id: ZenitSampleProject.wasteFactorColumn,
                title: NSLocalizedString("Waste Factor", comment: "Custom ledger column header"),
                kind: .number, dimension: .ratio, width: 110,
                alignment: .trailing, isEditable: true
            ),
            LedgerColumn(
                id: ZenitSampleProject.approvedColumn,
                title: NSLocalizedString("Approved", comment: "Custom ledger column header"),
                kind: .checkbox, width: 90, alignment: .center, isEditable: true
            ),
            LedgerColumn(
                id: ZenitSampleProject.installDateColumn,
                title: NSLocalizedString("Install Date", comment: "Custom ledger column header"),
                kind: .date, width: 120, isEditable: true
            ),
            LedgerColumn(
                id: ZenitSampleProject.extendedCostColumn,
                title: NSLocalizedString("Extended Cost", comment: "Custom formula ledger column header"),
                kind: .formula, dimension: .currency(currencyCode), width: 140,
                alignment: .trailing,
                formulaSource: ZenitSampleProject.extendedCostFormula,
                aggregate: .sum,
                displayUnitSymbol: currencyCode
            )
        ]
    }

    // MARK: - Tool Library

    /// Eight presets spread across the editable Tool Library panels.
    static func makePresets() -> [ToolPresetSummary] {
        [
            ToolPresetSummary(
                id: SampleFormatting.sampleID(600),
                name: "Interior Partition",
                category: "Carpentry",
                panel: .myTools,
                markupKind: .measurement,
                measurementKind: .polylength,
                colorRGBA: ColorRGBA.Zenit.Dark.cyan,
                defaultSubject: "Interior Partition",
                displayLengthUnit: .metre,
                customDefaults: ["material": "Gypsum", "trade": "Carpentry"],
                isFavorite: true,
                shortcutDisplayString: "⌥1",
                sortIndex: 0
            ),
            ToolPresetSummary(
                id: SampleFormatting.sampleID(601),
                name: "Floor Screed",
                category: "Flooring",
                panel: .myTools,
                markupKind: .measurement,
                measurementKind: .area,
                colorRGBA: ColorRGBA.Zenit.Dark.blue,
                defaultSubject: "Floor Screed",
                displayLengthUnit: .metre,
                customDefaults: ["material": "Screed", "trade": "Flooring"],
                isFavorite: true,
                shortcutDisplayString: "⌥2",
                sortIndex: 1
            ),
            ToolPresetSummary(
                id: SampleFormatting.sampleID(602),
                name: "Slab on Grade",
                category: "Concrete",
                panel: .projectTools,
                markupKind: .measurement,
                measurementKind: .volume,
                colorRGBA: ColorRGBA.Zenit.Dark.warning,
                defaultSubject: "Slab on Grade",
                defaultDepth: DecimalQuantity.metres(Decimal(string: "0.30") ?? 0),
                displayLengthUnit: .metre,
                customDefaults: ["material": "Concrete", "trade": "Concrete"],
                sortIndex: 0
            ),
            ToolPresetSummary(
                id: SampleFormatting.sampleID(603),
                name: "Strip Footing",
                category: "Concrete",
                panel: .projectTools,
                markupKind: .measurement,
                measurementKind: .volume,
                colorRGBA: ColorRGBA.Zenit.Dark.warning,
                defaultSubject: "Strip Footing",
                defaultDepth: DecimalQuantity.metres(Decimal(string: "0.60") ?? 0),
                displayLengthUnit: .metre,
                customDefaults: ["material": "Concrete", "trade": "Concrete"],
                sortIndex: 1
            ),
            ToolPresetSummary(
                id: SampleFormatting.sampleID(604),
                name: "Wall Area — 2.70 m",
                category: "Carpentry",
                panel: .projectTools,
                markupKind: .measurement,
                measurementKind: .wallArea,
                colorRGBA: ColorRGBA.Zenit.Dark.blue,
                defaultSubject: "Wall Finish",
                defaultHeight: DecimalQuantity.metres(Decimal(string: "2.70") ?? 0),
                displayLengthUnit: .metre,
                customDefaults: ["trade": "Carpentry"],
                sortIndex: 2
            ),
            ToolPresetSummary(
                id: SampleFormatting.sampleID(605),
                name: "Power Outlet",
                category: "Electrical",
                panel: .countSymbols,
                markupKind: .count,
                measurementKind: .count,
                colorRGBA: ColorRGBA.Zenit.Dark.green,
                defaultSubject: "Power Outlet",
                displayLengthUnit: .metre,
                customDefaults: ["trade": "Electrical"],
                countSymbolName: "bolt.circle",
                isFavorite: true,
                sortIndex: 0
            ),
            ToolPresetSummary(
                id: SampleFormatting.sampleID(606),
                name: "Ceiling Luminaire",
                category: "Electrical",
                panel: .countSymbols,
                markupKind: .count,
                measurementKind: .count,
                colorRGBA: ColorRGBA.Zenit.Dark.green,
                defaultSubject: "Ceiling Luminaire",
                displayLengthUnit: .metre,
                customDefaults: ["trade": "Electrical"],
                countSymbolName: "lightbulb.circle",
                sortIndex: 1
            ),
            ToolPresetSummary(
                id: SampleFormatting.sampleID(607),
                name: "Nordic Concrete Set",
                category: "Shared",
                panel: .importedLibraries,
                markupKind: .measurement,
                measurementKind: .area,
                colorRGBA: ColorRGBA.Zenit.Dark.secondary,
                defaultSubject: "Concrete Finish",
                displayLengthUnit: .metre,
                isReadOnly: true,
                sortIndex: 0
            )
        ]
    }

    // MARK: - Revisions and compare

    /// Three revisions of the ground floor sheet.
    static func makeRevisions(documentID: UUID) -> [RevisionSummary] {
        [
            RevisionSummary(
                id: SampleFormatting.sampleID(700),
                documentID: documentID,
                name: "Ground Floor Plan",
                revisionLabel: "Rev A",
                issuedDate: SampleFormatting.sampleDate(days: -84),
                author: "Sample Architects",
                pageCount: 3,
                isBaseline: true,
                colorRGBA: ColorRGBA.Zenit.Dark.secondary,
                fileName: "A-101-RevA.pdf"
            ),
            RevisionSummary(
                id: SampleFormatting.sampleID(701),
                documentID: documentID,
                name: "Ground Floor Plan",
                revisionLabel: "Rev B",
                issuedDate: SampleFormatting.sampleDate(days: -35),
                author: "Sample Architects",
                pageCount: 3,
                colorRGBA: ColorRGBA.Zenit.Dark.cyan,
                fileName: "A-101-RevB.pdf"
            ),
            RevisionSummary(
                id: SampleFormatting.sampleID(702),
                documentID: documentID,
                name: "Ground Floor Plan",
                revisionLabel: "Rev C",
                issuedDate: SampleFormatting.sampleDate(days: -7),
                author: "Sample Architects",
                pageCount: 3,
                colorRGBA: ColorRGBA.Zenit.Dark.blue,
                fileName: "A-101-RevC.pdf"
            )
        ]
    }

    /// Five candidate differences between Rev A and Rev C.
    static func makeDiffs(pages: [PageDescriptor]) -> [CompareDiffSummary] {
        let specs: [(CompareChangeKind, Int, Double, Double, Double, Bool)] = [
            (.added, 0, 640, 420, 0.94, false),
            (.modified, 0, 1180, 300, 0.81, false),
            (.removed, 0, 380, 240, 0.76, true),
            (.added, 1, 520, 360, 0.88, false),
            (.modified, 2, 300, 220, 0.63, false)
        ]
        return specs.enumerated().map { offset, spec in
            let (kind, pageIndex, width, height, confidence, accepted) = spec
            let page = pages[pageIndex]
            let bounds = PDFRectValue(
                x: 220 + Double(offset) * 260,
                y: 300 + Double(offset % 3) * 320,
                width: width,
                height: height
            )
            return CompareDiffSummary(
                id: SampleFormatting.sampleID(720 + offset),
                changeKind: kind,
                baselinePageID: kind == .added ? nil : page.id,
                comparisonPageID: kind == .removed ? nil : page.id,
                pageLabel: page.label,
                baselineBounds: kind == .added ? nil : bounds,
                comparisonBounds: kind == .removed ? nil : bounds,
                areaInSquarePoints: bounds.areaInSquarePoints,
                confidence: confidence,
                isAccepted: accepted,
                promotedMarkupID: accepted ? SampleFormatting.sampleID(740 + offset) : nil
            )
        }
        .sorted { $0.areaInSquarePoints > $1.areaInSquarePoints }
    }

    // MARK: - Search

    /// Six hits for the query `"screed"` across PDF text, markups and comments.
    static func makeSearchHits(
        documentID: UUID,
        documentTitle: String,
        pages: [PageDescriptor],
        markups: [MarkupSummary]
    ) -> [SearchHit] {
        let screedMarkups = markups.filter { $0.subject == "Floor Screed" }
        var hits: [SearchHit] = [
            SearchHit(
                id: SampleFormatting.sampleID(800),
                documentID: documentID,
                documentTitle: documentTitle,
                pageID: pages[0].id,
                pageIndex: 0,
                pageLabel: pages[0].label,
                source: .pdfText,
                snippet: "50 mm floor screed on separating layer, see detail 4/A-501",
                // BH-782: "screed" is UTF-16 12..<18; 7..<13 highlighted "loor s".
                highlightRange: 12..<18,
                boundsInPageSpace: PDFRectValue(x: 1420, y: 980, width: 420, height: 24)
            ),
            SearchHit(
                id: SampleFormatting.sampleID(801),
                documentID: documentID,
                documentTitle: documentTitle,
                pageID: pages[1].id,
                pageIndex: 1,
                pageLabel: pages[1].label,
                source: .pdfText,
                snippet: "Screed to fall 1:100 towards floor gully",
                highlightRange: 0..<6,
                boundsInPageSpace: PDFRectValue(x: 900, y: 1210, width: 380, height: 24)
            ),
            SearchHit(
                id: SampleFormatting.sampleID(802),
                documentID: documentID,
                documentTitle: documentTitle,
                pageID: pages[2].id,
                pageIndex: 2,
                pageLabel: pages[2].label,
                source: .ocrText,
                snippet: "SCREED THICKNESS TO BE CONFIRMED ON SITE",
                highlightRange: 0..<6,
                boundsInPageSpace: PDFRectValue(x: 460, y: 320, width: 520, height: 30)
            )
        ]
        for (offset, markup) in screedMarkups.prefix(3).enumerated() {
            hits.append(
                SearchHit(
                    id: SampleFormatting.sampleID(810 + offset),
                    documentID: documentID,
                    documentTitle: documentTitle,
                    pageID: markup.pageID,
                    pageIndex: markup.pageIndex,
                    pageLabel: markup.pageLabel,
                    source: .markups,
                    snippet: "\(markup.subject) — \(markup.label)",
                    highlightRange: 6..<12,
                    boundsInPageSpace: markup.boundsInPageSpace,
                    markupID: markup.id
                )
            )
        }
        return hits
    }

    // MARK: - Warnings

    /// Three warnings that exercise every severity.
    static func makeWarnings(pageID: PageDescriptor.ID, markupID: UUID) -> [AppWarning] {
        [
            AppWarning(
                id: SampleFormatting.sampleID(900),
                severity: .warning,
                title: NSLocalizedString("Scale changed after measuring", comment: "Sample warning title"),
                message: NSLocalizedString(
                    "Five markups were measured against an earlier version of the plan scale. Recalculate to bring them up to date.",
                    comment: "Sample warning message"
                ),
                source: NSLocalizedString("Scale", comment: "Sample warning source"),
                actionTitle: NSLocalizedString("Recalculate", comment: "Sample warning action"),
                timestamp: SampleFormatting.sampleDate(days: 4, hours: 2),
                relatedMarkupID: markupID
            ),
            AppWarning(
                id: SampleFormatting.sampleID(901),
                severity: .danger,
                title: NSLocalizedString("Markup crosses two Scale Regions", comment: "Sample warning title"),
                message: NSLocalizedString(
                    "One area markup spans the Footing Detail region and the page default. Choose which scale applies before it is totalled.",
                    comment: "Sample warning message"
                ),
                source: NSLocalizedString("Scale Regions", comment: "Sample warning source"),
                actionTitle: NSLocalizedString("Choose Scale", comment: "Sample warning action"),
                isDismissible: false,
                timestamp: SampleFormatting.sampleDate(days: 4, hours: 3),
                relatedPageID: pageID
            ),
            AppWarning(
                id: SampleFormatting.sampleID(902),
                severity: .info,
                title: NSLocalizedString("Vector Snap unavailable on S-201", comment: "Sample warning title"),
                message: NSLocalizedString(
                    "This sheet is a scan, so there is no vector geometry to snap to. Grid Snap and Markup Snap still work.",
                    comment: "Sample warning message"
                ),
                source: NSLocalizedString("Vector Snap", comment: "Sample warning source"),
                timestamp: SampleFormatting.sampleDate(days: 4, hours: 4),
                relatedPageID: pageID
            )
        ]
    }
}
#endif
