import AppKit
import ZPDFDesignSystem

/// The running number beside a numbered count mark (NL-MEASURE-12).
enum CanvasCountNumbers {

    /// Draws `number` to the upper right of a mark at `point` (flipped view coordinates), in the
    /// markup's ink on a paper-coloured backing so it reads over linework. The type keeps its size
    /// on the sheet, like the symbol, with a floor so it stays legible zoomed out.
    @MainActor
    static func drawNumber(_ number: Int, beside point: CGPoint, zoom: CGFloat, color: NSColor) {
        let size = Swift.max(8, 7 * zoom)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color
        ]
        let text = "\(number)" as NSString
        let textSize = text.size(withAttributes: attributes)
        let offset = Swift.max(5, 5 * zoom)
        let origin = CGPoint(x: point.x + offset, y: point.y - offset - textSize.height)
        let backing = CGRect(origin: origin, size: textSize).insetBy(dx: -2, dy: -1)
        ZPDFColor.nsColor(.elevated).withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: backing, xRadius: 2, yRadius: 2).fill()
        text.draw(at: origin, withAttributes: attributes)
    }
}
