import Foundation
import ZPDFContracts
import ZPDFPersistence

/// What one exported row can say about where its number came from (feature 16).
///
/// The strings are finished: an exporter appends them and does not interpret them. ``scaleText``
/// in particular is either the scale the measurement was taken under or the word
/// ``MeasurementTraceResolver/unknownText``, and there is no third answer.
public struct MeasurementTraceFacts: Hashable, Sendable {
    public let markupID: MarkupID
    /// The page's label — "A-40", not "page 3".
    public let sheetLabel: String
    /// The scale in force **for this markup's page at the moment it was measured**, rendered.
    /// `nil` when that transform is not recoverable. Never today's scale.
    public let scaleAtMeasureTime: String?
    /// The Scale Region the measurement fell inside, when it was measured in one.
    public let scaleRegionLabel: String?
    public let createdAt: Date
    /// When the current measurement was taken. Re-measuring moves it forward.
    public let measuredAt: Date
    public let author: String
    /// How the geometry was captured, in words — "drawn by hand", "traced, 1 closing line
    /// 25.4 pt" (ADR-0031). `nil` for a markup with no measurement.
    public let capture: String?

    public init(
        markupID: MarkupID,
        sheetLabel: String,
        scaleAtMeasureTime: String?,
        scaleRegionLabel: String?,
        createdAt: Date,
        measuredAt: Date,
        author: String,
        capture: String? = nil
    ) {
        self.markupID = markupID
        self.sheetLabel = sheetLabel
        self.scaleAtMeasureTime = scaleAtMeasureTime
        self.scaleRegionLabel = scaleRegionLabel
        self.createdAt = createdAt
        self.measuredAt = measuredAt
        self.author = author
        self.capture = capture
    }

    public var scaleText: String {
        scaleAtMeasureTime ?? MeasurementTraceResolver.unknownText
    }

}

/// Resolves the provenance of a measurement without ever guessing it.
///
/// # The rule this type exists for
///
/// It must never report a scale the measurement was not taken at. A markup measured before a
/// recalibration carries the scale it *was* measured at, or the trace is a lie that looks like
/// provenance.
///
/// The contract stores a scale **identifier and a version** on a markup (`MarkupRecord.scaleID`, `.scaleVersion`), and on its `MeasurementProvenance` (ADR-0007 §1) — never the matrix. A
/// recalibration produces a *new version* of the same `ScaleID` and leaves the markup pointing at
/// the old one, which is how `MarkupRecord.isMeasurementStale(against:)` can tell.
///
/// So every lookup here is keyed on identity **and version together** (``ScaleVersion``). A scale
/// whose version does not match is a different scale, and is not used. When no version matches,
/// the answer is ``unknownText`` — not the page's current scale, not the document's, not the
/// nearest version. That single decision is the whole feature: it is why
/// ``resolveScale(for:sources:)`` takes `[ScaleVersion: ScaleTransform]` and not
/// `[ScaleID: ScaleTransform]`, so the unsafe lookup is not expressible.
///
/// # Where the answer comes from, in order
///
/// 1. `MeasurementProvenance` on the markup's own result — the recording made at calculation time.
/// 2. The markup's stored `scaleID` + `scaleVersion`.
/// 3. The append-only audit trail: the `scale_id`/`scale_version` on the entry that created or
///    last re-measured this markup (ADR-0007 §2).
/// 4. `unknown`.
public struct MeasurementTraceResolver: Sendable {

    /// What a trace prints for a scale it could not recover. It matches
    /// `ZPDFExport.ExportRowTrace.unknownText`; the two packages do not depend on each other, and
    /// `MeasurementTraceTests` pins the spelling so they cannot drift apart silently.
    public static let unknownText = "unknown"

    /// A scale identity *and* the version of it. The pair, never the identifier alone.
    public struct ScaleVersion: Hashable, Sendable {
        public let id: ScaleID
        public let version: Int

        public init(id: ScaleID, version: Int) {
            self.id = id
            self.version = version
        }

        public init(_ scale: ScaleTransform) {
            self.init(id: scale.id, version: scale.version)
        }
    }

    /// Everything the resolver is allowed to look at. There is no ambient "current scale" here,
    /// and that absence is deliberate.
    public struct Sources: Sendable {
        public var pageLabels: [PageID: String]
        /// Every scale transform this session knows, current and superseded, keyed by identity
        /// and version. A version that is not in this map cannot be reported.
        public var scales: [ScaleVersion: ScaleTransform]
        public var scaleRegionNames: [ScaleRegionID: String]
        /// The scale identity and version recorded against each markup in the audit trail.
        public var auditScaleVersions: [MarkupID: ScaleVersion]
        /// When each markup was last created, modified or rescaled according to the audit trail.
        public var auditMeasuredAt: [MarkupID: Date]
        /// Each page's `/UserUnit`, so a scale's ratio is the nominal one its sheet is drawn at
        /// (CR-128, BH-092). A page absent from the map declares none and is `1`.
        public var pageUserUnits: [PageID: Double]

        public init(
            pageLabels: [PageID: String] = [:],
            scales: [ScaleVersion: ScaleTransform] = [:],
            scaleRegionNames: [ScaleRegionID: String] = [:],
            auditScaleVersions: [MarkupID: ScaleVersion] = [:],
            auditMeasuredAt: [MarkupID: Date] = [:],
            pageUserUnits: [PageID: Double] = [:]
        ) {
            self.pageUserUnits = pageUserUnits
            self.pageLabels = pageLabels
            self.scales = scales
            self.scaleRegionNames = scaleRegionNames
            self.auditScaleVersions = auditScaleVersions
            self.auditMeasuredAt = auditMeasuredAt
        }

        /// Indexes scale transforms by identity and version.
        public static func index(_ scales: [ScaleTransform]) -> [ScaleVersion: ScaleTransform] {
            Dictionary(scales.map { (ScaleVersion($0), $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    public init() {}

    // MARK: - Facts

    public func facts(for record: ZPDFContracts.MarkupRecord, sources: Sources) -> MeasurementTraceFacts {
        MeasurementTraceFacts(
            markupID: record.id,
            sheetLabel: sources.pageLabels[record.pageID] ?? "",
            scaleAtMeasureTime: resolveScale(for: record, sources: sources),
            scaleRegionLabel: record.scaleRegionID.flatMap { sources.scaleRegionNames[$0] },
            createdAt: record.createdAt,
            measuredAt: measuredAt(for: record, sources: sources),
            author: record.author,
            capture: record.measurement?.provenance.map { CaptureDescription.text($0.capture) }
        )
    }

    public func facts(
        for records: [ZPDFContracts.MarkupRecord],
        sources: Sources
    ) -> [MarkupID: MeasurementTraceFacts] {
        Dictionary(
            records.map { ($0.id, facts(for: $0, sources: sources)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - The scale

    /// - Returns: the rendered scale the measurement was taken under, or `nil`.
    public func resolveScale(for record: ZPDFContracts.MarkupRecord, sources: Sources) -> String? {
        for key in candidateVersions(for: record, sources: sources) {
            if let scale = sources.scales[key] {
                return Self.text(for: scale, userUnit: scale.pageID.flatMap { sources.pageUserUnits[$0] } ?? 1)
            }
        }
        // Every recorded version is one this session does not hold. The scale is gone, and the
        // honest export says so. Falling back to `record.scaleID` alone, or to the page's current
        // scale, would print a ratio the measurement was never taken at.
        return nil
    }

    /// The scale versions this markup could have been measured under, best evidence first.
    func candidateVersions(for record: ZPDFContracts.MarkupRecord, sources: Sources) -> [ScaleVersion] {
        var candidates: [ScaleVersion] = []
        if let provenance = record.measurement?.provenance {
            candidates.append(ScaleVersion(id: provenance.scaleID, version: provenance.scaleVersion))
        }
        if let id = record.scaleID, let version = record.scaleVersion {
            candidates.append(ScaleVersion(id: id, version: version))
        }
        if let audited = sources.auditScaleVersions[record.id] {
            candidates.append(audited)
        }
        // Distinct, order preserved: the same pair recorded twice is one candidate.
        var seen: Set<ScaleVersion> = []
        return candidates.filter { seen.insert($0).inserted }
    }

    /// A scale's own label when it has one — "Calibrated on grid line A" says more than a ratio —
    /// and its `1:n` otherwise.
    static func text(for scale: ScaleTransform, userUnit: Double = 1) -> String {
        if let label = scale.label, !label.isEmpty { return label }
        return ScaleBridge.ratioText(for: scale, userUnit: userUnit)
    }

    // MARK: - The date

    /// When this row's *current* measurement was taken.
    ///
    /// The provenance's `computedAt` is the calculation's own timestamp and is the truth when it
    /// is there. The audit trail is next, because a re-measure appends an entry. `modifiedAt` is
    /// the fallback, and `createdAt` only when nothing else exists.
    public func measuredAt(for record: ZPDFContracts.MarkupRecord, sources: Sources) -> Date {
        if let computed = record.measurement?.provenance?.computedAt { return computed }
        if let audited = sources.auditMeasuredAt[record.id] { return audited }
        return max(record.modifiedAt, record.createdAt)
    }
}

// MARK: - Reading the audit trail

extension MeasurementTraceResolver.Sources {

    /// Folds an append-only audit trail into the two maps the resolver reads.
    ///
    /// Later entries win, which is what "a re-measured row shows the later date" means: the
    /// trail is ordered by `sequence`, and the last entry that touched a markup's geometry or its
    /// scale is the one that describes the measurement now in the ledger. `compensated` and
    /// `recompensated` entries — undo and redo — are skipped: they record that something was
    /// taken back, not a measurement being taken.
    /// Whether the row's measured values (not its `review.*` text) changed.
    static func measuredValuesDiffer(_ record: MeasurementAuditRecord) -> Bool {
        guard record.beforeValuesJson != record.afterValuesJson else { return false }
        let before = MeasurementAuditStore.measuredValues(try? MeasurementAuditStore.decodeValues(record.beforeValuesJson))
        let after = MeasurementAuditStore.measuredValues(try? MeasurementAuditStore.decodeValues(record.afterValuesJson))
        return before != after
    }

    public mutating func absorb(auditTrail records: [MeasurementAuditRecord]) {
        for record in records.sorted(by: { $0.sequence < $1.sequence }) {
            guard let markup = record.markupId.flatMap({ UUID(uuidString: $0) }).map(MarkupID.init)
            else { continue }
            switch record.auditAction {
            case .markupCreated, .markupRescaled, .scaleChanged:
                break
            case .markupModified:
                // `markup_modified` is also what a label, subject, style, status or zone edit
                // writes. Only one that changed the measured values, or names a scale, re-measured
                // the markup; the rest used to move "measured at" to the time of a label edit
                // (BH-436).
                // Measured keys only: since ADR-0021 (collaboration) the same row can carry
                // `review.*` text for a status or note change, which is not a re-measure.
                guard record.scaleId != nil || Self.measuredValuesDiffer(record) else {
                    continue
                }
            case .markupDeleted, .compensated, .recompensated, .scaleVerified, nil:
                // A scale check (ADR-0030) names no markup and re-measures nothing.
                continue
            }
            if let scaleId = record.scaleId.flatMap({ UUID(uuidString: $0) }),
               let version = record.scaleVersion {
                auditScaleVersions[markup] = MeasurementTraceResolver.ScaleVersion(
                    id: ScaleID(scaleId),
                    version: version
                )
            }
            if let occurred = PersistenceTimestamp.date(from: record.occurredAt) {
                auditMeasuredAt[markup] = occurred
            }
        }
    }

    public func absorbing(auditTrail records: [MeasurementAuditRecord]) -> Self {
        var copy = self
        copy.absorb(auditTrail: records)
        return copy
    }
}
