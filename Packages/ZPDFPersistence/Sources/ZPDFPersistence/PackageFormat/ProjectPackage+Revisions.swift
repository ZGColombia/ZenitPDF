import Foundation
import GRDB

extension ProjectPackage {

    /// Keeps a dropped revision of a document in the project (NL-DOCS-11): the PDF is copied
    /// under `documents/revisions/<id>.pdf`, made read-only and
    /// hashed — the evidence rule ``addDocument(originalPDF:displayName:pageCount:)`` applies —
    /// and one `revision_entry` row is written with its sheet pairings. Before this, a dropped
    /// revision lived in the session only and was gone after close.
    ///
    /// If anything after the copy fails the copy is removed again, so a failed add leaves the
    /// package exactly as it was. Waits for an in-flight save, as `addDocument` does (BH-184).
    ///
    /// - Returns: the stored row.
    public func addRevision(
        pdf: URL,
        documentId: String,
        label: String,
        pageCount: Int,
        sheets: [RevisionSheetRecord] = []
    ) async throws -> RevisionEntryRecord {
        guard accessMode == .readWrite else { throw ZPDFPersistenceError.writeOnReadOnlyPackage }
        guard FileDurability.exists(pdf) else { throw ZPDFPersistenceError.packageNotFound(path: pdf.path) }
        await drainActiveSave()

        let id = environmentIdentifiers.nextIdentifier()
        let relativePath = "\(ProjectPackageLayout.revisions)/\(id).pdf"
        let directory = url.member(ProjectPackageLayout.revisions)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = url.member(relativePath)
        guard !FileDurability.exists(destination) else {
            throw ZPDFPersistenceError.packageAlreadyExists(path: destination.path)
        }
        try FileDurability.cloneItem(at: pdf, to: destination)
        let timestamp = PersistenceTimestamp.string(from: environmentClock.now())
        do {
            try FileDurability.makeReadOnly(destination)
            let hash = try FileDurability.sha256(ofFileAt: destination)
            return try await write { db in
                let order = (try Int.fetchOne(
                    db,
                    sql: "SELECT MAX(sort_order) FROM revision_entry WHERE document_id = ?",
                    arguments: [documentId]
                ) ?? -1) + 1
                let row = RevisionEntryRecord(
                    id: id, documentId: documentId, label: label, relativePath: relativePath,
                    sha256: hash, pageCount: pageCount, sortOrder: order, addedAt: timestamp
                )
                let paired = sheets.map {
                    RevisionSheetRecord(revisionId: id, revisionPageIndex: $0.revisionPageIndex, pageId: $0.pageId, evidence: $0.evidence)
                }
                try DocumentSetStore.upsertRevision(row, sheets: paired, in: db)
                return row
            }
        } catch {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
            FileDurability.removeIfPresent(destination)
            throw error
        }
    }

    /// The file URL of a stored revision.
    public nonisolated func revisionFileURL(_ revision: RevisionEntryRecord) -> URL {
        url.member(revision.relativePath)
    }
}
