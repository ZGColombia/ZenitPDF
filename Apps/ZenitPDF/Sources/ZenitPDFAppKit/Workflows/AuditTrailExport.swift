import Foundation
import ZPDFExport
import ZPDFUIPresentation

/// The audit trail as export rows (ADR-0007 §3, the S22 remainder): the CSV half and the
/// PDF-report appendix half render from the **same** row builder, so the two can never
/// disagree about what an entry says.
///
/// The strings are the History pane's own: `actionDisplayName`, the formatted value
/// changes, the recorded author. An export that re-derived them would be a second code
/// path waiting to drift (QUALITY_BAR C3's argument, applied to the trail).
@MainActor
public enum AuditTrailExport {

    /// The column titles, in export order.
    public static var columnTitles: [String] {
        [
            NSLocalizedString("#", comment: "Audit export column: sequence number"),
            NSLocalizedString("Time", comment: "Audit export column: when the entry occurred"),
            NSLocalizedString("Action", comment: "Audit export column: what happened"),
            NSLocalizedString("Author", comment: "Audit export column: who did it"),
            NSLocalizedString("Subject", comment: "Audit export column: the markup's subject"),
            NSLocalizedString("Page", comment: "Audit export column: the page label"),
            NSLocalizedString("Values", comment: "Audit export column: the value changes"),
            NSLocalizedString("Note", comment: "Audit export column: the entry's note")
        ]
    }

    /// One row per event, oldest first, finished strings.
    public static func rows(for events: [LedgerAuditEvent]) -> [[String]] {
        let timeFormatter = ISO8601DateFormatter()
        timeFormatter.formatOptions = [.withInternetDateTime]
        return events.map { event in
            [
                String(event.sequence),
                timeFormatter.string(from: event.occurredAt),
                event.actionDisplayName,
                event.actor,
                event.markupSubject ?? "",
                event.pageLabel ?? "",
                event.changes.map(valueChangeText).joined(separator: "; "),
                event.note ?? ""
            ]
        }
    }

    /// "Plan Length 5,04 m → 6,12 m", exactly as the History pane words a change.
    static func valueChangeText(_ change: LedgerAuditValueChange) -> String {
        let name = change.fieldDisplayName ?? change.field
        let before = change.beforeDisplay ?? change.before
        let after = change.afterDisplay ?? change.after
        switch (before, after) {
        case let (.some(from), .some(to)) where from != to:
            return "\(name) \(from) → \(to)"
        case let (_, .some(to)):
            return "\(name) \(to)"
        case let (.some(from), nil):
            return "\(name) \(from) → —"
        case (nil, nil):
            return name
        }
    }

    // MARK: - CSV

    /// RFC 4180 CSV of the trail, same quoting rules as the ledger CSV.
    public static func renderCSV(events: [LedgerAuditEvent], delimiter: Character = ",") -> String {
        let separator = String(delimiter)
        var lines = [columnTitles.map { LedgerCSVExport.field($0, delimiter: delimiter) }.joined(separator: separator)]
        for row in rows(for: events) {
            lines.append(row.map { LedgerCSVExport.field($0, delimiter: delimiter) }.joined(separator: separator))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - PDF appendix

    /// The trail as the PDF report's optional appendix (ADR-0007 §3).
    public static func pdfAppendix(events: [LedgerAuditEvent], documentName: String) -> PDFReportAuditAppendix {
        PDFReportAuditAppendix(
            title: NSLocalizedString("Audit Trail", comment: "PDF report appendix heading"),
            caption: String(
                format: NSLocalizedString(
                    "%d recorded change(s) on %@. The trail is append-only; an undo appears as its own entry.",
                    comment: "PDF report audit appendix caption; count and document name"
                ),
                events.count, documentName
            ),
            columnTitles: columnTitles,
            rows: rows(for: events)
        )
    }
}
