import AppKit
import Observation
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation

/// Which pages a bulk scale target resolves to (spec 10.5, NL-MEASURE-02). Pure.
public enum BulkScaleTargets {

    /// Two page boxes are "the same dimensions" within half a point, in the same orientation.
    static let sizeTolerance: Double = 0.5

    /// The page identifiers the selection names, in document order.
    ///
    /// - Parameters:
    ///   - selection: the sheet's target and typed range.
    ///   - current: the page on screen, whose scale is being applied.
    ///   - selected: the pages selected in the Navigator.
    ///   - pages: every page, in document order.
    public static func pages(
        for selection: BulkScaleSelection,
        current: UUID,
        selected: [UUID],
        pages: [ZPDFUIPresentation.PageDescriptor]
    ) -> [UUID] {
        switch selection.kind {
        case .currentPage:
            return pages.contains { $0.id == current } ? [current] : []
        case .selectedPages:
            let chosen = Set(selected)
            return pages.filter { chosen.contains($0.id) }.map(\.id)
        case .pageRange:
            guard selection.isRangeValid(pageCount: pages.count),
                  let start = selection.rangeStart, let end = selection.rangeEnd else { return [] }
            return pages[(start - 1)...(end - 1)].map(\.id)
        case .matchingDimensions:
            guard let reference = pages.first(where: { $0.id == current }) else { return [] }
            let size = reference.cropBox.size
            return pages.filter {
                abs($0.cropBox.size.width - size.width) <= sizeTolerance
                    && abs($0.cropBox.size.height - size.height) <= sizeTolerance
            }.map(\.id)
        case .entireDocument:
            return pages.map(\.id)
        }
    }
}

/// The bulk sheet's state: the target, and the preview the session computed for it.
@MainActor
@Observable
public final class BulkScaleModel {
    public var selection: BulkScaleSelection
    public private(set) var impact: BulkScaleImpact = .none
    public let scale: ScaleSummary
    public let pageCount: Int
    public let currentPageLabel: String
    @ObservationIgnored var onSelectionChange: () -> Void = {}
    @ObservationIgnored var onApply: (BulkScaleSelection, BulkScaleDecision) -> Void = { _, _ in }
    @ObservationIgnored var onCancel: () -> Void = {}

    init(scale: ScaleSummary, pageCount: Int, currentPageLabel: String, selection: BulkScaleSelection) {
        self.scale = scale
        self.pageCount = pageCount
        self.currentPageLabel = currentPageLabel
        self.selection = selection
    }

    func setImpact(_ impact: BulkScaleImpact) { self.impact = impact }
}

/// Binds ``BulkScaleSheet`` to the model; a changed target asks for a new preview.
struct BulkScaleHost: View {
    @Bindable var model: BulkScaleModel

    var body: some View {
        BulkScaleSheet(
            scale: model.scale,
            pageCount: model.pageCount,
            currentPageLabel: model.currentPageLabel,
            selection: $model.selection,
            impact: model.impact,
            onApply: { selection, decision in model.onApply(selection, decision) },
            // Keep existing measurements: values stay, flagged stale (NL-MEASURE-03, ADR-0030 §2).
            decisions: BulkScaleDecision.offeredChoices,
            onCancel: { model.onCancel() }
        )
        .onChange(of: model.selection) { _, _ in model.onSelectionChange() }
    }
}

/// Applies the page on screen's scale to other pages in one undoable step (NL-MEASURE-02):
/// Measure ▸ Apply Scale to Pages…. Presents the built ``BulkScaleSheet``; the preview counts
/// come from the session, and nothing is applied without the Apply press.
@MainActor
public final class BulkScaleCoordinator {

    public let model: BulkScaleModel
    public let sourcePage: PageID
    private weak var document: ZenitPDFProjectDocument?
    private weak var parent: NSWindow?
    public private(set) var sheetWindow: NSWindow?
    public private(set) var isFinished = false
    /// The pages the last Apply wrote to. Test affordance.
    public private(set) var appliedPages: [PageID] = []
    private var previewTask: Task<Void, Never>?

    public static let modalIdentifier = "scale.bulkApply"

    /// The open coordinator of each document, held while its sheet is up (V-016). The model's
    /// closures, the preview task and the sheet's completion all hold the coordinator weakly,
    /// and Measure ▸ Apply Scale to Pages… drops the value `present` returns — so the
    /// coordinator died with the command, and Apply and Cancel reached nothing.
    private static var open: [UUID: BulkScaleCoordinator] = [:]

    /// The coordinator whose sheet is up on `document`, if any.
    static func active(for document: ZenitPDFProjectDocument) -> BulkScaleCoordinator? {
        open[document.documentIdentity]
    }

    init(document: ZenitPDFProjectDocument, sourcePage: PageID, model: BulkScaleModel, parent: NSWindow) {
        self.document = document
        self.sourcePage = sourcePage
        self.model = model
        self.parent = parent
        model.onSelectionChange = { [weak self] in self?.refreshPreview() }
        model.onApply = { [weak self] selection, decision in
            guard let self else { return }
            Task { @MainActor in await self.apply(selection, keepExisting: decision == .keepExisting) }
        }
        model.onCancel = { [weak self] in self?.finish() }
    }

    /// Opens the sheet for the page on screen. A page with no scale has nothing to apply, so
    /// the calibration sheet opens instead, saying why.
    @discardableResult
    static func present(
        for document: ZenitPDFProjectDocument,
        in parent: NSWindow,
        orCalibrate calibrate: @MainActor (String) -> Void
    ) -> BulkScaleCoordinator? {
        if let existing = open[document.documentIdentity], existing.sheetWindow != nil {
            return existing
        }
        guard let core = document.core, let current = core.document.currentPageID else { return nil }
        guard let scale = core.snapshot.scale(onPage: current) else {
            calibrate(NSLocalizedString(
                "Set this page's scale first; it is the scale that will be applied to the other pages.",
                comment: "Calibration sheet notice when Apply Scale to Pages found no scale on the page"
            ))
            return nil
        }
        let label = core.snapshot.pages.first { $0.id == current }?.label ?? ""
        let model = BulkScaleModel(
            scale: scale,
            pageCount: core.snapshot.pages.count,
            currentPageLabel: label,
            // The rest of a drawing set is almost always the same paper size.
            selection: BulkScaleSelection(kind: .matchingDimensions)
        )
        let coordinator = BulkScaleCoordinator(document: document, sourcePage: PageID(current), model: model, parent: parent)
        coordinator.attach()
        if coordinator.sheetWindow != nil { open[document.documentIdentity] = coordinator }
        coordinator.refreshPreview()
        return coordinator
    }

    /// The pages the current target names, the source page left out (it already has the scale).
    func targetPages() -> [PageID] {
        namedPages().filter { $0 != sourcePage.rawValue }.map(PageID.init)
    }

    /// The pages the current target names, the source page included.
    private func namedPages() -> [UUID] {
        guard let core = document?.core else { return [] }
        return BulkScaleTargets.pages(
            for: model.selection,
            current: sourcePage.rawValue,
            selected: core.document.selectedPageIDs,
            pages: core.snapshot.pages
        )
    }

    /// Whether the target names the source page and nothing else — Current page, or a set of
    /// one size on a one-page drawing (L-69).
    func targetIsSourcePageOnly() -> Bool {
        let named = namedPages()
        return !named.isEmpty && named.allSatisfy { $0 == sourcePage.rawValue }
    }

    /// Recomputes the preview for the current target, off the session.
    func refreshPreview() {
        guard let core = document?.core else { return }
        let targets = targetPages()
        let sourceOnly = targetIsSourcePageOnly()
        let labels = Dictionary(uniqueKeysWithValues: core.snapshot.pages.map { ($0.id, $0.label) })
        let session = core.session
        previewTask?.cancel()
        previewTask = Task { @MainActor [weak self] in
            let pageSet = Set(targets)
            let markups = await session.markupCount(onPages: pageSet)
            let measurements = await session.measurementCount(onPages: pageSet)
            guard !Task.isCancelled, let self else { return }
            self.model.setImpact(BulkScaleImpact(
                pageCount: targets.count,
                markupCount: markups,
                affectedMeasurementCount: measurements,
                pageLabels: targets.compactMap { labels[$0.rawValue] },
                targetIsSourcePageOnly: sourceOnly
            ))
        }
    }

    /// Waits for the preview in flight. Test affordance.
    func settlePreview() async { await previewTask?.value }

    /// Applies the source page's scale to the target, as one ⌘Z.
    public func apply(_ selection: BulkScaleSelection, keepExisting: Bool = false) async {
        guard let core = document?.core else { return }
        model.selection = selection
        let targets = targetPages()
        guard !targets.isEmpty else { return }
        do {
            try await core.commands.applyScale(.copyOf(page: sourcePage), toPages: targets, keepExisting: keepExisting)
            appliedPages = targets
            await core.refresh()
            finish()
        } catch {
            if let parent { ZenitErrorPresenter.present(error, in: parent) }
        }
    }

    private func attach() {
        guard let parent, sheetWindow == nil else { return }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: BulkScaleHost(model: model)))
        sheet.setContentSize(CGSize(width: 520, height: 560))
        sheet.title = NSLocalizedString("Apply Scale", comment: "Bulk scale sheet title")
        sheet.styleMask = [.titled, .resizable]
        sheetWindow = sheet
        let attached = ZenitModalPresenter.beginSheet(sheet, on: parent, identifier: Self.modalIdentifier) { [weak self] in
            guard let self else { return }
            if self.sheetWindow === sheet { self.sheetWindow = nil }
            // Ended from outside (the quit sweep, a window closing): let the coordinator go.
            self.release()
        }
        if !attached { sheetWindow = nil }
    }

    func finish() {
        isFinished = true
        previewTask?.cancel()
        release()
        guard let sheet = sheetWindow else { return }
        sheetWindow = nil
        parent?.endSheet(sheet)
    }

    private func release() {
        guard let document, Self.open[document.documentIdentity] === self else { return }
        Self.open.removeValue(forKey: document.documentIdentity)
    }
}
