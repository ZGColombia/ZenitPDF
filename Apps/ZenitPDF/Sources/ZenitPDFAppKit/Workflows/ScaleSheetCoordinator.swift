import AppKit
import Observation
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation

// MARK: - The request a validated draft turns into

/// What a validated calibration draft asks the session to do (NL-MEASURE-01).
///
/// Pure, so the translation from the sheet's `Double` fields to the session's exact `Decimal`
/// entry points is testable without a sheet: a drawing ratio becomes `setPresetScale`
/// (`source == .preset`, no evidence), one line becomes `calibrate`, two lines become
/// `calibrateXY`.
public enum CalibrationRequest: Equatable, Sendable {
    case preset(denominator: Decimal, label: String, allowExtreme: Bool)
    case twoPoint(first: PDFPoint, second: PDFPoint, length: Decimal, unit: ZPDFContracts.LengthUnit, label: String?, allowExtreme: Bool)
    case separateAxes(
        xFirst: PDFPoint, xSecond: PDFPoint, xLength: Decimal,
        yFirst: PDFPoint, ySecond: PDFPoint, yLength: Decimal,
        unit: ZPDFContracts.LengthUnit, label: String?, allowExtreme: Bool
    )

    /// The request for a draft, or `nil` when the draft does not validate — the sheet's Apply
    /// is disabled then, and this is the second lock on the same door.
    public static func make(from draft: CalibrationDraft) -> CalibrationRequest? {
        guard CalibrationValidator.validate(draft).canApply else { return nil }
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String? = trimmed.isEmpty ? nil : trimmed
        switch draft.mode {
        case .drawingScale:
            guard let raw = draft.drawingScaleDenominator, let denominator = exact(raw) else { return nil }
            return .preset(
                denominator: denominator,
                label: name ?? drawingScaleTitle(for: raw),
                allowExtreme: draft.confirmsExtremeScale
            )
        case .uniform:
            guard let unit = draft.resolvedUnit,
                  let start = draft.primary.start, let end = draft.primary.end,
                  let raw = draft.primary.knownLength, let length = exact(raw) else { return nil }
            return .twoPoint(
                first: PDFPoint(shown: start), second: PDFPoint(shown: end),
                length: length, unit: Domain.Length(shown: unit), label: name,
                allowExtreme: draft.confirmsExtremeScale
            )
        case .separateAxes:
            guard let unit = draft.resolvedUnit,
                  let xStart = draft.primary.start, let xEnd = draft.primary.end,
                  let yStart = draft.secondary.start, let yEnd = draft.secondary.end,
                  let xRaw = draft.primary.knownLength, let xLength = exact(xRaw),
                  let yRaw = draft.secondary.knownLength, let yLength = exact(yRaw) else { return nil }
            return .separateAxes(
                xFirst: PDFPoint(shown: xStart), xSecond: PDFPoint(shown: xEnd), xLength: xLength,
                yFirst: PDFPoint(shown: yStart), ySecond: PDFPoint(shown: yEnd), yLength: yLength,
                unit: Domain.Length(shown: unit), label: name, allowExtreme: draft.confirmsExtremeScale
            )
        }
    }

    /// The printed form of a ratio: the preset's own title (`1/8" = 1'-0"`), else `1:n`.
    public static func drawingScaleTitle(for denominator: Double) -> String {
        if let preset = (DrawingScalePreset.metric + DrawingScalePreset.imperial)
            .first(where: { abs($0.denominator - denominator) < 1e-9 }) {
            return preset.title
        }
        return "1:\(exact(denominator).map { "\($0)" } ?? String(denominator))"
    }

    /// A field's `Double` as the `Decimal` the person typed: through the shortest round-trip
    /// spelling, so `12.5` is 12.5 and `0.1` is 0.1, never `0.1000000000000000055…`.
    static func exact(_ value: Double) -> Decimal? {
        guard value.isFinite, value > 0 else { return nil }
        return Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Runs the request on the page, through the bus, as one undoable step.
    ///
    /// - Parameter scaleID: a fresh identifier for a Scale Region's own scale; `nil` for the
    ///   page's scale.
    func perform(on commands: DocumentCommandBus, page: PageID, scaleID: ScaleID?, keepExisting: Bool = false) async throws {
        switch self {
        case let .preset(denominator, label, allowExtreme):
            try await commands.setPresetScale(
                page: page, ratioDenominator: denominator, label: label,
                scaleID: scaleID, allowExtreme: allowExtreme, keepExisting: keepExisting
            )
        case let .twoPoint(first, second, length, unit, label, allowExtreme):
            try await commands.calibrate(
                page: page, first: first, second: second,
                knownLength: length, knownLengthUnit: unit, scaleID: scaleID,
                label: label ?? NSLocalizedString("Calibrated", comment: "Default scale label"),
                allowExtreme: allowExtreme, keepExisting: keepExisting
            )
        case let .separateAxes(xFirst, xSecond, xLength, yFirst, ySecond, yLength, unit, label, allowExtreme):
            try await commands.calibrateXY(
                page: page,
                xFirst: xFirst, xSecond: xSecond, xKnownLength: xLength,
                yFirst: yFirst, ySecond: ySecond, yKnownLength: yLength,
                knownLengthUnit: unit, scaleID: scaleID,
                label: label ?? NSLocalizedString("Calibrated X/Y", comment: "Default label of a separate X/Y scale"),
                allowExtreme: allowExtreme, keepExisting: keepExisting
            )
        }
    }
}

// MARK: - The sheet's state

/// The calibration sheet's state, kept across the moments the sheet steps aside so the canvas
/// can collect points.
@MainActor
@Observable
public final class ScaleSheetModel {
    public var draft: CalibrationDraft
    public let pageLabel: String
    public let notice: String?
    @ObservationIgnored var onPickPoint: (CalibrationPickStep) -> Void = { _ in }
    @ObservationIgnored var onApply: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}

    init(draft: CalibrationDraft, pageLabel: String, notice: String?) {
        self.draft = draft
        self.pageLabel = pageLabel
        self.notice = notice
    }
}

/// Binds ``CalibrationSheet`` to the model.
struct ScaleSheetHost: View {
    @Bindable var model: ScaleSheetModel

    var body: some View {
        CalibrationSheet(
            draft: $model.draft,
            pageLabel: model.pageLabel,
            notice: model.notice,
            onPickPoint: { model.onPickPoint($0) },
            onApply: { _ in model.onApply() },
            onCancel: { model.onCancel() }
        )
    }
}

// MARK: - The coordinator

/// Presents the calibration sheet (uniform, separate X/Y, drawing ratio) and commits what it
/// returns (NL-MEASURE-01). Replaces the known-length `NSAlert` of ``CalibrationPrompt``.
///
/// Three doors open it: Measure ▸ Calibrate Scale…, the status strip's Scale segment (LT3-08),
/// and a measurement refused on a sheet with no scale (LT3-05). The toolbar's Calibrate keeps
/// its two-click start and lands here with the points filled in. "Pick points" hands the canvas
/// back for two clicks and the sheet returns with them.
@MainActor
public final class ScaleSheetCoordinator {

    /// The open coordinator of each document, so the points the canvas collects find the
    /// sheet that asked for them. One sheet per document at a time.
    private static var open: [UUID: ScaleSheetCoordinator] = [:]

    /// The coordinator waiting on `document`, when a sheet is open or stepped aside for points.
    static func active(for document: ZenitPDFProjectDocument) -> ScaleSheetCoordinator? {
        open[document.documentIdentity]
    }

    public let model: ScaleSheetModel
    public let page: PageID
    private weak var document: ZenitPDFProjectDocument?
    private weak var parent: NSWindow?
    private let beginPicking: @MainActor () -> Void
    /// The axis the canvas is collecting points for, while the sheet is stepped aside.
    public private(set) var pendingPick: CalibrationPickStep?
    /// The sheet window while it is attached.
    public private(set) var sheetWindow: NSWindow?
    /// How many times the sheet was attached. Test affordance.
    public private(set) var presentationCount = 0
    /// The last refusal the session gave, shown through the error presenter. Test affordance.
    public private(set) var lastError: Error?
    /// Set once the coordinator has finished — applied or cancelled.
    public private(set) var isFinished = false
    /// Whether this sheet is finishing a two-click Calibrate pick and so keeps the toolbar's
    /// Calibrate chip lit until it closes (L-05).
    public private(set) var holdsCalibrateTool = false

    /// The identifier every calibration sheet presentation is recorded under.
    public static let modalIdentifier = "calibration.sheet"

    init(
        document: ZenitPDFProjectDocument,
        page: PageID,
        pageLabel: String,
        draft: CalibrationDraft,
        notice: String?,
        parent: NSWindow,
        beginPicking: @escaping @MainActor () -> Void
    ) {
        self.document = document
        self.page = page
        self.parent = parent
        self.beginPicking = beginPicking
        self.model = ScaleSheetModel(draft: draft, pageLabel: pageLabel, notice: notice)
        model.onPickPoint = { [weak self] step in self?.pick(step) }
        model.onApply = { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.commit() }
        }
        model.onCancel = { [weak self] in self?.cancel() }
    }

    // MARK: Opening

    /// Opens the sheet for the page on screen.
    ///
    /// - Parameters:
    ///   - points: two points the canvas already collected (the toolbar's Calibrate), which
    ///     open the sheet in uniform mode with the line filled in.
    ///   - notice: why the sheet opened, when there is a reason to say.
    @discardableResult
    static func present(
        for document: ZenitPDFProjectDocument,
        in parent: NSWindow,
        points: [PDFPointValue] = [],
        notice: String? = nil,
        beginPicking: @escaping @MainActor () -> Void
    ) -> ScaleSheetCoordinator? {
        if let existing = open[document.documentIdentity] {
            // Already open, or stepped aside for points: bring it back rather than stack a
            // second sheet on the same page.
            if existing.sheetWindow == nil, existing.pendingPick == nil { existing.attach() }
            return existing
        }
        guard let core = document.core, let current = core.document.currentPageID else { return nil }
        let pageDescriptor = core.snapshot.pages.first { $0.id == current }
        var draft = CalibrationDraft.seeded(from: core.snapshot.scale(onPage: current))
        if let pageDescriptor {
            draft.pageSizePoints = PDFSizeValue(
                width: pageDescriptor.cropBox.size.width,
                height: pageDescriptor.cropBox.size.height
            )
        }
        if points.count == 2 {
            draft.mode = .uniform
            draft.primary = CalibrationAxisInput(start: points[0], end: points[1])
        } else if core.snapshot.scale(onPage: current) == nil {
            // A sheet with no scale yet: the drawing ratio is one step for a vector set, and the
            // ratio a title block states is the most common way to set one.
            draft.mode = .drawingScale
        }
        let coordinator = ScaleSheetCoordinator(
            document: document,
            page: PageID(current),
            pageLabel: pageDescriptor?.label ?? "",
            draft: draft,
            notice: notice,
            parent: parent,
            beginPicking: beginPicking
        )
        open[document.documentIdentity] = coordinator
        coordinator.attach()
        if points.count == 2 { coordinator.holdCalibrateTool() }
        return coordinator
    }

    /// Keeps the Calibrate chip lit while the sheet finishes a Calibrate pick (L-05).
    ///
    /// The canvas ends its pick by arming Select (so the chip never outlives a pick that goes
    /// nowhere), and the sheet that turns the two points into a scale opened a moment later: the
    /// whole time the calibration sheet was up, the toolbar lit Select. The pick is not done
    /// until the sheet is, so the sheet takes the chip back and returns it to Select when it
    /// closes. A sheet opened without a pick — Set Scale…, the status strip, a refused
    /// measurement — leaves the armed tool alone.
    private func holdCalibrateTool() {
        guard let toolbar = document?.shell?.toolbar else { return }
        holdsCalibrateTool = true
        toolbar.selectTool(.calibrate)
    }

    /// Hands the toolbar back to Select when the sheet held Calibrate and nothing else was armed
    /// since.
    private func releaseCalibrateTool() {
        guard holdsCalibrateTool else { return }
        holdsCalibrateTool = false
        guard let toolbar = document?.shell?.toolbar, toolbar.activeTool == .calibrate else { return }
        toolbar.selectTool(.select)
    }

    private func attach() {
        guard let parent, sheetWindow == nil else { return }
        let hosting = NSHostingController(rootView: ScaleSheetHost(model: model))
        let sheet = NSWindow(contentViewController: hosting)
        sheet.setContentSize(CGSize(width: 480, height: 560))
        sheet.title = NSLocalizedString("Calibrate Scale", comment: "Calibration sheet title")
        sheet.styleMask = [.titled, .resizable]
        sheetWindow = sheet
        presentationCount += 1
        let attached = ZenitModalPresenter.beginSheet(sheet, on: parent, identifier: Self.modalIdentifier) { [weak self] in
            self?.sheetDidEnd(sheet)
        }
        if !attached { sheetWindow = nil }
    }

    private func detach() {
        guard let sheet = sheetWindow else { return }
        sheetWindow = nil
        parent?.endSheet(sheet)
    }

    private func sheetDidEnd(_ sheet: NSWindow) {
        if sheetWindow === sheet { sheetWindow = nil }
    }

    // MARK: Point picking

    /// Steps aside so the canvas can collect the two points of one line.
    func pick(_ step: CalibrationPickStep) {
        pendingPick = step
        detach()
        beginPicking()
    }

    /// Receives the canvas's two points for the pending line and brings the sheet back.
    ///
    /// - Returns: whether the points were for this sheet.
    @discardableResult
    func receive(points: [PDFPointValue]) -> Bool {
        guard let step = pendingPick else { return false }
        pendingPick = nil
        if points.count == 2 {
            switch step {
            case .yAxisStart, .yAxisEnd:
                model.draft.secondary.start = points[0]
                model.draft.secondary.end = points[1]
            default:
                model.draft.primary.start = points[0]
                model.draft.primary.end = points[1]
            }
        }
        attach()
        // Back from a pick the canvas ended on Select: the sheet is still the calibration (L-05).
        holdCalibrateTool()
        return true
    }

    /// The canvas left point picking without two points (Escape): the sheet comes back as it was.
    func pickingAbandoned() {
        guard pendingPick != nil else { return }
        pendingPick = nil
        attach()
        holdCalibrateTool()
    }

    // MARK: Finishing

    /// Commits the draft through the bus. On a refusal the sheet stays open with the draft,
    /// and the refusal is presented.
    public func commit() async {
        guard let document, let core = document.core else { return }
        guard let request = CalibrationRequest.make(from: model.draft) else { return }
        // A Scale Region's calibration installs a second scale beside the page's own.
        let target = document.pendingScaleCalibration ?? .pageDefault
        let regionScaleID: ScaleID? = target == .pageDefault ? nil : ScaleID(UUID())
        // A recalibration says what it changes before it changes it (NL-MEASURE-03).
        var keepExisting = false
        if regionScaleID == nil {
            let decision = await ScaleImpactConfirmation.decide(request, page: page, core: core, window: sheetWindow ?? parent)
            guard decision != .cancel else { return }
            keepExisting = decision == .keepExisting
        }
        do {
            try await request.perform(on: core.commands, page: page, scaleID: regionScaleID, keepExisting: keepExisting)
            if let regionScaleID,
               let scale = await core.session.scaleTransform(regionScaleID),
               let shell = document.shell {
                await document.completeScaleRegionCalibration(scale: scale, shell: shell)
            } else {
                document.pendingScaleCalibration = nil
            }
            await core.refresh()
            document.refreshProjectStructureIfPossible()
            finish()
        } catch {
            lastError = error
            if let window = parent { ZenitErrorPresenter.present(error, in: window) }
        }
    }

    /// Dismisses without applying. A Scale Region's pending destination goes with it (CR-149).
    public func cancel() {
        document?.pendingScaleCalibration = nil
        finish()
    }

    private func finish() {
        isFinished = true
        detach()
        pendingPick = nil
        releaseCalibrateTool()
        if let document, Self.open[document.documentIdentity] === self {
            Self.open.removeValue(forKey: document.documentIdentity)
        }
    }
}
