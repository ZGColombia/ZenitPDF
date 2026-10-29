import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// NL-AUTO-09: inside Check Against Drawn Dimensions, the page's area measurements are compared
/// with the room areas printed inside them. Silent when nothing is printed or all agree; one
/// warning naming each room that differs by more than the tolerance.
extension ProjectWindowController {

    /// The printed-area warning's identity, so re-running replaces rather than stacks.
    static let printedAreaWarningID = UUID(uuidString: "0B0C2D9E-4A3F-4E61-9D7C-5A1E2B8F6C44")!

    /// The findings for one page's area markups.
    static func printedAreaFindings(markups: [MarkupRecord], lines: [PageTextLine]) -> [(name: String, finding: PrintedAreaCheck.Finding)] {
        let rooms = markups.compactMap { record -> PrintedAreaCheck.Room? in
            guard record.kind == .measurement,
                  let ring = record.geometry?.polygons.first?.outer.points, ring.count >= 3,
                  let area = record.measurement?[.netArea] ?? record.measurement?[.planArea]
            else { return nil }
            return PrintedAreaCheck.Room(markupID: record.id, ring: ring, measuredSquareMetres: area.value)
        }
        guard !rooms.isEmpty else { return [] }
        let recognised = lines.map {
            RecognisedTextLine(
                text: $0.text,
                boundsInPageSpace: PDFRectValue(
                    x: $0.boundsInPageSpace.origin.x, y: $0.boundsInPageSpace.origin.y,
                    width: $0.boundsInPageSpace.width, height: $0.boundsInPageSpace.height
                )
            )
        }
        let names = Dictionary(uniqueKeysWithValues: markups.map { ($0.id, $0.subject) })
        return PrintedAreaCheck.check(rooms: rooms, lines: recognised).map { finding in
            let subject = names[finding.markupID] ?? ""
            return (subject.isEmpty ? NSLocalizedString("Area", comment: "Nameless area in the printed-area check") : subject, finding)
        }
    }

    /// Posts the warning for the rooms that differ, or clears a stale one when none do.
    func reportPrintedAreas(_ findings: [(name: String, finding: PrintedAreaCheck.Finding)], core: AppCoreEnvironment) {
        let differing = findings.filter { !$0.finding.agrees }
        guard !differing.isEmpty else {
            core.document.dismissWarning(id: Self.printedAreaWarningID)
            return
        }
        let lines = differing.prefix(4).map { name, finding in
            String(
                format: NSLocalizedString(
                    "%1$@: printed %2$@ m², measured %3$@ m²",
                    comment: "One printed-area disagreement: room, printed area, measured area"
                ),
                name,
                Self.areaText(finding.printed),
                Self.areaText(finding.measured)
            )
        }
        core.document.post(AppWarning(
            id: Self.printedAreaWarningID,
            severity: .warning,
            title: String(
                format: NSLocalizedString(
                    "%d room area(s) differ from the area printed in the room.",
                    comment: "Printed-area check headline; the number of rooms"
                ),
                differing.count
            ),
            message: lines.joined(separator: "\n") + "\n" + NSLocalizedString(
                "A wrong scale, a trace across an opening or a missing cutout all show up this way.",
                comment: "Printed-area check explanation"
            ),
            source: NSLocalizedString("Dimension check", comment: "Warning source"),
            isDismissible: true,
            timestamp: Date()
        ))
    }

    /// An area rounded for display only, two decimals.
    static func areaText(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 2, .plain)
        return "\(rounded)"
    }
}
