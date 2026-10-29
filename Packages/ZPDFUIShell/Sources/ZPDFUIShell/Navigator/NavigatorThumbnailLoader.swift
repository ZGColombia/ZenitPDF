import CoreGraphics
import Foundation
import Observation
import ZPDFUIPresentation

/// What a Navigator thumbnail row keys its `.task` on (IM-125).
///
/// One rule for both thumbnail lists: the subject, the loader's ``NavigatorThumbnailLoader/
/// providerRevision`` (so a provider that arrives after the first render re-runs the request —
/// LT-1), and, for an open drawing, its page count (which moves 0 → n when it finishes loading).
/// A struct rather than an interpolated string, so no two keys can collide by formatting.
struct NavigatorThumbnailTaskKey: Hashable, Sendable {
    let subject: UUID
    let providerRevision: Int
    var pageCount: Int = 0
}

/// Loads and caches the Navigator's page thumbnails.
///
/// The pattern is placeholder-then-fill: a row renders immediately with the proportioned
/// blank sheet, requests its image, and re-renders when the raster arrives — the column
/// never waits on PDFKit. The loader is deliberately dumb about *how* a thumbnail is made:
/// the app tier injects ``provider``, which in the shipping application is the
/// engine-barrier-wrapped `PageRasterSource.thumbnail` (itself LRU-cached in the bridge).
/// The small cache here only stops a SwiftUI re-render from crossing an actor hop per row.
@MainActor
@Observable
public final class NavigatorThumbnailLoader {

    /// Produces a thumbnail no larger than `maximumPixelSize` on its long edge, or `nil`
    /// when the page cannot be rendered. Failures stay placeholders; they are never fatal.
    public typealias Provider = @MainActor (_ pageIndex: Int, _ maximumPixelSize: Int) async -> CGImage?

    /// The longest edge requested for a column thumbnail, in pixels. Twice the typical
    /// column width, so Retina panes stay sharp.
    public static let maximumPixelSize = 480

    /// How many images are kept. A drawing set rarely shows more than a few dozen rows;
    /// beyond the cap the least recently used image is dropped and simply re-requested if
    /// its row scrolls back in.
    public let capacity: Int

    /// The most decoded image bytes kept, whatever the count (IM-131).
    ///
    /// The count cap alone let one loader hold 64 × ~1.3 MB (480 × 680 RGBA) ≈ 83 MB, and the
    /// window runs two loaders — Pages and Drawings — so ~167 MB of thumbnails at worst. The
    /// default 24 MB per loader bounds the renders of both together to 48 MB. The newest image
    /// is always kept, even alone over budget, so a row that just filled never flickers back to
    /// a placeholder. Turned and cropped copies have their own budget, ``derivedByteBudget``.
    public let byteBudget: Int

    /// The most bytes the turned or cropped copies may hold: half of ``byteBudget``, about
    /// nine portrait or eighteen landscape full-size thumbnails, more than a Navigator column
    /// shows at once (S-044).
    ///
    /// Their own budget, trimmed against their own bytes. R-097 counted them in one total with
    /// the renders, which a scrolled set keeps within one render of ``byteBudget``, so every
    /// turned copy but the newest was dropped as soon as it was made — and with two turned rows
    /// on screen each body pass re-derived both (a crop and a CGContext turn apiece), each
    /// evicting the other. A loader holds at most `byteBudget + derivedByteBudget`.
    public var derivedByteBudget: Int { max(1, byteBudget / 2) }

    /// The default ``byteBudget``: 24 MiB per loader.
    public static let defaultByteBudget = 24 * 1024 * 1024

    /// Where thumbnails come from.
    ///
    /// Assigning this **does not** flush the cache on its own. A closure is not a document:
    /// the application re-installs an identical provider on every tab sync, and flushing on
    /// each assignment re-rasterised every open drawing's thumbnail after a single markup edit
    /// — amplified by ``providerRevision``, which then re-ran every visible row's task
    /// (CR-101). Only two things flush: the provider appearing or disappearing, and a caller
    /// saying the subject changed through ``setProvider(_:identity:)``.
    @ObservationIgnored
    public var provider: Provider? {
        get { storedProvider }
        set { setProvider(newValue, identity: nil) }
    }

    @ObservationIgnored
    private var storedProvider: Provider?

    /// Produces a thumbnail for an *identified* subject — an open drawing, not a page index.
    ///
    /// The Drawings section needs this because its rows are documents: a page-index provider
    /// cannot say *which document's* first sheet it is rendering, and resolving by position in
    /// the tab list would hand the wrong picture to the wrong drawing the moment a tab closes.
    public typealias IdentifiedProvider = @MainActor (_ id: UUID, _ maximumPixelSize: Int) async -> CGImage?

    /// The identified twin of ``provider``. A loader instance uses one or the other.
    ///
    /// Same rule as ``provider``: assigning it is not by itself a reason to flush. See
    /// ``setIdentifiedProvider(_:identity:)`` for the identity-carrying form the application
    /// should use, since it is the one that knows when the set of open drawings changed.
    @ObservationIgnored
    public var identifiedProvider: IdentifiedProvider? {
        get { storedIdentifiedProvider }
        set { setIdentifiedProvider(newValue, identity: nil) }
    }

    @ObservationIgnored
    private var storedIdentifiedProvider: IdentifiedProvider?

    /// What the installed provider serves — a document id, the set of open drawing ids, or
    /// whatever else the caller uses to mean "a different subject". `nil` until a caller says.
    @ObservationIgnored
    public private(set) var providerIdentity: AnyHashable?

    /// Installs a page-index provider, flushing only when the subject actually changed.
    ///
    /// - Parameters:
    ///   - provider: the new provider, or `nil` to remove one.
    ///   - identity: what the provider serves. Pass `nil` to say "the same subject as before",
    ///     which is what a re-install of an equivalent closure is.
    public func setProvider(_ provider: Provider?, identity: AnyHashable?) {
        let had = storedProvider != nil
        storedProvider = provider
        invalidateIfSubjectChanged(had: had, has: provider != nil, identity: identity)
    }

    /// Installs an identified provider, flushing only when the subject actually changed.
    ///
    /// - Parameters:
    ///   - provider: the new provider, or `nil` to remove one.
    ///   - identity: what the provider serves — for the Drawings section, the set of open
    ///     drawing ids. Pass `nil` to say "the same subject as before".
    public func setIdentifiedProvider(_ provider: IdentifiedProvider?, identity: AnyHashable?) {
        let had = storedIdentifiedProvider != nil
        storedIdentifiedProvider = provider
        invalidateIfSubjectChanged(had: had, has: provider != nil, identity: identity)
    }

    /// The one rule for when a provider assignment is worth dropping every cached raster.
    private func invalidateIfSubjectChanged(had: Bool, has: Bool, identity: AnyHashable?) {
        guard let identity else {
            // No identity declared, so the only change the loader can see for itself is the
            // provider appearing or going away. A gained provider is the LT-1 case — the rows
            // rendered against no provider and need their tasks re-run — and a lost one leaves
            // images nothing can refresh.
            if had != has { invalidate() }
            return
        }
        let changed = identity != providerIdentity
        providerIdentity = identity
        if changed || had != has { invalidate() }
    }

    /// Requests an identified subject's thumbnail. Same placeholder-then-fill contract as
    /// ``request(pageID:pageIndex:)``; failures stay placeholders.
    ///
    /// Deduplicated in flight exactly like the page path (IM-220): the Files rows re-key their
    /// task when a drawing's page count moves 0 → n or the provider revision bumps, and without
    /// the check a re-evaluated row started a second first-sheet render of the same drawing
    /// while the first was still running.
    public func request(id: UUID) async {
        guard images[id] == nil, !isInFlight(id),
              let identifiedProvider = storedIdentifiedProvider else { return }
        let requestGeneration = beginFlight(id)
        defer { endFlight(id, generation: requestGeneration) }
        guard let image = await identifiedProvider(id, Self.maximumPixelSize) else { return }
        guard requestGeneration == generation else { return }
        store(image, for: id)
    }

    /// The cache, keyed by page identity. Observable, so a row re-renders when its image lands.
    private var images: [UUID: CGImage] = [:]
    /// LRU order — **deliberately not observed**.
    ///
    /// `image(for:)` is called from `NavigatorPageThumbnail.sheet`, which is inside a SwiftUI
    /// `body`, and it touches this array to refresh the entry's recency. While `order` was an
    /// observed stored property that made the getter a *write* to something the same body had
    /// just read: body → invalidate → body, for ever. The Navigator span at 99.4 % CPU with the
    /// whole sample in `NavigatorPageThumbnail.body` under `GraphHost.flushTransactions`, and it
    /// needed a cached thumbnail to start, which is why it only appeared once a real render had
    /// landed.
    ///
    /// Recency is bookkeeping for eviction; no view renders it. `images` alone carries the change
    /// a row must see.
    @ObservationIgnored
    private var order: [UUID] = []
    /// The subjects being rendered, each with the ``generation`` its render started in.
    ///
    /// R-076: this was a plain set that ``invalidate()`` never cleared. A row re-keyed by the
    /// invalidation asked again at once, found the old render still "in flight" and returned;
    /// the old render then finished, failed the generation check and was discarded — and
    /// nothing asked a third time, so the row stayed a placeholder. A render from an older
    /// generation no longer counts as in flight, and only its own request removes its entry.
    @ObservationIgnored
    private var inFlight: [UUID: Int] = [:]

    private func isInFlight(_ id: UUID) -> Bool { inFlight[id] == generation }

    private func beginFlight(_ id: UUID) -> Int {
        inFlight[id] = generation
        return generation
    }

    private func endFlight(_ id: UUID, generation requestGeneration: Int) {
        if inFlight[id] == requestGeneration { inFlight.removeValue(forKey: id) }
    }
    /// Bumped by ``invalidate()`` so a fill from a stale provider is discarded.
    @ObservationIgnored
    private var generation = 0

    /// Decoded bytes held right now, renders and derived copies together. For tests and
    /// diagnostics.
    public var cachedBytes: Int { sourceBytes + heldDerivedBytes }

    /// Bytes held by the renders themselves, trimmed against ``byteBudget``.
    @ObservationIgnored
    private var sourceBytes = 0

    /// Bytes held by the turned or cropped copies, trimmed against ``derivedByteBudget``.
    @ObservationIgnored
    private var heldDerivedBytes = 0

    /// Creates a loader.
    public init(capacity: Int = 64, byteBudget: Int = NavigatorThumbnailLoader.defaultByteBudget) {
        self.capacity = max(1, capacity)
        self.byteBudget = max(1, byteBudget)
    }

    /// What one cached image costs in memory.
    static func byteCost(of image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    /// The cached image for a page, refreshing its LRU position.
    public func image(for pageID: UUID) -> CGImage? {
        guard let image = images[pageID] else { return nil }
        if let index = order.firstIndex(of: pageID) {
            order.remove(at: index)
            order.append(pageID)
        }
        return image
    }

    /// The provider of the drawing a page comes from, in a project of several drawings
    /// (NL-DOCS-04): a page index names a page only within its own PDF. `nil`, or a `nil`
    /// answer, falls back to ``provider``. Assigning it flushes nothing.
    @ObservationIgnored
    public var pageSource: (@MainActor (_ pageID: UUID) -> Provider?)?

    /// A page's thumbnail as the sheet is shown — cropped to its view crop and turned by its
    /// view rotation (NL-DOCS-07/16) — derived from the cached render and kept beside it.
    ///
    /// R-097: the derived images are budgeted and leave with their source. They used to sit
    /// beside any budget — up to `capacity + 1` extra bitmaps, flushed only when that count was
    /// passed. S-044: the budget is their own (``derivedByteBudget`` and ``capacity``), so a
    /// full render cache no longer evicts every turned copy but the newest.
    public func image(for page: PageDescriptor) -> CGImage? {
        guard let image = image(for: page.id) else { return nil }
        guard page.viewRotation != 0 || page.viewCrop != nil else { return image }
        let key = ViewKey(page: page.id, rotation: page.viewRotation, crop: page.viewCrop, width: image.width, height: image.height)
        if let derived = viewImages[key] {
            if let index = viewOrder.firstIndex(of: key) {
                viewOrder.remove(at: index)
                viewOrder.append(key)
            }
            return derived
        }
        guard let derived = Self.viewImage(image, for: page) else { return image }
        viewImages[key] = derived
        viewOrder.append(key)
        heldDerivedBytes += Self.byteCost(of: derived)
        // Only derived images are trimmed here: this runs inside a view body, and dropping a
        // source render would write the observed `images` from the body that just read it
        // — a render loop. The newest derived image is always kept.
        while viewOrder.count > 1, viewImages.count > capacity || heldDerivedBytes > derivedByteBudget {
            dropDerived(viewOrder[0])
        }
        return derived
    }

    /// Bytes held by derived (cropped or turned) images. For tests and diagnostics.
    public var derivedBytes: Int { heldDerivedBytes }

    /// How many derived images are held. For tests and diagnostics.
    public var derivedCount: Int { viewImages.count }

    private func dropDerived(_ key: ViewKey) {
        if let removed = viewImages.removeValue(forKey: key) {
            heldDerivedBytes -= Self.byteCost(of: removed)
        }
        if let index = viewOrder.firstIndex(of: key) { viewOrder.remove(at: index) }
    }

    /// Drops every derived image of one page — its source is leaving or being replaced.
    private func dropDerived(ofPage pageID: UUID) {
        for key in viewOrder where key.page == pageID { dropDerived(key) }
    }

    private struct ViewKey: Hashable {
        let page: UUID
        let rotation: Int
        let crop: PDFRectValue?
        let width: Int
        let height: Int
    }

    @ObservationIgnored
    private var viewImages: [ViewKey: CGImage] = [:]
    /// Derived images, least recently used first.
    @ObservationIgnored
    private var viewOrder: [ViewKey] = []

    /// Crops an upright thumbnail (the page's crop box after its own `/Rotate`) to the page's
    /// view box and turns it by its view rotation. Static and pure, so it is testable.
    static func viewImage(_ image: CGImage, for page: PageDescriptor) -> CGImage? {
        var working = image
        if page.viewCrop != nil {
            let box = page.cropBox, view = page.viewBox
            guard box.size.width > 0, box.size.height > 0 else { return nil }
            // The view box in the own-rotation display space, y down, as fractions.
            let u0 = (view.minX - box.minX) / box.size.width, u1 = (view.maxX - box.minX) / box.size.width
            let v0 = (view.minY - box.minY) / box.size.height, v1 = (view.maxY - box.minY) / box.size.height
            let fraction: CGRect
            switch page.rotation.rawValue {
            case 90: fraction = CGRect(x: v0, y: u0, width: v1 - v0, height: u1 - u0)
            case 180: fraction = CGRect(x: 1 - u1, y: v0, width: u1 - u0, height: v1 - v0)
            case 270: fraction = CGRect(x: 1 - v1, y: 1 - u1, width: v1 - v0, height: u1 - u0)
            default: fraction = CGRect(x: u0, y: 1 - v1, width: u1 - u0, height: v1 - v0)
            }
            let pixels = CGRect(
                x: fraction.minX * CGFloat(image.width), y: fraction.minY * CGFloat(image.height),
                width: fraction.width * CGFloat(image.width), height: fraction.height * CGFloat(image.height)
            ).integral
            guard let cropped = image.cropping(to: pixels) else { return nil }
            working = cropped
        }
        let turn = page.viewRotation
        guard turn != 0 else { return working }
        let swaps = turn == 90 || turn == 270
        let width = swaps ? working.height : working.width
        let height = swaps ? working.width : working.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // Clockwise on screen is a negative angle in the y-up bitmap context.
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turn) * .pi / 180)
        context.draw(working, in: CGRect(
            x: -CGFloat(working.width) / 2, y: -CGFloat(working.height) / 2,
            width: CGFloat(working.width), height: CGFloat(working.height)
        ))
        return context.makeImage()
    }

    /// Requests a page's thumbnail if it is neither cached nor already being rendered.
    public func request(pageID: UUID, pageIndex: Int) async {
        guard storedProvider != nil, images[pageID] == nil, !isInFlight(pageID) else { return }
        let requestGeneration = beginFlight(pageID)
        defer { endFlight(pageID, generation: requestGeneration) }
        let provider = pageSource?(pageID) ?? storedProvider
        guard let image = await provider?(pageIndex, Self.maximumPixelSize) else { return }
        // The document changed while the render was in flight: this image belongs to the
        // old provider and must not fill a row of the new one.
        guard requestGeneration == generation else { return }
        store(image, for: pageID)
    }

    /// Bumped whenever the provider changes — OBSERVED, deliberately, unlike `generation`.
    ///
    /// A row's `.task` keys on it: a document whose provider arrives AFTER the list first
    /// rendered used to leave every visible row a placeholder for ever, because the task
    /// had already run against a nil provider and nothing re-triggered it (LT-1,
    /// 2026-08-29). It is written only from `invalidate()`, never from a view body, so it
    /// cannot re-create the render loop documented on `order`.
    public private(set) var providerRevision = 0

    /// Drops everything cached. Called when the provider — the document — changes.
    public func invalidate() {
        viewImages.removeAll()
        viewOrder.removeAll()
        generation += 1
        providerRevision += 1
        images = [:]
        order = []
        sourceBytes = 0
        heldDerivedBytes = 0
    }

    /// How many images are held right now. For tests and diagnostics.
    public var cachedCount: Int { images.count }

    private func store(_ image: CGImage, for pageID: UUID) {
        if let replaced = images[pageID] {
            sourceBytes -= Self.byteCost(of: replaced)
            if let index = order.firstIndex(of: pageID) { order.remove(at: index) }
            dropDerived(ofPage: pageID)
        }
        order.append(pageID)
        images[pageID] = image
        sourceBytes += Self.byteCost(of: image)
        // The least recently used renders leave, each with its derived images (S-044: against
        // the renders' own bytes — the derived copies have their own budget).
        while order.count > 1, order.count > capacity || sourceBytes > byteBudget,
              let oldest = order.first {
            order.removeFirst()
            if let evicted = images.removeValue(forKey: oldest) {
                sourceBytes -= Self.byteCost(of: evicted)
            }
            dropDerived(ofPage: oldest)
        }
    }

    /// The cached subjects, least recently used first. For tests.
    var recencyOrder: [UUID] { order }
}
