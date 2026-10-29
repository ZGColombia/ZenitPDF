import Foundation
import ZPDFCollaboration
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// One document's connection to a Shared Review Folder (NL-COLLAB-12, ADR-0026), and the sync
/// that runs over it: publish what changed here, merge everybody's logs, bring the document to
/// the merged state in one undoable step.
///
/// The document's own `project.sqlite` never goes into the folder. The folder holds operations;
/// this machine keeps its project as the materialised view, and its base — what it last agreed
/// with the folder — beside its preferences, never in the folder.
@MainActor
public final class SharedReviewSync {

    /// What one sync did, for the status note and the tests.
    public struct Report: Sendable, Equatable {
        public var published = 0
        public var added = 0
        public var changed = 0
        public var removed = 0
        public var replies = 0
        /// Page scales another participant changed, installed here (round 2).
        public var scales = 0
        /// Markups the merge changed in a way this copy cannot apply in place; left as they were
        /// and named in the note. Includes the two counts below.
        public var notApplied = 0
        /// Of ``notApplied``: markups on a sheet removed from this copy's set, whose changes wait,
        /// left as they are, until the sheet is back (T-020).
        public var heldForRemovedSheets = 0
        /// Of ``notApplied``: markups naming a Project Zone or Scale Region this copy does not
        /// hold — filed without the zone, measured by this copy's own regions, or held when they
        /// lie across two (T-021).
        public var missingZonesOrRegions = 0
        /// Lines in other people's logs that could not be read (a sync still arriving, or damage).
        public var skippedLines = 0
        /// The other people who have written to the folder, by the name they last signed.
        public var others: [String] = []
        /// Local changes made while this sync ran, after it had read what to publish: markups,
        /// replies or page scales the new base does not hold yet. The next sync publishes them,
        /// and a caller that polls must run it rather than take them for the sync's own (S-013).
        public var unpublishedLocalChanges = 0
        public var isQuiet: Bool { added == 0 && changed == 0 && removed == 0 && replies == 0 && scales == 0 }

        public init() {}
    }

    public enum SyncError: Error, Equatable, Sendable {
        case otherProject(String)
        case newerFormat
        case unwritable(String)
        case refused(String)
    }

    public let folderURL: URL
    public let participantID: String
    public private(set) var base: SharedReviewBaseValue

    /// The folder reader. Injected by the app so every read goes through a file coordinator,
    /// which also downloads a file a sync service has evicted. Called off the main actor, and
    /// only for an entry already checked to be a regular file within the log size cap (T-081).
    public var readFile: @Sendable (URL) -> Data? = SharedReviewFolder.readLog

    /// The bounded log reader (T-081), for an app reader that wraps it — in a file coordinator,
    /// say — without importing the engine.
    public nonisolated static func readLog(_ url: URL) -> Data? {
        SharedReviewFolder.readLog(url)
    }

    /// Decoded logs, per folder, kept between syncs (T-083): a sync decodes only what the logs
    /// gained since the last read — its own new lines and anybody else's — never the history.
    private static var logCaches: [String: SharedReviewFolder.LogCache] = [:]

    public init(folderURL: URL, participantID: String, base: SharedReviewBaseValue?) {
        self.folderURL = folderURL
        self.participantID = participantID
        self.base = base ?? SharedReviewBaseValue(participantID: participantID)
    }

    /// Makes the folder ready for the project, or confirms it is.
    public func prepare(projectID: String, projectName: String) throws {
        do {
            try SharedReviewFolder(url: folderURL).prepare(projectID: projectID, projectName: projectName)
        } catch let error as SharedReviewFolder.FolderError {
            throw Self.map(error)
        }
    }

    /// Publish, merge, apply. The whole thing or, on a refusal, the document untouched.
    /// `looking` is where this person is: the sheet's label and how many markups they have
    /// selected, written into their presence file for the others to see.
    @discardableResult
    public func sync(core: AppCoreEnvironment, authorName: String, now: Date = Date(),
                     looking: (pageLabel: String?, selectedCount: Int)? = nil) async throws -> Report {
        let folder = SharedReviewFolder(url: folderURL)
        var report = Report()
        var working = base.value
        // A base agreed before X-042 can hold an Arc Length at four points that the document,
        // opened since, holds at three: opened alike, so the repair is not published as this
        // person's edit — newer than a colleague's move of it, which it would overwrite (X-042).
        working.markups = SavedMarkupRepair.opened(working.markups)

        // 1. Publish what changed here since the last sync. Markups set aside with a sheet removed
        //    from the set are the project's too: left out, they were published as deleted (T-020).
        let local = await core.session.reviewMarkups
        let localReplies = Self.localReplies(core.review)
        let localPageScales = await core.session.pageScales
        let localScales = localPageScales.values.compactMap(SharedPageScale.init(scale:))
        let participant = participantID
        // This participant's own log, already over the reader's cap — grown by a build from before
        // the append kept it under, or by two of this person's appends racing — is refused by
        // every reader, this one included, so the read below would refuse every sync for good and
        // the append's compaction would never be reached. Its owner is its only writer: it is
        // compacted here, first, even when there is nothing to publish (T-079). Nobody else's log
        // is ever rewritten; over the cap, it stays refused until its owner syncs.
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try folder.compactOwnLogIfOverLimit(participant: participant, now: now)
            }.value
        } catch let error as SharedReviewFolder.FolderError {
            throw Self.map(error)
        }
        // A folder read short of a log would merge that log's markups as removed (T-079): refused
        // before anything is published.
        let before = await readFolder(folder)
        if let refusal = Self.refusal(for: before) { throw refusal }
        // A page scale the folder already holds and this machine measures alike counts as agreed:
        // joining a review does not republish the scale everyone shares.
        let mergedBefore = Self.merged(before.operations)
        for scale in localScales where working.pageScales[scale.pageID] == nil {
            if let shared = mergedBefore.pageScales[scale.pageID], shared.measuresLike(scale) { working.pageScales[scale.pageID] = shared }
        }
        let publish = SharedReviewSyncPlanner.operationsToPublish(
            local: local, localReplies: localReplies, base: &working,
            observed: mergedBefore.latestClock,
            participantID: participantID, authorName: authorName, now: now,
            localScales: localScales
        )
        do {
            // Off the main actor: the append opens a file a sync service may first have to fetch.
            try await Task.detached(priority: .userInitiated) {
                try folder.append(publish, participant: participant, now: now)
            }.value
        } catch let error as SharedReviewFolder.FolderError {
            throw Self.map(error)
        }
        report.published = publish.count

        // 2. Merge everybody's logs — all of them, or none (T-079). A log missing from the merge
        //    would take every markup it holds for removed, here and in the base.
        let read = await readFolder(folder)
        if let refusal = Self.refusal(for: read) { throw refusal }
        report.skippedLines = read.skippedLines
        let merged = Self.merged(read.operations)
        report.others = merged.participants
            .filter { $0.key != participantID }
            .map(\.value)
            .sorted()

        // 3. Bring the document to the merged state, in one undoable step.
        let known = Set(working.markups.keys).union(local.map(\.id))
        let changes = SharedReviewSyncPlanner.localChanges(
            merged: merged, local: local, localReplies: localReplies, known: known, localScales: localScales
        )
        var plan = Self.commands(for: changes, context: await core.reviewApplyContext(for: changes))
        // Round 2: another person's scale is installed under this page's own scale identity, first,
        // so every measurement on the page is recomputed here from its geometry — values never travel.
        let livePages = Set(await core.session.pageDescriptors.map(\.id))
        let scaleCommands = changes.scales.filter { livePages.contains($0.pageID) }
            .map { DocumentCommand.changeScale($0.transform(replacing: localPageScales[$0.pageID])) }
        plan.commands = scaleCommands + plan.commands
        report.scales = scaleCommands.count
        let leftAsTheyAre = plan.unsupported.union(plan.onRemovedSheets).union(plan.missingStructure)
        report.added = changes.added.count - plan.skippedAdds.count
        report.changed = changes.changed.filter { !leftAsTheyAre.contains($0.record.id) }.count
        report.removed = changes.removed.count - plan.skippedRemovals.count
        report.notApplied = plan.notApplied
        report.heldForRemovedSheets = plan.onRemovedSheets.count
        report.missingZonesOrRegions = plan.missingStructure.count
        if !plan.commands.isEmpty {
            do {
                try await core.commands.performBatch(
                    plan.commands,
                    actionName: NSLocalizedString("Sync Shared Review", comment: "Undo action name for applying a Shared Review Folder sync")
                )
            } catch {
                throw SyncError.refused(String(describing: error))
            }
        }
        if !changes.newReplies.isEmpty {
            core.review.recordImportedReplies(changes.newReplies.map {
                AnnotationImportPlan.Reply(id: $0.id, markupID: $0.markupID, author: $0.authorName, body: $0.body, createdAt: $0.createdAt)
            }, origin: "shared-review")
            report.replies = changes.newReplies.count
        }
        for retraction in changes.retractions {
            core.review.setRetractedWithoutUndo(retraction.id, retraction.retracted)
        }
        // NL-COLLAB-15: replies to this person, @-mentions and status changes on their markups.
        core.review.recordActivity(from: changes, markups: await core.session.orderedMarkups, now: now)
        // NL-COLLAB-14: what arrived from other people is new to this person until looked at.
        core.review.markChangedElsewhere(
            changes.added.filter { !plan.skippedAdds.contains($0.id) }.map(\.id.rawValue)
                + changes.changed.map(\.record.id.rawValue)
                + changes.newReplies.map(\.markupID.rawValue)
        )
        await core.refresh()

        // 4. The new base: what step 1 published, plus what this sync applied — read back from
        //    the document, so the next publish carries only what a person changes here, never
        //    what this machine's engine restamped. Not the document wholesale (S-013): the sync
        //    awaits between step 1 and here, and an edit made meanwhile went into the base without
        //    ever being published, so no later diff against that base could find it.
        let after = await core.session.reviewMarkups
        let afterScales = Dictionary(
            (await core.session.pageScales).values.compactMap(SharedPageScale.init(scale:)).map { ($0.pageID, $0) },
            uniquingKeysWith: { first, _ in first })
        let afterReplies = Dictionary(Self.localReplies(core.review).map { ($0.reply.id, $0.retracted) }, uniquingKeysWith: { first, _ in first })
        let installedScalePages = Set(changes.scales.map(\.pageID).filter { livePages.contains($0) })
        let next = Self.base(
            published: (local, localReplies, localScales),
            after: (after, afterReplies, afterScales),
            appliedMarkups: Set(changes.added.map(\.id)).union(changes.changed.map(\.record.id)).union(changes.removed),
            appliedReplies: Set(changes.newReplies.map(\.id)).union(changes.retractions.map(\.id)),
            installedScalePages: installedScalePages
        )
        working.markups = next.markups
        working.replies = next.replies
        working.pageScales = next.pageScales
        working.clock.observe(merged.latestClock, now: now)
        report.unpublishedLocalChanges = next.unpublished
        base = SharedReviewBaseValue(value: working)

        heartbeat(authorName: authorName, now: now, looking: looking)
        return report
    }

    /// Writes this person's presence file — who, when, and where they are looking — without a
    /// sync. The only file besides the log this participant ever writes.
    public func heartbeat(authorName: String, now: Date = Date(), looking: (pageLabel: String?, selectedCount: Int)? = nil) {
        try? SharedReviewFolder(url: folderURL).writePresence(SharedReviewFolder.Presence(
            participantID: participantID, name: authorName, lastSync: now,
            pageLabel: looking?.pageLabel, selectedCount: looking?.selectedCount))
    }

    /// The other people's presence, fresh within `freshness` of `now`, newest first.
    public func others(now: Date = Date(), freshness: TimeInterval = 120) -> [SharedReviewFolder.Presence] {
        SharedReviewFolder(url: folderURL).presences()
            .filter { $0.participantID != participantID && now.timeIntervalSince($0.lastSync) <= freshness }
            .sorted { $0.lastSync > $1.lastSync }
    }

    // MARK: - The base after a sync

    /// The base a sync leaves (S-013): the published state from step 1, with every markup,
    /// reply and page scale this sync applied replaced by what the document holds for it now
    /// (removed when the document no longer holds it).
    /// `unpublished` counts what the document holds beyond that — edits made while the sync ran.
    static func base(
        published: (markups: [ZPDFContracts.MarkupRecord], replies: [SharedReviewSyncPlanner.LocalReply], scales: [SharedPageScale]),
        after: (markups: [ZPDFContracts.MarkupRecord], replies: [UUID: Bool], scales: [PageID: SharedPageScale]),
        appliedMarkups: Set<MarkupID>,
        appliedReplies: Set<UUID>,
        installedScalePages: Set<PageID>
    ) -> (markups: [MarkupID: MarkupRegisters], replies: [UUID: Bool], pageScales: [PageID: SharedPageScale], unpublished: Int) {
        let afterByID = Dictionary(after.markups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var markups = Dictionary(published.markups.map { ($0.id, MarkupRegisters(record: $0)) }, uniquingKeysWith: { first, _ in first })
        // What the sync touched: the markups it added, changed and removed; every markup on a page
        // whose scale it installed (the scale version and derivation are restamped); and the
        // parents and cutouts of those, whose links move with them.
        var touched = appliedMarkups
        let everyRecord = published.markups + after.markups
        for record in everyRecord where installedScalePages.contains(record.pageID) { touched.insert(record.id) }
        for record in everyRecord where touched.contains(record.id) {
            if let parent = record.parentMarkupID { touched.insert(parent) }
            touched.formUnion(record.cutoutMarkupIDs)
        }
        for id in touched { markups[id] = afterByID[id].map(MarkupRegisters.init(record:)) }

        var replies = Dictionary(published.replies.map { ($0.reply.id, $0.retracted) }, uniquingKeysWith: { first, _ in first })
        for id in appliedReplies { replies[id] = after.replies[id] }

        var scales = Dictionary(published.scales.map { ($0.pageID, $0) }, uniquingKeysWith: { first, _ in first })
        for page in installedScalePages { scales[page] = after.scales[page] }

        var unpublished = after.markups.filter { markups[$0.id] != MarkupRegisters(record: $0) }.count
        unpublished += markups.keys.filter { afterByID[$0] == nil }.count
        unpublished += after.replies.filter { replies[$0.key] != $0.value }.count
        unpublished += after.scales.values.filter { scale in !(scales[scale.pageID].map { $0.measuresLike(scale) } ?? false) }.count
        unpublished += scales.keys.filter { after.scales[$0] == nil }.count
        return (markups, replies, scales, unpublished)
    }

    // MARK: - Mapping

    /// Everybody's operations merged, with every markup opened as this build opens a saved one
    /// (``SavedMarkupRepair``): the merge a sync and a `.zpdfreview` import both read.
    ///
    /// A colleague on a build from before X-042 can publish an Arc Length at four points — added,
    /// or moved. This build's engine refuses a fourth point, and the refusal rolled back the whole
    /// sync on every attempt for as long as the colleague's record stood. Opened here, it arrives
    /// as the three points it was measured on, compares with the document's own three, and only a
    /// real change becomes a command (X-042, cycle 2).
    static func merged(_ operations: [ReviewOperation]) -> MergedReview {
        var merged = MergedReview.merge(operations)
        merged.markups = SavedMarkupRepair.opened(merged.markups)
        return merged
    }

    static func localReplies(_ review: AppReviewPresenter) -> [SharedReviewSyncPlanner.LocalReply] {
        review.entries.compactMap { entry in
            guard entry.kind == ReviewEntryRecord.Kind.reply.rawValue,
                  let id = UUID(uuidString: entry.id), let markup = UUID(uuidString: entry.markupId) else { return nil }
            return SharedReviewSyncPlanner.LocalReply(
                reply: SharedReply(
                    id: id, markupID: MarkupID(markup), authorName: entry.authorName, body: entry.body,
                    createdAt: PersistenceTimestamp.date(from: entry.createdAt) ?? Date(timeIntervalSince1970: 0)
                ),
                retracted: entry.retracted
            )
        }
    }

    /// Document commands that turn the local markups into the merged ones.
    ///
    /// Each changed register maps to the command a person would have used, so the undo step, the
    /// History and the recomputed quantities are exactly what a local edit produces. A change this
    /// build has no in-place command for — a markup's identity, layer, symbol or claim — is left
    /// alone and counted, never forced through a delete and re-add that would take cutouts with it.
    ///
    /// A markup set aside with a sheet removed from this copy's set, or arriving on one, is left
    /// until the sheet is back (T-020). A Project Zone, Scale Region or scale this copy does not
    /// hold is never named in a command (T-021). Both are counted in the plan for the note.
    static func commands(
        for changes: SharedReviewSyncPlanner.LocalChanges,
        context: ReviewApplyContext
    ) -> ReviewApplyPlan {
        var plan = ReviewApplyPlan()
        var unlock: [DocumentCommand] = []
        var body: [DocumentCommand] = []
        var lock: [DocumentCommand] = []
        let local = context.local
        func isLive(_ id: MarkupID) -> Bool { local[id] != nil && !context.setAside.contains(id) }

        // Parents before their cutouts.
        let added = changes.added.sorted { ($0.parentMarkupID == nil ? 0 : 1) < ($1.parentMarkupID == nil ? 0 : 1) }
        var placed: Set<MarkupID> = []
        for arriving in added {
            // Opened as a saved record is (X-042): a caller that did not merge through `merged`
            // still never sends a four-point Arc Length the engine refuses.
            var record = SavedMarkupRepair.opened(arriving)
            // A markup on a sheet this copy has removed from the set, or never held, waits for the
            // sheet: added live it would count in a ledger whose sheet is gone, and one whose id is
            // set aside here would exist twice (T-020).
            guard !context.setAside.contains(record.id), context.livePages.contains(record.pageID) else {
                plan.onRemovedSheets.insert(record.id)
                plan.skippedAdds.insert(record.id)
                continue
            }
            // A Project Zone this copy does not hold is not written: the save's foreign key would
            // refuse it (T-021). The markup comes in unfiled, and the note says so.
            func fileOnlyInHeldZones() {
                guard let zone = record.zoneID, !context.zones.contains(zone) else { return }
                record.zoneID = nil
                plan.missingStructure.insert(record.id)
            }
            if let parent = record.parentMarkupID {
                // `addCutout` gives the cutout its parent's page, scale and region; one whose parent
                // did not come in waits with it.
                guard isLive(parent) || placed.contains(parent) else {
                    if plan.onRemovedSheets.contains(parent) {
                        plan.onRemovedSheets.insert(record.id)
                    } else if plan.missingStructure.contains(parent) {
                        plan.missingStructure.insert(record.id)
                    } else {
                        plan.unsupported.insert(record.id)
                    }
                    plan.skippedAdds.insert(record.id)
                    continue
                }
                fileOnlyInHeldZones()
                body.append(.addCutout(parent: parent, cutout: record))
                placed.insert(record.id)
                continue
            }
            fileOnlyInHeldZones()
            if let region = record.scaleRegionID {
                if let scale = context.regions[region] {
                    record.scaleID = scale
                } else {
                    // Another copy's region: measured by where it lies among this copy's regions,
                    // or held when it lies across two — never at a scale nobody chose (T-021).
                    plan.missingStructure.insert(record.id)
                    switch context.placement(of: record) {
                    case let .region(here, scale):
                        record.scaleRegionID = here
                        record.scaleID = scale
                    case .pageDefault:
                        record.scaleRegionID = nil
                        record.scaleID = nil
                    case .held:
                        plan.skippedAdds.insert(record.id)
                        continue
                    }
                    record.scaleVersion = nil
                }
            } else if let scale = record.scaleID, !context.scales.contains(scale) {
                // The other machine's own page-scale identity: the page's own scale here measures it.
                record.scaleID = nil
                record.scaleVersion = nil
            }
            body.append(.addMarkup(record))
            placed.insert(record.id)
        }

        let unsupportedKeys: Set<RegisterKey> = [.identity, .printable, .layer, .symbol, .claim]
        for (arriving, keys) in changes.changed {
            // The shape compared with the document's, and sent, as a saved record opens (X-042).
            let record = SavedMarkupRepair.opened(arriving)
            guard let mine = local[record.id] else { continue }
            // Set aside with a removed sheet: no command reaches it, and none should (T-020).
            guard isLive(record.id), context.livePages.contains(mine.pageID) else {
                plan.onRemovedSheets.insert(record.id)
                continue
            }
            if keys.contains(where: unsupportedKeys.contains) {
                plan.unsupported.insert(record.id)
                continue
            }
            if mine.locked { unlock.append(.setLocked(ids: [record.id], locked: false)) }
            for key in keys {
                switch key {
                case .style: body.append(.changeStyle(id: record.id, style: record.style))
                case .subject: body.append(.editSubject(id: record.id, subject: record.subject))
                case .label: body.append(.editLabel(id: record.id, label: record.label))
                case .comment: body.append(.editComment(id: record.id, comment: record.comment))
                case .caption: body.append(.editText(id: record.id, text: record.caption ?? ""))
                case .status: body.append(.batchStatusChange(ids: [record.id], status: record.status))
                case .hidden: body.append(.setHidden(ids: [record.id], hidden: record.hidden))
                case .zone:
                    // A zone this copy does not hold threw, rolled the batch back and refused every
                    // later sync the same way (T-021). The filing is left as it is here.
                    if let zone = record.zoneID, !context.zones.contains(zone) {
                        plan.missingStructure.insert(record.id)
                    } else {
                        body.append(.setMarkupZone(ids: [record.id], zoneID: record.zoneID))
                    }
                case .customValues:
                    let columns = Set(record.customValues.keys).union(mine.customValues.keys)
                    for column in columns.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString })
                    where record.customValues[column] != mine.customValues[column] {
                        body.append(.editCustomValue(id: record.id, column: column, value: record.customValues[column] ?? .empty))
                    }
                case .shape:
                    var region = record.scaleRegionID
                    if context.namesForeignRegion(record) {
                        plan.missingStructure.insert(record.id)
                        switch context.placement(of: record) {
                        case let .region(here, _): region = here
                        case .pageDefault: region = nil
                        case .held: continue   // the shape is left as it is here
                        }
                    }
                    // No scale travels: a region's own scale, or the page's own scale, measures it.
                    // The other machine's page-scale identity refused every sync (T-021).
                    if region != mine.scaleRegionID {
                        body.append(.setMarkupScaleRegion(ids: [record.id], regionID: region, scaleID: nil))
                    }
                    if let geometry = record.geometry, geometry != mine.geometry {
                        body.append(.editVertices(id: record.id, geometry: geometry))
                    }
                    if let parameters = record.parameters, parameters != mine.parameters {
                        body.append(.editParameters(id: record.id, parameters: parameters))
                    }
                case .stamp:
                    if let degrees = record.stamp?.rotationDegrees, degrees != mine.stamp?.rotationDegrees {
                        body.append(.rotateStamp(id: record.id, degrees: degrees))
                    }
                case .locked, .identity, .printable, .layer, .symbol, .claim:
                    break
                }
            }
            if record.locked { lock.append(.setLocked(ids: [record.id], locked: true)) }
        }

        // A removed parent takes its cutouts with it (TakeoffSession.applyRemove), and the other
        // participant's publish lists those cutouts as removed too. Sending their own
        // `.removeMarkup` after the parent's threw `unknownMarkup`, rolled the whole batch back,
        // and — since the base only moves on a successful apply — refused every later sync the
        // same way whenever the parent's UUID sorted first (S-025).
        let removedSet = Set(changes.removed)
        for id in changes.removed {
            // Set aside with a removed sheet: it waits for the sheet like every other change (T-020).
            if context.setAside.contains(id) {
                plan.onRemovedSheets.insert(id)
                plan.skippedRemovals.insert(id)
                continue
            }
            if let parent = local[id]?.parentMarkupID, removedSet.contains(parent) { continue }
            if local[id]?.locked == true { unlock.append(.setLocked(ids: [id], locked: false)) }
            body.append(.removeMarkup(id))
        }
        plan.commands = unlock + body + lock
        return plan
    }

    static func map(_ error: SharedReviewFolder.FolderError) -> SyncError {
        switch error {
        case .otherProject(let name): return .otherProject(name)
        case .newerFormat: return .newerFormat
        case .unwritable(let reason): return .unwritable(reason)
        case .invalidParticipant: return .refused("participant")
        case .unreadable(let files): return .refused(unreadableDetail(files))
        case .logFull:
            return .refused(NSLocalizedString(
                "your log in the shared review folder has reached its size limit, even compacted",
                comment: "Shared review refusal detail: this person's operation log is full; completes 'The changes could not be applied: %@.'"))
        }
    }

    // MARK: - Reading the folder

    /// Every log in the folder, read and decoded off the main actor through this folder's cache.
    private func readFolder(_ folder: SharedReviewFolder) async -> SharedReviewFolder.Contents {
        let reader = readFile
        let key = folderURL.standardizedFileURL.path
        let cache = Self.logCaches[key] ?? SharedReviewFolder.LogCache()
        let (contents, updated) = await Task.detached(priority: .userInitiated) {
            var cache = cache
            let contents = folder.readAll(cache: &cache, read: reader)
            return (contents, cache)
        }.value
        Self.logCaches[key] = updated
        return contents
    }

    /// Why a read of the folder may not be merged, or `nil` when every log in it was read.
    static func refusal(for contents: SharedReviewFolder.Contents) -> SyncError? {
        if contents.isFolderUnreadable {
            return .refused(NSLocalizedString(
                "the shared review folder could not be read, so nobody's changes could be",
                comment: "Shared review refusal detail: the participants folder could not be listed; completes 'The changes could not be applied: %@.'"))
        }
        guard !contents.unreadableLogs.isEmpty else { return nil }
        return .refused(unreadableDetail(contents.unreadableLogs.map { "\($0).\(SharedReviewFolder.logExtension)" }))
    }

    /// "the shared review log “bo-mac.zlog” could not be read in full, …", naming the files.
    static func unreadableDetail(_ files: [String]) -> String {
        let names = AppLanguageList.joined(files.sorted().map { "“\($0)”" })
        if files.count == 1 {
            return String(format: NSLocalizedString(
                "the shared review file %@ could not be read in full, and going on without it would remove what it holds from this project",
                comment: "Shared review refusal detail: one unreadable file in the folder, quoted; completes 'The changes could not be applied: %@.'"), names)
        }
        return String(format: NSLocalizedString(
            "the shared review files %@ could not be read in full, and going on without them would remove what they hold from this project",
            comment: "Shared review refusal detail: several unreadable files in the folder, quoted; completes 'The changes could not be applied: %@.'"), names)
    }
}

/// A participant's base, as a value the app can store and restore without importing the engine.
public struct SharedReviewBaseValue: Codable, Hashable, Sendable {
    var value: SharedReviewBase

    public init(participantID: String) {
        value = SharedReviewBase(participantID: participantID)
    }

    init(value: SharedReviewBase) {
        self.value = value
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decoded(_ data: Data) -> SharedReviewBaseValue? { try? JSONDecoder().decode(Self.self, from: data) }
}

extension AppReviewPresenter {

    /// Sets a reply's withdrawal as another participant did, with no undo step of this person's.
    public func setRetractedWithoutUndo(_ id: UUID, _ retracted: Bool) {
        applyRetraction(id.uuidString, retracted)
    }
}
