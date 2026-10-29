import AppKit
import Foundation
import ZPDFUIPresentation

/// The pointer each canvas verb wears.
///
/// # Why two of them are drawn here
///
/// macOS ships a cursor for *select*, for *pan* and for *place a point*. It ships nothing that
/// means "this click writes properties onto the thing underneath" or "this click drops a copy",
/// and both of those clicks are destructive in a way a crosshair does not warn about — Apply
/// rewrites a whole selection, Place leaves a markup behind. So Zenit draws them: a crosshair,
/// which is the promise that the hot spot is the point under the pen, plus a badge in the lower
/// right that names the verb.
///
/// The artwork is generated from SF Symbols and plain strokes, in code, from
/// ``CanvasCursorKind/badgeSymbolName``. Nothing here is traced from another product; the
/// crosshair-plus-badge composition is the platform's own idiom for a modified pointer, and the
/// badge is the system symbol for the verb.
///
/// # The hot spot is the crosshair centre, always
///
/// A cursor whose hot spot is not where the estimator thinks the point is puts every stamp a
/// few points off. The badge is drawn *away* from the hot spot for that reason, and
/// ``hotSpot`` is asserted against the crosshair geometry rather than hard-coded twice.
@MainActor
public enum ZenitCanvasCursor {

    /// Side of the generated cursor image, in points.
    static let imageSide: CGFloat = 24
    /// Side of the crosshair, which occupies the upper-left of the image.
    static let crosshairSide: CGFloat = 16
    /// Where the click lands: the crosshair's centre.
    static let hotSpot = NSPoint(x: crosshairSide / 2, y: crosshairSide / 2)

    /// The cursor for one verb.
    public static func cursor(for kind: CanvasCursorKind) -> NSCursor {
        switch kind {
        case .select: return .arrow
        case .pan: return .openHand
        case .zoom: return .crosshair
        case .draw: return .crosshair
        case .apply: return applyCursor
        case .place: return placeCursor
        }
    }

    /// The Apply brush.
    public static let applyCursor = makeBadgedCrosshair(kind: .apply)
    /// The Place stamp.
    public static let placeCursor = makeBadgedCrosshair(kind: .place)

    /// Builds a crosshair with the verb's badge in the lower right.
    ///
    /// Drawn twice — a white outline under a black core — so the cursor reads on a white sheet
    /// and on the dark canvas backdrop alike. A single-colour cursor disappears against one of
    /// them, and which one it disappears against depends on the drawing.
    static func makeBadgedCrosshair(kind: CanvasCursorKind) -> NSCursor {
        let image = NSImage(size: NSSize(width: imageSide, height: imageSide), flipped: false) { _ in
            drawCrosshair(lineWidth: 3, color: .white)
            drawCrosshair(lineWidth: 1, color: .black)
            if let symbolName = kind.badgeSymbolName {
                drawBadge(symbolName: symbolName)
            }
            return true
        }
        image.accessibilityDescription = kind.verbDescription
        return NSCursor(image: image, hotSpot: hotSpot)
    }

    private static func drawCrosshair(lineWidth: CGFloat, color: NSColor) {
        let centre = NSPoint(x: crosshairSide / 2, y: imageSide - crosshairSide / 2)
        let arm = crosshairSide / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: centre.x - arm, y: centre.y))
        path.line(to: NSPoint(x: centre.x + arm, y: centre.y))
        path.move(to: NSPoint(x: centre.x, y: centre.y - arm))
        path.line(to: NSPoint(x: centre.x, y: centre.y + arm))
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }

    private static func drawBadge(symbolName: String) {
        let side: CGFloat = 13
        let rect = NSRect(x: imageSide - side, y: 0, width: side, height: side)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return
        }
        // A white plate behind the badge, for the same reason the crosshair has a white
        // outline: the badge has to survive both backdrops.
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: side, weight: .semibold)
        ) ?? symbol
        configured.isTemplate = true
        NSColor.black.set()
        configured.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

extension CanvasCursorKind {

    /// The AppKit cursor for this verb.
    @MainActor
    public var nsCursor: NSCursor { ZenitCanvasCursor.cursor(for: self) }
}
