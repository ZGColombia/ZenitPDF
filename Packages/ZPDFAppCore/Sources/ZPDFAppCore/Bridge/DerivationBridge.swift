import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// Turns the derivation a value was computed with (ADR-0007) into the sections the Inspector's
/// "How This Number Was Calculated" disclosure renders.
///
/// The disclosure had the vocabulary — `scale.id`, `scale.version`, `scale.source`, the
/// calibration keys — and nothing filling it: `derivation(for:)` returned
/// `sections: []`, so every markup fell through to *"No derivation is recorded"*. This is the
/// filler, and the reason it lands with per-page scale is `scale.page`: a disclosure that names
/// a ratio without naming the sheet it was calibrated on cannot be checked by the person reading
/// it, which on a set that mixes 1:100 and 1:20 is the difference between a number they can
/// defend and one they cannot.
///
/// Everything here is a **projection of the stored provenance**. Nothing is recomputed, nothing
/// is inferred, and a fact whose input is absent is omitted rather than filled with a plausible
/// value — an invented derivation is worse than none, because it looks like evidence.
public enum DerivationBridge {

    /// The disclosure sections for one measurement, or `nil` when it carries no derivation.
    ///
    /// - Parameters:
    ///   - provenance: what the engine recorded at computation time.
    ///   - pageLabel: the printed label of ``MeasurementProvenance/scalePageID``'s page, resolved
    ///     by the caller against the document's page table. `nil` when the scale names no page
    ///     (a pre-per-page-scale value) or when the page is gone, and in both cases the fact is
    ///     omitted rather than guessed at.
    ///   - scaleName: the scale's ratio as the rest of the UI spells it, for example `"1:50"`.
    public static func sections(
        for provenance: MeasurementProvenance,
        pageLabel: String?,
        scaleName: String?
    ) -> [LedgerDerivationSection] {
        var sections: [LedgerDerivationSection] = []

        sections.append(LedgerDerivationSection(key: "geometry", facts: [
            LedgerDerivationFact(key: "geometry.digest", value: provenance.geometryDigest),
            // ADR-0031 (NL-AUTO-18): who or what drew the geometry.
            LedgerDerivationFact(key: "geometry.capture", value: CaptureDescription.text(provenance.capture))
        ]))

        var scaleFacts: [LedgerDerivationFact] = [
            LedgerDerivationFact(
                key: "scale.id",
                value: scaleName ?? provenance.scaleID.rawValue.uuidString
            )
        ]
        // The sheet the scale belongs to. This is the half of "1:50, calibrated on page 3" that
        // the record could not answer before `scalePageID` existed: the scale identifier alone
        // is a UUID, and resolving it after the fact fails the moment the scale is deleted.
        if let pageLabel {
            scaleFacts.append(LedgerDerivationFact(key: "scale.page", value: pageLabel))
        }
        scaleFacts.append(LedgerDerivationFact(key: "scale.version", value: String(provenance.scaleVersion)))
        scaleFacts.append(LedgerDerivationFact(key: "scale.source", value: provenance.scaleSource.rawValue))
        if let evidence = provenance.calibrationEvidence {
            scaleFacts.append(LedgerDerivationFact(
                key: "scale.calibration.points",
                value: evidence.points
                    .map { "(\(Self.number($0.x)), \(Self.number($0.y)))" }
                    .joined(separator: " → ")
            ))
            scaleFacts.append(LedgerDerivationFact(
                key: "scale.calibration.enteredLength",
                value: evidence.enteredLength.value.description
            ))
            scaleFacts.append(LedgerDerivationFact(
                key: "scale.calibration.enteredUnit",
                value: evidence.enteredUnit.rawValue
            ))
        }
        sections.append(LedgerDerivationSection(key: "scale", facts: scaleFacts))

        sections.append(LedgerDerivationSection(key: "engine", facts: [
            LedgerDerivationFact(key: "engine.formulaVersion", value: String(provenance.formulaVersion)),
            LedgerDerivationFact(key: "engine.version", value: provenance.engineVersion),
            LedgerDerivationFact(
                key: "engine.computedAt",
                value: Self.timestamp(provenance.computedAt)
            )
        ]))

        return sections
    }

    /// A page-space coordinate, at the precision a person can compare against a ruler and no
    /// more. `Double.description` would print seventeen digits of a number that came from a
    /// pointer, which reads as precision the picked point never had.
    private static func number(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

extension DerivationBridge {
    /// A derivation timestamp: fixed format, UTC, locale-independent, so two builds print the
    /// same instant the same way and two derivations can be diffed. Built per call rather than
    /// shared — `ISO8601DateFormatter` is a class with mutable state and is not `Sendable`, and
    /// a shared instance behind a lock would cost more than the handful of calls a disclosure
    /// makes.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
