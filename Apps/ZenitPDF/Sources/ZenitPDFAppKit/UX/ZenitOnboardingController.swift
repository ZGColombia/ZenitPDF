import AppKit
import Observation
import SwiftUI
import ZPDFAppCore
import ZPDFDesignSystem
import ZPDFUIShell
import ZPDFUIWorkflows

/// The first-run guide, shipped (NL-UX-13).
///
/// `OnboardingModel` and `OnboardingFlow` were finished and tested and never presented: the only
/// instance lived in a preview and `onPerformStep` was never assigned. This controller is the
/// missing half:
///
/// - **Shown on first launch**, as the flow's own corner card in a small non-activating panel
///   at the project window's bottom-leading corner. It never takes the keyboard and never
///   blocks; Skip is on every step. Help ▸ Welcome to Zenit PDF brings it back from the start.
/// - **Each step's button does the thing**: Open…, Calibrate Scale…, arm Area, show the
///   Quantity Ledger — the same commands the menus run.
/// - **Steps complete from real events**, never from the button: a drawing open, a scale set, a
///   measurement filed, the ledger on screen with a row in it.
/// - **Progress persists** in the shipping app's defaults; any other process keeps it in memory,
///   and a test process never draws the card.
@MainActor
final class ZenitOnboardingController: NSObject {

    static let shared = ZenitOnboardingController()

    /// The guide's state. Injectable for tests (``init(store:)``).
    let model: OnboardingModel
    private(set) var panel: NSPanel?
    /// The project window the card stands on. Test affordance for reading.
    private(set) weak var hostWindow: NSWindow?
    private weak var observedDocument: ZenitPDFProjectDocument?
    private var observationGeneration = 0

    private override init() {
        let store: any OnboardingProgressStoring = ZenitModalPresenter.canPresentModally
            ? UserDefaultsOnboardingProgressStore()
            : InMemoryOnboardingProgressStore()
        self.model = OnboardingModel(store: store)
        super.init()
    }

    /// A controller over its own store, for tests.
    init(store: any OnboardingProgressStoring) {
        self.model = OnboardingModel(store: store)
        super.init()
    }

    // MARK: - What completes a step

    /// The steps a document's state proves done. Pure, so the rule is testable on its own.
    static func completedSteps(
        hasDrawing: Bool,
        hasScale: Bool,
        hasMeasurement: Bool,
        ledgerShowsRows: Bool
    ) -> Set<OnboardingStep> {
        var done = Set<OnboardingStep>()
        if hasDrawing { done.insert(.openDrawing) }
        if hasScale { done.insert(.calibrateScale) }
        if hasMeasurement { done.insert(.firstMeasurement) }
        if ledgerShowsRows { done.insert(.seeInQuantityLedger) }
        return done
    }

    /// The steps a document's state proves done, or `nil` before its takeoff has loaded.
    func provenSteps(of document: ZenitPDFProjectDocument) -> Set<OnboardingStep>? {
        guard let core = document.core else { return nil }
        let snapshot = core.snapshot
        return Self.completedSteps(
            hasDrawing: document.drawing != nil,
            hasScale: !snapshot.pageScales.isEmpty || snapshot.firstPageScale != nil,
            hasMeasurement: snapshot.markups.contains { !$0.measurementFields.isEmpty },
            ledgerShowsRows: (document.shell?.isSurfaceVisible(.quantityLedger) ?? false) && !core.ledger.isEmpty
        )
    }

    /// Reads a document's state and completes whatever it proves, in path order.
    func advance(from document: ZenitPDFProjectDocument) {
        guard let done = provenSteps(of: document) else { return }
        for step in model.steps where done.contains(step) && !model.isComplete(step) {
            model.complete(step)
        }
    }

    // MARK: - Joining a window

    /// Called when a document is attached to a project window: wires the step actions to that
    /// window, starts watching the document for the events that complete steps, and shows the
    /// card when the guide is still visible.
    func attach(document: ZenitPDFProjectDocument, controller: ProjectWindowController) {
        retarget(document: document, controller: controller)
        advance(from: document)
        present()
    }

    /// Points the guide at one window's drawing: the card stands on that window, its step
    /// buttons act there, and that drawing's events complete steps.
    private func retarget(document: ZenitPDFProjectDocument, controller: ProjectWindowController) {
        observedDocument = document
        hostWindow = controller.window
        model.onPerformStep = { [weak controller, weak document] step in
            guard let controller, let document else { return }
            Self.perform(step, controller: controller, document: document)
        }
        observe(document)
    }

    /// What each step's button does. The same commands the menus run.
    static func perform(_ step: OnboardingStep, controller: ProjectWindowController, document: ZenitPDFProjectDocument) {
        switch step {
        case .openDrawing:
            NSDocumentController.shared.openDocument(nil)
        case .calibrateScale:
            ZenitAppCommandTable.perform(.calibrateScale, controller: controller, document: document)
        case .firstMeasurement:
            document.shell?.toolbar.activateMeasurement(.area)
        case .seeInQuantityLedger:
            guard let shell = document.shell else { return }
            if !shell.isSurfaceVisible(.quantityLedger) { shell.perform(.toggleQuantityLedger) }
        }
    }

    /// Re-reads the document whenever anything the steps depend on changes.
    private func observe(_ document: ZenitPDFProjectDocument) {
        observationGeneration &+= 1
        let generation = observationGeneration
        guard let core = document.core else { return }
        withObservationTracking {
            _ = core.snapshot
            _ = document.shell?.isSurfaceVisible(.quantityLedger)
            _ = model.isVisible
        } onChange: { [weak self, weak document] in
            Task { @MainActor [weak self, weak document] in
                guard let self, let document, generation == self.observationGeneration else { return }
                self.advance(from: document)
                if !self.model.isVisible { self.dismissPanel() }
                self.observe(document)
            }
        }
    }

    // MARK: - The card

    /// Help ▸ Welcome to Zenit PDF, and Settings ▸ Show the Welcome Guide Again: from the start,
    /// over the project window in front.
    ///
    /// The Help item did nothing visible in the installed build while the Settings button worked
    /// (L-98), for two reasons this fixes. The card stood on the window the last
    /// drawing was *attached* to — a second window closed since was still that window, and an
    /// invisible host shows no card. And on a drawing that already proves every step (open,
    /// scaled, measured, ledger showing rows) the restart completed all four at once, and
    /// completing the last step puts the card away.
    @objc func showWelcome(_ sender: Any?) {
        if let front = Self.frontProjectWindow() {
            retarget(document: front.document, controller: front.controller)
        }
        restart(proven: observedDocument.flatMap(provenSteps(of:)) ?? [])
        present()
    }

    /// Starts the guide over: every step undone, then the ones `proven` already done ticked —
    /// and the card stays up, because the person asked to see it.
    func restart(proven: Set<OnboardingStep>) {
        model.reset()
        for step in model.steps where proven.contains(step) && !model.isComplete(step) {
            model.complete(step)
        }
        if !model.isVisible { model.resume() }
    }

    /// The project window in front and its drawing in front: the key window when it is a
    /// project window, else the main window, else the frontmost visible one. A test replaces it;
    /// nothing under `Apps/ZenitPDF/Sources` reassigns it.
    static var frontProjectWindow: @MainActor () -> (document: ZenitPDFProjectDocument, controller: ProjectWindowController)? = {
        let application = NSApplication.shared
        let candidates = [application.keyWindow, application.mainWindow].compactMap { $0 } + application.orderedWindows
        for window in candidates where window.isVisible {
            guard let controller = window.windowController as? ProjectWindowController,
                  let document = controller.activeDocument else { continue }
            return (document, controller)
        }
        return nil
    }

    /// Shows the card beside the host window — only in the shipping app, only while the guide
    /// is visible, and only over a window a person can see.
    func present() {
        guard model.isVisible else { dismissPanel(); return }
        guard ZenitModalPresenter.canPresentModally, let parent = hostWindow, parent.isVisible else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = panel.contentView?.fittingSize ?? CGSize(width: 360, height: 260)
        panel.setFrame(Self.frame(in: parent.frame, size: size), display: false)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    /// Where the card sits: the window's bottom-leading corner, clear of the status strip.
    static func frame(in parent: NSRect, size: CGSize) -> NSRect {
        let inset: CGFloat = 16
        let statusStrip: CGFloat = 40
        return NSRect(x: parent.minX + inset, y: parent.minY + statusStrip, width: size.width, height: size.height)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.setAccessibilityLabel(NSLocalizedString("Welcome to Zenit PDF", comment: "Help menu item opening the onboarding path"))
        panel.contentViewController = NSHostingController(rootView: OnboardingFlow(model: model))
        return panel
    }

    private func dismissPanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
