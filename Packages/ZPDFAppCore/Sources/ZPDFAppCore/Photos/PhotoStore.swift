import Foundation
import ZPDFContracts
import ZPDFPersistence

/// The project's site-photograph sidecar: attachments keyed by markup, pixels stored once
/// per digest.
///
/// # A sidecar, on purpose
///
/// Nothing in the frozen contracts changes for photographs. `MarkupRecord` does not know
/// they exist; the attachment carries the ``ZPDFContracts/MarkupID`` and this store owns
/// the mapping. Deleting a markup means removing each of its attachments from this store
/// with ``removeAttachment(_:)``, exactly as the ledger is told.
///
/// # On-disk shape
///
/// One directory — the app tier mounts it inside the `.zpdfproj`'s existing
/// `attachments/` member, so the save pipeline's tree sync, version clones and atomic
/// swap carry it with no new persistence machinery:
///
/// ```text
/// photos/
/// ├── photo-manifest.json        every attachment, atomically replaced on each change
/// └── blobs/
///     └── <sha256>.jpg           content-addressed stored photographs, immutable
/// ```
///
/// # Content addressing
///
/// A blob is named by the SHA-256 of its own bytes, like the artwork store
/// (`ProjectArtworkStore`): the same photograph attached to two markups — or twice to
/// one — stores one file, and the name doubles as a checksum that ``photoData(for:)``
/// verifies on every read.
///
/// # Crash safety
///
/// The manifest is written with `FileDurability.writeFileAtomically` — temporary sibling,
/// `F_FULLFSYNC`, `rename(2)`, parent-directory fsync — the same idiom the package uses
/// for its recovery journal and project manifest, so a reader never sees half a manifest.
/// Blobs are written complete and synced *before* the manifest that references them, and
/// dereferenced *in* the manifest before the file is deleted. A crash between the two
/// steps therefore leaves, at worst, an unreferenced blob — bytes without a claim, which
/// ``sweepUnreferencedBlobs()`` reclaims — and never a manifest naming bytes that are not
/// there.
public actor PhotoStore {

    // MARK: Layout

    /// The manifest's file name inside the store directory.
    public static let manifestFileName = "photo-manifest.json"
    /// The blob directory's name inside the store directory.
    public static let blobsDirectoryName = "blobs"
    /// The sidecar directory's own name — what the app tier appends to the package's
    /// `attachments/` member when it mounts the store.
    public static let sidecarDirectoryName = "photos"

    /// The manifest format this build writes, and the newest it reads.
    static let currentFormatVersion = 1

    /// The manifest: a version stamp and every attachment, in attachment order.
    struct PhotoManifest: Codable, Sendable {
        var formatVersion: Int
        var attachments: [PhotoAttachment]
    }

    // MARK: State

    private let directory: URL
    private let budget: PhotoBudget
    private var attachments: [PhotoAttachment]

    private var manifestURL: URL {
        directory.appendingPathComponent(Self.manifestFileName, isDirectory: false)
    }
    private var blobsDirectoryURL: URL {
        directory.appendingPathComponent(Self.blobsDirectoryName, isDirectory: true)
    }
    private func blobURL(forDigest digest: String) -> URL {
        blobsDirectoryURL.appendingPathComponent("\(digest).jpg", isDirectory: false)
    }

    // MARK: - Opening

    /// Opens the store rooted at `directory`, creating the layout when it is new.
    ///
    /// A missing manifest is a fresh store. A manifest that exists but cannot be decoded
    /// is a loud ``PhotoStoreFailure/manifestUnreadable(path:detail:)`` — opening empty
    /// over it would let the next write orphan every photograph it named.
    ///
    /// - Parameter budget: ``PhotoBudget/standard`` in the product; injectable so a test
    ///   can prove the refusal machinery without 64 MB of fixtures.
    public init(directory: URL, budget: PhotoBudget = .standard) throws {
        self.directory = directory
        self.budget = budget
        try FileDurability.createDirectory(at: directory)
        try FileDurability.createDirectory(
            at: directory.appendingPathComponent(Self.blobsDirectoryName, isDirectory: true)
        )

        let manifestURL = directory.appendingPathComponent(Self.manifestFileName, isDirectory: false)
        guard FileDurability.exists(manifestURL) else {
            self.attachments = []
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw PhotoStoreFailure.manifestUnreadable(
                path: manifestURL.path, detail: error.localizedDescription
            )
        }
        let manifest: PhotoManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let text = try container.decode(String.self)
                guard let date = Self.manifestDate(text) else {
                    throw DecodingError.dataCorruptedError(
                        in: container, debugDescription: "not an ISO-8601 date: \(text)"
                    )
                }
                return date
            }
            manifest = try decoder.decode(PhotoManifest.self, from: data)
        } catch {
            throw PhotoStoreFailure.manifestUnreadable(
                path: manifestURL.path, detail: String(describing: error)
            )
        }
        guard manifest.formatVersion <= Self.currentFormatVersion else {
            throw PhotoStoreFailure.manifestVersionUnsupported(
                found: manifest.formatVersion, supported: Self.currentFormatVersion
            )
        }
        // A manifest read off disk is input again: a digest becomes a file path below,
        // so a malformed one is refused here, before it can name anything.
        for attachment in manifest.attachments {
            guard Self.isWellFormedDigest(attachment.digest) else {
                throw PhotoStoreFailure.manifestUnreadable(
                    path: manifestURL.path,
                    detail: "malformed digest on attachment \(attachment.id)"
                )
            }
        }
        self.attachments = manifest.attachments
        Self.sweepTemporaryFiles(in: [
            directory, directory.appendingPathComponent(Self.blobsDirectoryName, isDirectory: true)
        ])
    }

    /// A manifest date, ISO-8601 with fractional seconds, in UTC.
    ///
    /// Fractional seconds are written only when the date has them, so a whole-second capture
    /// time is stored exactly as the earlier `.iso8601` encoding stored it.
    static func manifestDateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let whole = date.timeIntervalSince1970.rounded(.down) == date.timeIntervalSince1970
        formatter.formatOptions = whole ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Reads a manifest date written with or without fractional seconds.
    static func manifestDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: text)
    }

    // MARK: - Adding

    /// Imports a photograph and attaches it to a markup.
    ///
    /// The source is normalised through ``PhotoImagePipeline`` — bounded, downscaled to
    /// the budget's longest edge, re-encoded JPEG, metadata dropped — and the stored
    /// bytes are digested. A digest the store already holds costs zero new disk bytes.
    /// Both byte budgets are checked **before** anything touches the disk: a refused add
    /// stores nothing.
    ///
    /// - Parameters:
    ///   - id: the new attachment's identity; minted here when the caller has no
    ///     generator of its own to inject.
    ///   - capturedAt: when the photograph was taken. `nil` adopts the source's EXIF
    ///     `DateTimeOriginal`, when it carries one.
    /// - Returns: the stored attachment, digest and stored sizes filled in.
    /// - Throws: ``PhotoImportRefusal`` for the source and the budgets.
    @discardableResult
    public func addPhoto(
        imageData: Data,
        to markupID: MarkupID,
        id: PhotoAttachmentID? = nil,
        capturedAt: Date? = nil,
        caption: String? = nil
    ) throws -> PhotoAttachment {
        let processed = try PhotoImagePipeline.process(imageData, budget: budget)
        let stored = processed.jpegData
        guard stored.count <= budget.bytesPerPhoto else {
            throw PhotoImportRefusal.photoTooLarge(bytes: stored.count, limit: budget.bytesPerPhoto)
        }

        let digest = FileDurability.sha256(of: stored)
        let blobURL = blobURL(forDigest: digest)
        // An existing file is reused only when it still hashes to its own name. A crash or a
        // full disk mid-write used to leave a truncated file at the final path; the next add of
        // the same photograph skipped the write and recorded an attachment naming it, which then
        // failed its digest check forever and could never be swept (BH-009).
        let blobIsIntact = FileDurability.exists(blobURL)
            && (try? Data(contentsOf: blobURL)).map { FileDurability.sha256(of: $0) == digest } == true
        let storedBytes = storedPhotoByteCount()
        // Only a digest the manifest already references is free. An orphaned leftover blob is
        // counted by nobody, so re-attaching it used to add bytes the budget never saw.
        let alreadyReferenced = attachments.contains { $0.digest == digest }
        let incomingBytes = alreadyReferenced ? 0 : stored.count
        guard storedBytes + incomingBytes <= budget.bytesPerProject else {
            throw PhotoImportRefusal.projectPhotoBudgetExceeded(
                storedBytes: storedBytes, incomingBytes: incomingBytes, limit: budget.bytesPerProject
            )
        }

        // Blob before manifest: the manifest must never name bytes that are not on the
        // platter. A crash after this write and before the manifest's leaves an
        // unreferenced blob, which the sweep reclaims.
        //
        // Written through the atomic idiom — temporary sibling, sync, rename — so a crash can
        // leave a stray temporary file (which the sweep reclaims) but never a truncated blob
        // under a real digest.
        if !blobIsIntact {
            try FileDurability.writeFileAtomically(stored, to: blobURL, token: UUID().uuidString)
        }

        let attachment = PhotoAttachment(
            id: id ?? PhotoAttachmentID(UUID()),
            markupID: markupID,
            digest: digest,
            capturedAt: capturedAt ?? processed.capturedAt,
            caption: caption,
            pixelWidth: processed.pixelWidth,
            pixelHeight: processed.pixelHeight,
            byteCount: stored.count
        )
        attachments.append(attachment)
        do {
            try writeManifest()
        } catch {
            // The manifest on disk still describes the store before this add; put the
            // memory back in step with it rather than reporting an attachment that will
            // not survive reopen. The blob, if new, stays as an unreferenced leftover
            // for the sweep — deleting it here could race a concurrent reference.
            attachments.removeLast()
            throw error
        }
        return attachment
    }

    /// Imports a photograph from a file, bounding the size before reading it.
    ///
    /// - Throws: ``PhotoImportRefusal`` and, for the read itself, whatever the
    ///   filesystem throws.
    @discardableResult
    public func addPhoto(
        contentsOf url: URL,
        to markupID: MarkupID,
        id: PhotoAttachmentID? = nil,
        capturedAt: Date? = nil,
        caption: String? = nil
    ) throws -> PhotoAttachment {
        // Bounded by reading at most one byte more than the budget, through a handle that
        // follows symbolic links. The size check used to stat the link itself — a few bytes —
        // and then read a 2 GB target in full before refusing it (BH-439).
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: budget.sourceBytes + 1) ?? Data()
        guard data.count <= budget.sourceBytes else {
            throw PhotoImportRefusal.sourceTooLarge(bytes: data.count, limit: budget.sourceBytes)
        }
        return try addPhoto(
            imageData: data, to: markupID, id: id, capturedAt: capturedAt, caption: caption
        )
    }

    // MARK: - Reading

    /// Every attachment, in the order they were added.
    public func allAttachments() -> [PhotoAttachment] {
        attachments
    }

    /// The photographs attached to one markup, in the order they were added.
    public func attachments(forMarkup markupID: MarkupID) -> [PhotoAttachment] {
        attachments.filter { $0.markupID == markupID }
    }

    /// The stored JPEG bytes of an attachment's photograph, verified against the digest.
    ///
    /// - Throws: ``PhotoStoreFailure/blobMissing(digest:)`` when the file is gone,
    ///   ``PhotoStoreFailure/blobCorrupted(digest:)`` when its bytes no longer hash to
    ///   their own name. Content addressing makes the read self-checking for free.
    public func photoData(for attachment: PhotoAttachment) throws -> Data {
        try photoData(forDigest: attachment.digest)
    }

    /// The stored JPEG bytes for a digest, verified.
    public func photoData(forDigest digest: String) throws -> Data {
        guard Self.isWellFormedDigest(digest) else {
            throw PhotoStoreFailure.malformedDigest(digest)
        }
        let url = blobURL(forDigest: digest)
        guard FileDurability.exists(url) else {
            throw PhotoStoreFailure.blobMissing(digest: digest)
        }
        let data = try Data(contentsOf: url)
        guard FileDurability.sha256(of: data) == digest else {
            throw PhotoStoreFailure.blobCorrupted(digest: digest)
        }
        return data
    }

    /// Total bytes of photograph blobs the manifest references — what the project budget
    /// is measured against. Each digest counts once however many attachments share it;
    /// an unreferenced leftover blob counts against nobody.
    public func storedPhotoByteCount() -> Int {
        var counted: Set<String> = []
        var total = 0
        for attachment in attachments where counted.insert(attachment.digest).inserted {
            total += attachment.byteCount
        }
        return total
    }

    // MARK: - Removing

    /// Removes one attachment; removes its blob only when no other attachment — on any
    /// markup — still references the digest.
    ///
    /// Order matters and is the reverse of the add: the manifest drops the reference
    /// first, durably, and only then does the blob go. A crash between the two leaves an
    /// unreferenced blob for the sweep, never a manifest naming missing bytes.
    public func removeAttachment(_ id: PhotoAttachmentID) throws {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else {
            throw PhotoStoreFailure.attachmentNotFound(id)
        }
        let removed = attachments.remove(at: index)
        do {
            try writeManifest()
        } catch {
            attachments.insert(removed, at: index)
            throw error
        }
        if !attachments.contains(where: { $0.digest == removed.digest }) {
            FileDurability.removeIfPresent(blobURL(forDigest: removed.digest))
            try? FileDurability.syncDirectory(at: blobsDirectoryURL)
        }
    }

    // MARK: - Maintenance

    /// Digests of blob files no attachment references — what a crash between a blob
    /// write and its manifest write leaves behind.
    public func unreferencedBlobDigests() -> [String] {
        let referenced = Set(attachments.map(\.digest))
        return FileDurability.directoryEntryNames(at: blobsDirectoryURL).compactMap { name in
            guard name.hasSuffix(".jpg") else { return nil }
            let digest = String(name.dropLast(4))
            guard Self.isWellFormedDigest(digest), !referenced.contains(digest) else { return nil }
            return digest
        }
    }

    /// Deletes unreferenced blobs. Safe at any time: a blob is only ever referenced by
    /// the manifest this actor owns, so "unreferenced now" cannot race a reference.
    ///
    /// - Returns: how many blobs were reclaimed.
    @discardableResult
    public func sweepUnreferencedBlobs() throws -> Int {
        let orphans = unreferencedBlobDigests()
        for digest in orphans {
            FileDurability.removeIfPresent(blobURL(forDigest: digest))
        }
        if !orphans.isEmpty {
            try? FileDurability.syncDirectory(at: blobsDirectoryURL)
        }
        sweepTemporaryFiles()
        return orphans.count
    }

    /// Removes the temporary siblings an interrupted atomic write leaves behind —
    /// `.photo-manifest.json.<token>.tmp` beside the manifest, `.<digest>.jpg.<token>.tmp`
    /// among the blobs. Each write uses a fresh token and only ever cleaned up its own, so a
    /// crash between write and rename left a permanent stray file inside the package that
    /// travelled with every save and version clone (BH-441). Safe at any time: writes are
    /// synchronous inside this actor, so no temporary file of a live write exists between calls.
    func sweepTemporaryFiles() {
        Self.sweepTemporaryFiles(in: [directory, blobsDirectoryURL])
    }

    private static func sweepTemporaryFiles(in folders: [URL]) {
        for folder in folders {
            for name in FileDurability.directoryEntryNames(at: folder)
            where name.hasPrefix(".") && name.hasSuffix(".tmp") {
                FileDurability.removeIfPresent(folder.appendingPathComponent(name, isDirectory: false))
            }
        }
    }

    // MARK: - Manifest write

    /// The package's atomic-write idiom, applied to the manifest: encode
    /// deterministically (sorted keys, ISO-8601 dates), then
    /// `FileDurability.writeFileAtomically` — temporary sibling, full sync, rename,
    /// parent-directory sync — so no reader, and no crash, ever sees half a manifest.
    private func writeManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Fractional seconds, so a capture time survives the round trip exactly: `.iso8601`
        // writes whole seconds, and a reopened attachment no longer equalled the one `addPhoto`
        // returned (BH-440). Reading accepts both spellings.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.manifestDateText(date))
        }
        let manifest = PhotoManifest(
            formatVersion: Self.currentFormatVersion, attachments: attachments
        )
        let data = try encoder.encode(manifest)
        try FileDurability.writeFileAtomically(data, to: manifestURL, token: UUID().uuidString)
    }

    // MARK: - Digest hygiene

    /// 64 lowercase hex characters, nothing else: the only string this store will ever
    /// turn into a file name.
    ///
    /// Judged on UTF-8 bytes, not on `Character`s: a `Character` range orders by Unicode
    /// comparison, under which "5\u{301}" (a digit with a combining accent) sorts between "5" and
    /// "6" and passed as hex (BH-442).
    static func isWellFormedDigest(_ digest: String) -> Bool {
        let bytes = digest.utf8
        return bytes.count == 64 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
