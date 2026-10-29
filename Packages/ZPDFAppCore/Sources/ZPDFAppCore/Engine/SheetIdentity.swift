import Foundation
import ZPDFContracts

/// Where a sheet's number and title came from (NL-DOCS-05).
public enum SheetNameSource: String, Codable, Sendable, Hashable, CaseIterable {
    /// Read from the text layer inside the title-block region.
    case titleBlockText
    /// Read by on-device OCR inside the title-block region.
    case titleBlockOCR
    /// Taken from the PDF's bookmark for the page.
    case outline
    /// Taken from the PDF's own page label.
    case pageLabel
    /// Typed by a person. Never overwritten by an automatic reading.
    case manual
}

/// A sheet's identity in the set: `A-101 · FLOOR PLAN LEVEL 1` (NL-DOCS-05).
///
/// Data over an immutable page (ADR-0022): the PDF is not rewritten to name a sheet. Persisted in
/// `page_set_entry` (schema v13), undoable through ``DocumentCommand/setSheetIdentities(_:overwriteManual:)``.
public struct SheetIdentity: Codable, Hashable, Sendable {
    /// "A-101". `nil` when only a title is known.
    public var number: String?
    /// "FLOOR PLAN LEVEL 1".
    public var title: String?
    /// "A" — the discipline the number starts with.
    public var discipline: String?
    public var source: SheetNameSource

    public init(number: String?, title: String?, discipline: String? = nil, source: SheetNameSource) {
        let number = number?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.number = (number?.isEmpty ?? true) ? nil : number
        self.title = (title?.isEmpty ?? true) ? nil : title
        self.discipline = discipline ?? self.number.flatMap(Self.discipline(of:))
        self.source = source
    }

    /// Whether it names anything.
    public var isEmpty: Bool { number == nil && title == nil }

    /// The discipline prefix of a sheet number: the letters before the first digit or
    /// separator — "A" for "A-101", "FP" for "FP2.01"; `nil` for a number with no letters.
    public static func discipline(of number: String) -> String? {
        let prefix = number.prefix { $0.isLetter }
        return prefix.isEmpty ? nil : String(prefix).uppercased()
    }

    /// "A-101 · FLOOR PLAN LEVEL 1", the number alone, or the title alone.
    public var displayName: String? {
        switch (number, title) {
        case let (number?, title?): return "\(number) · \(title)"
        case let (number?, nil): return number
        case let (nil, title?): return title
        case (nil, nil): return nil
        }
    }
}
