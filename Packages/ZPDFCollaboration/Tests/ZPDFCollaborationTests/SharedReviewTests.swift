import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFCollaboration

/// NL-COLLAB-12: the operation log, the clock and the merge behind the Shared Review Folder.
@Suite("Shared Review Folder engine")
struct SharedReviewTests {

    static let page = PageID(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
    static let document = DocumentID(UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!)
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func cloud(_ id: UUID = UUID(), label: String = "") -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(id), documentID: document, pageID: page, kind: .cloud, label: label, author: "Ada",
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10)
            ], isClosed: true))]),
            createdAt: t0, modifiedAt: t0
        )
    }

    // MARK: - Clock

    @Test("The clock never goes backwards, orders same-millisecond events, and follows a remote reading")
    func clockRules() {
        var clock = HybridLogicalClock(node: "a")
        let first = clock.tick(now: Self.t0)
        let second = clock.tick(now: Self.t0)
        let behind = clock.tick(now: Self.t0.addingTimeInterval(-60))
        #expect(first < second && second < behind, "a clock set back an hour still moves forward")
        clock.observe(HLCTimestamp(physicalMillis: first.physicalMillis + 5_000, counter: 7, node: "b"), now: Self.t0)
        let after = clock.tick(now: Self.t0)
        #expect(after.physicalMillis == first.physicalMillis + 5_000)
        #expect(after.counter == 9)
        #expect(HLCTimestamp(physicalMillis: 1, counter: 0, node: "a") < HLCTimestamp(physicalMillis: 1, counter: 0, node: "b"),
                "the node breaks an exact tie the same way everywhere")
    }

    // MARK: - Codec

    @Test("A log round-trips; a half-delivered last line and a garbage line are skipped, the rest read")
    func codecIsForgiving() throws {
        let operations = (0..<3).map { index in
            ReviewOperation(
                clock: HLCTimestamp(physicalMillis: Int64(index), counter: 0, node: "a"),
                participantID: "a", authorName: "Ada", payload: .removeMarkup(MarkupID(UUID()))
            )
        }
        var data = try OperationLogCodec.encode(operations)
        #expect(OperationLogCodec.decode(data).operations == operations)
        data.append(Data("not json\n".utf8))
        data.append(Data(#"{"id":"half"#.utf8))
        let decoded = OperationLogCodec.decode(data)
        #expect(decoded.operations == operations)
        #expect(decoded.skipped == 2)
    }

    // MARK: - Registers

    @Test("A record survives registers exactly, apart from the measurement every participant recomputes")
    func registersRoundTrip() throws {
        var record = Self.cloud(label: "RFI 12")
        record.comment = "Check"
        record.status = .accepted
        record.customValues = [ColumnID(UUID()): .currency(amount: Decimal(string: "12.3456789012345678")!, code: "SEK")]
        let back = try #require(MarkupRegisters(record: record).record(modifiedAt: Self.t0))
        #expect(back == record)
        #expect(MarkupRegisters(record: back) == MarkupRegisters(record: record))
    }

    // MARK: - Merge

    /// Old output: every copy of a project opens its drawing under its own document id, so the
    /// same markup compared as a changed identity and a second import never came up empty.
    @Test("The same markup in two copies of a project is unchanged, whatever each copy's document id")
    func identityIgnoresDocumentID() {
        let mine = Self.cloud()
        var theirs = mine
        theirs.documentID = DocumentID(UUID())
        #expect(MarkupRegisters(record: theirs).changedKeys(comparedWith: MarkupRegisters(record: mine)).isEmpty)
        theirs.author = "Bo"
        #expect(MarkupRegisters(record: theirs).changedKeys(comparedWith: MarkupRegisters(record: mine)) == [.identity])
    }

    @Test("The merge is the same for every order the logs are read in")
    func mergeIsOrderIndependent() {
        let id = UUID()
        var a = HybridLogicalClock(node: "a")
        var b = HybridLogicalClock(node: "b")
        let put = ReviewOperation(clock: a.tick(now: Self.t0), participantID: "a", authorName: "Ada",
                                  payload: .putMarkup(MarkupRegisters(record: Self.cloud(id))))
        var labelled = Self.cloud(id, label: "from Bo")
        labelled.label = "from Bo"
        let label = ReviewOperation(clock: b.tick(now: Self.t0.addingTimeInterval(1)), participantID: "b", authorName: "Bo",
                                    payload: .setRegisters(MarkupID(id), [.label: MarkupRegisters(record: labelled).values[.label]!]))
        var noted = Self.cloud(id)
        noted.comment = "from Ada"
        let comment = ReviewOperation(clock: a.tick(now: Self.t0.addingTimeInterval(1)), participantID: "a", authorName: "Ada",
                                      payload: .setRegisters(MarkupID(id), [.comment: MarkupRegisters(record: noted).values[.comment]!]))
        let all = [put, label, comment]
        let reference = MergedReview.merge(all)
        for permutation in [[label, comment, put], [comment, put, label], [put, comment, label, label]] {
            #expect(MergedReview.merge(permutation) == reference)
        }
        let record = reference.records().first
        #expect(record?.label == "from Bo" && record?.comment == "from Ada", "different fields both survive")
    }

    @Test("A removal hides the markup until a later put brings it back; replies grow, withdrawal is a flag")
    func removeReviveAndReplies() {
        let id = MarkupID(UUID())
        var clock = HybridLogicalClock(node: "a")
        let registers = MarkupRegisters(record: Self.cloud(id.rawValue))
        let reply = SharedReply(id: UUID(), markupID: id, authorName: "Bo", body: "ok", createdAt: Self.t0)
        var operations = [
            ReviewOperation(clock: clock.tick(now: Self.t0), participantID: "a", authorName: "Ada", payload: .putMarkup(registers)),
            ReviewOperation(clock: clock.tick(now: Self.t0), participantID: "a", authorName: "Ada", payload: .addReply(reply)),
            ReviewOperation(clock: clock.tick(now: Self.t0), participantID: "a", authorName: "Ada", payload: .removeMarkup(id)),
            ReviewOperation(clock: clock.tick(now: Self.t0), participantID: "a", authorName: "Ada", payload: .setReplyRetracted(reply.id, true))
        ]
        var merged = MergedReview.merge(operations)
        #expect(merged.markups[id] == nil)
        #expect(merged.replies[reply.id]?.retracted == true, "the thread outlives the markup")
        operations.append(ReviewOperation(clock: clock.tick(now: Self.t0), participantID: "a", authorName: "Ada", payload: .putMarkup(registers)))
        merged = MergedReview.merge(operations)
        #expect(merged.markups[id] == registers)
    }

    // MARK: - Two participants on one folder

    /// A participant: a document (records + replies), a base and a clock, syncing through a folder.
    struct Participant {
        let id: String
        let name: String
        var records: [MarkupID: MarkupRecord] = [:]
        var replies: [UUID: SharedReviewSyncPlanner.LocalReply] = [:]
        var base: SharedReviewBase

        init(id: String, name: String) {
            self.id = id
            self.name = name
            base = SharedReviewBase(participantID: id)
        }

        /// Publish, merge, apply — the whole sync, against the real folder files.
        mutating func sync(_ folder: SharedReviewFolder, now: Date) throws {
            let before = folder.readAll()
            let latest = MergedReview.merge(before.operations).latestClock
            let publish = SharedReviewSyncPlanner.operationsToPublish(
                local: Array(records.values), localReplies: Array(replies.values), base: &base,
                observed: latest, participantID: id, authorName: name, now: now
            )
            try folder.append(publish, participant: id)
            let merged = MergedReview.merge(folder.readAll().operations)
            let known = Set(base.markups.keys).union(records.keys)
            let changes = SharedReviewSyncPlanner.localChanges(
                merged: merged, local: Array(records.values), localReplies: Array(replies.values), known: known
            )
            for record in changes.added { records[record.id] = record }
            for (record, _) in changes.changed { records[record.id] = record }
            for id in changes.removed { records[id] = nil }
            for reply in changes.newReplies { replies[reply.id] = .init(reply: reply, retracted: false) }
            for (replyID, retracted) in changes.retractions { replies[replyID]?.retracted = retracted }
            base.markups = Dictionary(records.map { ($0.key, MarkupRegisters(record: $0.value)) }, uniquingKeysWith: { first, _ in first })
            base.replies = replies.mapValues(\.retracted)
            base.clock.observe(merged.latestClock, now: now)
        }
    }

    static func folder() throws -> (SharedReviewFolder, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-shared-\(UUID().uuidString)", isDirectory: true)
        let folder = SharedReviewFolder(url: url)
        try folder.prepare(projectID: "P1", projectName: "Tower", now: t0)
        return (folder, url)
    }

    /// The acceptance criteria, at the engine: A adds a cloud, B sees it; concurrent edits to
    /// different fields both survive; the same field resolves identically on both; offline B
    /// merges on return; no file is ever written by two participants.
    @Test("Two participants converge: add, different-field edits, same-field edit, offline return")
    func twoParticipantsConverge() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        var ada = Participant(id: "ada-mac", name: "Ada")
        var bo = Participant(id: "bo-mac", name: "Bo")

        let cloud = Self.cloud()
        ada.records[cloud.id] = cloud
        try ada.sync(folder, now: Self.t0)
        try bo.sync(folder, now: Self.t0.addingTimeInterval(1))
        #expect(bo.records[cloud.id]?.kind == .cloud, "B sees A's cloud")

        // Different fields of one markup, concurrently.
        ada.records[cloud.id]?.comment = "Ada's note"
        bo.records[cloud.id]?.status = .rejected
        try ada.sync(folder, now: Self.t0.addingTimeInterval(2))
        try bo.sync(folder, now: Self.t0.addingTimeInterval(3))
        try ada.sync(folder, now: Self.t0.addingTimeInterval(4))
        #expect(ada.records[cloud.id]?.comment == "Ada's note" && ada.records[cloud.id]?.status == .rejected)
        #expect(bo.records[cloud.id]?.comment == "Ada's note" && bo.records[cloud.id]?.status == .rejected)

        // The same field, concurrently: both end with the same answer.
        ada.records[cloud.id]?.label = "A"
        bo.records[cloud.id]?.label = "B"
        try ada.sync(folder, now: Self.t0.addingTimeInterval(5))
        try bo.sync(folder, now: Self.t0.addingTimeInterval(5))
        try ada.sync(folder, now: Self.t0.addingTimeInterval(6))
        #expect(ada.records[cloud.id]?.label == bo.records[cloud.id]?.label)
        #expect(ada.records[cloud.id]?.label == "B", "Bo's clock is later, having observed Ada's")

        // Bo goes offline and works; Ada keeps going; Bo returns.
        let offline = Self.cloud()
        bo.records[offline.id] = offline
        let replyID = UUID()
        bo.replies[replyID] = .init(reply: SharedReply(id: replyID, markupID: cloud.id, authorName: "Bo", body: "done", createdAt: Self.t0), retracted: false)
        ada.records[cloud.id] = nil
        try ada.sync(folder, now: Self.t0.addingTimeInterval(7))
        try ada.sync(folder, now: Self.t0.addingTimeInterval(8))
        try bo.sync(folder, now: Self.t0.addingTimeInterval(9))
        try ada.sync(folder, now: Self.t0.addingTimeInterval(10))
        #expect(Set(ada.records.keys) == Set(bo.records.keys))
        #expect(bo.records[cloud.id] == nil, "Ada's delete reached Bo")
        #expect(ada.records[offline.id] != nil, "Bo's offline markup reached Ada")
        #expect(ada.replies.count == 1 && bo.replies.count == 1, "the thread record survives the markup")
        #expect(ada.records.mapValues { MarkupRegisters(record: $0) } == bo.records.mapValues { MarkupRegisters(record: $0) })

        // One writer per file: each log holds only its own participant's lines.
        let logs = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("participants").path).sorted()
        #expect(logs == ["ada-mac.zlog", "bo-mac.zlog"])
        for log in logs {
            let data = try Data(contentsOf: url.appendingPathComponent("participants").appendingPathComponent(log))
            let owner = String(log.dropLast(5))
            #expect(OperationLogCodec.decode(data).operations.allSatisfy { $0.participantID == owner })
        }
    }

    @Test("A folder that reviews another project is refused; a forged line in someone's log is ignored")
    func folderGuards() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SharedReviewFolder.FolderError.otherProject(name: "Tower")) {
            try folder.prepare(projectID: "OTHER", projectName: "Villa")
        }
        #expect(throws: SharedReviewFolder.FolderError.invalidParticipant) {
            try folder.append([ReviewOperation(clock: .zero, participantID: "../x", authorName: "X", payload: .removeMarkup(MarkupID(UUID())))], participant: "../x")
        }
        // Mallory writes a line into her own log claiming to be Ada.
        let forged = ReviewOperation(clock: HLCTimestamp(physicalMillis: 1, counter: 0, node: "ada-mac"),
                                     participantID: "ada-mac", authorName: "Ada", payload: .removeMarkup(MarkupID(UUID())))
        try OperationLogCodec.encode([forged]).write(to: url.appendingPathComponent("participants/mallory.zlog"))
        let read = folder.readAll()
        #expect(read.operations.isEmpty)
        #expect(read.skippedLines == 1)
    }
}
