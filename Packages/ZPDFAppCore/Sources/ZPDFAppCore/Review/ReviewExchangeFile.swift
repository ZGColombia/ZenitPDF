import Foundation
import ZPDFCollaboration
import ZPDFContracts
import ZPDFPersistence

/// `.zpdfreview` — the lossless Zenit-to-Zenit review exchange file (NL-COLLAB-10).
///
/// The same operations a Shared Review Folder log holds (ADR-0026), in one file: every markup whole,
/// every reply, signed by the person who exported it. It carries shapes and words, never numbers —
/// the importer recomputes every quantity from the shape under its own scale, which is the rule
/// that keeps two ledgers equal digit for digit.
///
/// Importing merges, it never deletes: a markup the file does not mention stays. A markup both
/// sides changed keeps whichever edit is newer, and the preview says which were conflicts.
public struct ReviewExchangeFile: Codable, Sendable {

    public static let formatName = "zpdfreview"
    public static let formatVersion = 1
    public static let fileExtension = "zpdfreview"
    /// A review file is words and outlines; one larger than this is not one.
    public static let maximumBytes = 128 << 20

    public var format: String
    public var formatVersion: Int
    public var projectID: String
    public var projectName: String
    public var exportedBy: String
    public var exportedAt: Date
    public var operations: [ReviewOperation]

    public enum ExchangeError: Error, Equatable, Sendable {
        case notAReviewFile
        case newerFormat(Int)
        case otherProject(fileProject: String, thisProject: String)
        case tooLarge
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    public static func decode(_ data: Data) throws -> ReviewExchangeFile {
        guard data.count <= maximumBytes else { throw ExchangeError.tooLarge }
        guard let file = try? decoder.decode(ReviewExchangeFile.self, from: data), file.format == formatName else {
            throw ExchangeError.notAReviewFile
        }
        guard file.formatVersion <= formatVersion else { throw ExchangeError.newerFormat(file.formatVersion) }
        return file
    }
}

/// What importing a review file would do, shown before anything changes (NL-COLLAB-10).
public struct ReviewExchangePlan: Sendable {
    public var changes: SharedReviewSyncPlanner.LocalChanges
    /// Markups both sides changed where this project's edit is newer: kept as they are here.
    public var conflictsKeptLocal: [MarkupID] = []
    /// Who contributed, by the name they signed.
    public var authors: [String] = []
    /// Markups on sheets removed from this project's set: left out, and left as they are here, so
    /// none of them exists twice (T-020). Restore the sheet and import again to bring them in.
    public var onRemovedSheets = 0
    /// Markups naming a Project Zone or Scale Region this project does not have: filed without the
    /// zone, measured by this project's own Scale Regions, or left out when one lies across two
    /// (T-021).
    public var missingZonesOrRegions = 0
    /// Markups changed — or arriving — in a way this build has no command for (a new identity,
    /// layer, symbol, claim or printable flag, or a cutout whose parent does not come in): left
    /// as they are here, and not counted as changed (U-040).
    public var notApplied = 0

    public var isEmpty: Bool { changes.isEmpty }

    /// "2 new markups, 1 changed, 3 replies, 1 conflict kept as yours".
    public var summary: String {
        var parts: [String] = []
        if !changes.added.isEmpty {
            parts.append(String(format: NSLocalizedString("%lld new markups", comment: "Review import summary: several new markups"), changes.added.count))
        }
        if !changes.changed.isEmpty {
            parts.append(String(format: NSLocalizedString("%lld changed", comment: "Review file import summary: changed markups"), changes.changed.count))
        }
        if !changes.newReplies.isEmpty {
            parts.append(String(format: NSLocalizedString("%lld replies", comment: "Review import summary: several replies"), changes.newReplies.count))
        }
        if !conflictsKeptLocal.isEmpty {
            parts.append(String(format: NSLocalizedString("%lld conflicts kept as yours", comment: "Review file import summary: markups both sides changed, where this project's edit is newer"), conflictsKeptLocal.count))
        }
        if onRemovedSheets > 0 {
            parts.append(String(format: NSLocalizedString("%lld on sheets removed from the set, left out", comment: "Review file import summary: markups on sheets removed from this project's set"), onRemovedSheets))
        }
        if missingZonesOrRegions > 0 {
            parts.append(String(format: NSLocalizedString("%lld naming a zone or Scale Region this project does not have", comment: "Review file import summary: markups naming a Project Zone or Scale Region this project lacks"), missingZonesOrRegions))
        }
        if notApplied > 0 {
            parts.append(String(format: NSLocalizedString("%lld changes this version cannot apply, left as they are", comment: "Review file import summary: markups changed in a way this build has no command for"), notApplied))
        }
        return parts.isEmpty
            ? NSLocalizedString("Nothing to import.", comment: "Review import summary when the file adds nothing")
            : parts.joined(separator: NSLocalizedString(", ", comment: "Review import summary separator"))
    }
}

extension AppCoreEnvironment {

    /// The whole review of this document as a `.zpdfreview`.
    public func exportReviewFile(projectID: String, projectName: String, author: String, participantID: String, now: Date = Date()) async -> ReviewExchangeFile {
        var base = SharedReviewBase(participantID: participantID)
        // The whole review: markups set aside with a removed sheet are the project's too (T-020).
        let records = await session.reviewMarkups
        let operations = SharedReviewSyncPlanner.operationsToPublish(
            local: records,
            localReplies: SharedReviewSync.localReplies(review),
            base: &base,
            observed: .zero,
            participantID: participantID,
            authorName: author,
            now: now
        )
        return ReviewExchangeFile(
            format: ReviewExchangeFile.formatName,
            formatVersion: ReviewExchangeFile.formatVersion,
            projectID: projectID,
            projectName: projectName,
            exportedBy: author,
            exportedAt: now,
            operations: operations
        )
    }

    /// Plans importing a review file onto this document. Refuses a file from another project,
    /// naming both.
    public func planReviewFileImport(_ file: ReviewExchangeFile, projectID: String) async throws -> ReviewExchangePlan {
        guard file.projectID == projectID else {
            throw ReviewExchangeFile.ExchangeError.otherProject(fileProject: file.projectName, thisProject: projectID)
        }
        // Opened as a saved record is: a file exported by an older build can carry an Arc Length
        // at four points (X-042).
        let merged = SharedReviewSync.merged(file.operations)
        // A set-aside markup is present: it is never offered as new, which put a second copy live
        // on the removed sheet and wrote the id twice at the next save (T-020).
        let local = await session.reviewMarkups
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changes = SharedReviewSyncPlanner.localChanges(
            merged: merged, local: local, localReplies: SharedReviewSync.localReplies(review), known: []
        )
        // A file never deletes, and a newer local edit wins a conflict.
        changes.removed = []
        var conflicts: [MarkupID] = []
        changes.changed = changes.changed.filter { change in
            guard let mine = localByID[change.record.id] else { return true }
            let theirs = merged.modified[change.record.id].map { Date(timeIntervalSince1970: Double($0.physicalMillis) / 1000) }
                ?? .distantPast
            if mine.modifiedAt > theirs {
                conflicts.append(change.record.id)
                return false
            }
            return true
        }
        // What this project can take, decided now so the preview says what will happen: changes
        // waiting for a removed sheet, and arrivals held for a scale decision, are left out.
        let applied = SharedReviewSync.commands(for: changes, context: await reviewApplyContext(for: changes))
        changes.added.removeAll { applied.skippedAdds.contains($0.id) }
        // A change this build cannot apply is not a change it will make: counted apart, so the
        // preview's "changed" is what Import changes, and accepting tags only those (U-040).
        changes.changed.removeAll { applied.onRemovedSheets.contains($0.record.id) || applied.unsupported.contains($0.record.id) }
        var plan = ReviewExchangePlan(changes: changes)
        plan.onRemovedSheets = applied.onRemovedSheets.count
        plan.missingZonesOrRegions = applied.missingStructure.count
        plan.notApplied = applied.unsupported.count
        plan.conflictsKeptLocal = conflicts
        plan.authors = Array(Set(merged.participants.values)).sorted()
        return plan
    }

    /// Applies a planned review-file import: markups as one undoable step, then the replies.
    @discardableResult
    public func acceptReviewFileImport(_ plan: ReviewExchangePlan) async throws -> DocumentBatchOutcome? {
        let commands = SharedReviewSync.commands(for: plan.changes, context: await reviewApplyContext(for: plan.changes)).commands
        let outcome = try await commands.isEmpty ? nil : self.commands.performBatch(
            commands,
            actionName: NSLocalizedString("Import Review File", comment: "Undo action name for importing a .zpdfreview file")
        )
        review.recordImportedReplies(plan.changes.newReplies.map {
            AnnotationImportPlan.Reply(id: $0.id, markupID: $0.markupID, author: $0.authorName, body: $0.body, createdAt: $0.createdAt)
        }, origin: "review-file")
        for retraction in plan.changes.retractions {
            review.setRetractedWithoutUndo(retraction.id, retraction.retracted)
        }
        review.markChangedElsewhere(
            plan.changes.added.map(\.id.rawValue) + plan.changes.changed.map(\.record.id.rawValue)
                + plan.changes.newReplies.map(\.markupID.rawValue)
        )
        await refresh()
        return outcome
    }
}
