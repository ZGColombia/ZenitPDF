import Foundation

/// Length-prefixed frames for the stdio worker transport.
///
/// The `.xpc` bundle path cannot be exercised from `swift test` — an XPC service
/// launches only from inside its host app bundle — so the test transport spawns the
/// same service core as a plain subprocess and speaks these frames over its pipes.
/// The framing is deliberately dumb: 4-byte big-endian length, then that many bytes
/// of JSON. A length above ``maximumBodyBytes`` is a protocol violation and the
/// reader refuses it rather than allocating.
public enum WireFraming {
    /// Payload ceiling. Extraction of the real A1 drawing encodes to ~2 MB; 256 MB
    /// leaves room for pathological-but-legal documents while a corrupted length
    /// field cannot make either side allocate unbounded memory.
    public static let maximumBodyBytes = 256 * 1024 * 1024

    public static func encode(_ frame: some Encodable) throws -> Data {
        let body = try JSONEncoder().encode(frame)
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    public static func decodeBody<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }
}

/// What a request frame asks for.
public enum WireRequestKind: String, Sendable, Codable {
    case geometryExtract
    /// Page rasterisation for Revision Compare (S17-02).
    case geometryRasterize
    /// One page's box and rotation, with no pixels (S17-02).
    case geometryPageBox
    /// A DXF drawn as a PDF sheet (NL-PLAT-05, round 2).
    case geometryDXF
    case repairPerform
    case cancel
    case ping
}

/// One request over the stdio transport.
///
/// `filePath`/`outputPath` exist only on this transport: a subprocess spawned by a
/// test inherits no sandbox, and pipes cannot carry descriptors. The XPC transport
/// never sends paths — it passes `FileHandle`s, and these fields stay nil.
public struct WireRequestFrame: Sendable, Codable {
    public var id: UUID
    public var kind: WireRequestKind
    public var body: Data
    public var filePath: String?
    public var outputPath: String?

    public init(id: UUID = UUID(), kind: WireRequestKind, body: Data = Data(), filePath: String? = nil, outputPath: String? = nil) {
        self.id = id
        self.kind = kind
        self.body = body
        self.filePath = filePath
        self.outputPath = outputPath
    }
}

/// One reply over the stdio transport.
public struct WireReplyFrame: Sendable, Codable {
    public var id: UUID
    public var body: Data?
    public var failure: WireFailure?

    public init(id: UUID, body: Data? = nil, failure: WireFailure? = nil) {
        self.id = id
        self.body = body
        self.failure = failure
    }
}
