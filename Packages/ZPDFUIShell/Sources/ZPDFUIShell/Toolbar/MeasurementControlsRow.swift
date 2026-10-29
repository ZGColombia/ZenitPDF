import SwiftUI
import ZPDFDesignSystem
import ZPDFUIMeasurement
import ZPDFUIPresentation

/// Text decisions of the measurement controls row, testable without rendering it.
enum MeasurementControlsDisplay {

    /// The warning pill's text: the warning that actually blocks Finish (BH-823).
    ///
    /// The pill is shown only when a warning blocks, but it used to print the *first* warning,
    /// which could be a non-blocking "nearly collinear" while Finish was disabled for a missing
    /// scale. The blocking one is named; the first warning is the fallback.
    static func warningPillTitle(_ warnings: [MeasurementWarningSummary]) -> String {
        (warnings.first(where: \.isBlocking) ?? warnings.first)?.message
            ?? NSLocalizedString("Check this measurement", comment: "Generic measurement warning")
    }
}

/// The contextual controls that appear in the toolbar while a measurement tool is armed.
///
/// The row answers the three questions a person actually has mid-measurement: which tool am I
/// using, what does it read so far, and what units will the number land in. Everything else
/// belongs in the Inspector.
public struct MeasurementControlsRow: View {

    private let environment: ProjectShellEnvironment

    /// Creates the row.
    public init(environment: ProjectShellEnvironment) {
        self.environment = environment
    }

    private var measurement: any MeasurementToolPresenting { environment.measurement }

    public var body: some View {
        HStack(spacing: ZPDFSpacing.m) {
            if let kind = measurement.activeKind {
                toolBadge(kind)
                ZPDFHairlineDivider(axis: .vertical)
                liveReadout()
                if let requirement = kind.requiredParameter {
                    // The value the drawing does not contain. The same
                    // field the contextual tool options strip shows, so a user who has
                    // added this row to their toolbar is not sent looking for a second
                    // place to type a depth.
                    ZPDFHairlineDivider(axis: .vertical)
                    MeasurementParameterField(environment: environment, requirement: requirement)
                }
                ZPDFHairlineDivider(axis: .vertical)
                unitControls(kind)
                if measurement.hasBlockingWarning {
                    ZPDFHairlineDivider(axis: .vertical)
                    warningPill
                } else if measurement.missingParameterNote != nil {
                    ZPDFHairlineDivider(axis: .vertical)
                    missingParameterPill
                }
                Spacer(minLength: ZPDFSpacing.s)
                finishControls
            } else {
                Text(NSLocalizedString(
                    "Choose a measurement tool to see its controls",
                    comment: "Toolbar measurement row shown when no measurement tool is armed"
                ))
                .zpdfText(.caption, .textSecondary)
                .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, ZPDFSpacing.m)
        .frame(maxWidth: .infinity, minHeight: ZPDFSpacing.Control.toolbarHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Measurement controls",
            comment: "Accessibility label for the contextual measurement toolbar row"
        )))
    }

    private func toolBadge(_ kind: MeasurementKind) -> some View {
        ZPDFStatusPill(
            severity: .info,
            title: kind.displayName,
            value: nil,
            glyph: .measurement(for: kind),
            usesMonospacedValue: false
        )
    }

    @ViewBuilder
    private func liveReadout() -> some View {
        let remaining = measurement.remainingPointCount
        if let field = measurement.livePrimaryField {
            VStack(alignment: .leading, spacing: 0) {
                Text(field.field.displayName)
                    .zpdfText(.caption, .textSecondary)
                Text(field.displayTextWithUnit)
                    .zpdfText(.monoNumericStrong, .textPrimary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(field.field.displayName))
            .accessibilityValue(Text(field.accessibilityValue))
        } else if remaining > 0 {
            // "1 more point" (BH-822, IM-137): the phrase the Finish refusal uses (W-074).
            Text(MeasurementPointPhrases.morePoints(remaining))
                .zpdfText(.caption, .textSecondary)
        } else {
            Text(NSLocalizedString(
                "Ready",
                comment: "Measurement row state before any point has been placed"
            ))
            .zpdfText(.caption, .textSecondary)
        }
    }

    @ViewBuilder
    private func unitControls(_ kind: MeasurementKind) -> some View {
        HStack(spacing: ZPDFSpacing.s) {
            if kind.dimension == .length || kind.dimension == .volume || kind.dimension == .area {
                ZPDFUnitPicker(
                    selection: lengthUnitBinding,
                    options: MeasurementUnitCatalog.lengthOptions,
                    accessibilityTitle: NSLocalizedString("Length unit", comment: "Unit picker label")
                )
            }
            if kind.dimension == .area {
                ZPDFUnitPicker(
                    selection: areaUnitBinding,
                    options: MeasurementUnitCatalog.areaOptions,
                    accessibilityTitle: NSLocalizedString("Area unit", comment: "Unit picker label")
                )
            }
            if kind.dimension == .volume {
                ZPDFUnitPicker(
                    selection: volumeUnitBinding,
                    options: MeasurementUnitCatalog.volumeOptions,
                    accessibilityTitle: NSLocalizedString("Volume unit", comment: "Unit picker label")
                )
            }
            if !measurement.lengthUnit.isMetric {
                ZPDFUnitPicker(
                    selection: precisionBinding,
                    options: Self.precisionOptions,
                    accessibilityTitle: NSLocalizedString(
                        "Fraction precision",
                        comment: "Imperial fraction precision picker label"
                    )
                )
            }
            if kind == .slope || kind == .riseDrop {
                ZPDFUnitPicker(
                    selection: slopeBinding,
                    options: Self.slopeOptions,
                    accessibilityTitle: NSLocalizedString(
                        "Slope display",
                        comment: "Slope display mode picker label"
                    )
                )
            }
        }
    }

    private var warningPill: some View {
        ZPDFStatusPill(
            severity: .warning,
            title: MeasurementControlsDisplay.warningPillTitle(measurement.liveWarnings),
            usesMonospacedValue: false
        )
    }

    /// Why Finish is disabled, when the reason is a value the tool has not been given.
    @ViewBuilder
    private var missingParameterPill: some View {
        if let note = measurement.missingParameterNote {
            ZPDFStatusPill(severity: .warning, title: note, usesMonospacedValue: false)
        }
    }

    private var finishControls: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            ZPDFToolbarButton(
                glyph: .symbol(.success),
                title: NSLocalizedString("Finish", comment: "Finish the measurement in progress"),
                showsTitle: true,
                prominence: .accent,
                keyboardHint: environment.commands.command(.finishGeometry)?.binding?.displayString
            ) {
                environment.perform(.finishGeometry)
            }
            .disabled(!measurement.canCommit)

            ZPDFToolbarButton(
                glyph: .symbol(.remove),
                title: NSLocalizedString("Cancel", comment: "Cancel the measurement in progress"),
                showsTitle: false,
                keyboardHint: environment.commands.command(.cancelTool)?.binding?.displayString
            ) {
                environment.perform(.cancelTool)
            }
        }
    }

    // MARK: - Bindings

    private var lengthUnitBinding: Binding<String> {
        Binding(
            get: { measurement.lengthUnit.rawValue },
            set: { raw in
                guard let unit = LengthUnit(rawValue: raw) else { return }
                measurement.setLengthUnit(unit)
            }
        )
    }

    private var areaUnitBinding: Binding<String> {
        Binding(
            get: { measurement.areaUnit.rawValue },
            set: { raw in
                guard let unit = AreaUnit(rawValue: raw) else { return }
                measurement.setAreaUnit(unit)
            }
        )
    }

    private var volumeUnitBinding: Binding<String> {
        Binding(
            get: { measurement.volumeUnit.rawValue },
            set: { raw in
                guard let unit = VolumeUnit(rawValue: raw) else { return }
                measurement.setVolumeUnit(unit)
            }
        )
    }

    private var precisionBinding: Binding<String> {
        Binding(
            get: { String(measurement.imperialPrecision.rawValue) },
            set: { raw in
                guard let value = Int(raw), let precision = ImperialPrecision(rawValue: value) else { return }
                measurement.setImperialPrecision(precision)
            }
        )
    }

    private var slopeBinding: Binding<String> {
        Binding(
            get: { measurement.slopeDisplayMode.rawValue },
            set: { raw in
                guard let mode = SlopeDisplayMode(rawValue: raw) else { return }
                measurement.setSlopeDisplayMode(mode)
            }
        )
    }

    // MARK: - Option lists

    // The length, area and volume lists are `MeasurementUnitCatalog`'s, the ones the calibration
    // sheet offers, so the two unit pickers cannot drift apart (W-078).

    static let precisionOptions: [ZPDFUnitOption] = ImperialPrecision.allCases.map {
        ZPDFUnitOption(
            id: String($0.rawValue),
            name: $0.displayName,
            abbreviation: $0.displayName
        )
    }

    static let slopeOptions: [ZPDFUnitOption] = SlopeDisplayMode.allCases.map {
        ZPDFUnitOption(id: $0.rawValue, name: $0.displayName, abbreviation: $0.displayName)
    }
}

#if DEBUG
struct MeasurementControls_Previews: PreviewProvider {
    static var previews: some View {
        MeasurementControlsRow(environment: .mock())
            .frame(width: 620, height: 38)
    }
}
#endif
