import CoreGraphics
import Foundation
import os
import ZPDFCompare
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// Speaks the compare engine's vocabulary on Revision Overlay's behalf.
///
/// Everything in this file is in `ZPDFCompare`'s terms: `OverlayLayer`, `OverlayColor`,
/// `AlignmentTransform`, `OverlayCompositePlan`, and `ZPDFCompare.RevisionOverlayModel` — the
/// engine's stack of layer *settings*, which is a different type from the shell's mode state of
/// the same name. The two names never meet in one file: the shell's side is
/// ``RevisionOverlayCompositing``, and the seam between them is
/// ``RevisionOverlayProducing``.
enum RevisionOverlayEngine {

    /// How many pixels one composite may be.
    ///
    /// The same 24 megapixels gate Z8 allows a whole-page raster, for the same reason: it is the
    /// largest picture worth producing for a screen. The overlay costs more per pixel than the
    /// viewer does — one gray page per visible layer plus the RGBA output, so seven bytes a pixel
    /// for a three-revision stack, about 170 MB at the cap — which is why the cap is not raised
    /// for it. On an A1 sheet that binds at 400 %: the whole sheet at 8 px/pt would be 257
    /// megapixels, so the plan reduces the scale and the pane states the reduction.
    static let maximumCompositePixels = 24_000_000

    /// A registered page's `/Rotate`, read from its file; 0 when the file is not reachable.
    nonisolated static func pageRotation(of reference: RevisionPageReference) -> Int {
        guard let url = reference.fileURL,
              let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: reference.pageIndex + 1)
        else { return 0 }
        let angle = Int(page.rotationAngle) % 360
        return angle < 0 ? angle + 360 : angle
    }

    /// The engine stack, in the shell's stacking order, the engine's integer ids being the
    /// position in that order.
    static func engineModel(
        for layers: [RevisionOverlayLayer],
        blendMode: RevisionOverlayBlendMode
    ) -> ZPDFCompare.RevisionOverlayModel {
        let mode = engineBlendMode(blendMode)
        let engineLayers = layers.enumerated().map { index, layer in
            OverlayLayer(
                id: index,
                label: "\(layer.revisionName) \(layer.revisionLabel)",
                color: OverlayColor(
                    red: layer.colorRGBA.red,
                    green: layer.colorRGBA.green,
                    blue: layer.colorRGBA.blue
                ),
                opacity: layer.opacity,
                isVisible: layer.isVisible,
                blendMode: mode
            )
        }
        // Difference composites onto black, everything else onto paper. Not a style choice:
        // `difference` exists so that two identical revisions cancel, and they can only cancel
        // to the ground they were painted on. On white, two identical black sheets come out
        // white — and so does blank paper, which is the one reading the mode must not produce.
        return ZPDFCompare.RevisionOverlayModel(
            layers: engineLayers,
            background: mode == .difference ? .black : .white
        )
    }

    static func engineBlendMode(_ mode: RevisionOverlayBlendMode) -> OverlayBlendMode {
        switch mode {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .difference: return .difference
        }
    }

    /// The bottom sheet is the frame; every sheet above it is registered onto that frame by the
    /// one manual fit. With exactly two layers that is the whole story; with more it is a
    /// simplification, which the inspector states out loud rather than letting a person assume
    /// each sheet was aligned on its own.
    static func alignments(count: Int, fit: RevisionAlignmentTransform?) -> [AlignmentTransform] {
        let mapped = fit.map {
            AlignmentTransform(a: $0.a, b: $0.b, c: $0.c, d: $0.d, tx: $0.tx, ty: $0.ty)
        } ?? .identity
        return (0..<count).map { $0 == 0 ? .identity : mapped }
    }

    /// Alignments for a stack whose bottom may not be the sheet the fit was made against.
    ///
    /// The fit registers every sheet onto the **baseline** it was captured over. Reordering
    /// the stack — or an unregistered bottom layer dropping out — made another sheet the frame,
    /// and applying the fit unchanged misregistered by twice the fit (BH-387). With the
    /// baseline elsewhere in the stack, the frame is the fitted family's, so the baseline gets
    /// the inverse and the others go through unchanged.
    static func alignments(
        stackIDs: [RevisionSummary.ID],
        fit: RevisionAlignmentTransform?,
        fitBaselineID: RevisionSummary.ID?
    ) -> [AlignmentTransform] {
        guard let fit, let baseline = fitBaselineID, let bottom = stackIDs.first, bottom != baseline else {
            return alignments(count: stackIDs.count, fit: fit)
        }
        let inverse = invert(fit)
        return stackIDs.map { $0 == baseline ? inverse : .identity }
    }

    /// The inverse of an affine fit, identity when it is singular.
    static func invert(_ fit: RevisionAlignmentTransform) -> AlignmentTransform {
        let determinant = fit.a * fit.d - fit.b * fit.c
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return .identity }
        let a = fit.d / determinant
        let b = -fit.b / determinant
        let c = -fit.c / determinant
        let d = fit.a / determinant
        let tx = -(a * fit.tx + c * fit.ty)
        let ty = -(b * fit.tx + d * fit.ty)
        return AlignmentTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    /// One sentence a person can act on, out of a typed engine fault.
    static func sentence(for error: any Error) -> String {
        let detail = (error as? CompareFault)?.description ?? String(describing: error)
        return String(
            format: NSLocalizedString(
                "The revisions could not be stacked: %@",
                comment: "Revision Overlay failure sentence: the engine's reason"
            ),
            detail
        )
    }
}

/// Composites through a ``RevisionComparator`` — which in the shipping application is the one
/// built over `ServiceBackedRevisionDocumentSource.automatic()`, so the compared document's
/// pages are rasterised in `GeometryService` and not here (finding S17-02).
struct ComparatorOverlayProducer: RevisionOverlayProducing {

    let comparator: RevisionComparator
    /// The page behind each revision, read on the main actor at the moment it is needed rather
    /// than captured, because dropping a drawing adds one while the mode is open.
    let pages: @MainActor @Sendable () -> [RevisionSummary.ID: RevisionPageReference]
    /// The revisions that have a page, without pairing them: the count ``registeredPageCount(among:)``
    /// needs. `nil` counts through ``pages`` (U-014: pairing posts its warnings, and the count
    /// runs on every composite request, before the coalescing wait).
    let registeredIDs: (@MainActor @Sendable () -> Set<RevisionSummary.ID>)?
    /// Which sheet the current manual fit was made against: the bottom of the stack when the
    /// fit first arrived (BH-387). Lock-protected, so the producer stays Sendable.
    private let fitAnchor = OSAllocatedUnfairLock<FitAnchor>(initialState: FitAnchor())

    struct FitAnchor: Sendable {
        var fit: RevisionAlignmentTransform?
        var baseline: RevisionSummary.ID?
    }

    init(
        comparator: RevisionComparator,
        pages: @escaping @MainActor @Sendable () -> [RevisionSummary.ID: RevisionPageReference],
        registeredIDs: (@MainActor @Sendable () -> Set<RevisionSummary.ID>)? = nil
    ) {
        self.comparator = comparator
        self.pages = pages
        self.registeredIDs = registeredIDs
    }

    /// The baseline for `fit`, recording the current bottom when the fit is new.
    func fitBaseline(for fit: RevisionAlignmentTransform?, bottom: RevisionSummary.ID?) -> RevisionSummary.ID? {
        fitAnchor.withLock { anchor in
            if anchor.fit != fit {
                anchor.fit = fit
                anchor.baseline = fit == nil ? nil : bottom
            }
            return anchor.baseline
        }
    }

    @MainActor
    func registeredPageCount(among ids: [RevisionSummary.ID]) -> Int {
        let registered = registeredIDs?() ?? Set(pages().keys)
        return ids.filter { registered.contains($0) }.count
    }

    func compose(
        _ request: RevisionOverlayCompositeRequest
    ) async throws -> RevisionOverlayComposite {
        let registered = await MainActor.run { pages() }
        let stacked = request.layers.compactMap { layer -> (RevisionOverlayLayer, RevisionPageReference)? in
            guard let page = registered[layer.id] else { return nil }
            return (layer, page)
        }
        guard let baseline = stacked.first?.1, stacked.count >= 2 else {
            throw CompareFault.overlayLayerMismatch(
                reason: "\(stacked.count) of \(request.layers.count) layers have a page"
            )
        }

        let model = RevisionOverlayEngine.engineModel(
            for: stacked.map(\.0), blendMode: request.blendMode
        )
        let box = try await comparator.pageBox(of: baseline)
        let plan = try OverlayCompositePlan.fit(
            pageBox: box,
            requestedScale: request.requestedScale,
            layerCount: model.visibleLayers.count,
            maximumPixels: RevisionOverlayEngine.maximumCompositePixels,
            // The baseline sheet's /Rotate, so a rotated set composites the way it is read
            // (BH-472, host half).
            rotationDegrees: RevisionOverlayEngine.pageRotation(of: baseline)
        )
        let produced = try await comparator.overlay(
            references: stacked.map(\.1),
            alignments: RevisionOverlayEngine.alignments(
                stackIDs: stacked.map(\.0.id),
                fit: request.fit,
                fitBaselineID: fitBaseline(for: request.fit, bottom: stacked.first?.0.id)
            ),
            model: model,
            plan: plan
        )
        try Task.checkCancellation()

        // The engine's ids are positions in the stack; the shell's are revision identities. The
        // mapping is the same array both ways round, so it cannot drift.
        let ids = stacked.map(\.0.id)
        let contributing = produced.composite.contributingLayerIDs.compactMap {
            $0 >= 0 && $0 < ids.count ? ids[$0] : nil
        }
        return RevisionOverlayComposite(
            image: try produced.composite.image.cgImage(),
            pixelWidth: produced.composite.image.width,
            pixelHeight: produced.composite.image.height,
            pageBox: PDFRectValue(
                x: Double(box.origin.x),
                y: Double(box.origin.y),
                width: Double(box.size.width),
                height: Double(box.size.height)
            ),
            scale: plan.scale,
            requestedScale: plan.requestedScale,
            contributingLayerIDs: contributing,
            elapsedNanoseconds: produced.elapsedNanoseconds
        )
    }
}
