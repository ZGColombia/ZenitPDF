import SwiftUI
import ZPDFDesignSystem

/// The first-run guide, as a card the person can ignore.
///
/// It sits in the bottom-leading corner of the window. It never takes the keyboard, never covers
/// the canvas, and has Skip on every step. A guide that has to be dismissed before work can start
/// is not a guide, it is a toll gate.
public struct OnboardingFlow: View {

    private let model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable {
        case action
        case skip
        case disclosure
    }

    /// Whether the step's action button answers Return.
    ///
    /// `false` for the corner card, always. It is an overlay on the document window, and a
    /// `.defaultAction` there is dispatched before the first responder sees the key — so
    /// Return that should have committed a Quantity Ledger cell, a search or a calibration
    /// value opened a panel or switched tools instead. Finding BH-307. The button stays
    /// reachable from the keyboard by Tab and Space; a host that shows the guide in its own
    /// window may pass `true`.
    let claimsReturnKey: Bool

    /// Creates the flow.
    public init(model: OnboardingModel, claimsReturnKey: Bool = false) {
        self.model = model
        self.claimsReturnKey = claimsReturnKey
    }

    public var body: some View {
        if model.isVisible {
            card
                .transition(ZPDFMotion.transition(.opacity, reduceMotion: reduceMotion))
                .zpdfAnimation(ZPDFMotion.standard, value: model.currentStep)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            header
            Text(model.currentStep.detail)
                .zpdfText(.body, .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.isExpanded {
                stepList
            }
            footer
        }
        .padding(ZPDFSpacing.l)
        .frame(width: 340, alignment: .leading)
        .zpdfControlBackground(fill: .surface, cornerRadius: ZPDFRadius.large)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Getting started",
            comment: "Accessibility label for the onboarding card"
        )))
        .accessibilityValue(Text(model.positionSummary))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.s) {
            ZPDFGlyphView(model.currentStep.glyph, size: ZPDFSpacing.Control.iconLarge)
                .foregroundStyle(ZPDFColor.accentCyan)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.positionSummary)
                    .zpdfText(.caption, .textSecondary)
                    .textCase(.uppercase)
                Text(model.currentStep.title)
                    .zpdfText(.windowTitle, .textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: ZPDFSpacing.s)
            Button {
                model.isExpanded.toggle()
            } label: {
                ZPDFGlyphView(
                    .symbol(model.isExpanded ? .disclosureOpen : .disclosureClosed),
                    size: ZPDFSpacing.Control.icon
                )
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .disclosure)
            .zpdfFocusRing(focusedControl == .disclosure, cornerRadius: ZPDFRadius.small)
            .accessibilityLabel(Text(NSLocalizedString(
                "All steps",
                comment: "Accessibility label for the onboarding step list disclosure"
            )))
            .accessibilityValue(Text(model.isExpanded
                ? NSLocalizedString("Expanded", comment: "Accessibility value: disclosure open")
                : NSLocalizedString("Collapsed", comment: "Accessibility value: disclosure closed")))
            // The card never takes the keyboard, so its close control is not the window's
            // Escape target — Escape stays with the canvas and whatever mode owns it.
            WorkflowPanelCloseButton(
                panelName: NSLocalizedString("Getting Started", comment: "Panel name for the onboarding card"),
                isEscapeRouted: false,
                action: { model.skip() }
            )
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.steps) { step in
                stepRow(step)
            }
        }
        .padding(.vertical, ZPDFSpacing.xs)
    }

    private func stepRow(_ step: OnboardingStep) -> some View {
        let isDone = model.isComplete(step)
        let isCurrent = step == model.currentStep
        return Button {
            model.show(step)
        } label: {
            HStack(spacing: ZPDFSpacing.s) {
                ZPDFGlyphView(
                    .symbol(isDone ? .success : (isCurrent ? .disclosureOpen : .disclosureClosed)),
                    size: ZPDFSpacing.Control.iconSmall
                )
                .foregroundStyle(isDone ? ZPDFColor.success : ZPDFColor.textSecondary)
                Text(step.title)
                    .zpdfText(isCurrent ? .control.withWeight(.semibold) : .control, .textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ZPDFSpacing.xs)
            .frame(height: ZPDFSpacing.Control.listRow, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                    .fill(isCurrent ? ZPDFColor.elevated : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(step.title))
        .accessibilityValue(Text(isDone
            ? NSLocalizedString("Done", comment: "Accessibility value: onboarding step complete")
            : NSLocalizedString("Not done yet", comment: "Accessibility value: onboarding step incomplete")))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            ProgressView(value: model.progressFraction)
                .progressViewStyle(.linear)
                .accessibilityLabel(Text(NSLocalizedString(
                    "Getting started progress",
                    comment: "Accessibility label for the onboarding progress bar"
                )))
                .accessibilityValue(Text(model.positionSummary))

            HStack(spacing: ZPDFSpacing.s) {
                Button(NSLocalizedString("Not Now", comment: "Skip the onboarding guide")) {
                    model.skip()
                }
                .focused($focusedControl, equals: .skip)
                .zpdfFocusRing(focusedControl == .skip)
                Spacer(minLength: 0)
                Button(NSLocalizedString("Mark as Done", comment: "Mark the current onboarding step done")) {
                    model.complete(model.currentStep)
                }
                .controlSize(.small)
                Button(model.currentStep.actionTitle) {
                    model.performCurrentStep()
                }
                .keyboardShortcut(claimsReturnKey ? .defaultAction : nil)
                .focused($focusedControl, equals: .action)
                .zpdfFocusRing(focusedControl == .action)
            }

            Text(Self.reopenHint)
            .zpdfText(.caption, .textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension OnboardingFlow {

    /// Where the card says the guide comes back from. It names the Help menu item the
    /// application really has — "Getting Started" was the card's own name, and the Help menu
    /// never had an item by it (live test 8, L-39).
    public static var reopenHint: String {
        NSLocalizedString(
            "You can bring this back any time from Help ▸ Welcome to Zenit PDF.",
            comment: "Reassurance that onboarding is resumable; names the Help menu item that reopens it"
        )
    }
}

extension View {

    /// Puts the first-run guide in the bottom-leading corner without covering the content.
    ///
    /// The overlay does not take hit testing away from anything behind it beyond its own bounds,
    /// so the canvas is live the whole time the guide is up.
    public func zpdfOnboarding(_ model: OnboardingModel) -> some View {
        overlay(alignment: .bottomLeading) {
            OnboardingFlow(model: model)
                .padding(ZPDFSpacing.l)
        }
    }
}
