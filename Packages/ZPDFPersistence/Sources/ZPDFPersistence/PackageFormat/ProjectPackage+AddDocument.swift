import Foundation
import GRDB

extension ProjectPackage {

    /// Records another drawing as a document of this project — the API the Navigator's
    /// "add to project" drop programs against.
    ///
    /// The PDF is *copied into* the package under `documents/` and made read-only, the
    /// same evidence rule `create` applies to the first drawing: nothing in this package
    /// ever opens an added document for writing. One `document` row is inserted; the
    /// copy participates in every subsequent save because the save pipeline clones the
    /// whole `documents/` directory.
    ///
    /// If anything after the copy fails — the permission change, the hash, the database
    /// insert — the copied file is removed again, so a failed add leaves the package
    /// exactly as it was.
    ///
    /// An add that arrives while a save pipeline is in flight waits for it (BH-184): the
    /// pipeline clones `documents/` into the temporary package at one instant and, after
    /// the swap, removes the directory the package used to occupy. A drawing copied into
    /// that directory after the clone, with its row committed into the database the
    /// swap retires, would vanish while this call reported the id — the same window
    /// ``ProjectPackage/write(_:)`` closes for a row alone.
    ///
    /// - Parameters:
    ///   - originalPDF: the drawing to add, readable at call time.
    ///   - displayName: the name the Navigator shows, normally the file name without
    ///     extension.
    ///   - pageCount: the page count when the caller already knows it; `0` means "not
    ///     read yet", matching `create`.
    /// - Returns: the new document's stable identifier (the `document.id` column).
    public func addDocument(
        originalPDF: URL,
        displayName: String,
        pageCount: Int = 0
    ) async throws -> String {
        guard accessMode == .readWrite else {
            throw ZPDFPersistenceError.writeOnReadOnlyPackage
        }
        guard FileDurability.exists(originalPDF) else {
            throw ZPDFPersistenceError.packageNotFound(path: originalPDF.path)
        }
        await drainActiveSave()

        let documentId = environmentIdentifiers.nextIdentifier()
        let relativePath = ProjectPackageLayout.addedDocumentPath(id: documentId)
        let destination = url.member(relativePath)
        guard !FileDurability.exists(destination) else {
            throw ZPDFPersistenceError.packageAlreadyExists(path: destination.path)
        }

        try FileDurability.cloneItem(at: originalPDF, to: destination)
        let timestamp = PersistenceTimestamp.string(from: environmentClock.now())
        let projectId = currentProjectId

        do {
            // Inside the clean-up scope, not before it (BH-599): a `chmod` a volume
            // refuses or a read error while hashing used to strand the copy under
            // `documents/` with no row, and every later save carried the orphan forward.
            try FileDurability.makeReadOnly(destination)
            let hash = try FileDurability.sha256(ofFileAt: destination)
            try await write { db in
                try DocumentRecord(
                    id: documentId,
                    projectId: projectId,
                    displayName: displayName,
                    relativePath: relativePath,
                    sha256: hash,
                    pageCount: pageCount,
                    createdAt: timestamp,
                    modifiedAt: timestamp
                ).insert(db)
            }
        } catch {
            // The row did not land, so the file must not stay: a failed add leaves the
            // package exactly as it was. The copy may be a directory if the caller handed
            // one in, and `removeItem` handles either.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: destination.path
            )
            FileDurability.removeIfPresent(destination)
            throw error
        }

        return documentId
    }
}
