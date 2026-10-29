import AppKit
import Foundation
import SwiftUI
import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Slip-sheeting with carry-forward (NL-DOCS-12): the newest revision's matching sheets take
/// the place of the chosen sheets in the set, every measurement on them is carried onto its new
/// sheet and re-measured by the engine, the old sheets are kept (removed from the set, not
/// deleted), and a report lists every measurement's old and new value and the total delta.
/// One ⌘Z reverts the whole carry.
extension ZenitPDFProjectDocument {

    /// How the report reaches the screen, with the formatter of the takeoff's display units.
    /// A test injects a capture; nothing is shown outside the assembled bundle.
    static var carryForwardReportPresenter: (@MainActor (CarryForwardReport, QuantityFormatter, NSWindow?) -> Void) = { report, formatter, window in
        guard ZenitModalPresenter.canPresentModally, let window else { return }
        let display = CarryForwardReportDisplay(report: report, formatter: formatter)
        let panel = NSWindow(contentViewController: NSHostingController(rootView: CarryForwardReportView(display: display)))
        panel.styleMask = [.titled, .resizable]
        // Through the one modal door: recorded, and refused on a visible window in a
        // process with no user (R-039).
        ZenitModalPresenter.beginSheet(panel, on: window, identifier: "documents.carry-forward-report") {}
    }

    /// The comparator Carry Forward compares each old sheet with its revision through: the
    /// document's own, Revision Compare's, over `GeometryService`. A test process has no service
    /// to reach, so a test injects one that reads in process over ``compareProvider`` and
    /// restores this in a `defer`; nothing under `Apps/ZenitPDF/Sources` reassigns it.
    static var carryForwardComparator: (@MainActor (ZenitPDFProjectDocument) -> RevisionComparator?) = { document in
        document.revisionComparator
    }

    /// Carries the takeoff on `pageIDs` onto their partners in the newest revision. Returns the
    /// report, or `nil` when nothing could be carried (said in the status bar).
    @discardableResult
    func carryForward(_ pageIDs: [PageID], window: NSWindow?) async -> CarryForwardReport? {
        guard let core, let revision = newestRevision,
              let url = revisionPages[revision.id]?.fileURL,
              let pairs = revisionSheetPairs[revision.id] else {
            core?.status.setActiveToolNote(NSLocalizedString(
                "There is no matched revision to carry the takeoff to.",
                comment: "Status note: Carry Forward without a reviewed revision"
            ))
            return nil
        }
        let wanted = pageIDs.filter { pairs[$0.rawValue] != nil }
        guard !wanted.isEmpty else {
            core.status.setActiveToolNote(NSLocalizedString(
                "These sheets have no match in the revision.",
                comment: "Status note: Carry Forward on sheets the revision does not have"
            ))
            return nil
        }
        // The revision becomes a drawing of the project once; its sheets are placed below.
        let member: DrawingSet.Member
        if let existing = carriedRevisionDrawings[revision.id].flatMap({ drawingSet?.member(for: $0) }) {
            member = existing
        } else {
            guard let attached = await attachDrawing(fileAt: url) else { return nil }
            carriedRevisionDrawings[revision.id] = attached.drawing.documentID
            member = attached
        }
        let newByIndex = Dictionary(member.drawing.pages.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let state = await core.session.takeoffState()
        let order = await core.session.pageOrderIDs

        var carryPairs: [PageID: CarryPair] = [:]
        var placements: [(old: PageID, new: ZPDFContracts.PageDescriptor)] = []
        for old in wanted {
            guard let index = pairs[old.rawValue], let new = newByIndex[index], !order.contains(new.id) else { continue }
            // Each old sheet is compared with its new revision (NL-DOCS-12): a measurement under
            // changed linework is carried as "needs review", never as "unchanged".
            carryPairs[old] = await comparedCarryPair(old: old, new: new, revisionPage: revisionPages[revision.id])
            placements.append((old, new))
        }
        guard !placements.isEmpty else { return nil }
        // Slip-sheet: each new sheet goes where its predecessor stood (last first, so earlier
        // positions hold), then the predecessors leave the set.
        var commands: [DocumentCommand] = []
        for placement in placements.sorted(by: { (order.firstIndex(of: $0.old) ?? 0) > (order.firstIndex(of: $1.old) ?? 0) }) {
            commands.append(.insertPages([placement.new], at: order.firstIndex(of: placement.old) ?? order.count))
        }
        // The sheet's scale and its Scale Regions go with it: same drawing scales, new page (U-030).
        let scales = CarryForwardPlanner.carriedScales(from: state, pairs: carryPairs, keeping: state.scaleRegions)
        commands += scales.commands
        let carried = state.markups.filter { carryPairs[$0.pageID] != nil }
        let plan = CarryForwardPlanner.plan(markups: carried, pairs: carryPairs, now: Date(), scales: scales)
        commands += plan.commands
        var names: [PageID: SheetIdentity?] = [:]
        for placement in placements { if let identity = state.sheetIdentities[placement.old] { names[placement.new.id] = identity } }
        if !names.isEmpty { commands.append(.setSheetIdentities(names, overwriteManual: true)) }
        commands.append(.setPagesExcluded(placements.map(\.old), excluded: true))
        do {
            _ = try await core.commands.performBatch(
                commands,
                actionName: NSLocalizedString("Carry Forward to Revision", comment: "Undo action name: markups carried onto a newer revision's sheets")
            )
        } catch {
            core.status.setActiveToolNote(String(
                format: NSLocalizedString("The takeoff was not carried: %@", comment: "Status note: carry forward refused; the reason"),
                String(describing: error)
            ))
            return nil
        }
        await core.refresh()
        let after = Dictionary(await core.session.orderedMarkups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let report = CarryForwardReport.make(
            plan: plan,
            source: Dictionary(carried.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            carried: after
        )
        // In the Quantity Ledger's units and precision (V-020), never raw SI values.
        Self.carryForwardReportPresenter(report, core.snapshot.ledger.formatter, window)
        return report
    }

    /// The old sheet compared with its new revision, for the carry's alignment and changed
    /// regions (NL-DOCS-12). When no comparison can be made, the geometry is carried unmoved and
    /// the pair reviews everything: every measurement carried through it asks for review,
    /// including one that lies beyond the new sheet's extent.
    private func comparedCarryPair(
        old: PageID,
        new: ZPDFContracts.PageDescriptor,
        revisionPage: RevisionPageReference?
    ) async -> CarryPair {
        guard let comparator = Self.carryForwardComparator(self), let provider = compareProvider, var revised = revisionPage,
              let source = loadedDrawing(forPage: old.rawValue),
              let oldPage = source.pages.first(where: { $0.id == old }),
              let opened = try? await provider.open(fileAt: source.url, password: drawingPassword(forPage: old.rawValue))
        else {
            return CarryForwardComparison.reviewingEverything(target: new.id)
        }
        revised.pageIndex = new.index
        let baseline = RevisionPageReference(document: opened.handle, pageIndex: oldPage.index, fileURL: source.url, label: "")
        // Revision Compare's own tolerance and smallest reported region, as the set compare
        // report uses them, so the carry flags exactly what the review lists.
        let pair = await CarryForwardComparison.pair(
            target: new.id, baseline: baseline, revised: revised, comparator: comparator,
            raster: comparePresenter?.rasterOptions ?? .standard,
            minimumAreaInSquarePoints: comparePresenter?.minimumRegionAreaPoints ?? 0
        )
        await provider.close(opened.handle)
        return pair
    }
}

/// The carry-forward report's words: every row and the total change per quantity, in the
/// takeoff's display units and precision (V-020). The view used to print the raw SI values —
/// `12.3456789` metres on a project measured in feet — with no unit, field or column header,
/// and never showed the total change the report computes.
@MainActor
struct CarryForwardReportDisplay: Equatable {

    struct Row: Equatable {
        var measurement: String
        var before: String
        var after: String
        var change: String
        var result: String
    }

    struct Total: Equatable {
        var field: String
        var change: String
    }

    static var header: [String] {
        [
            NSLocalizedString("Measurement", comment: "Carry forward report column: the measurement and its quantity"),
            NSLocalizedString("Before", comment: "Carry forward report column: the value on the old sheet"),
            NSLocalizedString("After", comment: "Carry forward report column: the value on the new sheet"),
            NSLocalizedString("Change", comment: "Carry forward report column: after minus before"),
            NSLocalizedString("Result", comment: "Carry forward report column: how the measurement moved"),
        ]
    }

    var rows: [Row]
    var totals: [Total]
    var heldForScale: Int

    init(report: CarryForwardReport, formatter: QuantityFormatter) {
        rows = report.rows.map { row in
            let subject = row.subject.isEmpty
                ? NSLocalizedString("Measurement", comment: "Carry forward row without a subject")
                : row.subject
            let measurement = row.field.map { "\(subject) · \(ScaleImpactConfirmation.fieldName($0))" } ?? subject
            return Row(
                measurement: measurement,
                before: Self.text(row.oldValue, field: row.field, formatter: formatter),
                after: Self.text(row.newValue, field: row.field, formatter: formatter),
                change: Self.text(row.delta, field: row.field, formatter: formatter, signed: true),
                result: CarryForwardReportView.classText(row.classification)
            )
        }
        var order: [ZPDFContracts.MeasurementField] = []
        for row in report.rows { if let field = row.field, !order.contains(field) { order.append(field) } }
        totals = order.compactMap { field in
            guard let total = report.totalDelta[field] else { return nil }
            return Total(field: ScaleImpactConfirmation.fieldName(field), change: Self.text(total, field: field, formatter: formatter, signed: true))
        }
        heldForScale = report.heldForScale
    }

    /// One value with its unit, through the ledger's own formatter; a change carries its sign.
    static func text(_ value: Decimal?, field: ZPDFContracts.MeasurementField?, formatter: QuantityFormatter, signed: Bool = false) -> String {
        guard let value else { return "—" }
        guard let field else { return NSDecimalNumber(decimal: value).stringValue }
        let quantity = Shown.Quantity(value: value, dimension: Shown.Dimension(domain: field.dimension))
        let text = formatter.textWithUnit(quantity)
        guard signed, value > 0 else { return text }
        return "+" + text
    }
}

/// The carry-forward report: every measurement's old and new value, how it moved, the total.
struct CarryForwardReportView: View {
    let display: CarryForwardReportDisplay

    static func classText(_ value: CarryForwardClass) -> String {
        switch value {
        case .unchanged: NSLocalizedString("Unchanged", comment: "Carry forward: the measurement landed where it was")
        case .moved: NSLocalizedString("Moved with the drawing", comment: "Carry forward: the measurement moved with the aligned drawing")
        case .needsReview: NSLocalizedString("Linework changed — review", comment: "Carry forward: the drawing changed under the measurement")
        }
    }

    private static let valueWidth: CGFloat = 110

    private func line(_ cells: [String], emphasis: ZPDFColorToken = .textPrimary, style: ZPDFTextStyle = .body) -> some View {
        HStack(spacing: ZPDFSpacing.s) {
            Text(cells[0]).zpdfText(style, emphasis).frame(maxWidth: .infinity, alignment: .leading)
            Text(cells[1]).zpdfText(style, .textSecondary).monospacedDigit().frame(width: Self.valueWidth, alignment: .trailing)
            Text(cells[2]).zpdfText(style, emphasis).monospacedDigit().frame(width: Self.valueWidth, alignment: .trailing)
            Text(cells[3]).zpdfText(style, emphasis).monospacedDigit().frame(width: Self.valueWidth, alignment: .trailing)
            Text(cells[4]).zpdfText(.caption, .textSecondary).frame(width: 180, alignment: .leading)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(NSLocalizedString("Carried forward", comment: "Carry forward report title"))
                .zpdfText(.windowTitle, .textPrimary)
            if display.heldForScale > 0 {
                Text(String(format: NSLocalizedString(
                    "%lld measurements stayed on the old sheets: their Scale Region could not be carried.",
                    comment: "Carry forward report: measurements held because their Scale Region was not carried; the count"
                ), display.heldForScale)).zpdfText(.body, .textSecondary)
            }
            line(CarryForwardReportDisplay.header, emphasis: .textSecondary, style: .caption)
                .padding(.horizontal, ZPDFSpacing.s)
                .accessibilityAddTraits(.isHeader)
            List(Array(display.rows.enumerated()), id: \.offset) { _, row in
                line([row.measurement, row.before, row.after, row.change, row.result])
            }
            .listStyle(.inset)
            if !display.totals.isEmpty {
                VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
                    ForEach(Array(display.totals.enumerated()), id: \.offset) { _, total in
                        Text(String(
                            format: NSLocalizedString(
                                "Total change, %1$@: %2$@",
                                comment: "Carry forward report footer: the quantity and its total change"
                            ),
                            total.field, total.change
                        ))
                        .zpdfText(.body, .textPrimary)
                        .monospacedDigit()
                    }
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button(NSLocalizedString("Done", comment: "Close the carry forward report")) {
                    if let sheet = NSApp.keyWindow, let parent = sheet.sheetParent { parent.endSheet(sheet) }
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ZPDFSpacing.l)
        .frame(minWidth: 720, minHeight: 360)
        .background(ZPDFColor.background)
    }
}
