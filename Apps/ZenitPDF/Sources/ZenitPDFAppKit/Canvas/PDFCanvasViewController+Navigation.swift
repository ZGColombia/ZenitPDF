import AppKit
import Foundation
import ZPDFAppCore
import ZPDFUIPresentation

/// Places on the sheet (NL-DOCS-06 bookmarks, NL-DOCS-09 links and history): where the view is,
/// showing a destination's left/top — keeping an axis the destination leaves open — and the
/// pointing hand and tooltip over a drawing's own link.
extension PDFCanvasViewController {

    /// The sheet on screen and the page point at the view's top-left.
    func currentPlace() -> NavigationPlace? {
        guard let page = core.document.currentPage else { return nil }
        guard let transform = pageView.transform else { return NavigationPlace(pageID: page.id) }
        let visible = pageView.visibleRect
        let point = transform.pagePoint(from: CGPoint(x: visible.minX, y: visible.minY))
        return NavigationPlace(pageID: page.id, left: point.x, top: point.y)
    }

    /// Shows a place: turns to its sheet and brings `left`/`top` (page space) to the view's
    /// top-left. An axis given as `nil` keeps the current position on that axis (BH-586).
    func show(pageID: UUID, left: Double?, top: Double?, turn: (UUID) -> Void) {
        pendingDestination = (pageID, left, top)
        if core.document.currentPageID == pageID, let transform = pageView.transform {
            applyPendingDestination(on: pageID, transform: transform)
        } else {
            turn(pageID)
        }
    }

    /// Applies the waiting destination once its sheet is laid out.
    func applyPendingDestination(on pageID: UUID, transform: PageDisplayTransform) {
        guard let pending = pendingDestination, pending.pageID == pageID else { return }
        pendingDestination = nil
        guard pending.left != nil || pending.top != nil else { return }
        let visible = pageView.visibleRect
        let here = transform.pagePoint(from: CGPoint(x: visible.minX, y: visible.minY))
        let target = PDFPointValue(x: pending.left ?? here.x, y: pending.top ?? here.y)
        let view = transform.viewPoint(from: target)
        // Only the axes the destination names move.
        let origin = NSPoint(
            x: pending.left == nil ? visible.minX : view.x,
            y: pending.top == nil ? visible.minY : view.y
        )
        pageView.scroll(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The chords ``handleNavigationKey(_:)`` takes before the menu does: ⌘[ back, ⌘] forward —
    /// the Mac navigation standard, which keeps them (Arrange
    /// uses ⌥⌘ chords). `ShortcutChordUniquenessTests` holds every other chord against these.
    static let navigationChords: [ZenitKeyEquivalent] = [
        ZenitKeyEquivalent("[", [.command]),
        ZenitKeyEquivalent("]", [.command])
    ]

    /// ⌘[ back, ⌘] forward.
    func handleNavigationKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let characters = event.charactersIgnoringModifiers, let onNavigateHistory else { return false }
        switch characters {
        case "[": onNavigateHistory(true); return true
        case "]": onNavigateHistory(false); return true
        default: return false
        }
    }

    /// Whether a click at the pointer would follow a drawing link: the conditions `handleClick`
    /// checks before `followDrawingLink` — no tool, preset, calibration or text box in charge,
    /// and no markup under the pointer (a click there selects the markup first).
    var drawingLinkHoverApplies: Bool {
        guard core.markup.activeKind == nil, core.measurement.activeKind == nil, !isCalibrating,
              activeTextEntry == nil, !isCapturingSnippetRegion, pageView.hoverTarget == nil else { return false }
        if core.toolLibrary.activePreset != nil, core.toolLibrary.armedSetMode != .draw { return false }
        return true
    }

    /// The pointing hand and a tooltip naming the target over a drawing's own link.
    ///
    /// R-010: the hand used to stick after the pointer left the link — the cursor rect is only
    /// reapplied on re-entry and an empty-paper hover sets no cursor — and it replaced the move
    /// hand over a markup lying on a link, although a click there selects the markup.
    func updateLinkHover(at point: PDFPointValue?) {
        guard drawingLinkHoverApplies, let page = core.document.currentPage else {
            leaveDrawingLinkHover()
            return
        }
        let key = rasterKey(of: page)
        guard let links = drawingLinksByPage[key] else {
            // Read once per page, in the background; the next move uses them.
            if onFollowLink != nil, !drawingLinkReads.contains(key), let source = rasterSource(for: page) {
                drawingLinkReads.insert(key)
                let index = page.index
                Task { @MainActor [weak self] in
                    let read = (try? await source.links(pageIndex: index)) ?? []
                    self?.drawingLinksByPage[key] = read
                }
            }
            return
        }
        guard let point, let hit = DrawingLink.hit(CGPoint(x: point.x, y: point.y), in: links) else {
            leaveDrawingLinkHover()
            return
        }
        let text = describeLinkTarget?(hit.target) ?? ""
        if pageView.toolTip != text { pageView.toolTip = text.isEmpty ? nil : text }
        isOverDrawingLink = true
        NSCursor.pointingHand.set()
    }

    /// Off a link: no tooltip, and the cursor the canvas would show without the link.
    private func leaveDrawingLinkHover() {
        if pageView.toolTip != nil { pageView.toolTip = nil }
        guard isOverDrawingLink else { return }
        isOverDrawingLink = false
        pageView.restingCursor().set()
    }
}
