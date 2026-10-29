import Foundation
import GRDB

extension ProjectPackage {

    /// Copies every imported stamp artwork row into `destination` — what a Save As from
    /// Project Mode needs so the new package draws the same stamps (BH-071).
    ///
    /// Artwork rows are content-addressed by `digest`, so a row the destination already
    /// holds is kept as it is and not counted. The copy is one read of this package and
    /// one transaction in the destination: either every missing row lands or none does.
    ///
    /// - Returns: how many rows were inserted into `destination`.
    @discardableResult
    public func copyStampArtwork(to destination: ProjectPackage) async throws -> Int {
        let rows = try await read { db in try StampArtworkRecord.fetchAll(db) }
        guard !rows.isEmpty else { return 0 }
        return try await destination.write { db in
            var inserted = 0
            for row in rows where try !StampArtworkRecord.exists(db, key: row.digest) {
                try row.insert(db)
                inserted += 1
            }
            return inserted
        }
    }
}
