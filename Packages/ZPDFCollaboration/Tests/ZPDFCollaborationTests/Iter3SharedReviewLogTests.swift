import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFCollaboration

/// The Shared Review log is appended in place and never
/// rewritten over a log that could not be read (T-078); a log that cannot be read, or is too
/// large, is named instead of merged as empty, and a log at its size cap is compacted (T-079);
/// a FIFO named like a log never reaches the reader (T-081); decoded logs are kept between reads
/// (T-083).
@Suite("Iteration 3 — Shared Review log safety", .serialized)
struct Iter3SharedReviewLogTests {

    static let page = PageID(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
    static let otherPage = PageID(UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!)
    static let document = DocumentID(UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!)
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func folder() throws -> (SharedReviewFolder, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-it3-shared-\(UUID().uuidString)", isDirectory: true)
        let folder = SharedReviewFolder(url: url)
        try folder.prepare(projectID: "P1", projectName: "Tower", now: t0)
        return (folder, url)
    }

    static func cloud(_ id: UUID = UUID(), label: String = "") -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(id), documentID: document, pageID: page, kind: .cloud, label: label, author: "Ada",
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 10)
            ], isClosed: true))]),
            createdAt: t0, modifiedAt: t0
        )
    }

    static func operation(_ payload: ReviewOperation.Payload, millis: Int64, counter: Int32 = 0, node: String, name: String? = nil) -> ReviewOperation {
        ReviewOperation(clock: HLCTimestamp(physicalMillis: millis, counter: counter, node: node),
                        participantID: node, authorName: name ?? node, payload: payload)
    }

    static func log(_ url: URL, _ participant: String) -> URL {
        url.appendingPathComponent("participants/\(participant).zlog")
    }

    // MARK: - T-078: append never rewrites a log it could not read

    /// Old output: the append succeeded, and the log held one operation — the new one. The read
    /// of the unreadable log was taken for an empty log, and the atomic rename (which needs only
    /// the directory's permission) replaced it.
    @Test("T-078: an existing log that cannot be read is refused by append and left exactly as it was")
    func unreadableOwnLogIsNotRewritten() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = (0..<3).map { Self.operation(.removeMarkup(MarkupID(UUID())), millis: Int64(1_790_000_000_000 + $0), node: "ada-mac") }
        try folder.append(first, participant: "ada-mac")
        let log = Self.log(url, "ada-mac")
        let original = try Data(contentsOf: log)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path) }

        let next = Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_001_000, node: "ada-mac")
        #expect(throws: SharedReviewFolder.FolderError.self) { try folder.append([next], participant: "ada-mac") }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        #expect(try Data(contentsOf: log) == original, "the log keeps every line it had")
        #expect(OperationLogCodec.decode(try Data(contentsOf: log), now: Self.t0.addingTimeInterval(86_400)).operations == first)
    }

    @Test("T-078: a log that is not a regular file is refused as unreadable, and left in place")
    func directoryInPlaceOfTheLogIsRefused() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = Self.log(url, "ada-mac")
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        let next = Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_001_000, node: "ada-mac")
        #expect(throws: SharedReviewFolder.FolderError.unreadable(files: ["ada-mac.zlog"])) {
            try folder.append([next], participant: "ada-mac")
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: log.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    /// Old output: two different inodes — every append rewrote the whole log and renamed it
    /// into place, re-uploading the entire history on a synced folder.
    @Test("T-078/T-083: append writes only the new lines, at the end of the same file")
    func appendIsInPlace() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = Self.log(url, "ada-mac")
        let first = Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_000, node: "ada-mac")
        try folder.append([first], participant: "ada-mac")
        let before = try Data(contentsOf: log)
        let inodeBefore = try #require(try FileManager.default.attributesOfItem(atPath: log.path)[.systemFileNumber] as? Int)
        let second = Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_001, node: "ada-mac")
        try folder.append([second], participant: "ada-mac")
        let after = try Data(contentsOf: log)
        let inodeAfter = try #require(try FileManager.default.attributesOfItem(atPath: log.path)[.systemFileNumber] as? Int)
        #expect(inodeAfter == inodeBefore)
        #expect(after.prefix(before.count) == before, "nothing the log held was rewritten")
        #expect(OperationLogCodec.decode(after, now: Self.t0.addingTimeInterval(86_400)).operations == [first, second])
    }

    @Test("T-078: a log whose last line lost its newline gets one before the new lines")
    func unterminatedTailIsClosed() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = Self.log(url, "ada-mac")
        try Data(#"{"half":"#.utf8).write(to: log)
        let next = Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_000, node: "ada-mac")
        try folder.append([next], participant: "ada-mac")
        let decoded = OperationLogCodec.decode(try Data(contentsOf: log), now: Self.t0.addingTimeInterval(86_400))
        #expect(decoded.operations == [next])
        #expect(decoded.skipped == 1, "the damaged line is skipped, not glued to the new one")
    }

    /// Old output: `prepare` returned a new manifest for "OTHER" — the unreadable manifest of
    /// project P1 was taken for a missing one and written over.
    @Test("T-078: a manifest that is there and cannot be read is refused, never written over")
    func unreadableManifestIsNotReplaced() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let manifest = url.appendingPathComponent(SharedReviewFolder.manifestName)
        let original = try Data(contentsOf: manifest)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: manifest.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest.path) }
        #expect(throws: SharedReviewFolder.FolderError.unreadable(files: ["review.json"])) {
            try folder.prepare(projectID: "OTHER", projectName: "Villa")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest.path)
        #expect(try Data(contentsOf: manifest) == original)

        // Damage is refused the same way; a manifest from a newer build still says so.
        try Data("{not json".utf8).write(to: manifest)
        #expect(throws: SharedReviewFolder.FolderError.unreadable(files: ["review.json"])) {
            try folder.prepare(projectID: "P1", projectName: "Tower")
        }
        try Data(#"{"formatVersion":99,"somethingNew":true}"#.utf8).write(to: manifest)
        #expect(throws: SharedReviewFolder.FolderError.newerFormat(99)) {
            try folder.prepare(projectID: "P1", projectName: "Tower")
        }
    }

    // MARK: - T-079: a log that cannot be read is named, not merged as empty

    /// Old output: `operations` held only Ada's line and nothing said Bo's log was missing — the
    /// merge then took every markup Bo had published for removed.
    @Test("T-079: a log the reader refuses, or one over the cap, is named as unreadable")
    func unreadableLogsAreNamed() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        try folder.append([Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_000, node: "ada-mac")], participant: "ada-mac")
        try folder.append([Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_001, node: "bo-mac")], participant: "bo-mac")
        let now = Self.t0.addingTimeInterval(86_400)

        let complete = folder.readAll(now: now)
        #expect(complete.isComplete && complete.logs == ["ada-mac", "bo-mac"] && complete.operations.count == 2)

        // Bo's log is evicted and cannot be fetched: the reader returns nothing for it.
        let evicted = folder.readAll(now: now) { url in
            url.lastPathComponent == "bo-mac.zlog" ? nil : SharedReviewFolder.readLog(url)
        }
        #expect(evicted.unreadableLogs == ["bo-mac"])
        #expect(!evicted.isComplete)
        #expect(evicted.logs == ["ada-mac"])

        // Over the cap: refused on its size, before a byte is read.
        let size = try #require(try FileManager.default.attributesOfItem(atPath: Self.log(url, "bo-mac").path)[.size] as? Int)
        var calls: [String] = []
        let capped = folder.readAll(now: now, limit: size - 1) { url in
            calls.append(url.lastPathComponent)
            return SharedReviewFolder.readLog(url)
        }
        #expect(capped.unreadableLogs.contains("bo-mac"))
        #expect(!calls.contains("bo-mac.zlog"), "an oversized log is refused on its size")
    }

    /// Old output: `operations` empty and no word of a problem, so every known markup merged as
    /// removed.
    @Test("T-079: a participants folder that cannot be listed is reported, not read as empty")
    func unlistableFolderIsReported() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-it3-gone-\(UUID().uuidString)", isDirectory: true)
        let contents = SharedReviewFolder(url: url).readAll()
        #expect(contents.isFolderUnreadable)
        #expect(!contents.isComplete)
    }

    /// Old output: the append grew the log past the cap, and every reader then dropped the
    /// whole log — every markup this person had published — as over 256 MB.
    @Test("T-079: a log the new lines would take past the cap is compacted and still merges the same")
    func appendAtTheCapCompacts() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let registers = MarkupRegisters(record: Self.cloud())
        var history = [Self.operation(.putMarkup(registers), millis: 1_790_000_000_000, node: "ada-mac", name: "Ada")]
        for index in 1...40 {
            let label = try JSONEncoder().encode("label \(index)")
            history.append(Self.operation(.setRegisters(registers.id, [.label: label]), millis: 1_790_000_000_000 + Int64(index), node: "ada-mac", name: "Ada"))
        }
        let now = Self.t0.addingTimeInterval(86_400)
        try folder.append(Array(history.dropLast()), participant: "ada-mac", now: now)
        let log = Self.log(url, "ada-mac")
        let grown = try Data(contentsOf: log)
        let expected = MergedReview.merge(history)

        // A cap the plain append would pass, but the compacted log fits.
        try folder.append([history.last!], participant: "ada-mac", now: now, limit: grown.count)
        let compacted = try Data(contentsOf: log)
        #expect(compacted.count <= grown.count)
        let read = folder.readAll(now: now)
        #expect(read.isComplete)
        #expect(read.operations.count == 2, "the put and the newest label are all the merge needs")
        #expect(MergedReview.merge(read.operations) == expected)

        // A cap even the compacted log passes: refused, and the log is left as it was.
        #expect(throws: SharedReviewFolder.FolderError.logFull) {
            try folder.append([Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_001_000, node: "ada-mac")],
                              participant: "ada-mac", now: now, limit: 64)
        }
        #expect(try Data(contentsOf: log) == compacted)
    }

    @Test("T-079: compaction keeps the merge of everybody's logs exactly, over many random histories")
    func compactionPreservesTheMerge() {
        var generator = Iter3SeededGenerator(seed: 0x5EED_0079)
        let markups = (0..<4).map { _ in MarkupRegisters(record: Self.cloud()) }
        let replies = (0..<3).map { _ in UUID() }
        let keys: [RegisterKey] = [.label, .comment, .status, .style, .hidden]
        let pages = [Self.page, Self.otherPage]
        let now = Date(timeIntervalSince1970: 1_790_000_100)
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)

        func randomOperation(node: String, millis: Int64, counter: Int32) -> ReviewOperation {
            let markup = markups[Int.random(in: 0..<markups.count, using: &generator)]
            let reply = replies[Int.random(in: 0..<replies.count, using: &generator)]
            let payload: ReviewOperation.Payload
            switch Int.random(in: 0..<6, using: &generator) {
            case 0: payload = .putMarkup(markup)
            case 1:
                let key = keys[Int.random(in: 0..<keys.count, using: &generator)]
                payload = .setRegisters(markup.id, [key: Data("\(node)-\(millis)-\(counter)".utf8)])
            case 2: payload = .removeMarkup(markup.id)
            case 3: payload = .addReply(SharedReply(id: reply, markupID: markup.id, authorName: node, body: "\(node) \(millis)", createdAt: Self.t0))
            case 4: payload = .setReplyRetracted(reply, Bool.random(using: &generator))
            default:
                let factor = Decimal(Int.random(in: 1...9, using: &generator))
                payload = .setPageScale(SharedPageScale(
                    pageID: pages[Int.random(in: 0..<pages.count, using: &generator)],
                    matrix: AffineScaleMatrix(a: factor, b: 0, c: 0, d: factor), units: .metric, label: nil, source: .preset))
            }
            return ReviewOperation(clock: HLCTimestamp(physicalMillis: millis, counter: counter, node: node),
                                   participantID: node, authorName: "\(node) \(millis)", payload: payload)
        }

        for _ in 0..<200 {
            var own: [ReviewOperation] = []
            var other: [ReviewOperation] = []
            for index in 0..<Int.random(in: 1...40, using: &generator) {
                // Mostly settled clocks, some after `now`, the two logs interleaved in time.
                let millis = nowMillis - 50_000 + Int64(Int.random(in: 0...60_000, using: &generator))
                own.append(randomOperation(node: "ada-mac", millis: millis, counter: Int32(index)))
            }
            for index in 0..<Int.random(in: 0...20, using: &generator) {
                let millis = nowMillis - 50_000 + Int64(Int.random(in: 0...60_000, using: &generator))
                other.append(randomOperation(node: "bo-mac", millis: millis, counter: Int32(index)))
            }
            let compacted = ReviewLogCompaction.compact(own, now: now)
            #expect(compacted.count <= own.count)
            #expect(MergedReview.merge(compacted + other) == MergedReview.merge(own + other))
        }
    }

    // MARK: - T-079 (iteration 3 re-fix): a log already over the cap is compacted by its owner

    /// Ada's edit history, 41 lines: one put and forty label changes.
    static func labelHistory() throws -> [ReviewOperation] {
        let registers = MarkupRegisters(record: cloud())
        var history = [operation(.putMarkup(registers), millis: 1_790_000_000_000, node: "ada-mac", name: "Ada")]
        for index in 1...40 {
            let label = try JSONEncoder().encode("label \(index)")
            history.append(operation(.setRegisters(registers.id, [.label: label]), millis: 1_790_000_000_000 + Int64(index), node: "ada-mac", name: "Ada"))
        }
        return history
    }

    /// Old output: nothing could shrink a log already over the cap. `readAll` refused it on its
    /// size, the sync threw at that read, and the append — the only place compaction ran — was
    /// never reached, so the log stayed refused on every machine, its owner's included.
    @Test("T-079: an own log already over the cap is compacted by its owner, and nobody else's log is touched")
    func ownLogOverTheCapIsCompactedByItsOwner() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Self.t0.addingTimeInterval(86_400)
        let limit = 8 * 1024
        let history = try Self.labelHistory()

        // Written as a build without the cap wrote it, one append per edit, past the limit. A line
        // speaking for Bo, a line over the line cap, damage and a half-written last line are in
        // it too: none of them survives, and none of them stops the compaction.
        var ada = Data()
        for operation in history { ada.append(try OperationLogCodec.encode([operation])) }
        ada.append(try OperationLogCodec.encode([Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_500, node: "bo-mac")]))
        ada.append(Data(repeating: 0x41, count: OperationLogCodec.maximumLineBytes + 1))
        ada.append(Data("\n{not json\n".utf8))
        ada.append(Data(#"{"half":"#.utf8))
        try ada.write(to: Self.log(url, "ada-mac"))
        // Bo's log, over the limit as well.
        let boOperations = (0..<3).map { Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_100 + Int64($0), node: "bo-mac") }
        var bo = try OperationLogCodec.encode(boOperations)
        bo.append(Data(repeating: 0x42, count: limit))
        bo.append(0x0A)
        try bo.write(to: Self.log(url, "bo-mac"))
        #expect(folder.readAll(now: now, limit: limit).unreadableLogs == ["ada-mac", "bo-mac"])

        // Ada compacts her log, and only hers.
        #expect(try folder.compactOwnLogIfOverLimit(participant: "ada-mac", now: now, limit: limit))
        let compacted = try Data(contentsOf: Self.log(url, "ada-mac"))
        #expect(compacted.count <= limit)
        #expect(try Data(contentsOf: Self.log(url, "bo-mac")) == bo, "nobody else's log is rewritten")
        let half = folder.readAll(now: now, limit: limit)
        #expect(half.unreadableLogs == ["bo-mac"], "Bo's log stays refused until Bo compacts it")
        #expect(half.logs == ["ada-mac"])
        #expect(half.skippedLines == 0, "the foreign, overlong, damaged and half-written lines are gone")
        #expect(half.operations.count == 2, "the put and the newest label are all the merge needs")
        #expect(MergedReview.merge(half.operations) == MergedReview.merge(history))

        // Under the limit, nothing is done: the same file, the same bytes.
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: Self.log(url, "ada-mac").path)[.systemFileNumber] as? Int)
        #expect(try !folder.compactOwnLogIfOverLimit(participant: "ada-mac", now: now, limit: limit))
        #expect(try FileManager.default.attributesOfItem(atPath: Self.log(url, "ada-mac").path)[.systemFileNumber] as? Int == inode)
        #expect(try Data(contentsOf: Self.log(url, "ada-mac")) == compacted)
        #expect(try !folder.compactOwnLogIfOverLimit(participant: "cy-mac", now: now, limit: limit), "no log, nothing to do")

        // Bo compacts his own; now every log reads, and the merge is everybody's history.
        #expect(try folder.compactOwnLogIfOverLimit(participant: "bo-mac", now: now, limit: limit))
        let whole = folder.readAll(now: now, limit: limit)
        #expect(whole.isComplete)
        #expect(MergedReview.merge(whole.operations) == MergedReview.merge(history + boOperations))

        // A limit even the compacted log passes: refused, and the log left as it was.
        #expect(throws: SharedReviewFolder.FolderError.logFull) {
            try folder.compactOwnLogIfOverLimit(participant: "ada-mac", now: now, limit: 64)
        }
        #expect(try Data(contentsOf: Self.log(url, "ada-mac")) == compacted)
    }

    /// Old output: a log extended past the real 256 MB cap — as the checker planted it, a sparse
    /// file — was refused by every read, forever.
    @Test("T-079: an own log past the real cap (a sparse file) is compacted back to its lines, streamed")
    func sparseOwnLogPastTheRealCapIsCompacted() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Self.t0.addingTimeInterval(86_400)
        let operations = (0..<3).map { Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_000 + Int64($0), node: "ada-mac") }
        try folder.append(operations, participant: "ada-mac")
        let log = Self.log(url, "ada-mac")
        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: UInt64(OperationLogCodec.maximumLogBytes + 4096))
        try handle.close()
        #expect(folder.readAll(now: now).unreadableLogs == ["ada-mac"])

        #expect(try folder.compactOwnLogIfOverLimit(participant: "ada-mac", now: now))
        #expect(try Data(contentsOf: log) == OperationLogCodec.encode(operations), "the zeros past the data are dropped as a half-written line")
        let read = folder.readAll(now: now)
        #expect(read.isComplete && read.operations == operations && read.skippedLines == 0)
    }

    @Test("T-079: the streamed compaction keeps exactly what the whole-log compaction keeps, whatever the chunks and folds")
    func streamedCompactionEqualsTheWholeLog() throws {
        var generator = Iter3SeededGenerator(seed: 0x5EED_1079)
        let markups = (0..<4).map { _ in MarkupRegisters(record: Self.cloud()) }
        let replies = (0..<3).map { _ in UUID() }
        let now = Date(timeIntervalSince1970: 1_790_000_100)
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        for _ in 0..<60 {
            var log = Data()
            var own: [ReviewOperation] = []
            var other: [ReviewOperation] = []
            for index in 0..<Int.random(in: 1...40, using: &generator) {
                let millis = nowMillis - 50_000 + Int64(Int.random(in: 0...60_000, using: &generator))
                let node = Int.random(in: 0..<5, using: &generator) == 0 ? "bo-mac" : "ada-mac"
                let operation = Self.randomOperation(node: node, millis: millis, counter: Int32(index),
                                                     markups: markups, replies: replies, using: &generator)
                if node == "ada-mac" { own.append(operation) } else { other.append(operation) }
                log.append(try OperationLogCodec.encode([operation]))
                if Int.random(in: 0..<8, using: &generator) == 0 { log.append(Data("{damage}\n".utf8)) }
            }
            // Fold after every line, and feed the log in chunks that cut lines anywhere.
            var compactor = SharedReviewFolder.OwnLogCompactor(participant: "ada-mac", now: now, batchBytes: 1)
            log.withUnsafeBytes { raw in
                var start = 0
                while start < raw.count {
                    let end = min(raw.count, start + Int.random(in: 1...97, using: &generator))
                    compactor.feed(UnsafeRawBufferPointer(rebasing: raw[start..<end]))
                    start = end
                }
            }
            let streamed = compactor.finish(adding: [])
            #expect(compactor.folds == own.count)
            #expect(streamed == ReviewLogCompaction.compact(own, now: now))
            #expect(MergedReview.merge(streamed + other) == MergedReview.merge(own + other))
        }
    }

    static func randomOperation(node: String, millis: Int64, counter: Int32, markups: [MarkupRegisters], replies: [UUID],
                                using generator: inout Iter3SeededGenerator) -> ReviewOperation {
        let markup = markups[Int.random(in: 0..<markups.count, using: &generator)]
        let reply = replies[Int.random(in: 0..<replies.count, using: &generator)]
        let keys: [RegisterKey] = [.label, .comment, .status, .style, .hidden]
        let payload: ReviewOperation.Payload
        switch Int.random(in: 0..<6, using: &generator) {
        case 0: payload = .putMarkup(markup)
        case 1:
            let key = keys[Int.random(in: 0..<keys.count, using: &generator)]
            payload = .setRegisters(markup.id, [key: Data("\(node)-\(millis)-\(counter)".utf8)])
        case 2: payload = .removeMarkup(markup.id)
        case 3: payload = .addReply(SharedReply(id: reply, markupID: markup.id, authorName: node, body: "\(node) \(millis)", createdAt: t0))
        case 4: payload = .setReplyRetracted(reply, Bool.random(using: &generator))
        default:
            let factor = Decimal(Int.random(in: 1...9, using: &generator))
            payload = .setPageScale(SharedPageScale(
                pageID: [page, otherPage][Int.random(in: 0..<2, using: &generator)],
                matrix: AffineScaleMatrix(a: factor, b: 0, c: 0, d: factor), units: .metric, label: nil, source: .preset))
        }
        return ReviewOperation(clock: HLCTimestamp(physicalMillis: millis, counter: counter, node: node),
                               participantID: node, authorName: "\(node) \(millis)", payload: payload)
    }

    // MARK: - T-081: nothing but a regular file reaches the reader

    /// Old output: the reader was handed the FIFO — in the app, the file coordinator's
    /// `coordinate(readingItemAt:)`, which blocks on a FIFO and never returns.
    @Test("T-081: a FIFO or a link named like a log never reaches the reader, and is named as unreadable")
    func specialFilesNeverReachTheReader() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        try folder.append([Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_000, node: "ada-mac")], participant: "ada-mac")
        #expect(mkfifo(Self.log(url, "eve").path, 0o644) == 0)
        try FileManager.default.createSymbolicLink(atPath: Self.log(url, "mallory").path, withDestinationPath: "/dev/zero")
        var calls: [String] = []
        let contents = folder.readAll(now: Self.t0.addingTimeInterval(86_400)) { url in
            calls.append(url.lastPathComponent)
            return SharedReviewFolder.readLog(url)
        }
        #expect(calls == ["ada-mac.zlog"])
        #expect(contents.unreadableLogs == ["eve", "mallory"])
        #expect(contents.logs == ["ada-mac"])
        #expect(SharedReviewFolder.readLog(Self.log(url, "eve")) == nil, "the default reader refuses a FIFO without blocking")
    }

    // MARK: - T-083: decoded logs are kept between reads

    /// Old output: every read decoded every line of every log — 21 lines, then 22, then 22.
    @Test("T-083: an unchanged log is not decoded again, and a grown one decodes only its new lines")
    func cacheDecodesOnlyWhatChanged() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Self.t0.addingTimeInterval(86_400)
        let own = (0..<20).map { Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_000 + Int64($0), node: "ada-mac") }
        try folder.append(own, participant: "ada-mac")
        try folder.append([Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_100, node: "bo-mac")], participant: "bo-mac")

        var cache = SharedReviewFolder.LogCache()
        let first = folder.readAll(now: now, cache: &cache)
        #expect(cache.decodedLineCount == 21)
        let again = folder.readAll(now: now, cache: &cache)
        #expect(cache.decodedLineCount == 21, "nothing changed, nothing decoded")
        #expect(again.operations == first.operations)

        let next = Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_200, node: "ada-mac")
        try folder.append([next], participant: "ada-mac")
        let grown = folder.readAll(now: now, cache: &cache)
        #expect(cache.decodedLineCount == 22, "one new line, one decode")
        #expect(grown.operations == folder.readAll(now: now).operations, "the cached read equals a fresh one")

        // A log replaced by another writer is decoded afresh, whatever it looks like.
        let replaced = [Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_300, node: "bo-mac")]
        try OperationLogCodec.encode(replaced).write(to: Self.log(url, "bo-mac"), options: .atomic)
        let afterReplace = folder.readAll(now: now, cache: &cache)
        #expect(cache.decodedLineCount == 23)
        #expect(afterReplace.operations.filter { $0.participantID == "bo-mac" } == replaced)
    }

    @Test("T-083: a cached log's clocks are judged at every read, never frozen at the first")
    func cachedClocksAreJudgedAtEachRead() throws {
        let (folder, url) = try Self.folder()
        defer { try? FileManager.default.removeItem(at: url) }
        let ahead = Self.operation(.removeMarkup(MarkupID(UUID())), millis: 1_790_000_000_000 + 2 * 86_400_000, node: "bo-mac")
        try folder.append([ahead], participant: "bo-mac")
        var cache = SharedReviewFolder.LogCache()
        let early = folder.readAll(now: Self.t0, cache: &cache)
        #expect(early.operations.isEmpty && early.skippedLines == 1, "two days ahead: not plausible yet")
        let later = folder.readAll(now: Self.t0.addingTimeInterval(2 * 86_400), cache: &cache)
        #expect(later.operations == [ahead] && later.skippedLines == 0)
        #expect(cache.decodedLineCount == 1)
    }
}

/// A small deterministic generator (SplitMix64), so a failing history can be replayed.
struct Iter3SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
