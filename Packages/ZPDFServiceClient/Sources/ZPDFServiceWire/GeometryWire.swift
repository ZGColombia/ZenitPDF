import Foundation

/// Names shared by the client and the geometry service.
public enum ZPDFGeometryServiceIdentity {
    /// `CFBundleIdentifier` of `GeometryService.xpc`, and the `NSXPCConnection`
    /// service name the app connects with.
    public static let bundleIdentifier = "com.zenitgroup.zenitpdf.GeometryService"
    public static let bundleName = "GeometryService"
}

/// The allow-listed XPC interface of the geometry service. Nothing else is
/// exported: no file paths cross this boundary — the document arrives as an
/// inherited read-only file descriptor, options and results are opaque `Data`
/// (Codable request, hardened-codec extraction), and requests are named by UUID
/// string so they can be cancelled.
@objc public protocol ZPDFGeometryXPCProtocol {
    /// `requestData` is a JSON-encoded ``GeometryWireRequest``. The reply carries
    /// `VectorExtractionCodec` bytes on success, or a ``WireFailure`` bridged
    /// through `NSError` on failure.
    func extractPageGeometry(
        _ requestData: Data,
        fileHandle: FileHandle,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// `requestData` is a JSON-encoded ``RasterWireRequest``. The reply carries
    /// ``RasterWireCodec`` bytes on success — the page's geometry and its gray
    /// pixels — or a ``WireFailure`` bridged through `NSError`.
    ///
    /// Revision Compare's page rasterisation crosses here rather than running in
    /// the application (finding S17-02): the revision drawing is the most
    /// untrusted file the product opens.
    func rasterizePage(
        _ requestData: Data,
        fileHandle: FileHandle,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// `requestData` is a JSON-encoded ``RasterWireRequest``; the reply is a
    /// JSON-encoded ``PageBoxWireReply``. The pixel-free half of the same job.
    func pageBox(
        _ requestData: Data,
        fileHandle: FileHandle,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// `requestData` is a JSON-encoded ``DXFWireRequest``; the descriptor is the `.dxf`. The
    /// reply carries ``DXFWireCodec`` bytes — the sheet the service drew — or a ``WireFailure``.
    /// The application never parses the DXF itself (NL-PLAT-05, round 2).
    func convertDXF(
        _ requestData: Data,
        fileHandle: FileHandle,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    /// Cancels the in-flight request with this UUID string, if it is running.
    func cancelRequest(_ requestID: String)

    /// Liveness probe; replies with the service protocol version.
    func ping(reply: @escaping @Sendable (Int) -> Void)
}

/// One extraction request, as it crosses the wire.
public struct GeometryWireRequest: Sendable, Codable, Hashable {
    public var requestID: UUID
    public var pageIndex: Int
    public var options: GeometryWireOptions
    /// Original file name, carried for error messages only — the service never
    /// touches the path this name came from.
    public var fileName: String
    /// Test hook: the worker sleeps this long before extracting, so a test can
    /// kill it deterministically mid-request. The app-facing facade never sets it.
    public var debugDelayMilliseconds: Int

    public init(
        requestID: UUID = UUID(),
        pageIndex: Int,
        options: GeometryWireOptions = GeometryWireOptions(),
        fileName: String = "document.pdf",
        debugDelayMilliseconds: Int = 0
    ) {
        self.requestID = requestID
        self.pageIndex = pageIndex
        self.options = options
        self.fileName = fileName
        self.debugDelayMilliseconds = debugDelayMilliseconds
    }
}

/// The Codable projection of `VectorExtractionOptions`.
///
/// The real options struct carries a time source (not serialisable, deliberately);
/// the service always runs the system clock. Fields absent here take the library's
/// `.standard` values on the service side, so wire defaults and in-process defaults
/// cannot drift apart.
public struct GeometryWireOptions: Sendable, Codable, Hashable {
    public var flatness: Double?
    public var emitsClipDerivedPrimitives: Bool?
    public var excludesGeometryOutsideClip: Bool?
    public var emitsShapePrimitives: Bool?
    public var includesHiddenOptionalContent: Bool?
    /// The user password of a password-protected drawing (BH-069), so a drawing the person
    /// unlocked gets Vector Snap too. It crosses the boundary inside the request and is
    /// used for that one extraction only: the service never logs, persists or caches it,
    /// the extractor never caches a locked document's result, and every textual rendering
    /// of this value (`description`, `debugDescription`, `Mirror`) redacts it.
    public var password: String?

    public init(
        flatness: Double? = nil,
        emitsClipDerivedPrimitives: Bool? = nil,
        excludesGeometryOutsideClip: Bool? = nil,
        emitsShapePrimitives: Bool? = nil,
        includesHiddenOptionalContent: Bool? = nil,
        password: String? = nil
    ) {
        self.password = password
        self.flatness = flatness
        self.emitsClipDerivedPrimitives = emitsClipDerivedPrimitives
        self.excludesGeometryOutsideClip = excludesGeometryOutsideClip
        self.emitsShapePrimitives = emitsShapePrimitives
        self.includesHiddenOptionalContent = includesHiddenOptionalContent
    }
}

extension GeometryWireOptions: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Never shows the password — only whether one is present.
    public var description: String {
        "GeometryWireOptions(flatness: \(flatness.map(String.init(describing:)) ?? "nil"), "
            + "emitsClipDerivedPrimitives: \(emitsClipDerivedPrimitives.map(String.init(describing:)) ?? "nil"), "
            + "excludesGeometryOutsideClip: \(excludesGeometryOutsideClip.map(String.init(describing:)) ?? "nil"), "
            + "emitsShapePrimitives: \(emitsShapePrimitives.map(String.init(describing:)) ?? "nil"), "
            + "includesHiddenOptionalContent: \(includesHiddenOptionalContent.map(String.init(describing:)) ?? "nil"), "
            + "password: \(password == nil ? "nil" : "<redacted>"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "flatness": flatness as Any,
            "emitsClipDerivedPrimitives": emitsClipDerivedPrimitives as Any,
            "excludesGeometryOutsideClip": excludesGeometryOutsideClip as Any,
            "emitsShapePrimitives": emitsShapePrimitives as Any,
            "includesHiddenOptionalContent": includesHiddenOptionalContent as Any,
            "password": (password == nil ? "nil" : "<redacted>") as Any,
        ])
    }
}
