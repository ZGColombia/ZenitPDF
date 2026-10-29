import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFMeasurementEngine
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// Feature 13 — check the page's measurements against the dimensions printed beside them.
/// **Opt-in by construction**: nothing runs until the person chooses the command, and the
/// engine (`DimensionChecker`) refuses to accuse on anything uncertain — low-confidence
/// text, unparseable text, or a figure that plainly belongs to another measurement all
/// resolve to silence.
extension ProjectWindowController {

    /// The one identity the check's warning uses, so re-running replaces rather than stacks.
    static let dimensionCheckWarningID = UUID(uuidString: "3D6A7C02-9B14-4E4B-8A45-0D7B7A9C2E13")!

    func checkDrawnDimensions(for document: ZenitPDFProjectDocument) {
        Task { @MainActor in
            guard let core = document.core, let drawing = document.currentPageDrawing else { return }
            guard let currentID = core.document.currentPageID,
                  let page = drawing.pages.first(where: { $0.id.rawValue == currentID })
            else { return }

            // r2-platform (NL-AUTO-03): the drawing's own text, else the
            // project's stored recognition — each line with its real confidence, which the checker
            // weighs; no region is recognised by this check.
            let sourced = await PageTextLoader.lines(document: document, page: page, region: nil, allowRegionOCR: false)
            let lines = sourced.map { line in
                (text: line.text, confidence: line.confidence,
                 boundsInPageSpace: CGRect(x: line.boundsInPageSpace.minX, y: line.boundsInPageSpace.minY,
                                           width: line.boundsInPageSpace.size.width, height: line.boundsInPageSpace.size.height))
            }
            guard !lines.isEmpty else {
                core.status.setActiveToolNote(NSLocalizedString(
                    "This page has no readable text to check dimensions against.",
                    comment: "Status note when the dimension check finds no text layer"
                ))
                return
            }

            let options = DimensionChecker.Options()
            let markups = await core.session.orderedMarkups.filter { $0.pageID == page.id }
            var verdicts: [(name: String, verdict: DimensionChecker.Verdict)] = []
            for record in markups {
                guard record.kind == .measurement,
                      let quantity = Self.dimensionCheckQuantity(of: record),
                      quantity.value > 0,
                      let box = Self.geometryBounds(of: record.geometry)
                else { continue }
                let near = box.insetBy(dx: -40, dy: -40)
                let candidates = lines
                    .filter { near.intersects($0.boundsInPageSpace) }
                    // Embedded PDF text is the drawing's own (1.0); a recognised line carries its
                    // recogniser's confidence, and the checker stays silent on a weak one.
                    .map { DimensionChecker.Candidate(text: $0.text, confidence: $0.confidence) }
                let name = record.subject.isEmpty
                    ? NSLocalizedString("Measurement", comment: "Nameless markup in the dimension check")
                    : record.subject
                verdicts.append((name, DimensionChecker.check(
                    measuredMetres: quantity.value,
                    candidates: candidates,
                    options: options
                )))
            }

            // NL-AUTO-09: the areas printed inside rooms, against the areas measured for them.
            self.reportPrintedAreas(Self.printedAreaFindings(markups: markups, lines: lines
                .filter { $0.confidence >= 0.5 }
                .map { PageTextLine(text: $0.text, boundsInPageSpace: $0.boundsInPageSpace) }), core: core)

            switch Self.dimensionCheckOutcome(verdicts, toleranceMetres: options.toleranceMetres) {
            case let .note(text):
                core.status.setActiveToolNote(text)
            case let .warning(title, message):
                core.document.post(AppWarning(
                    id: Self.dimensionCheckWarningID,
                    severity: .warning,
                    title: title,
                    message: message,
                    source: NSLocalizedString("Dimension check", comment: "Warning source"),
                    isDismissible: true,
                    timestamp: Date()
                ))
            }
        }
    }

    /// The length a drawn dimension is compared with: the **plan** length first.
    ///
    /// Dimensions printed on a plan are plan lengths. A sloped-length or wall-area markup
    /// stores both, and preferring the true (sloped) length told the person a correct 5.400 m
    /// run "differs by 0.019 m" at a 1:12 pitch — and that it "usually means the
    /// calibration" (BH-073).
    static func dimensionCheckQuantity(of record: MarkupRecord) -> ZPDFContracts.DecimalQuantity? {
        record.measurement?[.planLength] ?? record.measurement?[.trueLength]
    }

    /// What the dimension check says for a set of verdicts.
    enum DimensionCheckOutcome: Equatable {
        case note(String)
        case warning(title: String, message: String)
    }

    /// Turns the per-measurement verdicts into the status note or the warning. Pure, so the
    /// wording rules are testable: only `.agrees` counts as agreement — `.noConfidentDimension`
    /// is the engine's *silence*, and reporting it as "7 measurements agree" claimed a check
    /// that never happened (BH-364); one disagreement is singular (BH-899).
    static func dimensionCheckOutcome(
        _ verdicts: [(name: String, verdict: DimensionChecker.Verdict)],
        toleranceMetres: Decimal
    ) -> DimensionCheckOutcome {
        var agreed = 0
        var disagreements: [String] = []
        for (name, verdict) in verdicts {
            switch verdict {
            case .agrees:
                agreed += 1
            case let .disagrees(drawn, measured, difference, _):
                disagreements.append(String(
                    format: NSLocalizedString(
                        "%@: drawn %@ m, measured %@ m — differs by %@ m",
                        comment: "One dimension-check disagreement line"
                    ),
                    name, "\(drawn)", "\(measured)", "\(difference)"
                ))
            case .noConfidentDimension:
                break
            }
        }
        let tolerance = "\(toleranceMetres)"

        if disagreements.isEmpty {
            if agreed == 0 {
                return .note(NSLocalizedString(
                    "Dimension check: no drawn dimension could be matched to a measurement on this page.",
                    comment: "Status note when the dimension check found no dimension it could confidently compare"
                ))
            }
            // Singular/plural split by hand: "1 measurements agree" shipped to the
            // status bar live (LT-13, 2026-08-29).
            if agreed == 1 {
                return .note(String(
                    format: NSLocalizedString(
                        "Dimension check: 1 measurement agrees with the drawn dimensions (tolerance %@ m)",
                        comment: "Status note when the dimension check finds nothing wrong, one measurement"
                    ),
                    tolerance
                ))
            }
            return .note(String(
                format: NSLocalizedString(
                    "Dimension check: %d measurements agree with the drawn dimensions (tolerance %@ m)",
                    comment: "Status note when the dimension check finds nothing wrong"
                ),
                agreed, tolerance
            ))
        }

        let shown = disagreements.prefix(4).joined(separator: "\n")
        let more = disagreements.count > 4
            ? "\n" + String(
                format: NSLocalizedString(
                    "…and %d more.",
                    comment: "Appended when the dimension check found more than four disagreements"
                ),
                disagreements.count - 4
            )
            : ""
        let title = disagreements.count == 1
            ? NSLocalizedString(
                "1 measurement disagrees with the drawn dimensions.",
                comment: "Dimension check warning headline, one disagreement"
            )
            : String(
                format: NSLocalizedString(
                    "%d measurements disagree with the drawn dimensions.",
                    comment: "Dimension check warning headline"
                ),
                disagreements.count
            )
        let message = shown + more + "\n" + String(
            format: NSLocalizedString(
                "Tolerance: %@ m. A disagreement this consistent usually means the calibration, not the drawing.",
                comment: "Dimension check warning footer, naming the tolerance in force"
            ),
            tolerance
        )
        return .warning(title: title, message: message)
    }

    /// The bounding box of a markup's geometry, in page space.
    static func geometryBounds(of geometry: MeasurementGeometry?) -> CGRect? {
        guard let geometry else { return nil }
        var points = geometry.points
        for polygon in geometry.polygons {
            points.append(contentsOf: polygon.outer.points)
            for hole in polygon.holes { points.append(contentsOf: hole.points) }
        }
        for segment in geometry.segments {
            points.append(segment.start)
            points.append(segment.end)
        }
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
