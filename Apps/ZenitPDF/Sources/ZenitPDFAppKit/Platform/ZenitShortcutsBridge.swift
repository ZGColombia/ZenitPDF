import AppKit
import Foundation
import ZPDFAppCore
import ZPDFExport

/// What Shortcuts actions (NL-PLAT-12) do, in the app library where it can be tested. The App
/// Intents themselves live in the executable target — `Metadata.appintents` is extracted from that
/// module by `Scripts/build-app.sh` — and each one is a thin call into this bridge, so a Shortcuts
/// action and a menu command run the same code.
@MainActor
public enum ZenitShortcutsBridge {

    public enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case noProjectOpen
        case notLoaded

        public var localizedStringResource: LocalizedStringResource {
            switch self {
            case .noProjectOpen: return LocalizedStringResource("No drawing or project is open in Zenit PDF.")
            case .notLoaded: return LocalizedStringResource("The drawing in front is still opening. Try again in a moment.")
            }
        }
    }

    public enum LedgerFormat: String, CaseIterable, Sendable {
        case xlsx, csv, json
        var fileExtension: String { self == .json ? "zpdfjson" : rawValue }
    }

    static func frontDocument() throws -> ZenitPDFProjectDocument {
        let controller = NSDocumentController.shared
        guard let document = (controller.currentDocument as? ZenitPDFProjectDocument)
                ?? controller.documents.lazy.compactMap({ $0 as? ZenitPDFProjectDocument }).first else {
            throw Failure.noProjectOpen
        }
        return document
    }

    /// The ledger's grand totals as lines of text: "Plan Length: 12.500 m".
    public static func frontTotals() async throws -> String {
        let document = try frontDocument()
        guard document.core != nil else { throw Failure.notLoaded }
        return try await totals(of: document)
    }

    /// One document's grand totals as text. The one implementation Shortcuts and AppleScript
    /// both answer with: AppleScript's own copy kept only the Sum rows and wrote them differently
    /// (R-027).
    ///
    /// The whole project's totals, whatever filter the ledger shows (W-021): the intent and the
    /// dictionary promise the drawing's or project's totals, and a subject or zone filter on
    /// screen used to come back as the project's, unmarked. The Quick Look summary follows the
    /// same rule (S-023).
    static func totals(of document: ZenitPDFProjectDocument) async throws -> String {
        guard let core = document.core else { throw Failure.notLoaded }
        let projection = try await ProjectWindowController.projection(
            core: core, documentName: document.displayName ?? "Takeoff",
            scaleDescription: core.snapshot.documentScaleDescription,
            request: ZenitPDFProjectDocument.wholeProjectRequest(from: core.ledger.request))
        return totalsText(projection)
    }

    nonisolated static func totalsText(_ projection: ExportProjection) -> String {
        let lines = totalRows(projection).map { "\($0.title): \($0.text)" }
        return lines.isEmpty
            ? NSLocalizedString("The ledger has no totals yet.", comment: "Shortcuts: Get Totals result when the ledger is empty")
            : lines.joined(separator: "\n")
    }

    /// The grand totals as (column title, displayed value) pairs, in the ledger's order: every
    /// numeric column of every grand-total row that has a value. The one reading Shortcuts,
    /// AppleScript and the Quick Look preview's summary (NL-PLAT-21) all share.
    nonisolated static func totalRows(_ projection: ExportProjection) -> [(title: String, text: String)] {
        let columns = projection.table.columns
        var rows: [(title: String, text: String)] = []
        for total in projection.table.grandTotals {
            for (index, column) in columns.enumerated() where index < total.cells.count && column.isNumeric {
                let text = total.cells[index].text
                guard !text.isEmpty else { continue }
                rows.append((column.title, text))
            }
        }
        return rows
    }

    /// Writes the front document's ledger, as on screen, to a temporary file and returns it; the
    /// shortcut decides where it goes (Save File, Mail, a folder action).
    public static func exportFrontLedger(format: LedgerFormat) async throws -> URL {
        let document = try frontDocument()
        guard document.core != nil else { throw Failure.notLoaded }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Zenit Shortcuts \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (document.displayName ?? "Quantity Ledger") + "." + format.fileExtension
        let url = folder.appendingPathComponent(name)
        try await writeLedger(of: document, format: format, to: url)
        return url
    }

    /// Writes one document's ledger, as on screen, the way File ▸ Export… writes it: the CSV from
    /// the table on screen, and every workbook with row identity so Import Spreadsheet Changes…
    /// can read it back. Shortcuts and AppleScript both write through here; AppleScript used to
    /// call the exporters bare, and its workbooks could not come back (R-027).
    static func writeLedger(of document: ZenitPDFProjectDocument, format: LedgerFormat, to url: URL) async throws {
        guard let core = document.core else { throw Failure.notLoaded }
        // A script or a shortcut names its file with no panel and no Replace: it may never name
        // the drawing, a drawing of the set, a revision or a file inside the project (U-018).
        try DerivedCopyGuard.refuseIfDocumentFile(url, document: document)
        switch format {
        case .csv:
            try ProjectWindowController.writeLedgerCSV(core: core, includeTrail: false, to: url)
        case .xlsx, .json:
            let projection = try await ProjectWindowController.projection(
                core: core, documentName: document.displayName ?? "Takeoff",
                scaleDescription: core.snapshot.documentScaleDescription, request: core.ledger.request)
            if format == .xlsx {
                let options = SpreadsheetRoundTrip.withRowIdentity(XLSXExportOptions(), projection: projection,
                                                                    identity: await SpreadsheetRoundTrip.identity(of: document))
                try XLSXExporter().export(projection, to: url, options: options)
            } else {
                try ZenitJSONExporter().export(projection).write(to: url, options: .atomic)
            }
        }
    }

    /// Opens a drawing or project, the same way File ▸ Open does.
    public static func open(_ url: URL) async throws {
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
