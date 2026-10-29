import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFUIPresentation

/// A committed measurement whose geometry lies in more than one Scale Region.
///
/// The record is held, not created. Spec §10.4's rule is that the application never silently
/// picks a scale, and "silently" includes creating the measurement now and correcting it after
/// the person answers: a row that existed for two seconds with the wrong number is a row an
/// estimator may have read.
public struct PendingScaleRegionCrossing: Sendable, Identifiable {

    /// Identity of the question, which the panel answers by.
    public let id: UUID
    /// The measurement that is waiting.
    public let record: MarkupRecord
    /// The regions the geometry touches, highest priority first.
    public let regionIDs: [ScaleRegionID]
    /// Whether any part of the geometry lies outside every region, so the page default is a
    /// real option rather than a theoretical one.
    public let touchesPageDefault: Bool
    /// The cut, when the geometry is one this build can cut exactly. `nil` means "Split at the
    /// boundary" is not offered — see ``ScaleRegionSplitter``.
    public let splitParts: [ScaleRegionSplitPart]?

    /// Creates a pending crossing.
    public init(
        id: UUID,
        record: MarkupRecord,
        regionIDs: [ScaleRegionID],
        touchesPageDefault: Bool,
        splitParts: [ScaleRegionSplitPart]?
    ) {
        self.id = id
        self.record = record
        self.regionIDs = regionIDs
        self.touchesPageDefault = touchesPageDefault
        self.splitParts = splitParts
    }

    /// Whether "Split at the boundary" may be offered for this crossing.
    public var canSplitAtBoundary: Bool { splitParts != nil }
}

/// One of the three legal outcomes of a crossing, in core vocabulary.
///
/// The panel's ``ScaleRegionCrossingResolution`` is the same three, spelled in presentation
/// types. The app tier translates; neither side imports the other.
public enum ScaleRegionCrossingOutcome: Sendable, Hashable {
    /// Cut the measurement at the boundaries and measure each piece with its own scale.
    case splitAtBoundary
    /// Measure the whole thing with one region's scale, or with the page default for `nil`.
    case useScale(regionID: ScaleRegionID?)
    /// Create nothing.
    case block
}

extension AppCoreEnvironment {

    /// How a commit resolved against the page's Scale Regions.
    enum ScaleRegionDecision {
        /// The geometry lies wholly inside one region; use its scale.
        case region(ScaleRegionID, ScaleID)
        /// The geometry lies outside every region, or the page has none.
        case pageDefault
        /// The geometry spans two or more, and only the person can settle it.
        case ask(PendingScaleRegionCrossing)
    }

    /// Decides which scale a committed measurement is measured with.
    ///
    /// Called on the one commit funnel, so there is no second path by which a measurement can
    /// reach the document with a scale nobody resolved.
    func scaleRegionDecision(for record: MarkupRecord) async -> ScaleRegionDecision {
        guard let geometry = record.geometry else { return .pageDefault }
        // `try?` over an optional-returning throwing call flattens, so this one binding
        // covers both "the page has no regions" and "a boundary the geometry package
        // refuses". Both mean the same thing here: nothing overrides the page default.
        let resolver: ScaleRegionResolver
        do {
            guard let built = try await session.scaleRegionResolver(page: record.pageID) else {
                return .pageDefault
            }
            resolver = built
        } catch {
            // The page's regions could not be evaluated at all. The measurement still lands at
            // the page scale — refusing every measurement on the sheet would be worse — but
            // not silently: spec §10.4 forbids a scale choice nobody was told about.
            reportUnevaluatedScaleRegions(error)
            return .pageDefault
        }

        // The one sampler (R-170): the same points the resolver's own `resolve(geometry:)` uses.
        let points = ScaleRegionResolver.samplePoints(of: geometry, tool: record.tool)   // U-090
        guard !points.isEmpty else { return .pageDefault }
        guard let resolution = try? resolver.resolve(geometry: points) else { return .pageDefault }

        switch resolution {
        case .pageDefault:
            return .pageDefault
        case let .region(id):
            guard let region = await session.scaleRegion(id) else { return .pageDefault }
            return .region(id, region.scaleID)
        case let .ambiguous(ambiguity):
            // Candidate order is the resolver's, which sorts by priority and breaks ties by
            // identifier — the same order on every run and every machine, so the prompt does
            // not reshuffle its options between two attempts at the same measurement.
            let candidates = ambiguity.candidates
            // Chains with or without arcs, and plain areas (ADR-0030 §5.6), through one door.
            let split = ScaleRegionSplitter.isCuttable(record)
                ? ScaleRegionSplitter.split(geometry: geometry, resolver: resolver)
                : nil
            // "Part of it is on the bare sheet" is not answerable from the vertices alone:
            // a length whose two ends sit in two different regions runs across the gap
            // between them, and every vertex it has is inside a region. The cut knows,
            // so the cut is asked whenever there is one.
            // Only a vertex no region claims is on the bare sheet. A vertex in two overlapping
            // regions is `.ambiguous`, which names no single region either, and counting it
            // offered the page default for a geometry that lies wholly inside regions (BH-427).
            let outsideByVertex = points.contains { resolver.resolve(point: $0) == .pageDefault }
            let outsideBySplit = split?.contains { $0.regionID == nil } ?? false
            let outside = outsideByVertex || outsideBySplit
            return .ask(
                PendingScaleRegionCrossing(
                    id: UUID(),
                    record: record,
                    regionIDs: candidates,
                    touchesPageDefault: outside,
                    splitParts: split
                )
            )
        }
    }

    /// Where a measurement that reaches the document by another road than drawing lies among this
    /// copy's Scale Regions: pasted (S-028), imported from a reviewer's PDF (T-025), or arriving
    /// from another copy through Shared Review or a review file (T-021).
    enum ScaleRegionPlacement: Sendable, Hashable {
        /// Wholly inside one region: measured with its scale.
        case region(ScaleRegionID, ScaleID)
        /// Outside every region, or the page has none: the page's own scale.
        case pageDefault
        /// Across two or more: only a person can choose, so the measurement is held (spec §10.4).
        case held
    }

    /// The one decision every such road takes, so none of them can measure at a scale nobody
    /// resolved. The region the record names is ignored: it is where the record came *from* —
    /// another sheet, another copy's region this copy may not have — and the scale that measures
    /// it is the one where it lies here. A markup that measures nothing lies at the page default.
    func scaleRegionPlacement(of record: MarkupRecord) async -> ScaleRegionPlacement {
        guard record.tool != nil else { return .pageDefault }
        var probe = record
        probe.scaleRegionID = nil
        probe.scaleID = nil
        probe.scaleVersion = nil
        switch await scaleRegionDecision(for: probe) {
        case .pageDefault: return .pageDefault
        case let .region(regionID, scaleID): return .region(regionID, scaleID)
        case .ask: return .held
        }
    }

    /// The one identity the unevaluated-regions warning uses, so it replaces itself.
    ///
    /// Its own literal: it used to share `…1A04` with ``columnRefusalWarningID``, and posting
    /// it replaced the once-per-open warning that names a held ledger column (S-032).
    static let unevaluatedScaleRegionsWarningID = UUID(uuidString: "8B0C6E64-4E2A-4C3E-9F2E-4E9E2B7B1A06")!

    /// Says that a measurement was taken at the page scale because the page's Scale Regions
    /// could not be evaluated.
    func reportUnevaluatedScaleRegions(_ error: any Error) {
        document.post(
            AppWarning(
                id: Self.unevaluatedScaleRegionsWarningID,
                severity: .warning,
                title: NSLocalizedString(
                    "The Scale Regions on this page could not be checked.",
                    comment: "Warning headline when a page's Scale Regions cannot be evaluated for a new measurement"
                ),
                message: String(
                    format: NSLocalizedString(
                        "The measurement was taken at the page scale. Check the regions in Scale Regions. %@",
                        comment: "Warning detail when a page's Scale Regions cannot be evaluated; the placeholder is the reason, as a sentence"
                    ),
                    UserFacingRefusal.sentence(for: error)
                ),
                source: NSLocalizedString("Scale Regions", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            )
        )
    }
}
