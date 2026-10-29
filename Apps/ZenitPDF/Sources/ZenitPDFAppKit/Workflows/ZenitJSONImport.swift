import AppKit
import UniformTypeIdentifiers
import ZPDFExport

/// File ▸ Import Zenit JSON… — the read half of the interchange format.
///
/// # Why this exists
///
/// `ZenitJSONExporter` has been reachable from the export dialog since 2026-08-24.
/// `ZenitJSONImporter` had **no caller in any tier** — not in `Apps/`, not in `Packages/`, not in
/// a test outside its own package. A project could be exported to `.zpdfjson` and never read back, which makes the file a
/// write-only artefact and the word "interchange" a claim nobody could exercise.
///
/// # What importing one does, and the one thing it deliberately does not
///
/// A `.zpdfjson` is a **ledger**: rows, cells, totals, and the metadata needed to read them. It
/// carries no geometry — no page, no vertex, no scale, no snap. The markups that produced those
/// numbers are not in the file, so there is no arithmetic by which importing one could rebuild a
/// takeoff, and this command does not pretend otherwise: **nothing an imported file contains is
/// ever written into the open project.** The import is a read, and the domain model is not on
/// the far side of it.
///
/// What it does instead is the thing the format is actually good for, and the thing an estimator
/// asks for when a ledger arrives from another firm:
///
/// 1. **Review** — parse it, validate it as untrusted data through ``ZenitInterchangeImport``,
///    and show what it contains before anything is believed: who wrote it, when, at which schema
///    version, over which columns, how many rows, whether the export was filtered.
/// 2. **Reconcile** — when a project is open, hold the file against the ledger on screen and
///    report, digit for digit, which rows agree, which differ and in which column, and which
///    exist on only one side (``ZenitLedgerReconciliation``).
///
/// # The dialog
///
/// The same format vocabulary as the export dialog, from the same source: the open panel is
/// restricted to ``ExportAccessoryView/Format/zenitJSON``'s own `contentType`, so the extension
/// the exporter writes is the extension the importer offers and the two cannot drift apart.
@MainActor
public enum ZenitJSONImport {

    /// The result of reading one file: what it says it is, and how it compares.
    public struct Outcome: Sendable {
        public let review: ZenitImportReview
        /// `nil` when there was no ledger to hold it against — no project open, or an empty one.
        public let reconciliation: ZenitLedgerReconciliation?
        /// Markup ids the file lists more than once (BH-392). The reconciliation keeps the first
        /// copy of each, so a file whose second copy says something else must not read as an
        /// exact match.
        public var duplicateMarkupIDs: [String] = []
    }

    /// Every markup id the file lists more than once, in first-seen order.
    nonisolated static func duplicateMarkupIDs(in document: ZenitInterchangeDocument) -> [String] {
        var seen: Set<String> = []
        var duplicates: [String] = []
        func visit(_ rows: [ZenitInterchangeDocument.Row]) {
            for row in rows where !seen.insert(row.markupID).inserted {
                if !duplicates.contains(row.markupID) { duplicates.append(row.markupID) }
            }
        }
        func visit(groups: [ZenitInterchangeDocument.Group]) {
            for group in groups {
                visit(group.rows)
                visit(groups: group.groups)
            }
        }
        visit(document.rows)
        visit(groups: document.groups)
        return duplicates
    }

    /// Reads and checks one payload, and reconciles it when there is something to reconcile.
    ///
    /// Pure: no panel, no window, no document. The whole decision the sheet reports is made
    /// here, so the app suite can drive it without putting anything on screen.
    ///
    /// - Throws: ``ZPDFExport/ExportError`` — the file is not read past the first rule it breaks.
    nonisolated public static func load(
        _ data: Data,
        fileName: String,
        against ledger: ZenitInterchangeDocument?
    ) throws -> Outcome {
        let (document, review) = try ZenitInterchangeImport.read(data, fileName: fileName)
        let duplicates = duplicateMarkupIDs(in: document)
        guard let ledger else {
            return Outcome(review: review, reconciliation: nil, duplicateMarkupIDs: duplicates)
        }
        return Outcome(
            review: review,
            reconciliation: ZenitLedgerReconciliation.compare(imported: document, against: ledger),
            duplicateMarkupIDs: duplicates
        )
    }

    /// The sheet's two blocks of text, as values.
    ///
    /// Separated from the presentation so a test asserts the sentence a person reads rather than
    /// the existence of an `NSAlert`. The strings are localizable; the numbers in them are the
    /// numbers the reconciliation produced, never rounded or softened.
    public static func text(for outcome: Outcome) -> (title: String, body: String) {
        let title = String(
            format: NSLocalizedString(
                "“%@” is a Zenit ledger export.",
                comment: "Title of the Zenit JSON import review sheet"
            ),
            outcome.review.fileName
        )
        var lines = outcome.review.fields.map { "\($0.label): \($0.value)" }
        lines.append("")
        lines.append(NSLocalizedString(
            "A ledger export carries quantities, not drawings. Zenit reads it to review and "
                + "compare it; nothing in it is written into the open project.",
            comment: "Explains that a Zenit JSON import does not modify the project"
        ))
        if !outcome.duplicateMarkupIDs.isEmpty {
            lines.append("")
            lines.append(duplicateNote(count: outcome.duplicateMarkupIDs.count))
        }
        if let result = outcome.reconciliation {
            lines.append("")
            lines.append(summary(of: result, duplicates: outcome.duplicateMarkupIDs.count))
        }
        return (title, lines.joined(separator: "\n"))
    }

    /// The reconciliation in words.
    public static func duplicateNote(count: Int) -> String {
        String(
            format: NSLocalizedString(
                "This file lists %d markup(s) more than once. Only the first copy of each was compared; the others may carry different values.",
                comment: "Import review note when the file repeats markup rows"
            ),
            count
        )
    }

    public static func summary(of result: ZenitLedgerReconciliation, duplicates: Int = 0) -> String {
        if let mismatch = result.columnMismatch {
            return NSLocalizedString(
                "This file cannot be compared with the ledger on screen: the two do not have the "
                    + "same columns.",
                comment: "Reconciliation refused because the columns differ"
            ) + "\n" + mismatch
        }
        if result.isExactMatch, duplicates > 0 {
            return String(
                format: NSLocalizedString(
                    "Compared with the ledger on screen: the first copy of each of %d row(s) matches, but the file repeats %d of them — it is not an exact match.",
                    comment: "Reconciliation result when the rows match but the file repeats markup rows"
                ),
                result.rowsIdentical, duplicates
            )
        }
        if result.isExactMatch {
            return String(
                format: NSLocalizedString(
                    "Compared with the ledger on screen: %d row(s), every value identical.",
                    comment: "Reconciliation result when the two ledgers agree completely"
                ),
                result.rowsIdentical
            )
        }
        var lines = [String(
            format: NSLocalizedString(
                "Compared with the ledger on screen: %1$d row(s) identical, %2$d differing, "
                    + "%3$d only in the file, %4$d only in this project.",
                comment: "Reconciliation result when the two ledgers disagree"
            ),
            result.rowsIdentical,
            result.rowsDiffering,
            result.rowsOnlyInFile.count,
            result.rowsOnlyInLedger.count
        )]
        for difference in result.differences.prefix(12) {
            lines.append("• \(difference.columnTitle): \(difference.inFile) ≠ \(difference.inLedger)")
        }
        if result.differences.count > 12 {
            lines.append(String(
                format: NSLocalizedString(
                    "…and %d more.",
                    comment: "Suffix when more differences exist than the sheet lists"
                ),
                result.differences.count - 12
            ))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Presentation

    /// The open panel the command puts up. Not private, so a test can assert what it accepts
    /// without opening it — the panel's configuration is the part that can be wrong.
    public static func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.message = NSLocalizedString(
            "Choose a Zenit ledger export to review.",
            comment: "Zenit JSON import panel message"
        )
        panel.prompt = NSLocalizedString("Import", comment: "Zenit JSON import panel button")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // The same content type the export dialog writes, read off the same enum, so the two
        // halves of the format cannot disagree about what a `.zpdfjson` is.
        panel.allowedContentTypes = [ExportAccessoryView.Format.zenitJSON.contentType]
        return panel
    }

    /// Runs the whole command: pick a file, read it, show what it is.
    ///
    /// - Parameters:
    ///   - window: the window the panel and the review sheet hang from.
    ///   - ledger: the ledger currently on screen, already projected into interchange form, or
    ///     `nil` when there is nothing to compare against.
    public static func present(in window: NSWindow?, against ledger: ZenitInterchangeDocument?) {
        let panel = makeOpenPanel()
        // The import chooser is one of the six modal paths that must be injectable. A
        // process with no user chooses nothing, and nothing is read.
        ZenitModalPresenter.runOpenPanel(
            panel,
            identifier: chooserModalIdentifier,
            sheetedOn: window
        ) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in _ = await review(url, against: ledger, window: window) }
        }
    }

    /// Reads one file and shows the review: the half the menu command and a file opened from
    /// Finder share (R-040).
    ///
    /// - Returns: the outcome shown, or `nil` when the file could not be read (the error is
    ///   presented).
    @discardableResult
    public static func review(_ url: URL, against ledger: ZenitInterchangeDocument?, window: NSWindow?) async -> Outcome? {
        do {
            // Up to 512 MB read, decoded and reconciled off the main actor: the window stayed
            // frozen for the whole of it (BH-924).
            let outcome = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                return try load(data, fileName: url.lastPathComponent, against: ledger)
            }.value
            show(outcome, in: window)
            return outcome
        } catch {
            ZenitErrorPresenter.present(error, in: window)
            return nil
        }
    }

    /// The stable names of this command's two dialogues.
    public static let chooserModalIdentifier = "import.chooseLedgerJSON"
    public static let reviewModalIdentifier = "import.ledgerReview"

    private static func show(_ outcome: Outcome, in window: NSWindow?) {
        let copy = text(for: outcome)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = copy.title
        alert.informativeText = copy.body
        alert.addButton(withTitle: NSLocalizedString("Done", comment: "Import review sheet button"))
        // Sheeted, never `runModal`: a modal loop in a process with no user hangs, and this
        // code path must stay incapable of it. Through the presenter, so a test reads the review
        // instead of seeing it.
        ZenitModalPresenter.runAlert(
            alert,
            identifier: reviewModalIdentifier,
            sheetedOn: window,
            answerWithoutAUser: .button(0)
        ) { _ in }
    }
}
