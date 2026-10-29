import Foundation

/// One line of the ledger's count-symbol legend (feature 19): which symbol counts which
/// subject, and how many marks stand placed. Derived from the placed marks themselves —
/// a preset edited after placement changes nothing here, which is the point.
public struct LedgerSymbolLegendRow: Identifiable, Hashable, Sendable {
    public let id: String
    /// The subject the symbol counts — "Drains", "D-12".
    public let subject: String
    /// The symbol's display name — the imported artwork's name, or the built-in glyph's.
    public let symbolName: String
    /// How many marks are placed under this subject-symbol pair.
    public let markCount: Int

    public init(id: String, subject: String, symbolName: String, markCount: Int) {
        self.id = id
        self.subject = subject
        self.symbolName = symbolName
        self.markCount = markCount
    }
}
