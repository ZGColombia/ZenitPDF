import Foundation
import Observation
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The four things a new user has to do once before Zenit makes sense.
///
/// The path is deliberately short and it ends at a number in the Quantity Ledger, because that
/// is the moment the app's point becomes obvious. Nothing here teaches the interface; it walks
/// one real takeoff from a file to a total.
public enum OnboardingStep: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Open a drawing.
    case openDrawing
    /// Set the scale from a known distance.
    case calibrateScale
    /// Take one measurement.
    case firstMeasurement
    /// Find it in the Quantity Ledger.
    case seeInQuantityLedger

    /// Stable identity.
    public var id: String { rawValue }

    /// Zero-based position in the path.
    public var index: Int {
        OnboardingStep.allCases.firstIndex(of: self) ?? 0
    }

    /// A localized title.
    public var title: String {
        switch self {
        case .openDrawing:
            return NSLocalizedString("Open a drawing", comment: "Onboarding step title")
        case .calibrateScale:
            return NSLocalizedString("Tell Zenit the scale", comment: "Onboarding step title")
        case .firstMeasurement:
            return NSLocalizedString("Measure something", comment: "Onboarding step title")
        case .seeInQuantityLedger:
            return NSLocalizedString("Find it in the Quantity Ledger", comment: "Onboarding step title")
        }
    }

    /// A localized sentence saying what to do and why it matters.
    public var detail: String {
        switch self {
        case .openDrawing:
            return NSLocalizedString(
                "Drag a PDF onto the window, or use File ▸ Open. Zenit works on the file where it is and never changes the original.",
                comment: "Onboarding step detail"
            )
        case .calibrateScale:
            return NSLocalizedString(
                "Draw along a dimension printed on the sheet and type what it should read. Until you do, Zenit will not turn distances into lengths, because a guessed scale is worse than none.",
                comment: "Onboarding step detail"
            )
        case .firstMeasurement:
            return NSLocalizedString(
                "Pick the Area tool and trace a room. The live readout follows your cursor, and Vector Snap locks on to the linework as you go.",
                comment: "Onboarding step detail"
            )
        case .seeInQuantityLedger:
            return NSLocalizedString(
                "Open the Quantity Ledger. Your measurement is already a row there, with its own units, and it stays linked to the markup on the page.",
                comment: "Onboarding step detail"
            )
        }
    }

    /// A localized label for the button that takes the person there.
    public var actionTitle: String {
        switch self {
        case .openDrawing:
            return NSLocalizedString("Open a Drawing…", comment: "Onboarding step action")
        case .calibrateScale:
            return NSLocalizedString("Start Calibration", comment: "Onboarding step action")
        case .firstMeasurement:
            return NSLocalizedString("Pick the Area Tool", comment: "Onboarding step action")
        case .seeInQuantityLedger:
            return NSLocalizedString("Show the Quantity Ledger", comment: "Onboarding step action")
        }
    }

    /// The glyph for the step row.
    public var glyph: ZPDFGlyph {
        switch self {
        case .openDrawing: return .symbol(.open)
        case .calibrateScale: return .measurement(.calibrate)
        case .firstMeasurement: return .measurement(.area)
        case .seeInQuantityLedger: return .symbol(.quantityLedger)
        }
    }
}

/// How far along the first-run path a person is.
public struct OnboardingProgress: Codable, Hashable, Sendable {

    /// The steps already done.
    public var completedSteps: Set<OnboardingStep>
    /// Whether the person put the guide away.
    public var isDismissed: Bool
    /// The step to come back to.
    public var lastViewedStep: OnboardingStep?

    /// Creates progress.
    public init(
        completedSteps: Set<OnboardingStep> = [],
        isDismissed: Bool = false,
        lastViewedStep: OnboardingStep? = nil
    ) {
        self.completedSteps = completedSteps
        self.isDismissed = isDismissed
        self.lastViewedStep = lastViewedStep
    }

    /// Whether every step is done.
    public var isComplete: Bool {
        completedSteps.count >= OnboardingStep.allCases.count
    }
}

/// Where onboarding progress is kept.
///
/// A protocol rather than a hard-coded `UserDefaults` call, so a preview and a test can run the
/// flow without touching the person's real preferences.
@MainActor
public protocol OnboardingProgressStoring: AnyObject {

    /// Reads the stored progress.
    func loadProgress() -> OnboardingProgress
    /// Writes the progress.
    func saveProgress(_ progress: OnboardingProgress)
}

/// Keeps progress only for as long as the object lives. Used by previews and tests.
@MainActor
public final class InMemoryOnboardingProgressStore: OnboardingProgressStoring {

    private var progress: OnboardingProgress

    /// Creates the store.
    public init(progress: OnboardingProgress = OnboardingProgress()) {
        self.progress = progress
    }

    public func loadProgress() -> OnboardingProgress { progress }

    public func saveProgress(_ progress: OnboardingProgress) { self.progress = progress }
}

/// Keeps progress in defaults under one key, so it survives a relaunch.
///
/// The backing is the shared ``ZPDFDefaultsStoring`` seam rather than `UserDefaults` directly,
/// which is what lets a test run against ``ZPDFInMemoryDefaults`` without touching the real
/// preferences database.
@MainActor
public final class UserDefaultsOnboardingProgressStore: OnboardingProgressStoring {

    /// The single key everything is stored under, so it can be removed in one go.
    public static let defaultsKey = "com.zenitgroup.zenitpdf.onboarding.progress"

    private let defaults: any ZPDFDefaultsStoring
    private let key: String

    /// Creates the store.
    public init(
        defaults: any ZPDFDefaultsStoring = UserDefaults.standard,
        key: String = UserDefaultsOnboardingProgressStore.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Reads the stored progress. Anything unreadable resolves to a fresh guide rather than an
    /// error, because a first-run card is never worth blocking a launch over.
    public func loadProgress() -> OnboardingProgress {
        defaults.decode(OnboardingProgress.self, forKey: key) ?? OnboardingProgress()
    }

    public func saveProgress(_ progress: OnboardingProgress) {
        defaults.encode(progress, forKey: key)
    }
}

/// Drives the first-run guide.
///
/// Three rules hold it together. It never blocks: it is a card in the corner, not a sheet. It is
/// always skippable, from any step. And it is resumable, so a person who puts it away on Tuesday
/// finds it exactly where they left it on Wednesday.
@MainActor
@Observable
public final class OnboardingModel {

    /// Every step, in order.
    public let steps: [OnboardingStep] = OnboardingStep.allCases
    /// Which steps are done.
    public private(set) var completedSteps: Set<OnboardingStep>
    /// The step the card is showing.
    public private(set) var currentStep: OnboardingStep
    /// Whether the card is on screen.
    public private(set) var isVisible: Bool
    /// Whether the list of remaining steps is expanded.
    public var isExpanded: Bool = true

    /// Runs when the person presses the step's action button.
    public var onPerformStep: (@MainActor (OnboardingStep) -> Void)?

    private let store: any OnboardingProgressStoring

    /// Creates the model over a progress store.
    public init(store: any OnboardingProgressStoring = InMemoryOnboardingProgressStore()) {
        self.store = store
        let progress = store.loadProgress()
        self.completedSteps = progress.completedSteps
        self.currentStep = progress.lastViewedStep
            ?? OnboardingStep.allCases.first { !progress.completedSteps.contains($0) }
            ?? .openDrawing
        self.isVisible = !progress.isDismissed && !progress.isComplete
    }

    // MARK: - Reading

    /// How many steps are done, `0...1`.
    public var progressFraction: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(completedSteps.count) / Double(steps.count)
    }

    /// A localized "Step 2 of 4" readout.
    public var positionSummary: String {
        let format = NSLocalizedString(
            "Step %1$d of %2$d",
            comment: "Onboarding position: current step number, total steps"
        )
        return String(format: format, currentStep.index + 1, steps.count)
    }

    /// Whether a step is done.
    public func isComplete(_ step: OnboardingStep) -> Bool {
        completedSteps.contains(step)
    }

    /// The next step still to do, or `nil` when everything is done.
    public var nextIncompleteStep: OnboardingStep? {
        steps.first { !completedSteps.contains($0) }
    }

    // MARK: - Actions

    /// Shows the card at whichever step is still outstanding.
    public func resume() {
        currentStep = nextIncompleteStep ?? currentStep
        isVisible = true
        persist(isDismissed: false)
    }

    /// Moves the card to a step without completing anything.
    public func show(_ step: OnboardingStep) {
        currentStep = step
        persist(isDismissed: !isVisible)
    }

    /// Marks a step done and moves on. Completing the last one puts the card away.
    public func complete(_ step: OnboardingStep) {
        completedSteps.insert(step)
        if let next = nextIncompleteStep {
            currentStep = next
        } else {
            isVisible = false
        }
        persist(isDismissed: !isVisible)
    }

    /// Runs the step's action, leaving completion to the host: a step is done when the person
    /// really did the thing, not when they pressed a button that offered to help.
    public func performCurrentStep() {
        onPerformStep?(currentStep)
    }

    /// Puts the card away. Progress is kept, and ``resume()`` brings it back.
    public func skip() {
        isVisible = false
        persist(isDismissed: true)
    }

    /// Clears everything, for the "show me this again" menu item.
    public func reset() {
        completedSteps = []
        currentStep = .openDrawing
        isVisible = true
        persist(isDismissed: false)
    }

    private func persist(isDismissed: Bool) {
        store.saveProgress(OnboardingProgress(
            completedSteps: completedSteps,
            isDismissed: isDismissed,
            lastViewedStep: currentStep
        ))
    }
}
