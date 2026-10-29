import Foundation
import ZPDFContracts

/// The review as every participant's operations describe it, merged (NL-COLLAB-12).
///
/// ### The merge
///
/// - Operations are de-duplicated by id and applied in ``HLCTimestamp`` order. That order is total
///   and the same on every machine, so the result does not depend on which log was read first.
/// - Markup registers are last-writer-wins: the later clock's bytes stand.
/// - A markup is present when its newest ``ReviewOperation/Payload/putMarkup(_:)`` is newer than its
///   newest removal. Register writes after a removal are kept (so a later put that revives the
///   markup is whole) but do not revive it on their own.
/// - Replies are a grow-only set; withdrawal is a last-writer-wins flag per reply.
/// - A page's scale is a last-writer-wins register per page. A page never loses its scale
///   through the folder: there is no "remove scale" operation.
///
/// Two participants who hold the same operations compute byte-identical states — the test suite
/// proves it by merging permutations of the same logs.
public struct MergedReview: Codable, Hashable, Sendable {

    public struct ReplyState: Codable, Hashable, Sendable {
        public var reply: SharedReply
        public var retracted: Bool
    }

    /// Present markups, as registers.
    public var markups: [MarkupID: MarkupRegisters] = [:]
    /// When each present markup's registers last changed (the newest clock among them).
    public var modified: [MarkupID: HLCTimestamp] = [:]
    public var replies: [UUID: ReplyState] = [:]
    /// The newest clock among all operations, which the local clock observes before it ticks.
    public var latestClock: HLCTimestamp = .zero
    /// Participant ids that contributed, with the name each last signed.
    public var participants: [String: String] = [:]
    /// Each page's shared scale, newest clock winning.
    public var pageScales: [PageID: SharedPageScale] = [:]

    public init() {}

    public static func merge(_ operations: [ReviewOperation]) -> MergedReview {
        var seen: Set<UUID> = []
        let ordered = operations
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.clock != $1.clock ? $0.clock < $1.clock : $0.id.uuidString < $1.id.uuidString }

        var registers: [MarkupID: [RegisterKey: (clock: HLCTimestamp, data: Data)]] = [:]
        var lastPut: [MarkupID: HLCTimestamp] = [:]
        var lastRemove: [MarkupID: HLCTimestamp] = [:]
        var replies: [UUID: SharedReply] = [:]
        var retracted: [UUID: (clock: HLCTimestamp, value: Bool)] = [:]
        var state = MergedReview()

        for operation in ordered {
            state.latestClock = max(state.latestClock, operation.clock)
            state.participants[operation.participantID] = operation.authorName
            switch operation.payload {
            case .putMarkup(let put):
                lastPut[put.id] = operation.clock
                for (key, data) in put.values {
                    registers[put.id, default: [:]][key] = (operation.clock, data)
                }
            case .setRegisters(let id, let values):
                for (key, data) in values {
                    registers[id, default: [:]][key] = (operation.clock, data)
                }
            case .removeMarkup(let id):
                lastRemove[id] = operation.clock
            case .addReply(let reply):
                if replies[reply.id] == nil { replies[reply.id] = reply }
            case .setReplyRetracted(let id, let value):
                retracted[id] = (operation.clock, value)
            case .setPageScale(let scale):
                // Operations arrive in clock order, so the last write stands.
                state.pageScales[scale.pageID] = scale
            }
        }

        for (id, values) in registers {
            guard let put = lastPut[id] else { continue } // registers of a markup never added
            if let removed = lastRemove[id], removed > put { continue }
            state.markups[id] = MarkupRegisters(id: id, values: values.mapValues(\.data))
            state.modified[id] = values.values.map(\.clock).max() ?? put
        }
        for (id, reply) in replies {
            state.replies[id] = ReplyState(reply: reply, retracted: retracted[id]?.value ?? false)
        }
        return state
    }

    /// The present markups as records, measurement-free, in a stable order.
    public func records() -> [MarkupRecord] {
        markups.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }.compactMap { id in
            let stamp = modified[id].map { Date(timeIntervalSince1970: Double($0.physicalMillis) / 1000) } ?? Date(timeIntervalSince1970: 0)
            return markups[id]?.record(modifiedAt: stamp)
        }
    }
}

/// What one participant has last agreed with the folder: the merged state after their previous
/// sync. Stored on the participant's own machine, never in the folder.
public struct SharedReviewBase: Codable, Hashable, Sendable {
    public var markups: [MarkupID: MarkupRegisters]
    public var replies: [UUID: Bool]
    public var clock: HybridLogicalClock
    /// Each page's scale as last agreed (round 2). A base written before it reads as none agreed,
    /// so the first sync publishes the page scales once.
    public var pageScales: [PageID: SharedPageScale]

    public init(participantID: String) {
        markups = [:]
        replies = [:]
        clock = HybridLogicalClock(node: participantID)
        pageScales = [:]
    }

    enum CodingKeys: String, CodingKey { case markups, replies, clock, pageScales }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        markups = try container.decode([MarkupID: MarkupRegisters].self, forKey: .markups)
        replies = try container.decode([UUID: Bool].self, forKey: .replies)
        clock = try container.decode(HybridLogicalClock.self, forKey: .clock)
        pageScales = try container.decodeIfPresent([PageID: SharedPageScale].self, forKey: .pageScales) ?? [:]
    }
}

/// The two halves of a sync (NL-COLLAB-12): what to publish, then how to bring the local
/// document to the merged state.
public enum SharedReviewSyncPlanner {

    /// A local reply, as the document holds it.
    public struct LocalReply: Hashable, Sendable {
        public var reply: SharedReply
        public var retracted: Bool
        public init(reply: SharedReply, retracted: Bool) {
            self.reply = reply
            self.retracted = retracted
        }
    }

    /// The operations that express what changed locally since `base`.
    ///
    /// A markup the base does not know is put whole; a known one publishes only the registers that
    /// differ; a known one that is gone locally is removed. Replies likewise. Every operation gets
    /// a fresh tick of the participant's clock, which has first observed the folder's newest.
    ///
    /// A base whose clock is beyond the drift bound at `now` agreed with the folder through
    /// operations no reader accepts, this participant included (S-115). Its agreement is void:
    /// the clock restarts from the wall clock and everything held here is published afresh —
    /// every markup put whole, every reply with its withdrawal, every page scale — so the merge
    /// that follows holds this person's work instead of deleting it. Removals the base implies
    /// are still published.
    public static func operationsToPublish(
        local: [MarkupRecord],
        localReplies: [LocalReply],
        base: inout SharedReviewBase,
        observed latest: HLCTimestamp,
        participantID: String,
        authorName: String,
        now: Date,
        localScales: [SharedPageScale] = []
    ) -> [ReviewOperation] {
        let agreementVoid = base.clock.discardImplausibleReading(now: now)
        base.clock.observe(latest, now: now)
        var operations: [ReviewOperation] = []
        func emit(_ payload: ReviewOperation.Payload) {
            operations.append(ReviewOperation(
                clock: base.clock.tick(now: now), participantID: participantID,
                authorName: authorName, payload: payload
            ))
        }
        let localByID = Dictionary(local.map { ($0.id, MarkupRegisters(record: $0)) }, uniquingKeysWith: { first, _ in first })
        for id in localByID.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard let registers = localByID[id] else { continue }
            if !agreementVoid, let known = base.markups[id] {
                let changed = registers.changedKeys(comparedWith: known)
                guard !changed.isEmpty else { continue }
                var values: [RegisterKey: Data] = [:]
                for key in changed { values[key] = registers.values[key] ?? Data() }
                emit(.setRegisters(id, values))
            } else {
                emit(.putMarkup(registers))
            }
        }
        for id in base.markups.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString })
        where localByID[id] == nil {
            emit(.removeMarkup(id))
        }
        for local in localReplies.sorted(by: { $0.reply.id.uuidString < $1.reply.id.uuidString }) {
            if !agreementVoid, let known = base.replies[local.reply.id] {
                if known != local.retracted { emit(.setReplyRetracted(local.reply.id, local.retracted)) }
            } else {
                emit(.addReply(local.reply))
                // A void agreement may have withdrawn or restored the reply unreadably: say which.
                if local.retracted || (agreementVoid && base.replies[local.reply.id] != nil) {
                    emit(.setReplyRetracted(local.reply.id, local.retracted))
                }
            }
        }
        // A scale changed here since the last agreement is published; one that measures like the
        // agreed one is not, whatever its identity or version on this machine.
        for scale in localScales.sorted(by: { $0.pageID.rawValue.uuidString < $1.pageID.rawValue.uuidString }) {
            if !agreementVoid, let known = base.pageScales[scale.pageID], known.measuresLike(scale) { continue }
            emit(.setPageScale(scale))
        }
        return operations
    }

    /// How the local document must change to equal the merged state.
    public struct LocalChanges: Sendable {
        /// Markups the document does not have.
        public var added: [MarkupRecord] = []
        /// Markups the document has, with the registers that differ.
        public var changed: [(record: MarkupRecord, keys: [RegisterKey])] = []
        /// Markups the merged state no longer has.
        public var removed: [MarkupID] = []
        public var newReplies: [SharedReply] = []
        public var retractions: [(id: UUID, retracted: Bool)] = []
        /// Page scales the merged state holds that this machine does not measure by.
        public var scales: [SharedPageScale] = []

        public var isEmpty: Bool {
            added.isEmpty && changed.isEmpty && removed.isEmpty && newReplies.isEmpty && retractions.isEmpty && scales.isEmpty
        }
    }

    /// - Parameter known: the markups the folder has heard of from this participant — the base
    ///   after publishing. Only those can be removed: a markup drawn since the publish is kept
    ///   for the next sync rather than deleted for being absent from the folder.
    public static func localChanges(
        merged: MergedReview,
        local: [MarkupRecord],
        localReplies: [LocalReply],
        known: Set<MarkupID>,
        localScales: [SharedPageScale] = []
    ) -> LocalChanges {
        var changes = LocalChanges()
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in merged.records() {
            if let mine = localByID[record.id] {
                let keys = MarkupRegisters(record: record).changedKeys(comparedWith: MarkupRegisters(record: mine))
                if !keys.isEmpty { changes.changed.append((record, keys)) }
            } else {
                changes.added.append(record)
            }
        }
        for id in localByID.keys where merged.markups[id] == nil && known.contains(id) {
            changes.removed.append(id)
        }
        changes.removed.sort { $0.rawValue.uuidString < $1.rawValue.uuidString }
        let localReplyIDs = Dictionary(localReplies.map { ($0.reply.id, $0.retracted) }, uniquingKeysWith: { first, _ in first })
        for (id, state) in merged.replies.sorted(by: { $0.value.reply.createdAt < $1.value.reply.createdAt }) {
            if let retracted = localReplyIDs[id] {
                if retracted != state.retracted { changes.retractions.append((id, state.retracted)) }
            } else {
                changes.newReplies.append(state.reply)
                if state.retracted { changes.retractions.append((id, true)) }
            }
        }
        let localScaleByPage = Dictionary(localScales.map { ($0.pageID, $0) }, uniquingKeysWith: { first, _ in first })
        for page in merged.pageScales.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard let shared = merged.pageScales[page] else { continue }
            if let mine = localScaleByPage[page], mine.measuresLike(shared) { continue }
            changes.scales.append(shared)
        }
        return changes
    }
}
