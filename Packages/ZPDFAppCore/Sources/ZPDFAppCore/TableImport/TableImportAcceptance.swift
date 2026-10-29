import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// Turns an **accepted** ``TableImportProposal`` into `.read` markup records (ADR-0012).
///
/// The proposal side of this directory never touches the document; this is the half that
/// produces something the command bus can land — through the **existing**
/// ``DocumentCommand/addMarkup(_:)``, one per row, so undo, audit and persistence treat an
/// imported row exactly like every other markup. No new command case exists for import,
/// because none is needed: what makes these rows different is not how they arrive but what
/// they claim, and the claim is on the record — `provenance: .read`, with a
/// ``QuantityDerivation`` carrying the source region and the recognised text verbatim.
///
/// What the records deliberately do **not** carry:
///
/// - No `geometry`, no `tool`, no `measurement`. Nothing here was measured, so nothing
///   here may look measured — `TakeoffSession`'s recompute leaves a record without tool
///   and geometry untouched, which is exactly right for a row whose value was read.
/// - No cell content that was not read. An unread cell is absent from `customValues` and
///   absent from the derivation's inputs; it is never filled in.
public enum TableImportAcceptance {

    /// One imported column bound to the ledger column id minted for it.
    ///
    /// The records write their cells into `customValues` under these ids; the app tier
    /// that owns the ledger's column configuration creates the matching
    /// `LedgerColumnDefinition`s (kind `.text`, these titles) so the cells surface in the
    /// ledger. The binding is returned rather than applied because column configuration
    /// lives above this package.
    public struct ColumnBinding: Hashable, Sendable {
        /// The freshly minted ledger column id the cells are keyed under.
        public let columnID: ColumnID
        /// The column's presented name: header text verbatim, or a positional name.
        public let title: String
        /// The column's zero-based position in the proposal.
        public let index: Int

        /// Creates a binding.
        public init(columnID: ColumnID, title: String, index: Int) {
            self.columnID = columnID
            self.title = title
            self.index = index
        }
    }

    /// Everything an accepted proposal becomes.
    public struct Acceptance: Sendable {
        /// One `.read` record per data row, in table order, each already valid under
        /// ``MarkupRecord/quantityProvenanceViolation()`` (it returns `nil`).
        public let records: [MarkupRecord]
        /// The minted column ids, for the app tier's ledger column creation.
        public let columnBindings: [ColumnBinding]

        /// The records as commands for the existing bus — one `.addMarkup` per row.
        public var commands: [DocumentCommand] {
            records.map { .addMarkup($0) }
        }
    }

    /// Builds the `.read` records for an accepted proposal.
    ///
    /// - Parameters:
    ///   - proposal: the accepted proposal, exactly as the engine produced it.
    ///   - documentID: the document the rows belong to.
    ///   - pageID: the page the table was read from — named in every row's derivation.
    ///   - identifiers: mints the markup and column ids. Injected, as everywhere.
    ///   - timestamps: supplies `createdAt`/`modifiedAt`. Injected, as everywhere.
    ///   - subjectColumnIndex: which column classifies the row (the ledger's grouping
    ///     key). Defaults to the leftmost.
    public static func records(
        from proposal: TableImportProposal,
        documentID: DocumentID,
        pageID: PageID,
        identifiers: any IdentifierGenerating,
        timestamps: any TimestampProviding,
        subjectColumnIndex: Int = 0
    ) -> Acceptance {
        let bindings = proposal.columns.map { column in
            ColumnBinding(
                columnID: ColumnID(identifiers.nextIdentifier()),
                title: column.title,
                index: column.index
            )
        }

        let records = proposal.rows.enumerated().map { rowIndex, row -> MarkupRecord in
            var customValues: [ColumnID: ZPDFContracts.LedgerCellValue] = [:]
            var inputs: [String: String] = [:]
            for (column, binding) in zip(proposal.columns, bindings) {
                // A ragged row — `TableImportRow.init` is public and enforces nothing — skips the
                // missing cell instead of trapping at accept time (BH-459).
                guard row.cells.indices.contains(column.index) else { continue }
                let cell = row.cells[column.index]
                guard !cell.isUnread else { continue }
                customValues[binding.columnID] = .text(cell.text)
                // Two headers that read the same word used to share one key, and the second
                // read value overwrote the first in the audit trail (BH-460).
                var key = column.title
                if inputs[key] != nil {
                    key = String(
                        format: NSLocalizedString(
                            "%1$@ (column %2$d)",
                            comment: "Derivation input name for a repeated table header; %2$d is the 1-based column"
                        ),
                        column.title,
                        column.index + 1
                    )
                }
                inputs[key] = cell.text
            }

            let subjectCell = row.cells.indices.contains(subjectColumnIndex)
                ? row.cells[subjectColumnIndex]
                : nil
            // An unread subject cell stays unread: the fallback names the row's position,
            // which is a fact about the import, never a value pretending it was printed.
            let subject: String
            if let subjectCell, !subjectCell.isUnread {
                subject = subjectCell.text
            } else {
                subject = "Imported row \(rowIndex + 1)"
            }

            let now = timestamps.now()
            return MarkupRecord(
                id: MarkupID(identifiers.nextIdentifier()),
                documentID: documentID,
                pageID: pageID,
                kind: .note,
                subject: subject,
                customValues: customValues,
                provenance: .read,
                derivation: QuantityDerivation(
                    sourceMarkupID: nil,
                    formulaText: row.sourceText,
                    inputs: inputs,
                    originIdentifier: originIdentifier(
                        pageID: pageID,
                        region: proposal.region,
                        rowIndex: rowIndex
                    )
                ),
                createdAt: now,
                modifiedAt: now
            )
        }

        return Acceptance(records: records, columnBindings: bindings)
    }

    /// The audit-trail name of one imported row's source: the page, the user-chosen
    /// region, and the row's position in it. Deterministic, so two identical imports
    /// name their origin identically.
    static func originIdentifier(
        pageID: PageID,
        region: PDFRectValue,
        rowIndex: Int
    ) -> String {
        func number(_ value: Double) -> String {
            String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        return "page \(pageID.rawValue.uuidString) "
            + "rect \(number(region.minX)),\(number(region.minY)) "
            + "\(number(region.size.width))x\(number(region.size.height)) "
            + "row \(rowIndex + 1)"
    }
}
