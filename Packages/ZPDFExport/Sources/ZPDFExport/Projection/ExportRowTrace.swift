import Foundation

/// The provenance one exported row carries beside its numbers (feature 16).
///
/// # Why the scale is a `String?` and not a `ScaleTransform`
///
/// The exporters see an ``ExportProjection`` and nothing else, so this type cannot go looking for
/// a scale; the caller resolves it and hands it over. That is deliberate, because the resolution
/// is the whole hazard. A markup measured before a recalibration was measured at the *old* scale,
/// and the ledger stores only a scale identifier and a version, never the matrix. When the caller
/// cannot recover the transform that was actually in force, it passes `nil` and the trace prints
/// ``unknownText`` — never the scale that happens to be in force now. A trace that quietly
/// substitutes today's scale is not provenance, it is a confident wrong number wearing an audit
/// trail.
///
/// `ZPDFAppCore`'s `MeasurementTraceResolver` is the resolver that decides this; it refuses to
/// fall back to the current scale by construction.
public struct ExportRowTrace: Hashable, Sendable {

    /// What the scale column prints when the scale a measurement was taken at is not recoverable.
    public static let unknownText = "unknown"

    /// The trace columns, in order, appended after every existing column of every format.
    public static let columnTitles = [
        "Trace: Sheet",
        "Trace: Scale",
        "Trace: Scale region",
        "Trace: Created",
        "Trace: Measured",
        "Trace: Author",
        // ADR-0031 (NL-AUTO-18): drawn by hand, or proposed by a detector and accepted.
        "Trace: Captured"
    ]

    /// The sheet the markup was drawn on — the page's label, not its index.
    public let sheetLabel: String
    /// The scale **the measurement was taken under**, already rendered ("1:100"). `nil` when the
    /// record does not carry it and the audit trail cannot supply it.
    public let scaleAtMeasureTime: String?
    /// The Scale Region the measurement fell inside, when it was measured in one.
    public let scaleRegionLabel: String?
    /// When the markup was first created.
    public let createdAt: ExportDate?
    /// When this row's *current* measurement was taken. Re-measuring moves this forward;
    /// ``createdAt`` stays where it was.
    public let measuredAt: ExportDate?
    /// Who measured it. A local name, never an account identity.
    public let author: String
    /// How the geometry was captured, in words (ADR-0031): "drawn by hand", "traced, 1 closing
    /// line 25.4 pt", "matched, residual 0.031". Empty when the caller did not say.
    public let capture: String?

    public init(
        sheetLabel: String = "",
        scaleAtMeasureTime: String? = nil,
        scaleRegionLabel: String? = nil,
        createdAt: Date? = nil,
        measuredAt: Date? = nil,
        author: String = "",
        capture: String? = nil
    ) {
        self.sheetLabel = sheetLabel
        self.scaleAtMeasureTime = scaleAtMeasureTime
        self.scaleRegionLabel = scaleRegionLabel
        // Built here rather than taken as an `ExportDate` so a trace assembled by the app tier
        // renders its dates through exactly the same ISO-8601 code every other export date uses.
        self.createdAt = createdAt.map { ExportDate(date: $0, iso8601: ExportProjector.iso8601($0)) }
        self.measuredAt = measuredAt.map { ExportDate(date: $0, iso8601: ExportProjector.iso8601($0)) }
        self.author = author
        self.capture = capture
    }

    /// The trace of a row nothing is known about. Its scale reads ``unknownText``, not blank:
    /// an empty scale cell invites the reader to assume the document scale.
    public static let unknown = ExportRowTrace()

    public var scaleText: String { scaleAtMeasureTime ?? Self.unknownText }
    public var scaleRegionText: String { scaleRegionLabel ?? "" }
    public var createdText: String { createdAt?.iso8601 ?? "" }
    public var measuredText: String { measuredAt?.iso8601 ?? "" }

    /// The field strings, parallel to ``columnTitles``.
    public var fieldTexts: [String] {
        [sheetLabel, scaleText, scaleRegionText, createdText, measuredText, author, capture ?? ""]
    }

    /// What a subtotal or grand-total record writes in the trace columns: nothing. A total was
    /// not measured on a sheet, at a scale, by a person, and saying otherwise would invent a
    /// provenance for a number that has none.
    public static let totalFieldTexts = [String](repeating: "", count: columnTitles.count)
}
