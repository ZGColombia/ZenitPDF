import Foundation
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// The review fields the audit trail records as plain text (ADR-0021 (collaboration)).
///
/// Keys carry `MeasurementAuditStore.reviewFieldPrefix`, which is what lets the store accept
/// them as text while every other key stays a canonical decimal (ADR-0007 §4). The values are
/// the stored spelling — a status as its contract raw value, a flag as `true`/`false` — so a
/// row compares with the record it describes, and the History pane localises them on display.
public enum ReviewAuditFields {

    public static let status = MeasurementAuditStore.reviewFieldPrefix + "status"
    public static let comment = MeasurementAuditStore.reviewFieldPrefix + "comment"
    public static let label = MeasurementAuditStore.reviewFieldPrefix + "label"
    public static let subject = MeasurementAuditStore.reviewFieldPrefix + "subject"
    public static let locked = MeasurementAuditStore.reviewFieldPrefix + "locked"
    public static let hidden = MeasurementAuditStore.reviewFieldPrefix + "hidden"
    /// The text a Text or Callout draws (NL-COLLAB-18), which is not its note.
    public static let text = MeasurementAuditStore.reviewFieldPrefix + "text"

    /// Every review field of a record, in stored spelling. Always all keys, so two records
    /// compare key by key.
    public static func values(of record: ZPDFContracts.MarkupRecord) -> [String: String] {
        var values: [String: String] = [
            status: record.status.rawValue,
            comment: bounded(record.comment),
            label: bounded(record.label),
            subject: bounded(record.subject),
            locked: record.locked ? "true" : "false",
            hidden: record.hidden ? "true" : "false"
        ]
        if MarkupVisibleText.carriesVisibleText(record.kind) {
            values[text] = bounded(MarkupVisibleText.text(of: record))
        }
        return values
    }

    /// Whether a value is the field's resting state — not worth a line on a creation.
    public static func isDefault(key: String, value: String) -> Bool {
        switch key {
        case status: return value == ZPDFContracts.MarkupStatus.none.rawValue
        case locked, hidden: return value == "false"
        default: return value.isEmpty
        }
    }

    /// The name the History pane shows for a review key, or `nil` for any other key.
    public static func displayName(of key: String) -> String? {
        switch key {
        case status: return NSLocalizedString("Status", comment: "History: review field name")
        case comment: return NSLocalizedString("Notes", comment: "History: review field name, the markup's note")
        case label: return NSLocalizedString("Label", comment: "History: review field name")
        case subject: return NSLocalizedString("Subject", comment: "History: review field name")
        case locked: return NSLocalizedString("Locked", comment: "History: review field name")
        case hidden: return NSLocalizedString("Hidden", comment: "History: review field name")
        case text: return NSLocalizedString("Text", comment: "History: review field name, the text a text box draws")
        default: return nil
        }
    }

    /// A stored review value as the History pane shows it, or `nil` for any other key.
    public static func displayValue(key: String, value: String?) -> String? {
        guard key.hasPrefix(MeasurementAuditStore.reviewFieldPrefix) else { return nil }
        guard let value else { return nil }
        switch key {
        case status:
            guard let domain = ZPDFContracts.MarkupStatus(rawValue: value) else { return value }
            return ZPDFUIPresentation.MarkupStatus(domain: domain).displayName
        case locked, hidden:
            return value == "true"
                ? NSLocalizedString("Yes", comment: "History: a flag that is on")
                : NSLocalizedString("No", comment: "History: a flag that is off")
        default:
            return value.isEmpty
                ? NSLocalizedString("(empty)", comment: "History: a text field that was emptied")
                : value
        }
    }

    /// A text value cut to what one audit row may carry, on a character boundary.
    static func bounded(_ text: String) -> String {
        let limit = MeasurementAuditStore.maximumReviewValueBytes
        guard text.utf8.count > limit else { return text }
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > limit - 3 { break }
            result.append(character)
            bytes += size
        }
        return result + "…"
    }
}
