import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The strip that appears above the canvas while the armed tool needs a value the drawing
/// does not contain.
///
/// Five of the twenty-two measurement tools measure something that is not on the sheet: a
/// slab's volume is its outline times a depth, a wall's area is its run times a height, a
/// true sloped length is a plan length times a pitch. The engine has always demanded those
/// values; nothing in the product ever asked for them, so the estimator drew the shape,
/// watched a live preview, pressed Return and got nothing, with no message.
///
/// The bar exists for exactly that question and is not there the rest of the time. That is
/// deliberate and it is why this is not simply the measurement controls row: that row stays
/// out of the default toolbar because a second permanent toolbar reads as clutter. A strip that appears for five tools and vanishes for the other seventeen is
/// not a second toolbar; it is the tool asking its question.
public struct ToolOptionsBar: View {

    private let environment: ProjectShellEnvironment

    /// Creates the bar.
    public init(environment: ProjectShellEnvironment) {
        self.environment = environment
    }

    private var measurement: any MeasurementToolPresenting { environment.measurement }

    public var body: some View {
        HStack(spacing: ZPDFSpacing.m) {
            if let kind = measurement.activeKind, let requirement = kind.requiredParameter {
                ZPDFStatusPill(
                    severity: .info,
                    title: kind.displayName,
                    value: nil,
                    glyph: .measurement(for: kind),
                    usesMonospacedValue: false
                )
                ZPDFHairlineDivider(axis: .vertical)
                MeasurementParameterField(environment: environment, requirement: requirement)
                if let note = measurement.missingParameterNote {
                    // Words, not a red ring: the bar says which number is missing and why
                    // the tool cannot finish without it (UX_COPY_STANDARD, no colour-only
                    // status).
                    Text(note)
                        .zpdfText(.caption, .textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else if MarkupStyleStrip.shows(in: environment) {
                // r2-markup (NL-MARKUP-03): the style strip for the selection or the armed tool.
                MarkupStyleStrip(environment: environment)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .frame(maxWidth: .infinity, minHeight: ProjectWindowLayoutController.toolOptionsBarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Tool options",
            comment: "Accessibility label for the contextual tool options bar"
        )))
    }
}

/// The one numeric field the parameter-hungry tools are waiting for.
///
/// Bound to text rather than to a `Double`, because the presenter parses with
/// `Decimal(string:)`: a depth typed as `0.15` must reach the engine as exactly fifteen
/// hundredths, and a value that has been through binary floating point is not that number.
/// The field commits as it is typed, so the live preview follows the depth the way it
/// follows the cursor — the running value is the point of the tool.
///
/// The box is one AppKit control (``MeasurementParameterBoxView``): a press anywhere in it puts
/// the keyboard in the field (L-103). The SwiftUI text field it replaces took the keyboard only on
/// its one inner text line, so most clicks on the box left the digits to the canvas.
public struct MeasurementParameterField: View {

    private let environment: ProjectShellEnvironment
    private let requirement: MeasurementParameterRequirement

    @State private var isEditing = false

    /// Creates the field.
    public init(environment: ProjectShellEnvironment, requirement: MeasurementParameterRequirement) {
        self.environment = environment
        self.requirement = requirement
    }

    private var measurement: any MeasurementToolPresenting { environment.measurement }

    /// The unit shown inside the field: the active length unit for a length, `%` for a slope.
    private var unitSymbol: String {
        requirement.isLength ? measurement.lengthUnit.symbol : "%"
    }

    public var body: some View {
        let environment = self.environment
        MeasurementParameterBox(
            label: requirement.displayName,
            unit: unitSymbol,
            help: requirement.shortHelp,
            text: measurement.parameterText,
            onTextChange: { text in
                guard environment.measurement.parameterText != text else { return }
                environment.setMeasurementParameterText(text)
            },
            onEditingChange: { editing in isEditing = editing }
        )
        .fixedSize()
        .background {
            RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                .fill(ZPDFColor.elevated)
                .overlay {
                    RoundedRectangle(cornerRadius: ZPDFRadius.small, style: .continuous)
                        .strokeBorder(ZPDFColor.border, lineWidth: ZPDFStroke.regular)
                }
        }
        .zpdfFocusRing(isEditing, cornerRadius: ZPDFRadius.small)
        .help(requirement.shortHelp)
    }
}

#if DEBUG
struct ToolOptionsBar_Previews: PreviewProvider {
    static var previews: some View {
        let environment = ProjectShellEnvironment.mock()
        environment.measurement.activate(kind: .volume)
        return ToolOptionsBar(environment: environment)
            .frame(width: 620, height: 30)
    }
}
#endif
