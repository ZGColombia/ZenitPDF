import CoreGraphics
import Foundation
import ZPDFPDFKitBridge
import ZPDFVectorExtraction

/// One page of one revision.
public struct RevisionPageReference: Sendable, Hashable {
    public var document: DocumentHandle
    public var pageIndex: Int
    public var box: PDFPageBox
    /// The file the document was opened from. Required only for the vector pass, which
    /// re-scans the content stream with `CGPDFScanner` rather than going through PDFKit.
    public var fileURL: URL?
    /// What the user calls this revision.
    public var label: String

    public init(
        document: DocumentHandle,
        pageIndex: Int,
        box: PDFPageBox = .crop,
        fileURL: URL? = nil,
        label: String
    ) {
        self.document = document
        self.pageIndex = pageIndex
        self.box = box
        self.fileURL = fileURL
        self.label = label
    }
}

/// The automatic path: page-box matching first, Vision only if asked for.
public struct AutoAlignmentPlan: Sendable, Hashable, Codable {
    /// Try to match the two page boxes. Cheap, deterministic and right most of the time.
    public var usesPageBoxMatching: Bool
    public var pageBox: PageBoxAlignmentOptions
    /// Refine with Vision's image registration. Off by default: it costs two full-page
    /// renders' worth of extra work, and on two revisions that came off the same plotter
    /// it has nothing to find.
    public var usesVisionRegistration: Bool
    public var vision: VisionAutoAligner

    public init(
        usesPageBoxMatching: Bool = true,
        pageBox: PageBoxAlignmentOptions = .standard,
        usesVisionRegistration: Bool = false,
        vision: VisionAutoAligner = .standard
    ) {
        self.usesPageBoxMatching = usesPageBoxMatching
        self.pageBox = pageBox
        self.usesVisionRegistration = usesVisionRegistration
        self.vision = vision
    }

    public static let standard = AutoAlignmentPlan()
}

/// How the two pages are to be brought into the same coordinate system.
public enum AlignmentPlan: Sendable, Hashable {
    /// The two pages already share a coordinate system.
    case identity
    /// Page-box matching, optionally refined by Vision. A Vision failure is not an
    /// error: the page-box result (or the identity) stands and the rejection reason is
    /// reported so the UI can offer manual alignment.
    case automatic(AutoAlignmentPlan)
    /// Translation, rotation and uniform scale from the user's point pairs.
    case manualTwoPoint([AlignmentCorrespondence])
    /// The full affine map from the user's point pairs.
    case manualThreePoint([AlignmentCorrespondence])
    /// A transform the caller already has — from a previous session, say.
    case explicit(AlignmentTransform)
}

public struct RevisionCompareRequest: Sendable, Hashable {
    public var baseline: RevisionPageReference
    public var revised: RevisionPageReference
    /// Pixels per PDF point. 2.0 is roughly 144 dpi: enough to see a 0.35 mm pen, cheap
    /// enough for a whole ARCH-D sheet.
    public var renderScale: Double
    public var alignment: AlignmentPlan
    public var raster: RasterDiffOptions
    public var vector: VectorDiffOptions
    /// Run the geometry comparison when both pages have a file URL. When either page has
    /// no vector content the outcome reports ``VectorDiffOutcome/isMeaningful`` false
    /// rather than pretending.
    public var includesVectorSignal: Bool

    public init(
        baseline: RevisionPageReference,
        revised: RevisionPageReference,
        renderScale: Double = 2,
        alignment: AlignmentPlan = .automatic(.standard),
        raster: RasterDiffOptions = .standard,
        vector: VectorDiffOptions = .standard,
        includesVectorSignal: Bool = true
    ) {
        self.baseline = baseline
        self.revised = revised
        self.renderScale = renderScale
        self.alignment = alignment
        self.raster = raster
        self.vector = vector
        self.includesVectorSignal = includesVectorSignal
    }
}

/// Everything one comparison found.
///
/// The two signals stay in separate fields. ``allRegions`` concatenates them for a UI
/// that wants one list, and every element is still tagged with its
/// ``DifferenceRegion/signal``.
public struct RevisionComparisonResult: Sendable {
    public let baselineLabel: String
    public let revisedLabel: String
    public let alignment: AlignmentSolution
    /// Present when the automatic path ran Vision.
    public let autoAlignmentMetrics: AutoAlignmentMetrics?
    /// Present when the automatic path ran Vision and did not accept its answer.
    public let autoAlignmentRejection: AutoAlignmentRejection?
    /// The scale the baseline was actually rendered at: the requested one, or the largest
    /// smaller one at which the sheet fits the raster budget (R-156).
    public let renderScale: Double
    /// The scale the revised page was actually rendered at. Each page is fitted to the budget
    /// on its own box, so a revision on a longer sheet than the baseline — an extended roll or
    /// profile plot — can be rendered coarser than the baseline and then resampled into the
    /// baseline's frame (V-080).
    public let revisedRenderScale: Double
    /// The scale the request asked for.
    public let requestedRenderScale: Double
    /// The coarser of the two pages' render scales: the resolution the comparison can actually
    /// resolve changes at.
    public var effectiveRenderScale: Double { Swift.min(renderScale, revisedRenderScale) }
    /// `true` when either sheet was too large for the budget at the requested scale and was
    /// compared at a reduced resolution — something the interface should say. It read the
    /// baseline alone until V-080, so an over-budget revision went unreported.
    public var isResolutionReduced: Bool { effectiveRenderScale < requestedRenderScale * 0.999 }
    /// The baseline frame every reported bound is expressed against.
    public let frame: RasterFrame
    /// Pixel-level findings. Never a statement about geometry.
    public let rasterRegions: [DifferenceRegion]
    public let rasterStatistics: RasterDiffStatistics
    /// Geometry-level findings, or `nil` when the vector pass was not run at all.
    public let vector: VectorDiffOutcome?
    public let elapsedNanoseconds: UInt64
    public let wasTruncated: Bool

    public init(
        baselineLabel: String,
        revisedLabel: String,
        alignment: AlignmentSolution,
        autoAlignmentMetrics: AutoAlignmentMetrics?,
        autoAlignmentRejection: AutoAlignmentRejection?,
        renderScale: Double,
        frame: RasterFrame,
        rasterRegions: [DifferenceRegion],
        rasterStatistics: RasterDiffStatistics,
        vector: VectorDiffOutcome?,
        elapsedNanoseconds: UInt64,
        wasTruncated: Bool,
        requestedRenderScale: Double? = nil,
        revisedRenderScale: Double? = nil
    ) {
        self.requestedRenderScale = requestedRenderScale ?? renderScale
        self.revisedRenderScale = revisedRenderScale ?? renderScale
        self.baselineLabel = baselineLabel
        self.revisedLabel = revisedLabel
        self.alignment = alignment
        self.autoAlignmentMetrics = autoAlignmentMetrics
        self.autoAlignmentRejection = autoAlignmentRejection
        self.renderScale = renderScale
        self.frame = frame
        self.rasterRegions = rasterRegions
        self.rasterStatistics = rasterStatistics
        self.vector = vector
        self.elapsedNanoseconds = elapsedNanoseconds
        self.wasTruncated = wasTruncated
    }

    /// Raster findings plus geometry findings.
    public var differenceCount: Int { rasterRegions.count + (vector?.regions.count ?? 0) }

    /// Both lists, raster first, renumbered so the ids are unique across the union.
    public var allRegions: [DifferenceRegion] {
        var result = rasterRegions
        for region in vector?.regions ?? [] {
            result.append(
                DifferenceRegion(
                    id: result.count,
                    signal: region.signal,
                    classification: region.classification,
                    pageBounds: region.pageBounds,
                    pixelBounds: region.pixelBounds,
                    changedPixelCount: region.changedPixelCount,
                    addedPixelCount: region.addedPixelCount,
                    removedPixelCount: region.removedPixelCount,
                    confidence: region.confidence,
                    vectorDetail: region.vectorDetail
                )
            )
        }
        return result
    }

    /// `true` when neither signal found anything.
    public var isIdentical: Bool {
        rasterRegions.isEmpty && rasterStatistics.isIdentical
            && (vector.map { $0.differences.isEmpty } ?? true)
    }

    public var elapsedSeconds: Double { Double(elapsedNanoseconds) / 1_000_000_000 }
}

/// One rendered revision page, in gray, with the frame that locates it on the page.
public struct RenderedRevisionPage: Sendable {
    public let image: GrayImage
    public let frame: RasterFrame
    public let label: String

    public init(image: GrayImage, frame: RasterFrame, label: String) {
        self.image = image
        self.frame = frame
        self.label = label
    }
}

/// A composite, the plan it was produced under, and what it cost.
public struct PlannedOverlayComposite: Sendable {
    public let composite: OverlayComposite
    public let plan: OverlayCompositePlan
    public let elapsedNanoseconds: UInt64

    public init(composite: OverlayComposite, plan: OverlayCompositePlan, elapsedNanoseconds: UInt64) {
        self.composite = composite
        self.plan = plan
        self.elapsedNanoseconds = elapsedNanoseconds
    }

    public var elapsedSeconds: Double { Double(elapsedNanoseconds) / 1_000_000_000 }
}

/// Revision Compare: render, align, diff.
///
/// An actor because it owns a rendering pipeline that must not be re-entered
/// concurrently for the same document.
///
/// Every byte of the two revisions reaches this type through
/// ``RevisionDocumentSourcing`` and through nothing else — see ``isolation``. The
/// diffing itself stays here: it is our arithmetic over buffers we produced, not
/// over attacker bytes.
public actor RevisionComparator {
    private let source: any RevisionDocumentSourcing
    private let clock: @Sendable () -> UInt64

    public init(
        source: any RevisionDocumentSourcing,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.source = source
        self.clock = clock
    }

    /// Where the compared documents are parsed. A shipping build asserts this is
    /// ``RevisionParsingIsolation/outOfProcess`` at construction time.
    public nonisolated var isolation: RevisionParsingIsolation { source.isolation }

    /// Removed by finding S17-02. The comparator no longer owns a PDFKit provider
    /// or a `VectorExtractor`; it takes a ``RevisionDocumentSourcing``, and the
    /// application must hand it the service-backed one so that the revision PDF —
    /// the most untrusted file the product opens — is parsed out of process.
    ///
    ///     // application:
    ///     RevisionComparator(source: ServiceBackedRevisionDocumentSource.automatic())
    ///     // swift test, and only swift test:
    ///     RevisionComparator(source: InProcessRevisionDocumentSource(provider: provider))
    @available(*, unavailable, message: "Revision Compare must not parse a revision PDF in the application process (S17-02). Pass source: ServiceBackedRevisionDocumentSource.automatic() from ZPDFServiceClient, or source: InProcessRevisionDocumentSource(provider:) under swift test.")
    public init(
        provider: any PDFDocumentProviding,
        extractor: VectorExtractor = VectorExtractor(),
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.source = InProcessRevisionDocumentSource(provider: provider, extractor: extractor)
        self.clock = clock
    }

    // MARK: - Rendering

    /// Rasterises one revision page to gray at `scale`, in whichever process the
    /// source parses in.
    public func render(
        _ reference: RevisionPageReference,
        scale: Double,
        maximumPixels: Int = 64_000_000
    ) async throws -> RenderedRevisionPage {
        guard scale.isFinite, scale > 0, scale <= 100 else {
            throw CompareFault.invalidRenderScale(scale)
        }
        try checkCompareCancellation()
        let page = try await source.render(reference, scale: scale, maximumPixels: maximumPixels)
        try checkCompareCancellation()
        return page
    }

    /// The page box of one revision page, in page space. What page-box alignment needs.
    public func pageBox(of reference: RevisionPageReference) async throws -> CGRect {
        try await source.pageBox(of: reference)
    }

    // MARK: - Comparison

    public func compare(_ request: RevisionCompareRequest) async throws -> RevisionComparisonResult {
        let started = clock()
        try checkCompareCancellation()

        let maximumPixels = request.raster.maximumPixels
        // Fitted to the budget first, as the overlay is (R-156): a long profile or roll-plot
        // sheet at the requested scale used to exceed the raster budget and fail the whole
        // compare with pixelBudgetExceeded. Each page gets the largest in-budget scale for its
        // own box; the warp below resamples the revision onto the baseline frame either way.
        guard request.renderScale.isFinite, request.renderScale > 0, request.renderScale <= 100 else {
            throw CompareFault.invalidRenderScale(request.renderScale)
        }
        let baselineScale = try await inBudgetScale(
            for: request.baseline, scale: request.renderScale, maximumPixels: maximumPixels
        )
        let baseline = try await render(
            request.baseline, scale: baselineScale, maximumPixels: maximumPixels
        )
        let revisedScale = try await inBudgetScale(
            for: request.revised, scale: request.renderScale, maximumPixels: maximumPixels
        )
        let revised = try await render(
            request.revised, scale: revisedScale, maximumPixels: maximumPixels
        )
        try checkCompareCancellation()

        var solution = try await resolveAlignment(
            request,
            baselineFrame: baseline.frame,
            revisedFrame: revised.frame
        )
        var visionMetrics: AutoAlignmentMetrics?
        var visionRejection: AutoAlignmentRejection?

        // Vision refinement runs on the rasters, so it happens after the pages are
        // rendered and after the page-box guess has been applied.
        if case let .automatic(plan) = request.alignment, plan.usesVisionRegistration {
            let prewarped = try warp(
                revised: revised, into: baseline.frame,
                alignment: solution.transform, maximumPixels: maximumPixels
            )
            let outcome = plan.vision.align(moving: prewarped, fixed: baseline.image)
            visionMetrics = outcome.metrics
            visionRejection = outcome.rejection
            if let refinement = outcome.solution {
                // Vision's transform is in the baseline's *pixel* space; the alignment
                // the rest of the pipeline speaks is in page space, and it composes on
                // top of the page-box guess rather than replacing it.
                let pixelToPage = try baseline.frame.pixelToPage()
                let pageSpaceRefinement = baseline.frame.pageToPixel
                    .concatenating(refinement.transform)
                    .concatenating(pixelToPage)
                let combined = solution.transform.concatenating(pageSpaceRefinement)
                // The gray-level dissimilarity Vision measured travels with the page-space
                // re-wrap: dropping it here left every real Vision alignment reporting
                // nothing (CR-131 follow-up).
                solution = AlignmentSolution(
                    transform: combined,
                    model: refinement.model,
                    provenance: .automaticVision,
                    residual: refinement.residual,
                    correspondenceCount: 0,
                    conditioning: refinement.conditioning,
                    pixelDissimilarity: refinement.pixelDissimilarity
                )
            }
        }
        try checkCompareCancellation()

        let warped = try warp(
            revised: revised, into: baseline.frame,
            alignment: solution.transform, maximumPixels: maximumPixels
        )
        let rasterOutcome = try RasterDiffEngine.diff(
            baseline: baseline.image,
            revised: warped,
            frame: baseline.frame,
            options: request.raster
        )
        try checkCompareCancellation()

        var vectorOutcome: VectorDiffOutcome?
        if request.includesVectorSignal {
            vectorOutcome = try await compareVector(request, alignment: solution.transform)
        }

        return RevisionComparisonResult(
            baselineLabel: request.baseline.label,
            revisedLabel: request.revised.label,
            alignment: solution,
            autoAlignmentMetrics: visionMetrics,
            autoAlignmentRejection: visionRejection,
            renderScale: baselineScale,
            frame: baseline.frame,
            rasterRegions: rasterOutcome.regions,
            rasterStatistics: rasterOutcome.statistics,
            vector: vectorOutcome,
            elapsedNanoseconds: clock() &- started,
            wasTruncated: rasterOutcome.wasTruncated || (vectorOutcome?.wasTruncated ?? false),
            requestedRenderScale: request.renderScale,
            revisedRenderScale: revisedScale
        )
    }

    /// Rasterises every revision in `references` into the baseline's frame and
    /// composites them through `model`.
    ///
    /// The first reference is the baseline: its frame is the shared frame, and the
    /// alignments map each later revision onto it. `alignments` must have one entry per
    /// reference; the first is normally the identity.
    public func overlay(
        references: [RevisionPageReference],
        alignments: [AlignmentTransform],
        model: RevisionOverlayModel,
        scale: Double,
        maximumPixels: Int = 64_000_000
    ) async throws -> OverlayComposite {
        guard references.count == alignments.count, references.count == model.layers.count else {
            throw CompareFault.overlayLayerMismatch(
                reason: "\(references.count) pages, \(alignments.count) alignments, "
                    + "\(model.layers.count) layers"
            )
        }
        guard let first = references.first else {
            throw CompareFault.overlayLayerMismatch(reason: "no pages")
        }
        guard !model.visibleLayers.isEmpty else {
            throw CompareFault.overlayLayerMismatch(reason: "no visible layer")
        }
        // CR-138. `alignments[0]` was validated for presence and then never used: the base
        // page is rendered as it is, because its frame is the frame the whole stack is
        // registered into, so warping it would move the target everyone else is aimed at.
        // Silently discarding it is the part that was wrong — a caller passing a real
        // transform for the bottom layer got a composite in which that layer alone had not
        // moved, with nothing said. Only the identity is meaningful here, and anything
        // else is refused rather than ignored.
        guard alignments[0].isIdentity() else {
            throw CompareFault.overlayLayerMismatch(
                reason: "the base layer's alignment must be the identity — it defines the "
                    + "frame every other layer is warped into — but it was "
                    + "\(alignments[0])"
            )
        }
        // The first page is rendered whether or not its layer is visible: its frame is the
        // frame every other layer is warped into, so hiding the bottom revision must not
        // silently change what the ones above it are registered against. Every *other*
        // hidden layer is skipped before its render, because a layer that contributes
        // nothing to the picture should not cost a page rasterisation to leave out.
        let base = try await render(first, scale: scale, maximumPixels: maximumPixels)
        var sources: [OverlaySource] = []
        if model.layers[0].isVisible {
            sources.append(OverlaySource(layerID: model.layers[0].id, image: base.image))
        }
        for index in 1..<references.count where model.layers[index].isVisible {
            try checkCompareCancellation()
            // The budget (and any plan) was fitted to the *first* layer's page box. A larger
            // sheet further up the stack rendered at the same scale used to exceed it and fail
            // the whole overlay with pixelBudgetExceeded (BH-122). It is rendered at the
            // largest in-budget scale for its own box instead; the warp below resamples it
            // onto the base frame either way.
            let layerScale = try await inBudgetScale(
                for: references[index], scale: scale, maximumPixels: maximumPixels
            )
            let page = try await render(references[index], scale: layerScale, maximumPixels: maximumPixels)
            let warped = try warp(
                revised: page, into: base.frame,
                alignment: alignments[index], maximumPixels: maximumPixels
            )
            sources.append(OverlaySource(layerID: model.layers[index].id, image: warped))
        }
        return try OverlayCompositor.composite(
            model: model, sources: sources, maximumPixels: maximumPixels
        )
    }

    /// Rasterises and composites, and reports the frame the composite was produced in.
    ///
    /// The plain ``overlay(references:alignments:model:scale:maximumPixels:)`` answers
    /// "what does the stack look like"; this one also answers "at what scale, over which
    /// page box, and how long did it take" — which is what an interface that has to state
    /// its own resolution and place a click back in page space needs.
    public func overlay(
        references: [RevisionPageReference],
        alignments: [AlignmentTransform],
        model: RevisionOverlayModel,
        plan: OverlayCompositePlan
    ) async throws -> PlannedOverlayComposite {
        let started = clock()
        let composite = try await overlay(
            references: references,
            alignments: alignments,
            model: model,
            scale: plan.scale,
            maximumPixels: Swift.max(plan.pixelCount, plan.maximumPixels)
        )
        // The composite's size is the truth. A plan fitted without the page's /Rotate
        // reports a quarter-turned sheet transposed (BH-472); correct it so a caller that
        // places a click from `plan.pixelWidth/Height` uses the real frame.
        var reported = plan
        if composite.image.width == plan.pixelHeight, composite.image.height == plan.pixelWidth,
           plan.pixelWidth != plan.pixelHeight {
            reported = OverlayCompositePlan(
                pageBox: plan.pageBox,
                requestedScale: plan.requestedScale,
                scale: plan.scale,
                pixelWidth: plan.pixelHeight,
                pixelHeight: plan.pixelWidth,
                layerCount: plan.layerCount,
                maximumPixels: plan.maximumPixels
            )
        }
        return PlannedOverlayComposite(
            composite: composite,
            plan: reported,
            elapsedNanoseconds: clock() &- started
        )
    }

    // MARK: - Internals

    /// `scale`, or the largest smaller scale at which `reference`'s own page box fits
    /// `maximumPixels`.
    private func inBudgetScale(
        for reference: RevisionPageReference,
        scale: Double,
        maximumPixels: Int
    ) async throws -> Double {
        let box = try await pageBox(of: reference)
        guard let fitted = try? OverlayCompositePlan.fit(
            pageBox: box, requestedScale: scale, layerCount: 1, maximumPixels: maximumPixels
        ) else { return scale }
        return fitted.scale
    }

    private func resolveAlignment(
        _ request: RevisionCompareRequest,
        baselineFrame: RasterFrame,
        revisedFrame: RasterFrame
    ) async throws -> AlignmentSolution {
        switch request.alignment {
        case .identity:
            return .identity
        case let .explicit(transform):
            guard transform.isFinite else {
                throw CompareFault.alignment(.nonInvertibleTransform(determinant: transform.determinant))
            }
            return AlignmentSolution(
                transform: transform,
                model: .affine,
                provenance: .explicit,
                residual: .zero,
                correspondenceCount: 0,
                conditioning: 1
            )
        case let .manualTwoPoint(correspondences):
            do { return try AlignmentSolver.solveTwoPoint(correspondences) }
            catch let fault as AlignmentFault { throw CompareFault.alignment(fault) }
        case let .manualThreePoint(correspondences):
            do { return try AlignmentSolver.solveThreePoint(correspondences) }
            catch let fault as AlignmentFault { throw CompareFault.alignment(fault) }
        case let .automatic(plan):
            guard plan.usesPageBoxMatching else { return .identity }
            let solution = PageBoxAligner.align(
                baselineBox: baselineFrame.boxRect,
                revisedBox: revisedFrame.boxRect,
                options: plan.pageBox
            )
            // Conditioning 0 is PageBoxAligner's own "the boxes do not correspond" (aspect
            // mismatch beyond tolerance, e.g. a title strip added to the revision). Warping
            // by that centred rescale used to report every line on the sheet as changed
            // (BH-123); the honest fallback is no page-box warp at all.
            // The provenance and the 0 stay visible, so the caller can say why.
            guard solution.conditioning > 0 else {
                return AlignmentSolution(
                    transform: .identity,
                    model: .translation,
                    provenance: .pageBox,
                    residual: .zero,
                    correspondenceCount: 0,
                    conditioning: 0
                )
            }
            return solution
        }
    }

    private nonisolated func warp(
        revised: RenderedRevisionPage,
        into frame: RasterFrame,
        alignment: AlignmentTransform,
        maximumPixels: Int
    ) throws -> GrayImage {
        let inverse: AlignmentTransform
        do {
            inverse = try frame.inverseResamplingMap(from: revised.frame, alignment: alignment)
        } catch let fault as AlignmentFault {
            throw CompareFault.alignment(fault)
        }
        return try revised.image.resampled(
            using: inverse,
            width: frame.pixelWidth,
            height: frame.pixelHeight,
            background: 255,
            maximumPixels: maximumPixels
        )
    }

    /// The geometry pass, which never fails the comparison it belongs to (U-078).
    ///
    /// The raster diff has already succeeded when this runs. A page the geometry scanner
    /// cannot read, or one over ``VectorDiffOptions/maximumPrimitivesPerPage`` (a dense CAD
    /// sheet: extraction allows ten times as many), used to throw out of ``compare(_:)`` and
    /// discard that raster result, so the review read "failed" with no regions. Now the refusal
    /// is carried in ``VectorDiffOutcome/refusal`` and the raster signal decides alone. Only
    /// cancellation still ends the comparison.
    private func compareVector(
        _ request: RevisionCompareRequest,
        alignment: AlignmentTransform
    ) async throws -> VectorDiffOutcome? {
        guard request.baseline.fileURL != nil, request.revised.fileURL != nil else { return nil }
        var baselineExtraction: VectorPageExtraction?
        var revisedExtraction: VectorPageExtraction?
        do {
            let baseline = try await source.extractGeometry(request.baseline)
            baselineExtraction = baseline
            let revised = try await source.extractGeometry(request.revised)
            revisedExtraction = revised
            return try VectorDiffEngine.diff(
                baseline: baseline,
                revised: revised,
                alignment: alignment,
                options: request.vector
            )
        } catch is CancellationError {
            throw CompareFault.cancelled
        } catch CompareFault.cancelled {
            throw CompareFault.cancelled
        } catch {
            try checkCompareCancellation()
            return .refused(VectorDiffRefusal(error), baseline: baselineExtraction, revised: revisedExtraction)
        }
    }
}
