import AppKit
import Foundation

/// What Copy puts on the pasteboard from the ledger.
public struct LedgerCopyPayload: Hashable, Sendable {

    /// Tab-separated rows, header first, lines ended by a line feed.
    public let tabSeparatedText: String

    /// Creates a payload.
    public init(tabSeparatedText: String) {
        self.tabSeparatedText = tabSeparatedText
    }
}

/// Where the ledger's Copy goes.
///
/// The platform pasteboard is one process-wide object, so the table reaches it through
/// this seam: a test injects a recorder and never touches `NSPasteboard.general`
/// (IM-015).
@MainActor
public protocol LedgerPasteboardWriting: AnyObject {

    /// Writes one copy.
    func write(_ payload: LedgerCopyPayload)
}

/// The shipping destination: `NSPasteboard.general`, as tab-separated values and as plain
/// text, so a spreadsheet pastes cells and a text editor pastes lines.
@MainActor
public final class SystemLedgerPasteboard: LedgerPasteboardWriting {

    /// Creates the writer. Nothing is touched until ``write(_:)``.
    public init() {}

    public func write(_ payload: LedgerCopyPayload) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.tabularText, .string], owner: nil)
        pasteboard.setString(payload.tabSeparatedText, forType: .tabularText)
        pasteboard.setString(payload.tabSeparatedText, forType: .string)
    }
}

// The text itself is built by `LedgerTabularText` (ZPDFUIPresentation), the one writer Copy,
// a row dragged out and the Summary Matrix share, with the spreadsheet formula guard (X-030).
