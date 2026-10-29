import AppKit
import ZPDFDesignSystem

/// Renders every measurement glyph into one PNG so the icon set can be reviewed without Xcode.
enum ContactSheet {

    @MainActor
    static func write(to path: String, cell: CGFloat = 72, columns: Int = 5) -> Bool {
        let kinds = ZPDFIconKind.allCases
        let rows = Int((Double(kinds.count) / Double(columns)).rounded(.up))
        let width = Int(cell * CGFloat(columns))
        let height = Int(cell * CGFloat(rows))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return false
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        ZPDFColor.rgba(.surface, .light).nsColor.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()

        for (index, kind) in kinds.enumerated() {
            let column = index % columns
            let row = index / columns
            // The bitmap context has a bottom-left origin; lay the grid out top-down.
            let originY = CGFloat(height) - CGFloat(row + 1) * cell
            let box = NSRect(x: CGFloat(column) * cell, y: originY, width: cell, height: cell)

            ZPDFColor.rgba(.border, .light).nsColor.setStroke()
            NSBezierPath(rect: box.insetBy(dx: 0.25, dy: 0.25)).stroke()

            let glyph = ZPDFIcon.image(kind, size: 40)
            let glyphRect = NSRect(x: box.midX - 20, y: box.midY - 14, width: 40, height: 40)
            ZPDFColor.rgba(.textPrimary, .light).nsColor.set()
            glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            let label = kind.rawValue as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: ZPDFTypography.nsFont(.caption.withSize(8)),
                .foregroundColor: ZPDFColor.rgba(.textSecondary, .light).nsColor
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.minY + 5), withAttributes: attributes)
        }

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
