import Foundation
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// One consistent instant of the document, in the vocabulary the UI renders.
///
/// Everything a presenter shows comes from a single snapshot, so the ledger row, the
/// canvas markup and the status-bar scale on screen at any moment all describe the same
/// document state. Building them from separate calls is how the three drift apart, and a
/// drifting scale readout is how a user measures a wall against the wrong drawing.
public struct DocumentSnapshot: Sendable {

    /// The document these pages belong to.
    public let documentID: UUID
    /// Pages in document order.
    public let pages: [ZPDFUIPresentation.PageDescriptor]
    /// The first page's own scale, or `nil` when that page is not calibrated.
    ///
    /// Not "the document scale" — there is none. Anything that knows which sheet is on screen
    /// must ask ``scale(onPage:)`` instead; this is for the document-wide readouts that
    /// genuinely have no page in hand.
    public let firstPageScale: ScaleSummary?
    /// Every page that has its own scale, keyed by page identity.
    ///
    /// A page absent from this map is uncalibrated, and a measurement on it is refused. The
    /// map is what lets a status bar, an inspector and an export all answer "what scale is this
    /// sheet at?" from the same instant of the document instead of from a document-wide field
    /// that was only ever right about one sheet.
    public let pageScales: [UUID: ScaleSummary]
    /// Markups that carry geometry, in insertion order, ready for the canvas.
    public let markups: [MarkupSummary]
    /// The ledger projection: index-addressed, not a row array.
    public let ledger: LedgerProjection
    /// Units and precision every display string above was rendered with.
    public let units: DisplayUnitSelection
    /// Scale Regions, highest priority first, as the panel renders them.
    public let scaleRegions: [ScaleRegionSummary]
    /// Project Zones, with the markup counts the ledger will subtotal by.
    public let zones: [ProjectZoneSummary]
    /// The derivation of each measured value, keyed by markup (ADR-0007 §1).
    ///
    /// On the snapshot rather than fetched on demand, for the reason every other field is:
    /// the disclosure a person opens must describe the same instant of the document as the row
    /// they opened it from. A markup with no measurement, or one measured by a build that did
    /// not record derivations, has no entry and the panel says so.
    public let derivations: [UUID: [LedgerDerivationSection]]
    /// Each page's `/UserUnit`, keyed by page identity, for the display strings that convert
    /// page units to real ones — the page-size readout, the nominal ratio (CR-128). A page
    /// absent from the map declares none and is `1`.
    public let userUnits: [UUID: Double]
    /// ADR-0032: the project's markup layers, top first, and the active one.
    public var markupLayers: [MarkupLayer] = [MarkupLayer.makeDefault()]
    public var activeMarkupLayerID: LayerID = MarkupLayer.defaultID
    /// U-086: the saved Project Zone and Scale Region outlines and calibration picks the canvas
    /// draws, pages in document order — the same marks the snap boundary layer is fed from
    /// (`TakeoffSession+SnapBoundaries.swift`), so no boundary target is invisible.
    public var boundaryMarks: [PageBoundaryMark] = []

    /// Creates a snapshot.
    public init(
        documentID: UUID,
        pages: [ZPDFUIPresentation.PageDescriptor],
        firstPageScale: ScaleSummary?,
        pageScales: [UUID: ScaleSummary] = [:],
        markups: [MarkupSummary],
        ledger: LedgerProjection,
        units: DisplayUnitSelection,
        scaleRegions: [ScaleRegionSummary] = [],
        zones: [ProjectZoneSummary] = [],
        derivations: [UUID: [LedgerDerivationSection]] = [:],
        userUnits: [UUID: Double] = [:]
    ) {
        self.documentID = documentID
        self.pages = pages
        self.firstPageScale = firstPageScale
        self.pageScales = pageScales
        self.markups = markups
        self.ledger = ledger
        self.units = units
        self.scaleRegions = scaleRegions
        self.zones = zones
        self.derivations = derivations
        self.userUnits = userUnits
    }

    /// The `/UserUnit` of a page, `1` for a page that declares none or is not in the document.
    public func userUnit(onPage pageID: UUID?) -> Double {
        guard let pageID, let unit = userUnits[pageID], unit.isFinite, unit > 0 else { return 1 }
        return unit
    }

    /// Markups on one page.
    public func markups(onPage pageID: UUID) -> [MarkupSummary] {
        markups.filter { $0.pageID == pageID }
    }

    /// The scale in force on one page, or `nil` when that page has none.
    ///
    /// `nil` for an unknown page and `nil` for an uncalibrated one, deliberately the same
    /// answer: both mean "no scale applies here", and both must produce a refusal rather than a
    /// number. Passing `nil` — no page selected — is `nil` for the same reason.
    public func scale(onPage pageID: UUID?) -> ScaleSummary? {
        guard let pageID else { return nil }
        return pageScales[pageID]
    }

    /// The scale to print on a **document-wide** export, or `nil` when no page has one.
    ///
    /// A whole-document export has no page, and a set can now hold several scales, so the old
    /// single string would have named one sheet's ratio and let a reader assume it covered the
    /// rest. When every calibrated page agrees this is that one ratio; when they do not it is
    /// the distinct ratios, listed, so a summary sheet says the drawing set is mixed instead of
    /// picking a winner. Sorted, so two exports of one takeoff are the same export.
    public var documentScaleDescription: String? {
        let distinct = Set(pageScales.values.map(\.displayString)).sorted()
        guard let first = distinct.first else { return nil }
        return distinct.count == 1 ? first : distinct.joined(separator: ", ")
    }
}

/// What the ledger is currently showing: filter, sort and grouping, in UI terms.
///
/// Held by the presenter and handed to the session on every rebuild, so the projection is
/// a pure function of `(document state, request)` and two rebuilds from the same pair
/// always agree.
public struct LedgerRequest: Hashable, Sendable {

    /// Columns to group by, outermost first. Empty means a flat ledger.
    public var grouping: [LedgerColumnID]
    /// Sort levels, outermost first.
    public var sort: [ZPDFUIPresentation.LedgerSortDescriptor]
    /// The filter tree.
    public var filter: LedgerFilterGroup
    /// Columns to show, in order. Empty means every visible column.
    public var visibleColumns: [LedgerColumnID]
    /// Narrows the request to exactly these markups — "Export selected rows" (NL-QTY-14).
    /// `nil`, the default, is every row the filter passes.
    public var markupScope: Set<UUID>?
    /// Narrows the ledger to values kept under an older scale (NL-MEASURE-03,
    /// ``LedgerOlderScale``); resolved by the session into ``markupScope``.
    public var onlyOlderScaleValues: Bool = false

    /// Creates a request.
    public init(
        grouping: [LedgerColumnID] = [],
        sort: [ZPDFUIPresentation.LedgerSortDescriptor] = [],
        filter: LedgerFilterGroup = LedgerFilterGroup(id: UUID()),
        visibleColumns: [LedgerColumnID] = []
    ) {
        self.grouping = grouping
        self.sort = sort
        self.filter = filter
        self.visibleColumns = visibleColumns
    }

    /// A flat, unsorted, unfiltered ledger.
    public static var flat: LedgerRequest { LedgerRequest() }
}

/// The production clock for export reports: reports carry a generation timestamp, and
/// outside a test that timestamp is now.
public struct SystemTimestampProvider: TimestampProviding {
    public init() {}
    public func now() -> Date { Date() }
}

extension TakeoffSession {

    /// Builds a snapshot of the whole document.
    ///
    /// The expensive part is the ledger view — one filter pass, one sort, one group build
    /// over row *indices*. No cell is produced here; cells appear when the table asks for
    /// a row by index (``LedgerProjection/row(at:)``).
    public func snapshot(ledger request: LedgerRequest = .flat) throws -> DocumentSnapshot {
        let pages = pageDescriptors
        let rendered = cachedSummaries()
        var built = DocumentSnapshot(
            documentID: documentID.rawValue,
            pages: pages.map { page in
                var presented = ZPDFUIPresentation.PageDescriptor(domain: page)
                // A sheet's view — turned, cropped — rides with it (NL-DOCS-07/16).
                if let view = pageViewTable[page.id] {
                    presented = presented.withView(
                        rotation: view.rotation,
                        crop: view.crop.map { crop in
                            PDFRectValue(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height)
                        }
                    )
                }
                // A named sheet (NL-DOCS-05) shows its own number and title.
                guard let identity = sheetIdentityTable[page.id] else { return presented }
                return presented.withSheetIdentity(number: identity.number, title: identity.title)
            },
            firstPageScale: firstPageScale.map {
                ScaleSummary(domain: $0, name: nil, userUnit: userUnit(onPage: $0.pageID), localeIdentifier: localeIdentifier)
            },
            pageScales: pageScales.reduce(into: [:]) { result, entry in
                result[entry.key.rawValue] = ScaleSummary(
                    domain: entry.value, name: nil, userUnit: userUnit(onPage: entry.key),
                    localeIdentifier: localeIdentifier
                )
            },
            markups: rendered.summaries,
            ledger: try ledgerProjection(request),
            units: displayUnits,
            scaleRegions: scaleRegionSummaries(),
            zones: projectZoneSummaries(),
            derivations: rendered.derivations,
            userUnits: pages.reduce(into: [:]) { $0[$1.id.rawValue] = $1.userUnit }
        )
        built.markupLayers = markupLayers          // ADR-0032
        built.activeMarkupLayerID = activeMarkupLayer
        built.boundaryMarks = allBoundaryMarks()   // U-086
        return built
    }

    /// The derivation of every measured value in the document, keyed by markup.
    ///
    /// The page label is resolved here, where the page table lives, so the disclosure can print
    /// *"page 3"* — the label the sheet prints, not a UUID — and can print nothing at all when
    /// the scale's page is gone rather than a stale name.
    func derivationSections() -> [UUID: [LedgerDerivationSection]] {
        let names = nameTable
        var result: [UUID: [LedgerDerivationSection]] = [:]
        for record in orderedMarkups {
            guard let provenance = record.measurement?.provenance else { continue }
            let pageLabel = provenance.scalePageID.flatMap { names.pages[$0] }.map(\.label)
            result[record.id.rawValue] = DerivationBridge.sections(
                for: provenance,
                pageLabel: pageLabel?.isEmpty == false ? pageLabel : nil,
                scaleName: names.scales[provenance.scaleID]
            )
        }
        return result
    }

    /// The Scale Regions as the panel renders them, resolved against the scales they name.
    ///
    /// A region whose scale has vanished is dropped rather than shown with an invented ratio.
    /// That cannot happen through the command path — ``DocumentCommand/setScaleRegions(_:)``
    /// refuses a region naming a scale the document does not hold — so a drop here means a
    /// damaged file, and a missing row is a better answer than a fabricated scale.
    func scaleRegionSummaries() -> [ScaleRegionSummary] {
        let labels = Dictionary(uniqueKeysWithValues: pageDescriptors.map { ($0.id, $0.label) })
        return scaleRegionDefinitions.compactMap { region in
            guard let scale = scaleTransform(region.scaleID) else { return nil }
            return region.summary(
                scale: scale,
                pageLabel: labels[region.pageID] ?? "",
                userUnit: userUnit(onPage: region.pageID),
                localeIdentifier: localeIdentifier
            )
        }
    }

    /// The Project Zones as the Navigator renders them, each with its live markup count.
    func projectZoneSummaries() -> [ProjectZoneSummary] {
        let labels = Dictionary(uniqueKeysWithValues: pageDescriptors.map { ($0.id, $0.label) })
        let counts = markupCountsByZone()
        return projectZoneDefinitions.map { zone in
            zone.summary(
                pageLabel: zone.pageID.flatMap { labels[$0] },
                markupCount: counts[zone.id] ?? 0
            )
        }
    }

    /// The ledger as an export report — the input of the CSV / PDF-report export pipeline
    /// (`ExportProjector` → renderers). Same store, same columns, same names as
    /// ``ledgerProjection(_:)``, so an exported number is the ledger's number.
    ///
    /// `request` is the view being exported, and passing the *live* one is what makes the
    /// export match the screen. It used to be ignored: the report was always built over an
    /// unfiltered, ungrouped, unsorted spec, so exporting a filtered ledger produced every
    /// row in the document with a grand total to match, under a save panel that says
    /// "Export the Quantity Ledger as it is on screen". Because `LedgerReportBuilder`
    /// derives `filterDescription`, `rowCount` and `totalRowCountBeforeFilter` from the
    /// spec it is handed, an empty spec also produced a *label* claiming the export was
    /// unfiltered. That is QUALITY_BAR A35 twice over — an export whose totals do not
    /// reconcile with the rows the user checked, and a filtered view that does not say so.
    ///
    /// Returns the export report **and** the filter rules its view could not apply.
    ///
    /// The export report previously built its spec through a path that threw the diagnostics away, so a CSV,
    /// PDF or XLSX banner derived from the spec named only the surviving rules — a filter that
    /// had silently lost its pattern rule was exported as if it had been applied, with the wider
    /// row set (BH-101). Report metadata contains the diagnostic messages, while the returned
    /// tuple also carries structured diagnostics for callers that print their own banner.
    public func exportReportWithDiagnostics(
        title: String,
        request: LedgerRequest = .flat,
        timestamps: any TimestampProviding = SystemTimestampProvider()
    ) throws -> (report: LedgerReport, unappliedFilterRules: [LedgerFilterDiagnostic]) {
        let translation = LedgerSpecBuilder.translate(resolvingOlderScale(request), columns: ledgerColumns, formatter: snapshotFormatter)
        // The live store, not a rebuilt one (IM-002): the exported numbers are the ledger's.
        let view = try cachedLedgerView(for: translation.spec)
        // The unapplied rules ride in the report's own metadata, in words, so the PDF cover
        // and the workbook's metadata sheet say the filter was not applied in full — and in the
        // tuple, for a caller that prints its own banner (BH-101).
        return (
            LedgerReportBuilder(timestamps: timestamps).makeReport(
                view,
                title: title,
                unappliedFilterRules: translation.unappliedFilterRules.map(\.message)
            ),
            translation.unappliedFilterRules
        )
    }

    /// Builds only the ledger projection, for a filter or sort change that did not touch
    /// the document. Rebuilding the markup summaries as well would be a second full pass
    /// over the takeoff for no reason.
    public func ledgerProjection(_ request: LedgerRequest = .flat) throws -> LedgerProjection {
        let translation = LedgerSpecBuilder.translate(resolvingOlderScale(request), columns: ledgerColumns, formatter: snapshotFormatter)
        var projection = LedgerBridge.project(
            try cachedLedgerView(for: translation.spec),
            formatter: snapshotFormatter,
            unappliedFilterRules: translation.unappliedFilterRules
        )
        projection.nonMeasurementMarkupCount = nonQuantityMarkupCount   // L-50
        return projection
    }
}

extension TakeoffSession {

    /// `request` with ``LedgerRequest/onlyOlderScaleValues`` turned into a markup scope: the
    /// ledger rows whose value was kept under an older scale (NL-MEASURE-03).
    func resolvingOlderScale(_ request: LedgerRequest) -> LedgerRequest {
        guard request.onlyOlderScaleValues else { return request }
        var resolved = request
        let kept = Set(orderedMarkups.filter(LedgerOlderScale.isKept).map(\.id.rawValue))
        resolved.markupScope = request.markupScope.map { $0.intersection(kept) } ?? kept
        return resolved
    }
}

/// A filter rule the engine could not evaluate, and why.
///
/// The seam used to drop such a rule silently — a regex rule, for which no budgeted evaluator
/// exists yet, or a rule on the synthesised Value / Unit display columns, which have no engine
/// column — while the builder reported the filter as applied and the CSV banner claimed it
/// (CR-56). Naming the rule is what lets the pane and the export say "this rule was not
/// applied" instead of presenting a ledger the rule never narrowed.
public struct LedgerFilterDiagnostic: Hashable, Sendable {

    /// Why the rule could not be translated.
    public enum Reason: Hashable, Sendable {
        /// `matchesRegex` has no engine operator: spec 15.6 requires a complexity and
        /// time guard, and a guard that fires mid-scan yields a partial result set that looks
        /// complete (QUALITY_BAR A23). A pattern operand kept under any other comparison that
        /// takes a value has no engine value for the same reason (U-063).
        case unsupportedComparison
        /// The column is synthesised for display — Value, Unit — and has no engine column.
        case displayOnlyColumn
        /// The column does not exist in this document's column set: a stale saved filter.
        case unknownColumn
    }

    /// The column the rule named.
    public let column: LedgerColumnID
    /// The comparison the rule asked for.
    public let comparison: LedgerFilterComparison
    /// Why it was not applied.
    public let reason: Reason

    public init(column: LedgerColumnID, comparison: LedgerFilterComparison, reason: Reason) {
        self.column = column
        self.comparison = comparison
        self.reason = reason
    }

    /// A sentence for the pane or an export banner. Names the column by key; a caller that
    /// has the column's title substitutes it.
    public var message: String {
        switch reason {
        case .unsupportedComparison:
            return String(
                format: NSLocalizedString(
                    "The pattern rule on “%@” was not applied: this version cannot evaluate patterns.",
                    comment: "Ledger filter diagnostic; the placeholder is the column key"
                ),
                column.rawValue
            )
        case .displayOnlyColumn:
            return String(
                format: NSLocalizedString(
                    "The rule on “%@” was not applied: that column is for display only and cannot be filtered.",
                    comment: "Ledger filter diagnostic; the placeholder is the column key"
                ),
                column.rawValue
            )
        case .unknownColumn:
            return String(
                format: NSLocalizedString(
                    "The rule on “%@” was not applied: this document has no such column.",
                    comment: "Ledger filter diagnostic; the placeholder is the column key"
                ),
                column.rawValue
            )
        }
    }
}

/// Turns a UI ledger request into the engine's view spec.
///
/// Column identity crosses the seam as the column's stable `key`, not as its `ColumnID`
/// UUID: the UI's `LedgerColumnID` is a string and the engine's is a UUID, and the `key`
/// is the one spelling both sides already agree on.
enum LedgerSpecBuilder {

    /// The engine spec for a request, plus every filter rule that could not be translated.
    ///
    /// - Parameter formatter: the formatter the ledger's cells are written with. Given, "is" and
    ///   "is not" on a measured column compare what the cells show (X-033,
    ///   ``displayedEquality(column:op:value:formatter:)``); `nil` compares exactly.
    static func translate(
        _ request: LedgerRequest,
        columns: LedgerColumnSet,
        formatter: QuantityFormatter? = nil
    ) -> (spec: LedgerViewSpec, unappliedFilterRules: [LedgerFilterDiagnostic]) {
        var unapplied: [LedgerFilterDiagnostic] = []
        var node = filter(request.filter, columns: columns, formatter: formatter, unapplied: &unapplied)
        if let scope = request.markupScope {
            let selected = LedgerFilterNode.markups(Set(scope.map(MarkupID.init)))
            node = node.matchesEverything ? selected : .and([node, selected])
        }
        let spec = LedgerViewSpec(
            filter: node,
            sort: request.sort.compactMap { descriptor in
                columns.column(key: descriptor.column.rawValue).map {
                    ZPDFQuantityLedger.LedgerSortDescriptor(column: $0.id, ascending: descriptor.ascending)
                }
            },
            grouping: request.grouping.compactMap { id in
                columns.column(key: id.rawValue).map { LedgerGroupingField(column: $0.id) }
            },
            aggregation: LedgerAggregationPlan.standard(for: columns),
            visibleColumns: request.visibleColumns.compactMap { columns.column(key: $0.rawValue)?.id }
        )
        return (spec, unapplied)
    }

    /// Translates the UI's filter tree into the engine's, naming every rule it leaves out.
    ///
    /// A rule naming a column the engine does not have is dropped rather than made to
    /// match nothing: a stale saved filter must not silently empty a ledger. Dropped — and
    /// **reported** in `unapplied`, because a filter the pane calls applied and the export
    /// banner claims must not have quietly lost a rule (CR-56).
    static func filter(
        _ group: LedgerFilterGroup,
        columns: LedgerColumnSet,
        formatter: QuantityFormatter? = nil,
        unapplied: inout [LedgerFilterDiagnostic]
    ) -> LedgerFilterNode {
        var nodes: [LedgerFilterNode] = []
        for rule in group.rules where rule.isEnabled {
            guard let column = columns.column(key: rule.column.rawValue) else {
                let displayOnly = rule.column == LedgerDefaultColumns.valueColumnID
                    || rule.column == LedgerDefaultColumns.unitColumnID
                unapplied.append(LedgerFilterDiagnostic(
                    column: rule.column,
                    comparison: rule.comparison,
                    reason: displayOnly ? .displayOnlyColumn : .unknownColumn
                ))
                continue
            }
            guard let op = filterOperator(rule.comparison) else {
                unapplied.append(LedgerFilterDiagnostic(
                    column: rule.column,
                    comparison: rule.comparison,
                    reason: .unsupportedComparison
                ))
                continue
            }
            if case .regex = rule.operand, !rule.comparison.isUnary {
                // A pattern operand under a comparison that takes a value — "Label is /^C-/", a
                // pattern rule whose comparison was changed (BH-712). The engine has no pattern
                // value: `filterValue` makes it `.none`, and the core then matched no row for
                // "is" / "contains" and every row for "is not" / "does not contain", while the
                // pane and the export banner — ZPDFUILedger's LedgerFilterDiagnostic.isApplied —
                // treat the rule as not applied and said "No filter applied" over those rows
                // (U-063). Dropped and reported like a pattern rule, so the rows and the banner
                // describe the same filter.
                unapplied.append(LedgerFilterDiagnostic(
                    column: rule.column,
                    comparison: rule.comparison,
                    reason: .unsupportedComparison
                ))
                continue
            }
            var value = filterValue(rule.operand, column: column, comparison: rule.comparison)
            // L-46: the Page index cells show the page from 1 and the person types what they
            // read; the engine compares the stored 0-based index.
            if column.standard == .pageIndex { value = LedgerBridge.pageIndexFilterValue(value) }
            if let formatter, let shows = displayedEquality(column: column, op: op, value: value, formatter: formatter) {
                nodes.append(shows)
                continue
            }
            if case .date(let day) = value, op == .equals || op == .notEquals {
                // The builder sends a date as the local start of its day, and the core compares
                // date instants exactly, so "Created is 2026-09-01" matched only markups created
                // at midnight (BH-041). A date equality is the whole day.
                let dayRule = LedgerFilterNode.rule(ZPDFQuantityLedger.LedgerFilterRule(
                    column: column.id,
                    op: .between,
                    value: .dateRange(lower: day, upper: Self.endOfDay(startingAt: day))
                ))
                nodes.append(op == .equals ? dayRule : .not(dayRule))
                continue
            }
            nodes.append(.rule(ZPDFQuantityLedger.LedgerFilterRule(
                column: column.id,
                op: op,
                value: value
            )))
        }
        for child in group.groups {
            let node = filter(child, columns: columns, formatter: formatter, unapplied: &unapplied)
            guard !node.matchesEverything else { continue }
            nodes.append(node)
        }
        guard !nodes.isEmpty else { return .all }
        let combined: LedgerFilterNode = group.conjunction == .all ? .and(nodes) : .or(nodes)
        return group.isNegated ? .not(combined) : combined
    }

    /// The engine operator for a UI comparison, or `nil` when the engine has none.
    ///
    /// `matchesRegex` has no engine operator on purpose: spec 15.6 requires a
    /// complexity and time guard for regex, and a guard that fires mid-scan yields a
    /// partial result set that looks complete (QUALITY_BAR A23). Until that budgeted
    /// evaluator exists, a regex rule is dropped rather than approximated — a filter that
    /// silently matched everything, or nothing, would be worse than one that is ignored.
    static func filterOperator(_ comparison: LedgerFilterComparison) -> LedgerFilterOperator? {
        switch comparison {
        case .contains: .contains
        case .notContains: .notContains
        case .equals: .equals
        case .notEquals: .notEquals
        case .beginsWith: .beginsWith
        case .endsWith: .endsWith
        case .lessThan: .lessThan
        case .lessThanOrEqual: .lessThanOrEqual
        case .greaterThan: .greaterThan
        case .greaterThanOrEqual: .greaterThanOrEqual
        case .between: .between
        case .isEmpty: .isEmpty
        case .isNotEmpty: .isNotEmpty
        case .isTrue: .isTrue
        case .isFalse: .isFalse
        case .isAnyOf: .inSet
        case .matchesRegex: nil
        }
    }

    /// The engine operand for a UI operand, resolved against the column it is compared with.
    ///
    /// A Choice column's cells are `.choice(id)`, and the evaluator compares a choice cell
    /// with a choice operand only. Sending "Open" as `.text` — and `[Open]` as `.textSet` —
    /// matched nothing on the Status column and made "is not Open" match everything, so the
    /// export carried zero rows under a banner claiming the filter (CR-52). The stored value
    /// the panel sends is resolved to the option's identity through the column's own choices.
    /// The last instant of the calendar day that starts at `start`: one day later, minus a
    /// millisecond — through the calendar, so a 23- or 25-hour day is still one day.
    static func endOfDay(startingAt start: Date, calendar: Calendar = .current) -> Date {
        (calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
            .addingTimeInterval(-0.001)
    }

    static func filterValue(
        _ operand: LedgerFilterOperand,
        column: LedgerColumnDefinition? = nil,
        comparison: LedgerFilterComparison? = nil
    ) -> LedgerFilterValue {
        switch operand {
        case .none: return .none
        case .text(let text):
            // Only an equality names an option. "contains Open" resolved to the option and then
            // matched nothing — the engine's text comparisons need a text needle — while
            // "does not contain Open" matched every row, the Open ones included (BH-429).
            let namesAnOption = comparison.map { $0 == .equals || $0 == .notEquals } ?? true
            if namesAnOption, let column, column.kind == .choice, let id = choiceID(text, in: column) {
                return .choice(id)
            }
            return .text(text)
        case .number(let value): return .number(value)
        case .numberRange(let lower, let upper):
            // "between 12 and 5" is the same band as "between 5 and 12" to a person. The core
            // tests `lower <= value <= upper`, so the reversed pair matched nothing (C-01). The
            // pair is ordered here, as the builder already orders a date range.
            return .numberRange(lower: min(lower, upper), upper: max(lower, upper))
        case .date(let date): return .date(date)
        case .dateRange(let start, let end):
            // A saved or hand-built filter can reach the seam without passing the builder's
            // normaliser; ordered here too, so the seam never depends on who built the rule.
            return .dateRange(lower: min(start, end), upper: max(start, end))
        case .boolean(let flag): return .boolean(flag)
        case .choices(let values):
            if let column, column.kind == .choice {
                // An unresolvable value is a value no row can carry, so it contributes no
                // member — the set still matches exactly the rows that hold a named option.
                return .choiceSet(values.compactMap { choiceID($0, in: column) })
            }
            return .textSet(values)
        case .regex: return .none
        }
    }

    /// The option of a Choice column a panel value names: by stored value first, then
    /// case-insensitively, then by identifier — never by guessing a display name.
    static func choiceID(_ value: String, in column: LedgerColumnDefinition) -> ChoiceOptionID? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = column.choices.first(where: { $0.value == trimmed }) { return exact.id }
        let folded = Self.foldedChoiceText(trimmed)
        if let loose = column.choices.first(where: { Self.foldedChoiceText($0.value) == folded }) {
            return loose.id
        }
        if let uuid = UUID(uuidString: trimmed) {
            let id = ChoiceOptionID(uuid)
            if column.choices.contains(where: { $0.id == id }) { return id }
        }
        return nil
    }

    /// `"In Progress"`, `"in-progress"` and `"inProgress"` are one stored value to a person.
    private static func foldedChoiceText(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
