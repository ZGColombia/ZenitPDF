import CoreGraphics
import Foundation
import ZPDFUIPresentation

/// Where every page of a document sits in continuous scrolling: one vertical strip of sheets,
/// each on a shared centre line, with a gap between neighbours that scales with the zoom.
///
/// The canvas lays one page out *live* (the one the tools act on) and shows its neighbours as
/// passive pictures; all of them are placed by this value. It is pure arithmetic over the
/// pages' display sizes, so the follow rule, the slots and the resting positions are testable
/// without a window, and the per-event questions a scroll asks — which slot is under a point,
/// which slots meet the viewport — are binary searches, never a walk over the document.
///
/// ## Geometry
///
/// In the document view's flipped coordinates, page `k` occupies
///
/// - `y_k = panMargin.height + zoom × Σ_{j<k}(H_j + gap) − windowShift`
/// - `x_k = panMargin.width + zoom × (maxW − W_k) / 2`
///
/// where `W` and `H` are display sizes in page points. Because the gap is in page points the
/// strip is an exact similarity under zoom: every point keeps its place relative to every
/// other, so zooming about a point on any sheet is the arithmetic a single sheet already uses.
/// For a one-page document the slot origin is `panMargin`, the single-page layout exactly.
///
/// ## The window
///
/// A long document at a high zoom is taller than any view hierarchy should be: 323 A1 sheets at
/// 6400 % are about 35 million points. Core Animation's behaviour at that magnitude could not be
/// shown to be exact without a display, so the strip lays out only a *window* of pages, at most
/// ``maximumDocumentHeight`` tall, around an anchor page. `windowShift` moves the window's first
/// slot to the top of the document by a whole number of points, so a re-base moves every sheet
/// by whole device pixels and every cached tile stays valid. A strip that fits is never
/// windowed, which is every document at the zooms a person reads at.
public struct PageStripLayout: Equatable, Sendable {

    /// Page points between two sheets. Scaled by the zoom like the sheets themselves.
    public static let gap: CGFloat = 24

    /// The tallest document view the strip lays out: 2¹⁹ points. Single-page layout reaches
    /// about 2¹⁸ (an A0 at 6400 % plus its pan margins), so magnitudes stay within a factor of
    /// two of what the canvas has always shown.
    public static let maximumDocumentHeight: CGFloat = 524_288

    /// Breathing room between the viewport's top edge and a sheet that navigation rests on.
    public static let restingGap: CGFloat = 16

    /// How much larger a challenger's visible area must be before the current page hands over.
    public static let followHysteresis: CGFloat = 1.2

    /// How many slots the follow rule weighs at most, nearest the viewport centre first.
    public static let followCandidateLimit = 64

    /// Each page's display size in page points: the view box after the display rotation.
    public let pageSizes: [CGSize]
    /// View points per page point.
    public let zoom: CGFloat
    /// Pannable space around the strip, on each side.
    public let panMargin: CGSize
    /// The pages the document view lays out.
    public let window: Range<Int>
    /// Whole points the window's first slot is moved up by.
    public let windowShift: CGFloat
    /// The widest page's display width, page points.
    public let maximumWidth: CGFloat
    /// `offsets[k]` is Σ_{j<k}(H_j + gap), page points; `count == pageSizes.count + 1`.
    private let offsets: [CGFloat]

    /// Lays the strip out.
    ///
    /// - Parameters:
    ///   - pageSizes: every page's display size, in document order.
    ///   - zoom: view points per page point.
    ///   - panMargin: pannable space on each side of the strip.
    ///   - windowAnchor: the page a window is centred on when the strip is too tall for one
    ///     document view. Ignored when it fits.
    ///   - maximumDocumentHeight: the window's bound; a test passes a small one.
    public init(
        pageSizes: [CGSize],
        zoom: CGFloat,
        panMargin: CGSize,
        windowAnchor: Int = 0,
        maximumDocumentHeight: CGFloat = PageStripLayout.maximumDocumentHeight
    ) {
        self.pageSizes = pageSizes
        self.zoom = max(zoom, .leastNormalMagnitude)
        self.panMargin = panMargin
        var offsets = [CGFloat](repeating: 0, count: pageSizes.count + 1)
        var running: CGFloat = 0
        var widest: CGFloat = 0
        for (index, size) in pageSizes.enumerated() {
            offsets[index] = running
            running += size.height + Self.gap
            widest = max(widest, size.width)
        }
        offsets[pageSizes.count] = running
        self.offsets = offsets
        self.maximumWidth = widest
        let window = Self.window(
            offsets: offsets, sizes: pageSizes, zoom: self.zoom,
            budget: max(0, maximumDocumentHeight - 2 * panMargin.height),
            anchor: windowAnchor
        )
        self.window = window
        self.windowShift = window.isEmpty ? 0 : (self.zoom * offsets[window.lowerBound]).rounded(.down)
    }

    /// A page's display size: its view box, turned by its display rotation.
    public static func displaySize(of box: PDFRectValue, rotation: Int) -> CGSize {
        PageDisplayTransform(pageBox: box, rotation: rotation, zoom: 1, origin: .zero).displaySize
    }

    public var pageCount: Int { pageSizes.count }

    /// Whether every page is laid out.
    public var isWindowed: Bool { window != 0..<pageSizes.count }

    // MARK: Slots

    /// The top of page `index`'s slot, document coordinates. Defined for any index, laid out
    /// or not, so a re-base can be computed before it happens.
    public func slotMinY(of index: Int) -> CGFloat {
        panMargin.height + zoom * offsets[index] - windowShift
    }

    /// The bottom of page `index`'s slot.
    public func slotMaxY(of index: Int) -> CGFloat {
        slotMinY(of: index) + zoom * pageSizes[index].height
    }

    /// Page `index`'s rectangle, document coordinates.
    public func slotFrame(of index: Int) -> CGRect {
        let size = pageSizes[index]
        return CGRect(
            x: panMargin.width + zoom * (maximumWidth - size.width) / 2,
            y: slotMinY(of: index),
            width: zoom * size.width,
            height: zoom * size.height
        )
    }

    /// The origin a page's display transform takes in its slot.
    public func slotOrigin(of index: Int) -> CGPoint { slotFrame(of: index).origin }

    /// The laid-out sheets together, without the pan margin.
    public var stripFrame: CGRect {
        guard let first = window.first, let last = window.last else { return .null }
        let top = slotMinY(of: first)
        return CGRect(
            x: panMargin.width,
            y: top,
            width: zoom * maximumWidth,
            height: slotMaxY(of: last) - top
        )
    }

    /// The document view's size: the laid-out strip and the pan margin on every side.
    public var documentSize: CGSize {
        let strip = stripFrame
        guard !strip.isNull else { return CGSize(width: 2 * panMargin.width, height: 2 * panMargin.height) }
        return CGSize(width: strip.width + 2 * panMargin.width, height: strip.maxY + panMargin.height)
    }

    // MARK: Questions a scroll asks, in O(log n)

    /// The laid-out page whose slot contains `point`, or `nil` over a gap, a margin or beside
    /// a narrower sheet.
    public func page(at point: CGPoint) -> Int? {
        guard let index = slotIndex(atOrAbove: point.y) else { return nil }
        let frame = slotFrame(of: index)
        guard point.y <= frame.maxY, point.x >= frame.minX, point.x <= frame.maxX else { return nil }
        return index
    }

    /// The laid-out pages whose slots meet `rect`, top to bottom.
    public func visibleRange(_ rect: CGRect) -> Range<Int> {
        guard !window.isEmpty, !rect.isNull, rect.height >= 0 else { return window.lowerBound..<window.lowerBound }
        // The first slot whose bottom reaches the rect's top…
        var low = window.lowerBound, high = window.upperBound
        while low < high {
            let mid = (low + high) / 2
            if slotMaxY(of: mid) <= rect.minY { low = mid + 1 } else { high = mid }
        }
        let first = low
        // …to the last slot whose top is above the rect's bottom.
        high = window.upperBound
        while low < high {
            let mid = (low + high) / 2
            if slotMinY(of: mid) < rect.maxY { low = mid + 1 } else { high = mid }
        }
        guard rect.maxX > panMargin.width, rect.minX < panMargin.width + zoom * maximumWidth else {
            return first..<first
        }
        return first..<max(first, low)
    }

    /// The laid-out page nearest a document y: the slot containing it, or across a gap the
    /// nearer of the two neighbours.
    public func nearestPage(toY y: CGFloat) -> Int? {
        guard let last = window.last else { return nil }
        guard let index = slotIndex(atOrAbove: y) else { return window.lowerBound }
        guard y > slotMaxY(of: index), index < last else { return index }
        return (y - slotMaxY(of: index)) <= (slotMinY(of: index + 1) - y) ? index : index + 1
    }

    /// The last laid-out slot whose top is at or above `y`.
    private func slotIndex(atOrAbove y: CGFloat) -> Int? {
        var low = window.lowerBound, high = window.upperBound
        while low < high {
            let mid = (low + high) / 2
            if slotMinY(of: mid) <= y { low = mid + 1 } else { high = mid }
        }
        return low == window.lowerBound ? nil : low - 1
    }

    // MARK: Navigation

    /// The scroll origin that rests page `index`: its top edge ``restingGap`` below the viewport's
    /// top, or the whole sheet centred when it fits. Horizontally the sheet is centred when it
    /// fits and `currentX` is kept when it does not. Clamped to the document.
    public func restingOrigin(for index: Int, viewport: CGSize, currentX: CGFloat) -> CGPoint {
        let frame = slotFrame(of: index)
        let document = documentSize
        let y: CGFloat = frame.height + 2 * Self.restingGap > viewport.height
            ? frame.minY - Self.restingGap
            : frame.midY - viewport.height / 2
        let x: CGFloat = frame.width <= viewport.width + 0.5 ? frame.midX - viewport.width / 2 : currentX
        return CGPoint(
            x: min(max(x, 0), max(0, document.width - viewport.width)),
            y: min(max(y, 0), max(0, document.height - viewport.height))
        )
    }

    // MARK: The follow rule

    /// The page the tools should follow for a viewport: the page with the largest visible
    /// area, ties going to the slot nearest the viewport's centre.
    ///
    /// Two rules keep it from flickering. A challenger must show ``followHysteresis`` times the
    /// current page's area before it takes over; and between two sheets wholly in view — several
    /// small sheets at a low zoom — the one under the viewport's centre line wins, which only
    /// one slot at a time can be. A current page that is not in view at all hands
    /// over to the best page unconditionally.
    public func pageToFollow(visible: CGRect, current: Int) -> Int {
        let range = visibleRange(visible)
        guard !range.isEmpty else { return current }
        let centre = CGPoint(x: visible.midX, y: visible.midY)
        // At most `followCandidateLimit` slots, nearest the centre: zoomed far out a viewport can
        // hold hundreds of small sheets, and the answer is always near the centre.
        var candidates = range
        if range.count > Self.followCandidateLimit {
            let middle = nearestPage(toY: centre.y).map { min(max($0, range.lowerBound), range.upperBound - 1) }
                ?? range.lowerBound
            let half = Self.followCandidateLimit / 2
            let low = max(range.lowerBound, middle - half)
            candidates = low..<min(range.upperBound, low + Self.followCandidateLimit)
        }
        func area(_ index: Int) -> CGFloat {
            let overlap = slotFrame(of: index).intersection(visible)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        func distance(_ index: Int) -> CGFloat {
            abs(slotFrame(of: index).midY - centre.y)
        }
        func isWhole(_ index: Int, _ shown: CGFloat) -> Bool {
            let frame = slotFrame(of: index)
            return shown >= frame.width * frame.height * 0.99
        }
        func holdsCentre(_ index: Int) -> Bool {
            let frame = slotFrame(of: index)
            return centre.y >= frame.minY && centre.y <= frame.maxY
        }
        var best = candidates.lowerBound
        var bestArea = area(best)
        for index in candidates.dropFirst() {
            let candidate = area(index)
            if candidate > bestArea * 1.01 || (candidate >= bestArea * 0.99 && distance(index) < distance(best)) {
                best = index
                bestArea = candidate
            }
        }
        if best == current { return current }
        guard window.contains(current) else { return best }
        let incumbent = area(current)
        if incumbent <= 0 { return best }
        if bestArea > incumbent * Self.followHysteresis { return best }
        // Equal areas only mean "both wholly in view"; then the centre line decides.
        if isWhole(best, bestArea), isWhole(current, incumbent), holdsCentre(best), !holdsCentre(current) {
            return best
        }
        return current
    }

    // MARK: Re-basing a window

    /// Whether the viewport has come close enough to an edge of the laid-out window, with
    /// pages beyond it, that the window should be laid out again around the viewport.
    public func needsRebase(visible: CGRect) -> Bool {
        guard isWindowed, let first = window.first, let last = window.last else { return false }
        let reach = max(visible.height * 2, (slotMaxY(of: last) - slotMinY(of: first)) / 4)
        if first > 0, visible.minY < slotMinY(of: first) + reach { return true }
        if last < pageCount - 1, visible.maxY > slotMaxY(of: last) - reach { return true }
        return false
    }

    /// The window around `anchor`: every page when the strip fits `budget`, otherwise the pages
    /// wholly inside a budget-tall band centred on the anchor — moved to lie inside the strip —
    /// and always the anchor itself.
    private static func window(
        offsets: [CGFloat], sizes: [CGSize], zoom: CGFloat, budget: CGFloat, anchor: Int
    ) -> Range<Int> {
        let count = sizes.count
        guard count > 0 else { return 0..<0 }
        let total = zoom * (offsets[count] - gap)
        guard total > budget, count > 1 else { return 0..<count }
        let anchor = min(max(anchor, 0), count - 1)
        let centre = zoom * (offsets[anchor] + sizes[anchor].height / 2)
        var low = centre - budget / 2
        var high = centre + budget / 2
        if low < 0 { high -= low; low = 0 }
        if high > total { low = max(0, low - (high - total)); high = total }
        // The first page whose top is inside the band.
        var first = 0, upper = count
        while first < upper {
            let mid = (first + upper) / 2
            if zoom * offsets[mid] < low { first = mid + 1 } else { upper = mid }
        }
        // One past the last page whose bottom is inside the band.
        var end = first
        upper = count
        while end < upper {
            let mid = (end + upper) / 2
            if zoom * (offsets[mid] + sizes[mid].height) <= high { end = mid + 1 } else { upper = mid }
        }
        return min(first, anchor)..<max(end, anchor + 1)
    }
}
