import Foundation
import ZPDFSnapEngine

/// Every sentence auto-trace speaks in the status bar, in one place so the words and their
/// tests agree.
enum AutoTraceWording {

    static func tracedNote(_ region: TracedRegion, filterNote: String?) -> String {
        let base: String
        if region.bridgedGapCount > 0 {
            base = String(
                format: NSLocalizedString(
                    "Traced. %1$d small gap(s) up to %2$.1f pt were treated as joins.",
                    comment: "Auto-trace note: gaps within tolerance were closed; count and widest gap"
                ),
                region.bridgedGapCount, region.largestBridgedGap
            )
        } else {
            base = NSLocalizedString(
                "Traced.", comment: "Auto-trace note: the boundary was closed and committed"
            )
        }
        return appending(filterNote, to: base)
    }

    static func notClosedNote(filterNote: String?) -> String {
        appending(filterNote, to: NSLocalizedString(
            "Not traced: the boundary around that point is not closed. Draw the area by hand, or click elsewhere.",
            comment: "Auto-trace refusal: open boundary"
        ))
    }

    /// Tracing walks a window round the click that grows until the room fits (L-73), so a refusal
    /// is about the linework there, not the sheet. The old sentence quoted the refusal's count as
    /// "vector primitives on this sheet", and on a real roof plan it was the count of edges in one
    /// window, not of anything on the sheet.
    static func tooComplexNote() -> String {
        NSLocalizedString(
            "Not traced: the linework around that point is too dense to follow. Draw the area by hand, or hide layers to thin it out.",
            comment: "Auto-trace refusal: the drawing round the click is over a work limit"
        )
    }

    /// "Closes 1 opening (0.90 m). Return to accept, Esc to cancel." — the width in metres on a
    /// calibrated page, in points on one that is not.
    static func proposalNote(_ proposal: OpeningProposal, metresPerPoint: Double?, filterNote: String?) -> String {
        let widths = proposal.closures.map { closure -> String in
            if let metresPerPoint {
                return String(
                    format: NSLocalizedString("%.2f m", comment: "Auto-trace opening width in metres"),
                    closure.width * metresPerPoint
                )
            }
            return String(
                format: NSLocalizedString("%.1f pt", comment: "Auto-trace opening width in page points"),
                closure.width
            )
        }.joined(separator: ", ")
        let base: String
        if proposal.closures.count == 1 {
            base = String(
                format: NSLocalizedString(
                    "Closes 1 opening (%@). Return to accept, Esc to cancel.",
                    comment: "Auto-trace proposal note: one opening; the width"
                ),
                widths
            )
        } else {
            base = String(
                format: NSLocalizedString(
                    "Closes %1$d openings (%2$@). Return to accept, Esc to cancel.",
                    comment: "Auto-trace proposal note: several openings; count and widths"
                ),
                proposal.closures.count, widths
            )
        }
        return appending(filterNote, to: base)
    }

    /// What the trace was told not to look at, or `nil` when nothing: "Tracing ignores: 2 hidden
    /// layers · dashed lines".
    static func filterNote(_ filter: TraceFilter) -> String? {
        let parts = filter.activeDescriptions.map { choice -> String in
            switch choice {
            case .hiddenLayers(let count):
                return String(
                    format: NSLocalizedString(
                        "%d hidden layer(s)", comment: "Auto-trace filter: how many layers are left out"
                    ),
                    count
                )
            case .ignoresDashed:
                return NSLocalizedString("dashed lines", comment: "Auto-trace filter: dashed lines are left out")
            case .ignoresFills:
                return NSLocalizedString("fills and hatch", comment: "Auto-trace filter: fill-only paths are left out")
            case .ignoresThinnerThan(let points):
                return String(
                    format: NSLocalizedString(
                        "lines under %.2f pt", comment: "Auto-trace filter: strokes thinner than this are left out"
                    ),
                    points
                )
            case .ignoresLowConfidence:
                return NSLocalizedString(
                    "uncertain geometry", comment: "Auto-trace filter: low-confidence geometry is left out"
                )
            }
        }
        guard !parts.isEmpty else { return nil }
        return String(
            format: NSLocalizedString("Tracing ignores: %@", comment: "Auto-trace filter summary; the list"),
            parts.joined(separator: " · ")
        )
    }

    private static func appending(_ note: String?, to base: String) -> String {
        guard let note else { return base }
        return base + " " + note + "."
    }
}
