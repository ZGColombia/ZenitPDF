import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The body of the Inspector's "How This Number Was Calculated" section (ADR-0007 §1, §3).
///
/// The user sees the same chain the engine walked: the geometry fingerprint, the scale with
/// its version and calibration evidence in words, the slope with its azimuth, the raw SI
/// value at full precision, and the display rounding as its own line — never folded into
/// the raw value. Below the derivation sits the markup's own change list, oldest first.
///
/// Everything shown comes from ``LedgerDerivationModel``, which the app tier fills from the
/// provenance captured at computation time. A value with no provenance says so plainly
/// instead of reconstructing a guess.
struct InspectorDerivationSection: View {

    let summary: InspectorSelectionSummary
    let audit: (any LedgerAuditPresenting)?

    var body: some View {
        if summary.count > 1 {
            Text(NSLocalizedString(
                "Select a single measurement to see how its values were calculated.",
                comment: "Inspector derivation section with several markups selected"
            ))
            .zpdfText(.caption, .textSecondary)
        } else if let markup = summary.markups.first {
            content(for: markup.id)
        }
    }

    @ViewBuilder
    private func content(for markupID: UUID) -> some View {
        if let model = audit?.derivation(for: markupID) {
            derivationView(model)
        } else {
            Text(NSLocalizedString(
                "No derivation is recorded for this markup.",
                comment: "Inspector derivation section without provenance data"
            ))
            .zpdfText(.caption, .textSecondary)
        }
    }

    @ViewBuilder
    private func derivationView(_ model: LedgerDerivationModel) -> some View {
        if !model.hasProvenance {
            Text(NSLocalizedString(
                "This value was measured before Zenit recorded derivations. Its change history is below.",
                comment: "Inspector derivation section for a pre-provenance value"
            ))
            .zpdfText(.caption, .textSecondary)
        }
        ForEach(model.sections) { section in
            if !section.facts.isEmpty {
                sectionView(section)
            }
        }
        if !model.history.isEmpty {
            historyView(model.history)
        }
    }

    private func sectionView(_ section: LedgerDerivationSection) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(Self.sectionTitle(section.key))
                .zpdfText(.sectionHeader, .textSecondary)
                .textCase(.uppercase)
                .padding(.top, ZPDFSpacing.xs)
            ForEach(section.facts, id: \.key) { fact in
                InspectorMockupRow(label: Self.factLabel(fact.key)) {
                    Text(Self.factText(fact))
                        .zpdfText(Self.isNumericFact(fact.key) ? .monoNumeric.withSize(11) : .control, .textPrimary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(fact.value)
                }
            }
        }
    }

    private func historyView(_ history: [LedgerAuditEvent]) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            Text(NSLocalizedString("Changes", comment: "Inspector derivation subheading: the markup's change list"))
                .zpdfText(.sectionHeader, .textSecondary)
                .textCase(.uppercase)
                .padding(.top, ZPDFSpacing.xs)
            ForEach(history) { event in
                HStack(alignment: .firstTextBaseline, spacing: ZPDFSpacing.s) {
                    Text(Self.timestampFormatter.string(from: event.occurredAt))
                        .zpdfText(.monoNumeric.withSize(10), .textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.actionDisplayName)
                            .zpdfText(.control, .textPrimary)
                        if let change = Self.changeSummary(event) {
                            Text(change)
                                .zpdfText(.monoNumeric.withSize(10), .textSecondary)
                                .lineLimit(2)
                        }
                        Text(event.actor)
                            .zpdfText(.caption, .textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Copy

    /// "Plan Length 5,04 m → 6,12 m" for an edit, "Plan Length 5,04 m" for a creation —
    /// through the presenter's display strings when it filled them,
    /// falling back to the raw canonical values for an entry written before they existed.
    static func changeSummary(_ event: LedgerAuditEvent) -> String? {
        guard !event.changes.isEmpty else { return event.note }
        return event.changes.map { change in
            let name = change.fieldDisplayName ?? change.field
            let before = change.beforeDisplay ?? change.before
            let after = change.afterDisplay ?? change.after
            switch (before, after) {
            case (nil, let after?):
                return "\(name) \(after)"
            case (let before?, nil):
                return "\(name) \(before) → —"
            case (let before?, let after?):
                return before == after ? "\(name) \(after)" : "\(name) \(before) → \(after)"
            case (nil, nil):
                return name
            }
        }
        .joined(separator: "\n")
    }

    static func sectionTitle(_ key: String) -> String {
        switch key {
        case "geometry":
            return NSLocalizedString("Geometry", comment: "Derivation section heading")
        case "scale":
            return NSLocalizedString("Scale", comment: "Derivation section heading")
        case "slope":
            return NSLocalizedString("Slope", comment: "Derivation section heading")
        case "parameters":
            return NSLocalizedString("Parameters", comment: "Derivation section heading")
        case "values":
            return NSLocalizedString("Values", comment: "Derivation section heading")
        case "engine":
            return NSLocalizedString("Engine", comment: "Derivation section heading")
        default:
            return key
        }
    }

    /// Localized label for a derivation fact key. Unknown keys — written by a newer engine —
    /// show their raw key rather than disappearing.
    static func factLabel(_ key: String) -> String {
        switch key {
        case "geometry.digest":
            return NSLocalizedString("Fingerprint", comment: "Derivation fact label: geometry digest")
        case "geometry.capture":
            // r2-platform, ADR-0031: drawn by hand, or proposed by a detector and accepted.
            return NSLocalizedString("Captured", comment: "Derivation fact label: how the geometry was captured")
        case "scale.id":
            return NSLocalizedString("Scale", comment: "Derivation fact label")
        case "scale.page":
            return NSLocalizedString(
                "Calibrated on",
                comment: "Derivation fact label: the page a scale was calibrated on"
            )
        case "scale.version":
            return NSLocalizedString("Scale version", comment: "Derivation fact label")
        case "scale.source":
            return NSLocalizedString("Established by", comment: "Derivation fact label: how the scale was established")
        case "scale.calibration.points":
            return NSLocalizedString("Picked points", comment: "Derivation fact label: calibration evidence")
        case "scale.calibration.enteredLength":
            return NSLocalizedString("Entered length", comment: "Derivation fact label: calibration evidence")
        case "scale.calibration.enteredUnit":
            return NSLocalizedString("Entered unit", comment: "Derivation fact label: calibration evidence")
        case "slope.mode":
            return NSLocalizedString("Mode", comment: "Derivation fact label: slope mode")
        case "slope.magnitude":
            return NSLocalizedString("Magnitude", comment: "Derivation fact label: slope magnitude")
        case "slope.azimuth":
            return NSLocalizedString("Fall-line azimuth", comment: "Derivation fact label: slope azimuth")
        // BH-616: these fell back to the raw key.
        case "slope.totalRiseDrop":
            return NSLocalizedString("Total rise/drop", comment: "Derivation fact label: one rise or drop over the whole run")
        case "slope.perSegmentRiseDrop":
            return NSLocalizedString("Rise/drop per segment", comment: "Derivation fact label: a rise or drop per segment")
        case "parameters.depth":
            return NSLocalizedString("Depth", comment: "Derivation fact label")
        case "parameters.height":
            return NSLocalizedString("Height", comment: "Derivation fact label")
        case "parameters.heightAtEnd":
            return NSLocalizedString("Height at end", comment: "Derivation fact label")
        case "parameters.volumeDepthReference":
            return NSLocalizedString("Volume depth reference", comment: "Derivation fact label")
        case "parameters.cutoutPolicy":
            return NSLocalizedString("Cutouts", comment: "Derivation fact label")
        case "parameters.perimeterPolicy":
            return NSLocalizedString("Perimeter", comment: "Derivation fact label")
        case "parameters.openingAreas":
            return NSLocalizedString("Opening areas", comment: "Derivation fact label")
        case "engine.formulaVersion":
            return NSLocalizedString("Formula version", comment: "Derivation fact label")
        case "engine.version":
            return NSLocalizedString("Engine build", comment: "Derivation fact label")
        case "engine.computedAt":
            return NSLocalizedString("Computed", comment: "Derivation fact label")
        default:
            if key.hasPrefix("value."), let field = valueField(of: key) {
                if key.hasSuffix(".si") {
                    let format = NSLocalizedString(
                        "%@ (exact)",
                        comment: "Derivation fact label: a value's raw SI form at full precision"
                    )
                    return String(format: format, field)
                }
                if key.hasSuffix(".display") {
                    let format = NSLocalizedString(
                        "%@ (shown as)",
                        comment: "Derivation fact label: a value after display rounding"
                    )
                    return String(format: format, field)
                }
            }
            return key
        }
    }

    /// Values already deterministic; the few enum-shaped ones get words.
    ///
    /// Value facts are shown verbatim: a `.display` fact already carries its unit symbol
    /// ("70 ft"), so nothing is appended here (BH-192).
    static func factText(_ fact: LedgerDerivationFact) -> String {
        if fact.key == "slope.magnitude", fact.value == "vertical" {
            // BH-616: the engine's word for an infinite slope, in the reader's language.
            return NSLocalizedString(
                "vertical (the run is zero)",
                comment: "Derivation: a slope whose run is zero"
            )
        }
        guard fact.key == "scale.source" else { return fact.value }
        switch fact.value {
        case "calibrationTwoPoint":
            return NSLocalizedString(
                "calibrated from two points",
                comment: "Derivation: scale established by two-point calibration"
            )
        case "calibrationXY":
            return NSLocalizedString(
                "calibrated with separate X and Y",
                comment: "Derivation: scale established by separate X and Y calibration"
            )
        case "preset":
            return NSLocalizedString("preset", comment: "Derivation: scale from a preset")
        case "inherited":
            return NSLocalizedString(
                "inherited, not calibrated on this page",
                comment: "Derivation: scale inherited from another page or the document default"
            )
        default:
            return fact.value
        }
    }

    static func isNumericFact(_ key: String) -> Bool {
        key == "geometry.digest"
            || key.hasPrefix("value.")
            || key.hasPrefix("scale.calibration")
            || key == "scale.version"
            || key.hasPrefix("engine.")
    }

    /// "value.planArea.si" -> the field's readable name.
    ///
    /// R-094: the quantity rows' own localized name first — `MeasurementField.displayName`,
    /// "Plan Area" — then a localized name for the fields only the domain carries. The camel-case
    /// split, English only and in sentence case ("Plan area"), is left for a key nothing knows.
    static func valueField(of key: String) -> String? {
        let parts = key.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let raw = String(parts[1])
        if let field = MeasurementField(rawValue: raw) { return field.displayName }
        if let name = domainOnlyFieldNames[raw] { return name }
        // Camel case to words: "planArea" -> "Plan area".
        var words: [String] = []
        var current = ""
        for character in raw {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character).lowercased()
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return raw }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    /// The derivation keys the domain writes for fields the presentation layer has no
    /// `MeasurementField` for (the domain `MeasurementField` raw values in `value.<field>.*` keys).
    static var domainOnlyFieldNames: [String: String] {
        [
            "truePerimeter": NSLocalizedString("True Perimeter", comment: "Measurement field name: perimeter corrected for slope"),
            "cutoutArea": NSLocalizedString("Cutout Area", comment: "Measurement field name: the area cut out of a measured area"),
            "planWallArea": NSLocalizedString("Plan Wall Area", comment: "Measurement field name: wall area before openings"),
            "netWallArea": NSLocalizedString("Net Wall Area", comment: "Measurement field name: wall area after openings")
        ]
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
