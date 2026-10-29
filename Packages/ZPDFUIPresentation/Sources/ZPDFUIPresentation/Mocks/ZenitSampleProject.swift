// Debug and test builds only (R-142): a plain release build of ZPDFUIPresentation ships no
// mock. A release build that compiles tests passes -DZPDF_MOCKS (verify-viewer-budgets.sh).
#if DEBUG || ZPDF_MOCKS
import Foundation

/// Real-world metres per PDF point at a given drawing ratio.
private func metresPerPoint(ratio: Double) -> Double { 0.0254 / 72.0 * ratio }

/// A complete, self-consistent construction-takeoff project held entirely in memory.
///
/// Every UI package binds to this through ``MockPresenters`` so that toolbars, sidebars,
/// the canvas, the Quantity Ledger and the inspector can be built and previewed without the
/// core engines. The data is deterministic: identifiers, dates and
/// formatted strings are identical on every machine and every run, which is what lets the
/// consistency tests assert exact decimal equality.
public struct ZenitSampleProject: Sendable {

    /// Identity of the sample document.
    public let documentID: UUID
    /// Title shown in the tab bar and the window.
    public let documentTitle: String
    /// Source file name.
    public let fileName: String
    /// ISO 4217 code every monetary value in the sample uses.
    public let currencyCode: String
    /// Open documents.
    public let tabs: [DocumentTabSummary]
    /// The three drawing sheets.
    public let pages: [PageDescriptor]
    /// The four Project Zones.
    public let zones: [ProjectZoneSummary]
    /// Scale applied to pages outside any Scale Region.
    public let defaultScale: ScaleSummary
    /// The two Scale Regions.
    public let scaleRegions: [ScaleRegionSummary]
    /// The forty takeoff markups.
    public let markups: [MarkupSummary]
    /// Ledger columns, including four custom columns and one formula column.
    public let columns: [LedgerColumn]
    /// One ledger row per markup, in markup order.
    public let rows: [LedgerRow]
    /// Rows grouped by Project Zone.
    public let rootGroups: [LedgerGroupNode]
    /// Totals over every row.
    public let grandTotals: LedgerTotals
    /// Tool Library presets.
    public let presets: [ToolPresetSummary]
    /// Revisions available to Revision Compare.
    public let revisions: [RevisionSummary]
    /// Candidate differences between the two selected revisions.
    public let compareDiffs: [CompareDiffSummary]
    /// A pre-baked result set for the search field.
    public let searchHits: [SearchHit]
    /// Warnings shown in the tray.
    public let warnings: [AppWarning]
    /// The status bar as it looks on the first page.
    public let statusBar: StatusBarSnapshot

    /// The shared sample project. Building it is pure and deterministic.
    public static let shared: ZenitSampleProject = ZenitSampleProject()

    // MARK: Custom column identifiers

    /// Dimensionless waste allowance per row.
    public static let wasteFactorColumn = LedgerColumnID.custom("wasteFactor")
    /// Whether the quantity has been approved by the reviewer.
    public static let approvedColumn = LedgerColumnID.custom("approved")
    /// Planned installation date.
    public static let installDateColumn = LedgerColumnID.custom("installDate")
    /// Formula column: `Total Cost × (1 + Waste Factor)`.
    public static let extendedCostColumn = LedgerColumnID.custom("extendedCost")

    /// The formula source of ``extendedCostColumn``, parsed by the Zenit formula engine.
    public static let extendedCostFormula = "TotalCost * (1 + WasteFactor)"

    /// Builds the sample project.
    public init() {
        let currency = "SEK"
        self.currencyCode = currency
        let docID = SampleFormatting.sampleID(1)
        self.documentID = docID
        self.documentTitle = "Sample Block — Office Fit-Out"
        self.fileName = "Sample-Block-Fit-Out.zpdfproj"

        // MARK: Pages
        let sheetSize = PDFSizeValue(width: 2384, height: 1684)
        let fullBox = PDFRectValue(origin: .zero, size: sheetSize)
        let croppedBox = PDFRectValue(x: 12, y: 12, width: 2360, height: 1660)
        let pages = [
            PageDescriptor(
                id: SampleFormatting.sampleID(101),
                index: 0,
                label: "A-101",
                mediaBox: fullBox,
                cropBox: fullBox,
                rotation: .degrees0
            ),
            PageDescriptor(
                id: SampleFormatting.sampleID(102),
                index: 1,
                label: "A-102",
                mediaBox: fullBox,
                cropBox: fullBox,
                rotation: .degrees0
            ),
            PageDescriptor(
                id: SampleFormatting.sampleID(103),
                index: 2,
                label: "S-201",
                mediaBox: fullBox,
                cropBox: croppedBox,
                rotation: .degrees0
            )
        ]
        self.pages = pages

        self.tabs = [
            DocumentTabSummary(
                id: docID,
                title: "Sample Block — Office Fit-Out",
                fileName: "Sample-Block-Fit-Out.zpdfproj",
                pageCount: pages.count,
                hasUnsavedChanges: true,
                isActive: true,
                mode: .project
            ),
            DocumentTabSummary(
                id: SampleFormatting.sampleID(2),
                title: "Sample Block — Structural Set",
                fileName: "Sample-Block-Structural.pdf",
                pageCount: 8,
                hasUnsavedChanges: false,
                isActive: false,
                mode: .standalonePDF
            )
        ]

        // MARK: Scale
        let defaultScale = ScaleSummary(
            id: SampleFormatting.sampleID(201),
            name: NSLocalizedString("Plan Scale", comment: "Sample scale name"),
            displayString: "1:50",
            isUniform: true,
            sx: metresPerPoint(ratio: 50),
            sy: metresPerPoint(ratio: 50),
            unit: .metre,
            version: 3,
            locked: false
        )
        self.defaultScale = defaultScale

        let stairDetailScale = ScaleSummary(
            id: SampleFormatting.sampleID(202),
            name: NSLocalizedString("Stair Detail Scale", comment: "Sample scale name"),
            displayString: "1:20",
            isUniform: true,
            sx: metresPerPoint(ratio: 20),
            sy: metresPerPoint(ratio: 20),
            unit: .metre,
            version: 1,
            locked: true
        )
        let footingDetailScale = ScaleSummary(
            id: SampleFormatting.sampleID(203),
            name: NSLocalizedString("Footing Detail Scale", comment: "Sample scale name"),
            displayString: "1:10",
            isUniform: true,
            sx: metresPerPoint(ratio: 10),
            sy: metresPerPoint(ratio: 10),
            unit: .metre,
            version: 2,
            locked: false
        )

        let footingRegionName = "Footing Detail 1:10"
        self.scaleRegions = [
            ScaleRegionSummary(
                id: SampleFormatting.sampleID(211),
                name: "Stair Detail 1:20",
                pageID: pages[0].id,
                pageLabel: pages[0].label,
                scale: stairDetailScale,
                boundary: [
                    PDFPointValue(x: 1720, y: 180),
                    PDFPointValue(x: 2280, y: 180),
                    PDFPointValue(x: 2280, y: 640),
                    PDFPointValue(x: 1720, y: 640)
                ],
                priority: 10,
                locked: true,
                colorRGBA: ColorRGBA.Zenit.Dark.cyan
            ),
            ScaleRegionSummary(
                id: SampleFormatting.sampleID(212),
                name: footingRegionName,
                pageID: pages[2].id,
                pageLabel: pages[2].label,
                scale: footingDetailScale,
                // BH-783: inside the Foundation zone (x 1240…2300, y 900…1600), which is where
                // the markups that claim this region are filed.
                boundary: ZenitSampleProject.footingRegionBoundary,
                priority: 20,
                locked: false,
                colorRGBA: ColorRGBA.Zenit.Dark.blue
            )
        ]

        // MARK: Zones
        let zoneNames = [
            "Ground Floor — Zone A",
            "Ground Floor — Zone B",
            "Second Floor — Open Office",
            "Foundation — Grid A to D"
        ]
        let zoneKinds: [ProjectZoneKind] = [.tradeArea, .tradeArea, .floor, .buildingSection]
        let zonePages = [pages[0], pages[0], pages[1], pages[2]]
        let zoneColors = [
            ColorRGBA.Zenit.Dark.cyan,
            ColorRGBA.Zenit.Dark.blue,
            ColorRGBA.Zenit.Dark.green,
            ColorRGBA.Zenit.Dark.warning
        ]

        // MARK: Takeoff seeds
        let seeds = ZenitSampleProject.takeoffSeeds(footingRegionName: footingRegionName)

        // MARK: Markups and ledger rows
        let statuses: [MarkupStatus] = [.accepted, .open, .inProgress, .completed, .none]
        let authors = ["A. Mason", "J. Rivera", "S. Chen"]

        var markups: [MarkupSummary] = []
        var rows: [LedgerRow] = []
        var zoneMarkupCounts = [Int](repeating: 0, count: zoneNames.count)
        var zoneSlots = [Int](repeating: 0, count: zoneNames.count)
        var regionSlot = 0

        for (offset, seed) in seeds.enumerated() {
            let markupID = SampleFormatting.sampleID(1_000 + offset)
            let page = pages[seed.pageIndex]
            let dimension = seed.kind.dimension
            let primaryField = seed.kind.primaryField
            let primaryQuantity = DecimalQuantity(value: seed.value, dimension: dimension)
            let status = statuses[offset % statuses.count]
            let author = authors[offset % authors.count]
            let approved = offset % 3 == 0
            let installDate = SampleFormatting.sampleDate(days: 14 + offset)
            let created = SampleFormatting.sampleDate(days: offset / 8, hours: offset % 8)
            let modified = created.addingTimeInterval(3_600 * 6)
            let color = ZenitSampleProject.color(for: dimension)
            // BH-783: a markup sits inside the zone it is filed under, and inside the Scale
            // Region it claims — the grid used to run across every zone regardless.
            let bounds: PDFRectValue
            if seed.scaleRegionName == footingRegionName {
                bounds = ZenitSampleProject.slot(regionSlot, in: ZenitSampleProject.footingRegionBoundary, columns: 2)
                regionSlot += 1
            } else {
                bounds = ZenitSampleProject.slot(
                    zoneSlots[seed.zoneIndex], in: ZenitSampleProject.zoneBoundary(index: seed.zoneIndex), columns: 4
                )
                zoneSlots[seed.zoneIndex] += 1
            }

            let totalCost = seed.unitCost * seed.value
            let extendedCost = totalCost * (1 + seed.wasteFactor)

            // Measurement fields on the markup itself.
            var fields: [MeasurementFieldSummary] = [
                ZenitSampleProject.fieldSummary(primaryField, primaryQuantity)
            ]
            if let perimetre = seed.perimetre, primaryField != .perimeter {
                fields.append(
                    ZenitSampleProject.fieldSummary(
                        .perimeter,
                        DecimalQuantity.metres(perimetre),
                        isDerived: true
                    )
                )
            }
            if let depth = seed.depth {
                fields.append(
                    ZenitSampleProject.fieldSummary(.depth, DecimalQuantity.metres(depth))
                )
            }

            zoneMarkupCounts[seed.zoneIndex] += 1

            markups.append(
                MarkupSummary(
                    id: markupID,
                    kind: seed.kind == .count ? .count : .measurement,
                    measurementKind: seed.kind,
                    subject: seed.subject,
                    label: seed.label,
                    comment: seed.kind == .count
                        ? "Counted from the reflected ceiling plan."
                        : "Taken off against the \(seed.scaleRegionName ?? "page default") scale.",
                    pageLabel: page.label,
                    pageID: page.id,
                    pageIndex: page.index,
                    zone: zoneNames[seed.zoneIndex],
                    zoneID: SampleFormatting.sampleID(300 + seed.zoneIndex),
                    scaleRegionName: seed.scaleRegionName,
                    status: status,
                    author: author,
                    locked: offset % 11 == 0,
                    hidden: false,
                    colorRGBA: color,
                    measurementFields: fields,
                    layer: seed.trade,
                    created: created,
                    modified: modified,
                    boundsInPageSpace: bounds
                )
            )

            // Ledger cells.
            var values: [LedgerColumnID: LedgerCellValue] = [:]
            var display: [LedgerColumnID: String] = [:]

            values[.subject] = .text(seed.subject)
            display[.subject] = seed.subject
            values[.label] = .text(seed.label)
            display[.label] = seed.label
            values[.pageLabel] = .text(page.label)
            display[.pageLabel] = page.label
            values[.pageIndex] = .number(Decimal(page.index))
            display[.pageIndex] = String(page.index + 1)
            values[.projectZone] = .choice(zoneNames[seed.zoneIndex])
            display[.projectZone] = zoneNames[seed.zoneIndex]
            values[.scaleRegion] = seed.scaleRegionName.map { LedgerCellValue.text($0) } ?? .empty
            display[.scaleRegion] = seed.scaleRegionName ?? ""
            values[.status] = .choice(status.rawValue)
            display[.status] = status.displayName
            values[.author] = .text(author)
            display[.author] = author
            values[.created] = .date(created)
            display[.created] = ZenitSampleProject.dateText(created)
            values[.modified] = .date(modified)
            display[.modified] = ZenitSampleProject.dateText(modified)
            values[.material] = .choice(seed.material)
            display[.material] = seed.material
            values[.trade] = .choice(seed.trade)
            display[.trade] = seed.trade
            values[.comment] = .text(seed.kind == .count ? "Reflected ceiling plan" : "Plan takeoff")
            display[.comment] = seed.kind == .count ? "Reflected ceiling plan" : "Plan takeoff"

            let primaryColumn = ZenitSampleProject.column(for: primaryField)
            values[primaryColumn] = .quantity(primaryQuantity)
            display[primaryColumn] = SampleFormatting.string(primaryQuantity)

            if let perimetre = seed.perimetre, primaryColumn != .perimeter {
                let quantity = DecimalQuantity.metres(perimetre)
                values[.perimeter] = .quantity(quantity)
                display[.perimeter] = SampleFormatting.string(quantity)
            }
            if let depth = seed.depth {
                let quantity = DecimalQuantity.metres(depth)
                values[.depth] = .quantity(quantity)
                display[.depth] = SampleFormatting.string(quantity)
            }

            values[.unitCost] = .currency(amount: seed.unitCost, code: currency)
            display[.unitCost] = SampleFormatting.string(seed.unitCost, fractionDigits: 2)
            values[.totalCost] = .currency(amount: totalCost, code: currency)
            display[.totalCost] = SampleFormatting.string(totalCost, fractionDigits: 2)

            values[ZenitSampleProject.wasteFactorColumn] = .number(seed.wasteFactor)
            display[ZenitSampleProject.wasteFactorColumn] =
                SampleFormatting.string(seed.wasteFactor, fractionDigits: 2)
            values[ZenitSampleProject.approvedColumn] = .checkbox(approved)
            display[ZenitSampleProject.approvedColumn] = approved
                ? NSLocalizedString("Yes", comment: "Checkbox cell shown as text")
                : NSLocalizedString("No", comment: "Checkbox cell shown as text")
            values[ZenitSampleProject.installDateColumn] = .date(installDate)
            display[ZenitSampleProject.installDateColumn] = ZenitSampleProject.dateText(installDate)
            values[ZenitSampleProject.extendedCostColumn] = .currency(amount: extendedCost, code: currency)
            display[ZenitSampleProject.extendedCostColumn] =
                SampleFormatting.string(extendedCost, fractionDigits: 2)

            rows.append(
                LedgerRow(
                    markupID: markupID,
                    values: values,
                    displayValues: display,
                    colorRGBA: color,
                    kind: seed.kind == .count ? .count : .measurement,
                    measurementKind: seed.kind,
                    locked: offset % 11 == 0
                )
            )
        }

        self.markups = markups
        self.rows = rows

        self.zones = zoneNames.indices.map { index in
            ProjectZoneSummary(
                id: SampleFormatting.sampleID(300 + index),
                name: zoneNames[index],
                kind: zoneKinds[index],
                pageID: zonePages[index].id,
                pageLabel: zonePages[index].label,
                boundary: ZenitSampleProject.zoneBoundary(index: index),
                colorRGBA: zoneColors[index],
                markupCount: zoneMarkupCounts[index]
            )
        }

        // MARK: Ledger structure
        let columns = ZenitSampleProject.makeColumns(zoneNames: zoneNames, currencyCode: currency)
        self.columns = columns

        let format: (LedgerColumn, DecimalQuantity) -> String = { _, quantity in
            SampleFormatting.string(quantity)
        }

        var groups: [LedgerGroupNode] = []
        for (index, zoneName) in zoneNames.enumerated() {
            let zoneRows = rows.filter { $0.value(.projectZone).asText == zoneName }
            groups.append(
                LedgerGroupNode(
                    id: SampleFormatting.sampleID(400 + index),
                    title: zoneName,
                    groupingColumn: .projectZone,
                    groupingValue: zoneName,
                    depth: 0,
                    isExpanded: index < 2,
                    rows: zoneRows,
                    totals: LedgerTotals.mockSumming(rows: zoneRows, columns: columns, format: format),
                    colorRGBA: zoneColors[index]
                )
            )
        }
        self.rootGroups = groups
        self.grandTotals = LedgerTotals.mockSumming(rows: rows, columns: columns, format: format)

        // MARK: Everything else
        self.presets = ZenitSampleProject.makePresets()
        let revisions = ZenitSampleProject.makeRevisions(documentID: docID)
        self.revisions = revisions
        self.compareDiffs = ZenitSampleProject.makeDiffs(pages: pages)
        self.searchHits = ZenitSampleProject.makeSearchHits(
            documentID: docID,
            documentTitle: "Sample Block — Office Fit-Out",
            pages: pages,
            markups: markups
        )
        // BH-784: a fixed index into the seed list trapped the shared initialiser — and with it
        // every preview and every UI test — the moment the list shrank.
        let warnedMarkupID = markups.indices.contains(34) ? markups[34].id : (markups.last?.id ?? SampleFormatting.sampleID(1_000))
        self.warnings = ZenitSampleProject.makeWarnings(pageID: pages[2].id, markupID: warnedMarkupID)
        self.statusBar = StatusBarSnapshot(
            pageLabel: pages[0].label,
            pageIndex: 0,
            pageCount: pages.count,
            pageDimensionsText: "841 × 594 mm",
            activeScaleDisplay: defaultScale.displayString,
            scaleRegionName: nil,
            outputUnitSymbol: LengthUnit.metre.symbol,
            cursorPagePoint: PDFPointValue(x: 812.5, y: 640.0),
            cursorDisplayText: "14.33 m, 11.29 m",
            zoomDisplayString: "100%",
            gridSnapEnabled: false,
            vectorSnapEnabled: true,
            markupSnapEnabled: true,
            reuseToolEnabled: true,
            geometryIndexStatus: .ready
        )
    }
}
#endif
