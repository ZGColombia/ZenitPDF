import Foundation

/// PDF date strings (ISO 32000-1 §7.9.4), written in UTC.
///
/// The one formatter for every PDF date Zenit writes: the PDFKit-backed annotation writer, the
/// direct annotation writer in `ZPDFExport` and the signature writer all produce the same
/// `D:YYYYMMDDHHmmSSZ` spelling from it.
public enum PDFDateFormatting {
    /// Formats `date` as `D:YYYYMMDDHHmmSSZ`, in UTC.
    public static func string(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "D:%04d%02d%02d%02d%02d%02dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }
}
