import AppKit
import Foundation
import ZPDFAppCore
import ZPDFUIPresentation

/// What happens after an export has been written (IM-186): a non-modal confirmation naming
/// the file, the format and what went into it, with a Show in Finder action. Nothing used to
/// be shown on success — only failures surfaced, so a person could not tell a finished export
/// from a click that did nothing.
@MainActor
enum ExportCompletion {

    /// The one warning identity, so a second export replaces the first confirmation.
    static let warningID = UUID(uuidString: "0E6F3A4C-9B21-4D7A-8C55-4E2B1D0A7F11")!

    /// How a file is revealed. The shipping value opens a Finder window; a test replaces it,
    /// so no window is ever put in front of the user by a test.
    static var revealer: @MainActor (URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The confirmation's words.
    static func message(rowCount: Int, formatName: String) -> String {
        rowCount == 1
            ? String(
                format: NSLocalizedString("1 row as %@.", comment: "Export confirmation detail, one row; the format name"),
                formatName
            )
            : String(
                format: NSLocalizedString("%1$d rows as %2$@.", comment: "Export confirmation detail; row count, format name"),
                rowCount, formatName
            )
    }

    /// Remembers the file an export just wrote, for Share Last Export…. Every export that
    /// writes one file of the drawing, the takeoff or the review calls it on success: only the
    /// two ledger paths did, so after a drawing export Share Last Export shared an older file or
    /// said nothing had been exported (R-028). It never moves the confirmation's Show in Finder,
    /// which reveals the file its own note names (``announce(_:rowCount:formatName:document:)``).
    ///
    /// Not called by writes that are not one exported file: Split into Sheets (a folder of
    /// files), Send Project (its own share), the review file handed straight to the share
    /// picker, library and settings files (job templates, export profiles, assembly recipes,
    /// packs) and the print-service alias.
    static func remember(_ url: URL, document: ZenitPDFProjectDocument) {
        document.lastExportURL = url
    }

    /// Posts the confirmation and remembers the file, for Share Last Export… and for the
    /// confirmation's own Show in Finder.
    static func announce(
        _ url: URL,
        rowCount: Int,
        formatName: String,
        document: ZenitPDFProjectDocument
    ) {
        remember(url, document: document)
        document.announcedExportURL = url
        document.core?.document.post(AppWarning(
            id: warningID,
            severity: .info,
            title: String(
                format: NSLocalizedString("Exported “%@”", comment: "Export confirmation headline; the file name"),
                url.lastPathComponent
            ),
            message: message(rowCount: rowCount, formatName: formatName),
            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
            actionTitle: NSLocalizedString("Show in Finder", comment: "Export confirmation action"),
            isDismissible: true,
            timestamp: Date()
        ))
    }

    /// Handles the confirmation's action. Returns whether the warning was this one.
    @discardableResult
    static func handleAction(for warningID: UUID, document: ZenitPDFProjectDocument) -> Bool {
        // NL-PDF-03: the takeoff a reopened PDF carries.
        if EmbeddedTakeoffRestore.handleAction(warningID, document: document) { return true }
        // The file this note names, not whatever was exported since (R-028).
        guard warningID == Self.warningID, let url = document.announcedExportURL else { return false }
        revealer(url)
        return true
    }
}
