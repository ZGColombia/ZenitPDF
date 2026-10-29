import Foundation
import ZPDFContracts

extension RegisterKey: CodingKeyRepresentable {}

/// A reply in a review thread, as the Shared Review Folder carries it.
public struct SharedReply: Codable, Hashable, Sendable {
    public var id: UUID
    public var markupID: MarkupID
    public var authorName: String
    public var body: String
    public var createdAt: Date

    public init(id: UUID, markupID: MarkupID, authorName: String, body: String, createdAt: Date) {
        self.id = id
        self.markupID = markupID
        self.authorName = authorName
        self.body = body
        self.createdAt = createdAt
    }
}

/// One line of a participant's operation log (NL-COLLAB-12).
///
/// Operations are facts about the review, not commands against a document: "this markup's status
/// register became Accepted at clock C", never "run Change Status". That is what lets every
/// participant apply everybody's operations in clock order and arrive at the same state.
public struct ReviewOperation: Codable, Hashable, Sendable {

    public enum Payload: Codable, Hashable, Sendable {
        /// Every register of a markup — an add, or a markup brought back by an undo.
        case putMarkup(MarkupRegisters)
        /// Some registers of an existing markup.
        case setRegisters(MarkupID, [RegisterKey: Data])
        /// The markup is gone, until a later ``putMarkup(_:)`` brings it back.
        case removeMarkup(MarkupID)
        case addReply(SharedReply)
        /// Withdraws a reply, or with `false` puts it back (an undone withdrawal).
        case setReplyRetracted(UUID, Bool)
        /// A page's scale became this one (round 2). A build before it skips the line as
        /// unreadable and keeps everything else; the markups on that page then measure under
        /// that participant's own scale until they update.
        case setPageScale(SharedPageScale)
    }

    /// Unique per operation, so a log read twice is applied once.
    public var id: UUID
    public var clock: HLCTimestamp
    /// The participant whose log this line belongs to.
    public var participantID: String
    public var authorName: String
    public var payload: Payload

    public init(id: UUID = UUID(), clock: HLCTimestamp, participantID: String, authorName: String, payload: Payload) {
        self.id = id
        self.clock = clock
        self.participantID = participantID
        self.authorName = authorName
        self.payload = payload
    }
}

/// JSON Lines for operation logs: one operation per line, UTF-8, newline-terminated.
///
/// Reading is forgiving on purpose. A sync client may have delivered only part of a file, so a
/// last line without its newline — or any line that does not parse — is skipped and reported, and
/// everything before it is still read. Sizes are capped because a shared folder is writable by
/// anybody who can reach it.
public enum OperationLogCodec {

    public static let maximumLineBytes = 4 << 20
    public static let maximumLogBytes = 256 << 20

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

    public static func encode(_ operations: [ReviewOperation]) throws -> Data {
        var data = Data()
        for operation in operations {
            let line = try encoder.encode(operation)
            guard line.count <= maximumLineBytes else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "operation too large"])
            }
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    /// The operations a log holds, and how many lines were skipped.
    ///
    /// An operation whose clock is not plausible at `now` — more than
    /// ``HybridLogicalClock/maximumDrift`` in the future, or negative — is skipped and counted
    /// (R-202): observed, it would have moved every participant's clock to wherever it claimed,
    /// and every later edit would have ordered before it.
    public static func decode(_ data: Data, now: Date = Date()) -> (operations: [ReviewOperation], skipped: Int) {
        guard data.count <= maximumLogBytes else { return ([], 1) }
        let lines = decodeLines(data)
        let plausible = lines.operations.filter { HybridLogicalClock.isPlausible($0.clock, now: now) }
        let skipped = lines.malformed + (lines.unterminatedTail ? 1 : 0) + (lines.operations.count - plausible.count)
        return (plausible, skipped)
    }

    /// The complete lines of a log, decoded, before any clock is judged.
    struct Lines: Sendable {
        var operations: [ReviewOperation] = []
        /// Complete lines that did not parse, or were over ``maximumLineBytes``.
        var malformed = 0
        /// How many bytes, from the start of the data, the complete lines take: the offset just
        /// after the last newline. A later read of the same growing log resumes here.
        var consumed = 0
        /// A last line without its newline: a write still arriving. Not an error, not read.
        var unterminatedTail = false
        /// Complete lines examined, parsed or not. The Shared Review sync's decode cost.
        var examined = 0
    }

    /// The complete lines of `data` from byte `offset` on. The clock check is left to the reader
    /// (``decode(_:now:)``), because whether a clock is plausible depends on when it is read and
    /// a decoded log is kept between reads (T-083).
    static func decodeLines(_ data: Data, from offset: Int = 0) -> Lines {
        var lines = Lines()
        lines.consumed = offset
        var start = data.startIndex + offset
        while start < data.endIndex {
            guard let newline = data[start...].firstIndex(of: 0x0A) else {
                lines.unterminatedTail = true
                break
            }
            let line = data[start..<newline]
            start = data.index(after: newline)
            lines.consumed = start - data.startIndex
            guard !line.isEmpty else { continue }
            lines.examined += 1
            guard line.count <= maximumLineBytes,
                  let operation = try? decoder.decode(ReviewOperation.self, from: line)
            else {
                lines.malformed += 1
                continue
            }
            lines.operations.append(operation)
        }
        return lines
    }
}
