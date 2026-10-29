import CoreGraphics
import Foundation
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// One request for a composited overlay: the layer stack as the person has it, the blending, the
/// manual fit, and how sharp the canvas would like it.
struct RevisionOverlayCompositeRequest: Sendable {
    /// The stack, bottom first.
    let layers: [RevisionOverlayLayer]
    let blendMode: RevisionOverlayBlendMode
    /// The manual alignment, or `nil` while the sheets are taken as already registered.
    let fit: RevisionAlignmentTransform?
    /// Pixels per PDF point the canvas is showing at.
    let requestedScale: Double
}

/// What ``RevisionOverlayCompositing`` needs from the compare engine, and no more.
///
/// The seam is here so that the coordinator can be written in the *shell's* vocabulary alone.
/// `RevisionOverlayModel` is the name of two different things — the engine's stack of layer
/// settings in `ZPDFCompare` and the shell's observable mode state in `ZPDFUIWorkflows` — and a
/// file that imports both cannot say either name without qualifying it. Qualifying it compiles
/// and reads badly, and `Scripts/verify-hook-wiring.sh` cannot see through the alias it needs,
/// so it reported this file's three hook assignments as landing on some other type. Splitting
/// the vocabularies across two files fixes the ambiguity at its source: here the name means the
/// shell's model and nothing else, and in ``RevisionOverlayEngine`` it means the engine's.
protocol RevisionOverlayProducing: Sendable {

    /// How many of these layers have a page registered behind them. Fewer than two and there is
    /// nothing to stack, which is a thing to say rather than a thing to fail at.
    @MainActor func registeredPageCount(among ids: [RevisionSummary.ID]) -> Int

    /// Rasterises and composites. Runs off the main actor.
    func compose(_ request: RevisionOverlayCompositeRequest) async throws -> RevisionOverlayComposite
}

/// Produces Revision Overlay's composited picture and keeps it current.
///
/// This is the piece that was once missing: the overlay pane needs a compositor that can stack
/// two rasterised sheets under a hand-built alignment. It has one now, and it is the compare engine's — `OverlayCompositor`, driven through the
/// **same** `RevisionComparator` Revision Compare runs on, over the same
/// `ServiceBackedRevisionDocumentSource`.
///
/// That sameness is a security property, not a convenience. The compared document is the most
/// untrusted file the product opens, and finding S17-02 moved its page raster and page box into
/// `GeometryService`. An overlay that rasterised its own copy would have put that parsing
/// straight back into the application. Nothing here touches a PDF: it converts layer settings
/// into a request, hands the request to a producer, and installs the picture that comes back.
///
/// Recomposition is coalesced. Every opacity nudge, colour change and visibility toggle fires
/// ``RevisionOverlayModel/onLayersChange``; without coalescing a slider drag would queue sixty
/// whole-sheet composites, each already stale when it started.
@MainActor
final class RevisionOverlayCompositing {

    /// How long a burst of layer edits settles before the composite is rebuilt.
    ///
    /// 150 ms against a measured blend of 17 ms at fit and 73 ms at the pixel cap on an
    /// A1 sheet: long enough that a slider drag produces one composite at the end rather than one per
    /// tick, short enough that a single click does not feel deferred.
    private static let coalescingInterval = Duration.milliseconds(150)

    private let producer: any RevisionOverlayProducing
    private weak var model: RevisionOverlayModel?
    private let requestedScale: @MainActor () -> Double

    private var pending: Task<Void, Never>?

    init(
        producer: any RevisionOverlayProducing,
        model: RevisionOverlayModel,
        requestedScale: @escaping @MainActor () -> Double
    ) {
        self.producer = producer
        self.model = model
        self.requestedScale = requestedScale
    }

    deinit { pending?.cancel() }

    /// Installs the three hooks and asks for the first picture.
    ///
    /// `onLayersChange` and `onAlignmentChange` are the model's own outward edges, and both were
    /// once assigned by nothing. A layer edit and a re-fit are precisely the two things
    /// that change what the composite should look like, so wiring them *is* wiring the
    /// compositor. `onRecomposite` is the retry route a failed composite needs; without it a
    /// failure inside the mode would be a dead end.
    func attach(composeNow: Bool = true) {
        guard let model else { return }
        model.onLayersChange = { [weak self] _ in self?.requestComposite() }
        model.onAlignmentChange = { [weak self] _ in self?.requestComposite() }
        model.onRecomposite = { [weak self] in self?.requestComposite(immediately: true) }
        // `composeNow: false` keeps a failure already on the pane — a baseline that could not be
        // registered — instead of overwriting it with "there is 0 revisions" (BH-906, BH-920).
        if composeNow { requestComposite(immediately: true) }
    }

    /// The canvas turned the page or changed zoom: the composite is of another sheet, or at
    /// another sharpness, now (BH-386). Coalesced like a layer edit.
    func viewportDidChange() {
        requestComposite()
    }

    /// Cancels any in-flight composite and unhooks the model. Called when the mode is left.
    func detach() {
        pending?.cancel()
        pending = nil
        guard let model else { return }
        model.onLayersChange = nil
        model.onAlignmentChange = nil
        model.onRecomposite = nil
        model.clearComposite()
    }

    /// Rebuilds the composite, coalescing a burst of edits into one run.
    func requestComposite(immediately: Bool = false) {
        pending?.cancel()
        guard let model else { return }

        let ordered = model.layers.sorted { $0.order < $1.order }
        let registered = producer.registeredPageCount(among: ordered.map(\.id))
        guard registered >= 2 else {
            model.setCompositeStatus(.unavailable(Self.needsASecondRevision(count: registered)))
            return
        }
        guard ordered.contains(where: \.isVisible) else {
            model.setCompositeStatus(.unavailable(NSLocalizedString(
                "Every layer is hidden. Switch one on to see the sheet.",
                comment: "Revision Overlay status when no layer is visible"
            )))
            return
        }

        let request = RevisionOverlayCompositeRequest(
            layers: ordered,
            blendMode: model.blendMode,
            fit: model.fit?.transform,
            requestedScale: max(0.05, min(100, requestedScale()))
        )
        let producer = self.producer

        model.setCompositeStatus(.rendering)
        pending = Task { @MainActor [weak model] in
            if !immediately {
                try? await Task.sleep(for: Self.coalescingInterval)
                if Task.isCancelled { return }
            }
            do {
                let composite = try await producer.compose(request)
                if Task.isCancelled { return }
                model?.setComposite(composite)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                model?.setCompositeStatus(.failed(RevisionOverlayEngine.sentence(for: error)))
            }
        }
    }

    /// Why there is no picture yet, and the way to add a revision — the pane's own Add
    /// Revision… button first (L-57: the ⌥ drop from Finder was the only way, and the only one
    /// named; "There is 0." read as a fault).
    static func needsASecondRevision(count: Int) -> String {
        String(
            format: NSLocalizedString(
                "Revision Overlay stacks two or more revisions of the same sheet, and this drawing has %@. Choose Add Revision… to add the revised PDF, or drop it on the canvas with ⌥ held.",
                comment: "Revision Overlay status when there are not enough revisions to stack: the revision count as '1 revision'"
            ),
            LocalizedPlural.string(
                "%lld revisions", count: count,
                one: NSLocalizedString("%lld revision", comment: "Revision count, singular"),
                other: NSLocalizedString("%lld revisions", comment: "Revision count, plural")
            )
        )
    }
}
