import AppKit
import Observation
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation

/// The Page Scales sheet's state: every sheet's row, the Navigator-independent selection, and
/// the proposal each unscaled sheet's own text makes.
@MainActor
@Observable
public final class PageScalesModel {
    public private(set) var rows: [PageScaleRow]
    public var selection: Set<UUID> = []
    /// The ratio each proposed row would apply, by page.
    @ObservationIgnored public private(set) var proposals: [UUID: ScaleProposal] = [:]
    @ObservationIgnored var onApplyProposals: (Set<UUID>) -> Void = { _ in }
    @ObservationIgnored var onApplyScaleToPages: () -> Void = {}
    @ObservationIgnored var onClose: () -> Void = {}

    init(rows: [PageScaleRow]) { self.rows = rows }

    func setStatus(_ status: PageScaleStatus, for id: UUID, proposal: ScaleProposal? = nil) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].status = status
        proposals[id] = proposal
    }
}

struct PageScalesHost: View {
    @Bindable var model: PageScalesModel

    var body: some View {
        PageScalesPanel(
            rows: model.rows,
            selection: $model.selection,
            onApplyProposals: { model.onApplyProposals($0) },
            onApplyScaleToPages: { model.onApplyScaleToPages() },
            onClose: { model.onClose() }
        )
    }
}

/// Measure ▸ Page Scales…: every sheet of the set with its scale status — set (with its ratio
/// and source), proposed from its own title block, or none — and one press to apply the
/// proposals (NL-MEASURE-02). The proposal used to be read from the first sheet only, and
/// sheets 2…N never got one; here every sheet is read, in the
/// background, within a page budget, and nothing is applied without the press.
@MainActor
public final class PageScalesCoordinator {

    /// The most sheets whose text is read for a proposal in one opening. A 300-sheet set is
    /// read in full; a larger one says the rest was not read rather than stalling.
    public static let pageBudget = 400

    public let model: PageScalesModel
    private weak var document: ZenitPDFProjectDocument?
    private weak var parent: NSWindow?
    private var readTask: Task<Void, Never>?
    public private(set) var sheetWindow: NSWindow?
    public private(set) var isFinished = false

    public static let modalIdentifier = "scale.pageScales"

    /// The open coordinator of each document, held while its sheet is up (V-016). Everything
    /// else holds the coordinator weakly — the model's closures, the read task, the sheet's
    /// completion — and the menu command drops the value `present` returns, so without this
    /// the coordinator died with the command: the rows stayed on "Reading…" and Close did
    /// nothing, leaving a sheet on the window that nothing could end.
    private static var open: [UUID: PageScalesCoordinator] = [:]

    /// The coordinator whose sheet is up on `document`, if any.
    static func active(for document: ZenitPDFProjectDocument) -> PageScalesCoordinator? {
        open[document.documentIdentity]
    }

    init(document: ZenitPDFProjectDocument, model: PageScalesModel, parent: NSWindow) {
        self.document = document
        self.model = model
        self.parent = parent
    }

    @discardableResult
    static func present(
        for document: ZenitPDFProjectDocument,
        in parent: NSWindow,
        applyScaleToPages: @escaping @MainActor () -> Void
    ) -> PageScalesCoordinator? {
        if let existing = open[document.documentIdentity], existing.sheetWindow != nil {
            return existing
        }
        guard let core = document.core else { return nil }
        let rows = core.snapshot.pages.map { page in
            PageScaleRow(
                id: page.id,
                label: page.label,
                sizeText: sizeText(page.cropBox.size.width, page.cropBox.size.height),
                status: .reading
            )
        }
        let coordinator = PageScalesCoordinator(document: document, model: PageScalesModel(rows: rows), parent: parent)
        coordinator.model.onApplyProposals = { [weak coordinator] ids in
            guard let coordinator else { return }
            Task { @MainActor in await coordinator.applyProposals(ids) }
        }
        coordinator.model.onApplyScaleToPages = { [weak coordinator] in
            coordinator?.finish()
            applyScaleToPages()
        }
        coordinator.model.onClose = { [weak coordinator] in coordinator?.finish() }
        coordinator.attach()
        guard coordinator.sheetWindow != nil else { return coordinator }
        open[document.documentIdentity] = coordinator
        coordinator.readStatuses()
        return coordinator
    }

    /// "A1 · 841 × 594 mm" when the box is a standard size, else the millimetres alone.
    static func sizeText(_ width: Double, _ height: Double) -> String {
        let millimetres = String(format: "%.0f × %.0f mm", width * 25.4 / 72, height * 25.4 / 72)
        if let name = StandardPaperSize.match(PDFSizeValue(width: width, height: height)) {
            return "\(name) · \(millimetres)"
        }
        return millimetres
    }

    /// Fills every row: a set scale from the session at once; a proposal from each unscaled
    /// sheet's own text, read one sheet at a time in the background.
    ///
    /// Each sheet is read from its own drawing (U-008): the primary drawing's text was read at
    /// every sheet's PDF-local index, so a sheet of an added drawing was offered the scale printed
    /// on the primary drawing's same-index sheet. The text is the one ``PageTextLoader`` reads —
    /// the embedded text, else the stored recognition — as the per-sheet offer reads it.
    func readStatuses() {
        guard let document, let core = document.core else { return }
        let pages = core.snapshot.pages
        let session = core.session
        readTask?.cancel()
        readTask = Task { @MainActor [weak self] in
            var toRead: [ZPDFUIPresentation.PageDescriptor] = []
            for page in pages {
                if let scale = await session.scale(onPage: PageID(page.id)) {
                    let summary = core.snapshot.scale(onPage: page.id)
                    self?.model.setStatus(.set(
                        ratio: summary?.displayString ?? scale.label ?? "",
                        source: Self.sourceText(scale.source)
                    ), for: page.id)
                } else {
                    toRead.append(page)
                }
            }
            let contractPages = await session.pageDescriptors
            for (offset, page) in toRead.enumerated() {
                guard let self, !Task.isCancelled else { return }
                guard offset < Self.pageBudget, let document = self.document,
                      let sheet = contractPages.first(where: { $0.id.rawValue == page.id })
                        ?? document.pageDescriptor(forPage: page.id)
                else {
                    self.model.setStatus(.none, for: page.id)
                    continue
                }
                let recognised = await PageTextLoader.lines(document: document, page: sheet, region: nil, allowRegionOCR: false)
                    .map(\.recognisedTextLine)
                guard !Task.isCancelled else { return }
                let userUnit = sheet.userUnit
                let proposal = ScaleProposalEngine().proposal(
                    forRecognisedLines: recognised,
                    pageBoxSizeInPoints: PDFSizeValue(width: page.cropBox.size.width, height: page.cropBox.size.height),
                    userUnit: userUnit
                )
                if let proposal {
                    self.model.setStatus(
                        .proposed(ratio: proposal.displayString, evidence: proposal.evidence.matchedText),
                        for: page.id,
                        proposal: proposal
                    )
                } else {
                    self.model.setStatus(.none, for: page.id)
                }
            }
        }
    }

    static func sourceText(_ source: ScaleSource) -> String {
        switch source {
        case .calibrationTwoPoint: return NSLocalizedString("Calibrated", comment: "Scale source: two-point calibration")
        case .calibrationXY: return NSLocalizedString("Calibrated X/Y", comment: "Scale source: separate X/Y calibration")
        case .preset: return NSLocalizedString("Drawing ratio", comment: "Scale source: a preset drawing ratio")
        case .inherited: return NSLocalizedString("Copied from another page", comment: "Scale source: copied from another page")
        }
    }

    /// Applies the proposals of `ids` as one undoable step, then re-reads the statuses.
    public func applyProposals(_ ids: Set<UUID>) async {
        guard let core = document?.core else { return }
        let entries = model.rows.compactMap { row -> PresetScaleEntry? in
            guard ids.contains(row.id), let proposal = model.proposals[row.id] else { return nil }
            return PresetScaleEntry(
                page: PageID(row.id),
                ratioNumerator: Decimal(proposal.ratio.numerator),
                ratioDenominator: Decimal(proposal.ratio.denominator),
                label: proposal.displayString
            )
        }
        guard !entries.isEmpty else { return }
        do {
            try await core.commands.applyPresetScales(entries)
            await core.refresh()
            for entry in entries {
                model.setStatus(.set(
                    ratio: entry.label ?? "",
                    source: Self.sourceText(.preset)
                ), for: entry.page.rawValue)
            }
            model.selection = []
        } catch {
            if let parent { ZenitErrorPresenter.present(error, in: parent) }
        }
    }

    private func attach() {
        guard let parent, sheetWindow == nil else { return }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: PageScalesHost(model: model)))
        sheet.setContentSize(CGSize(width: 560, height: 520))
        sheet.title = NSLocalizedString("Page Scales", comment: "Page scales sheet title")
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
        readTask?.cancel()
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
