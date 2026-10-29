import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Design round, visual QA: the canvas half of the off-screen render harness.
///
/// Draws `CanvasPageView` — the shipping canvas — into a 1× bitmap with the markup families the
/// 2026-09-23 reference design shows: a selected area with its vertex handles and pill, a dashed length
/// with its pill, three callouts with leaders and two revision clouds, on a white sheet. No
/// window is created; the view is drawn with `cacheDisplay(in:to:)` standalone, as
/// `CanvasDrawingTests` does.
///
/// The geometry is placed where the reference design places it (design pixel = point, canvas
/// origin at design x 285, y 148), so a crop of the design and this render line up one to one. The
/// markup text and colours here are fixture values for the comparison, not product defaults.
/// With `ZENIT_DESIGN_QA_OUT` set the PNG is written there; otherwise nothing is written.
@MainActor
@Suite(.appTierSerialised)
struct DesignQACanvasRenderTests {

    static let viewSize = CGSize(width: 1_076, height: 712)
    static let pageSize = CGSize(width: 1_060, height: 696)
    static let origin = CGPoint(x: 8, y: 8)

    /// Design pixel → page point, through the same transform the view uses.
    static func page(_ mockX: CGFloat, _ mockY: CGFloat) -> PDFPointValue {
        let viewX = mockX - 285
        let viewY = mockY - 148
        return PDFPointValue(x: Double(viewX - origin.x), y: Double(pageSize.height - (viewY - origin.y)))
    }

    /// A white sheet with a light grid and a border, standing in for a floor plan.
    static func sheet() -> CGImage {
        let width = Int(pageSize.width), height = Int(pageSize.height)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1))
        context.setLineWidth(1)
        context.stroke(CGRect(x: 14, y: 80, width: 862, height: 604))
        context.setLineWidth(3)
        context.stroke(CGRect(x: 82, y: 146, width: 718, height: 400))
        context.setLineWidth(0.5)
        for x in stride(from: 82, through: 800, by: 120) {
            context.move(to: CGPoint(x: x, y: 146)); context.addLine(to: CGPoint(x: x, y: 546))
        }
        context.strokePath()
        return context.makeImage()!
    }

    static let blue = ColorRGBA(red: 0.10, green: 0.42, blue: 1.0, alpha: 1)
    static let red = ColorRGBA(red: 0.90, green: 0.12, blue: 0.14, alpha: 1)
    static let green = ColorRGBA(red: 0.10, green: 0.62, blue: 0.30, alpha: 1)

    static func callout(_ color: ColorRGBA, text: String, box: (CGFloat, CGFloat, CGFloat, CGFloat),
                        target: (CGFloat, CGFloat)) -> CanvasMarkupShape {
        let corner1 = page(box.0, box.1), corner2 = page(box.2, box.3)
        let rect = ZenitMarkupGeometry.boundingRect(corner1, corner2)
        let tip = page(target.0, target.1)
        let attachment = ZenitMarkupGeometry.leaderAttachment(target: tip, box: rect)
        let border = ZenitMarkupGeometry.rectangleCorners(
            PDFPointValue(x: rect.minX, y: rect.minY),
            PDFPointValue(x: rect.maxX, y: rect.maxY)
        )
        return CanvasMarkupShape(
            id: UUID(), pageID: pageID, color: color,
            strokes: [
                CanvasStroke(points: [attachment, tip], closed: false, filled: false, arrowAtEnd: true),
                CanvasStroke(points: border, closed: true, filled: false)
            ],
            counts: [], bounds: rect, hidden: false, kind: .callout, text: text, textBox: rect,
            leaderTarget: tip, fontSize: 12
        )
    }

    static func cloud(_ color: ColorRGBA, ring: [(CGFloat, CGFloat)]) -> CanvasMarkupShape {
        let points = ring.map { page($0.0, $0.1) }
        let radius = CanvasSceneBuilder.cloudScallopRadius(of: points)
        let outline = ZenitMarkupGeometry.cloudOutline(points, radius: radius)
        let xs = points.map(\.x), ys = points.map(\.y)
        return CanvasMarkupShape(
            id: UUID(), pageID: pageID, color: color,
            strokes: [CanvasStroke(points: outline, closed: true, filled: false)],
            counts: [],
            bounds: PDFRectValue(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!),
            hidden: false, kind: .cloud, lineWidth: 1.5
        )
    }

    static let pageID = UUID()

    /// The reference design's scene, in its places.
    static func scene() -> (shapes: [CanvasMarkupShape], selected: UUID) {
        let areaRing = [page(378, 312), page(543, 312), page(543, 442), page(378, 442)]
        let area = CanvasMarkupShape(
            id: UUID(), pageID: pageID, color: blue,
            strokes: [CanvasStroke(points: areaRing, closed: true, filled: true)],
            counts: [],
            bounds: PDFRectValue(x: areaRing[3].x, y: areaRing[3].y, width: 165, height: 130),
            hidden: false, caption: "Area: 620 SF", kind: .measurement, lineWidth: 2,
            vertices: areaRing
        )
        let length = CanvasMarkupShape(
            id: UUID(), pageID: pageID, color: blue,
            // A committed length carries the dimension grammar, as `CanvasSceneBuilder` builds it.
            strokes: [CanvasStroke(points: [page(395, 641), page(541, 641)], closed: false, filled: false,
                                   dimensioned: true)],
            counts: [],
            bounds: PDFRectValue(x: page(395, 641).x, y: page(395, 641).y, width: 146, height: 1),
            hidden: false, caption: "24' - 0\"", kind: .measurement, lineWidth: 2, lineStyle: .dashed,
            vertices: [page(395, 641), page(541, 641)]
        )
        let shapes = [
            area,
            length,
            callout(red, text: "Verify door type with Architect", box: (708, 463, 818, 505), target: (678, 523)),
            callout(green, text: "Confirm plumbing layout", box: (1000, 541, 1118, 582), target: (975, 575)),
            callout(blue, text: "Add wall per RFI #12", box: (755, 735, 893, 760), target: (706, 688)),
            cloud(red, ring: [(622, 512), (690, 512), (690, 562), (622, 562)]),
            cloud(green, ring: [(892, 548), (1088, 548), (1088, 712), (892, 712)])
        ]
        return (shapes, area.id)
    }

    @Test("The canvas draws the reference markup scene off screen")
    func canvasScene() {
        let view = CanvasPageView()
        view.backingScaleOverride = 1
        view.transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: Self.pageSize.width, height: Self.pageSize.height),
            rotation: 0, zoom: 1, origin: Self.origin
        )
        view.pageImage = Self.sheet()
        let scene = Self.scene()
        view.shapes = scene.shapes
        view.selection = [scene.selected]
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = CGRect(origin: .zero, size: Self.viewSize)

        let device = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(Self.viewSize.width), pixelsHigh: Int(Self.viewSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        // Tagged sRGB before drawing, so the bytes are sRGB whatever the process's window-server
        // state (device RGB means the display profile once a connection exists).
        let rep = device.retagging(with: .sRGB) ?? device
        rep.size = Self.viewSize
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }

        if let directory = ProcessInfo.processInfo.environment["ZENIT_DESIGN_QA_OUT"], !directory.isEmpty,
           let data = rep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? data.write(to: url.appendingPathComponent("canvas-markup-dark.png"))
        }

        // The sheet is light where nothing is drawn, and the selected area is tinted blue inside.
        // Raw sRGB bytes: `colorAt` converts through the display profile.
        func colour(_ mockX: CGFloat, _ mockY: CGFloat) -> [Int] {
            var pixel = [Int](repeating: 0, count: 4)
            rep.getPixel(&pixel, atX: Int(mockX - 285), y: Int(mockY - 148))
            return pixel
        }
        let paper = colour(1_150, 800)
        #expect(paper[0] > 230 && paper[1] > 230 && paper[2] > 230, "blank sheet should read as paper, got \(paper)")
        let areaInterior = colour(400, 330)
        #expect(areaInterior[2] > areaInterior[0] + 12, "the area interior carries a blue tint, got \(areaInterior)")
    }
}
