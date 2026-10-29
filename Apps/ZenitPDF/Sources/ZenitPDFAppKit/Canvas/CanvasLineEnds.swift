import AppKit
import ZPDFContracts

/// The line-end decorations a markup's style names, drawn in view space (nl-markup,
/// NL-MARKUP-07).
///
/// Until 2026-09-23 the canvas drew exactly one decoration — a filled arrowhead — and chose it
/// from the markup's *kind*: an Arrow had one at its end and nothing else had any. The
/// `startCap` and `endCap` the record stores were written at creation and never read, so a
/// Line could not get an arrowhead and an Arrow could not lose one. These painters draw what
/// the record says, at either end.
///
/// Every head scales with the stroke through ``CanvasPageView/arrowheadDimensions(strokeWidth:shaftLength:)``,
/// so a 9 pt line keeps a head that clears its own width, and a head never outgrows its shaft.
@MainActor
enum CanvasLineEnds {

    /// Draws `cap` at `tip`, pointing along the segment from `previous` to `tip`.
    ///
    /// `.none` and `.butt` draw nothing: the stroke's own butt end is the decoration.
    static func draw(
        _ cap: ZPDFContracts.LineCapStyle,
        from previous: CGPoint,
        to tip: CGPoint,
        color: NSColor,
        strokeWidth: CGFloat
    ) {
        guard let path = path(cap, from: previous, to: tip, strokeWidth: strokeWidth) else { return }
        color.setFill()
        color.setStroke()
        if strokes(cap) {
            path.lineWidth = max(1, strokeWidth)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        } else {
            path.fill()
        }
    }

    /// Whether the decoration is stroked (an open arrow, a slash) rather than filled.
    nonisolated static func strokes(_ cap: ZPDFContracts.LineCapStyle) -> Bool {
        cap == .openArrow || cap == .slash
    }

    /// The decoration's outline, or `nil` when it draws nothing. Pure, so the shapes are
    /// testable without a graphics context.
    static func path(
        _ cap: ZPDFContracts.LineCapStyle,
        from previous: CGPoint,
        to tip: CGPoint,
        strokeWidth: CGFloat
    ) -> NSBezierPath? {
        let dx = tip.x - previous.x
        let dy = tip.y - previous.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.5 else { return nil }
        let ux = dx / length
        let uy = dy / length
        let (size, half) = CanvasPageView.arrowheadDimensions(strokeWidth: strokeWidth, shaftLength: length)
        let path = NSBezierPath()
        switch cap {
        case .none, .butt:
            return nil
        case .closedArrow:
            let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
            path.move(to: tip)
            path.line(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
            path.line(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
            path.close()
        case .openArrow:
            let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
            path.move(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
            path.line(to: tip)
            path.line(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        case .circle:
            // Centred on the end point, the conventional "dot" end.
            let radius = max(half, strokeWidth)
            path.appendOval(in: CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2))
        case .round:
            // A round stroke end: a disc one stroke wide on the end point.
            let radius = max(0.5, strokeWidth / 2)
            path.appendOval(in: CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2))
        case .square:
            let side = max(half, strokeWidth)
            // Turned with the line, so a square end on a diagonal stays square to it.
            let corners = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].map { a, b in
                CGPoint(
                    x: tip.x + (ux * a - uy * b) * side,
                    y: tip.y + (uy * a + ux * b) * side
                )
            }
            path.move(to: corners[0])
            corners.dropFirst().forEach { path.line(to: $0) }
            path.close()
        case .diamond:
            let reach = max(half, strokeWidth) * 1.4
            path.move(to: CGPoint(x: tip.x + ux * reach, y: tip.y + uy * reach))
            path.line(to: CGPoint(x: tip.x + uy * reach, y: tip.y - ux * reach))
            path.line(to: CGPoint(x: tip.x - ux * reach, y: tip.y - uy * reach))
            path.line(to: CGPoint(x: tip.x - uy * reach, y: tip.y + ux * reach))
            path.close()
        case .slash:
            // The architectural tick: 45° through the end point.
            let reach = max(half, strokeWidth) * 1.3
            let sx = (ux + uy) / 2.0.squareRoot()
            let sy = (uy - ux) / 2.0.squareRoot()
            path.move(to: CGPoint(x: tip.x - sx * reach, y: tip.y - sy * reach))
            path.line(to: CGPoint(x: tip.x + sx * reach, y: tip.y + sy * reach))
        }
        return path
    }

    /// Draws both ends of an open stroke from its view-space points.
    static func drawEnds(
        of stroke: CanvasStroke,
        viewPoints: [CGPoint],
        color: NSColor,
        strokeWidth: CGFloat
    ) {
        guard !stroke.closed, viewPoints.count >= 2 else { return }
        let end = stroke.drawnEndCap
        if end != .none {
            draw(end, from: viewPoints[viewPoints.count - 2], to: viewPoints[viewPoints.count - 1],
                 color: color, strokeWidth: strokeWidth)
        }
        if stroke.startCap != .none {
            draw(stroke.startCap, from: viewPoints[1], to: viewPoints[0], color: color, strokeWidth: strokeWidth)
        }
    }
}

/// The stored font and alignment of a markup's text, resolved for drawing (nl-markup).
///
/// `MarkupStyle.fontName` is a family name ("Helvetica" by default) and the canvas drew the
/// system font whatever it said, so the screen and any font-aware export could disagree.
enum CanvasMarkupFont {

    /// The families the Inspector offers: faces that ship with every supported macOS, so a
    /// project opened on another Mac draws the same letters. `System` is the interface face.
    static let families: [String] = [
        systemFamily, "Helvetica", "Helvetica Neue", "Arial", "Avenir Next",
        "Times New Roman", "Georgia", "Courier New", "Menlo"
    ]

    /// The stored name that means "the system font".
    static let systemFamily = "System"

    /// The font for a markup's text: the named family at `size` and `weight`, or the system
    /// font when the family is missing, empty or "System".
    static func font(named name: String?, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        guard let name, !name.isEmpty, name != systemFamily else { return system }
        let manager = NSFontManager.shared
        let wantsBold = weight >= .semibold
        if let face = manager.font(
            withFamily: name,
            traits: wantsBold ? .boldFontMask : [],
            weight: wantsBold ? 9 : 5,
            size: size
        ) {
            return face
        }
        // A PostScript or full face name ("Helvetica-Bold") rather than a family.
        return NSFont(name: name, size: size) ?? system
    }

    /// The font with bold and italic traits from a stored `MarkupTextStyle` (ADR-0029). A face
    /// the family does not have (an italic of a font with none) keeps the upright face rather
    /// than falling back to a different family.
    static func font(named name: String?, size: CGFloat, weight: NSFont.Weight, bold: Bool, italic: Bool) -> NSFont {
        var face = font(named: name, size: size, weight: bold ? .bold : weight)
        let manager = NSFontManager.shared
        if bold, !manager.traits(of: face).contains(.boldFontMask) {
            face = manager.convert(face, toHaveTrait: .boldFontMask)
        }
        if italic {
            face = manager.convert(face, toHaveTrait: .italicFontMask)
        }
        return face
    }

    /// The paragraph alignment a stored `TextAlignment` means.
    static func alignment(_ alignment: ZPDFContracts.TextAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        case .justified: .justified
        }
    }
}
