import Foundation
import ZPDFContracts

/// The selection and snap overlay, built as its own small instance set.
///
/// # Why this is separate
///
/// Hover feedback fires on every mouse-moved event. If the handles and the snap glyph lived in
/// the same buffers as the page's markups, a hover would mark those buffers dirty and, on the
/// paths that grow or compact them, force a rebuild — which is exactly the "hover feedback
/// forces a full rebuild" failure this design is required to avoid. Keeping the overlay in its
/// own buffers, rebuilt from scratch every time because it is a few dozen instances, means the
/// geometry buffers are only ever touched when geometry actually changes.
public struct OverlayBuilder {

    /// Handle and outline colours. Plain values so the design system owns the real palette and
    /// the renderer owns none of it.
    public struct Palette: Sendable, Hashable {
        public var selectionOutline: RGBAColor
        public var hoverOutline: RGBAColor
        public var handleFill: RGBAColor
        public var snapGlyph: RGBAColor
        public var snapGlyphHeld: RGBAColor
        public var snapGuide: RGBAColor

        public init(
            selectionOutline: RGBAColor = RGBAColor(red: 0.12, green: 0.45, blue: 0.95, alpha: 1),
            hoverOutline: RGBAColor = RGBAColor(red: 0.12, green: 0.45, blue: 0.95, alpha: 0.5),
            handleFill: RGBAColor = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1),
            snapGlyph: RGBAColor = RGBAColor(red: 0.95, green: 0.42, blue: 0.06, alpha: 1),
            snapGlyphHeld: RGBAColor = RGBAColor(red: 0.95, green: 0.42, blue: 0.06, alpha: 0.55),
            snapGuide: RGBAColor = RGBAColor(red: 0.95, green: 0.42, blue: 0.06, alpha: 0.7)
        ) {
            self.selectionOutline = selectionOutline
            self.hoverOutline = hoverOutline
            self.handleFill = handleFill
            self.snapGlyph = snapGlyph
            self.snapGlyphHeld = snapGlyphHeld
            self.snapGuide = snapGuide
        }

        public static let `default` = Palette()
    }

    /// The overlay's instances, plus the handle centres so the hit tester can find them.
    public struct Overlay: Sendable {
        public var segments: [CompiledSegment] = []
        public var symbols: [CompiledSymbol] = []
        /// Handle centres in page space, in the order they were emitted, with their owning markup.
        public var handles: [(markupID: MarkupID, index: Int, center: PDFPoint)] = []
        /// Handle side length in view points, for hit testing at the drawn size.
        public var handleSizeViewPoints: Double = 0

        public var isEmpty: Bool { segments.isEmpty && symbols.isEmpty }
    }

    public var palette: Palette

    public init(palette: Palette = .default) {
        self.palette = palette
    }

    /// Builds the overlay for one frame. Cheap: it walks only the selected markups.
    public func build(
        selection: SelectionSnapshot,
        snapFeedback: RenderSnapFeedback?,
        bounds: [MarkupID: PDFRect],
        transform: RenderTransform
    ) -> Overlay {
        var overlay = Overlay()
        overlay.handleSizeViewPoints = selection.handleSizeViewPoints

        // A one-view-point outline: thin, and floored to one device pixel like every other
        // stroke, so it stays visible at 5 % zoom.
        let outlineWidthPagePoints = transform.pagePoints(fromViewPoints: 1.0)
        let dash = RenderDash.pattern(
            runs: [
                transform.pagePoints(fromViewPoints: 4),
                transform.pagePoints(fromViewPoints: 3)
            ],
            phase: 0
        )

        if let hovered = selection.hoveredID,
           !selection.selectedIDs.contains(hovered),
           let box = bounds[hovered] {
            overlay.segments.append(contentsOf: Self.outline(
                of: box,
                color: palette.hoverOutline,
                width: outlineWidthPagePoints,
                dash: .solid
            ))
        }

        for id in selection.selectedIDs.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard let box = bounds[id] else { continue }
            overlay.segments.append(contentsOf: Self.outline(
                of: box,
                color: palette.selectionOutline,
                width: outlineWidthPagePoints,
                dash: dash
            ))
        }

        if let primary = selection.primaryID, let box = bounds[primary] {
            for (index, center) in Self.handleCenters(of: box).enumerated() {
                overlay.symbols.append(CompiledSymbol(
                    center: center,
                    symbol: .filledSquare,
                    sizePagePoints: 0,
                    sizeViewPoints: selection.handleSizeViewPoints,
                    color: palette.handleFill
                ))
                overlay.symbols.append(CompiledSymbol(
                    center: center,
                    symbol: .hollowSquare,
                    sizePagePoints: 0,
                    sizeViewPoints: selection.handleSizeViewPoints,
                    color: palette.selectionOutline
                ))
                overlay.handles.append((primary, index, center))
            }
        }

        if let snap = snapFeedback, snap.point.isFinite {
            switch snap.guide {
            case .none:
                break
            case let .segment(from, to):
                if from.isFinite, to.isFinite {
                    overlay.segments.append(CompiledSegment(
                        start: from,
                        end: to,
                        widthPagePoints: outlineWidthPagePoints,
                        color: palette.snapGuide,
                        startCap: .butt,
                        endCap: .butt,
                        dash: DashPattern(dash),
                        dashOffsetPagePoints: 0
                    ))
                }
            case let .circle(center, radius):
                if center.isFinite, radius.isFinite, radius > 0 {
                    overlay.segments.append(contentsOf: Self.circle(
                        center: center,
                        radius: radius,
                        color: palette.snapGuide,
                        width: outlineWidthPagePoints
                    ))
                }
            }
            overlay.symbols.append(CompiledSymbol(
                center: snap.point,
                symbol: snap.glyph,
                sizePagePoints: 0,
                sizeViewPoints: snap.glyphSizeViewPoints,
                color: snap.isHeldByHysteresis ? palette.snapGlyphHeld : palette.snapGlyph
            ))
        }

        return overlay
    }

    /// The eight handle centres of a box: four corners then four edge midpoints.
    public static func handleCenters(of box: PDFRect) -> [PDFPoint] {
        [
            PDFPoint(x: box.minX, y: box.minY),
            PDFPoint(x: box.maxX, y: box.minY),
            PDFPoint(x: box.maxX, y: box.maxY),
            PDFPoint(x: box.minX, y: box.maxY),
            PDFPoint(x: box.midX, y: box.minY),
            PDFPoint(x: box.maxX, y: box.midY),
            PDFPoint(x: box.midX, y: box.maxY),
            PDFPoint(x: box.minX, y: box.midY)
        ]
    }

    private static func outline(
        of box: PDFRect,
        color: RGBAColor,
        width: Double,
        dash: RenderDash
    ) -> [CompiledSegment] {
        let corners = [
            PDFPoint(x: box.minX, y: box.minY),
            PDFPoint(x: box.maxX, y: box.minY),
            PDFPoint(x: box.maxX, y: box.maxY),
            PDFPoint(x: box.minX, y: box.maxY)
        ]
        let pattern = DashPattern(dash)
        var travelled = 0.0
        var segments: [CompiledSegment] = []
        for index in 0..<4 {
            let start = corners[index]
            let end = corners[(index + 1) % 4]
            segments.append(CompiledSegment(
                start: start,
                end: end,
                widthPagePoints: width,
                color: color,
                startCap: .butt,
                endCap: .butt,
                dash: pattern,
                dashOffsetPagePoints: travelled
            ))
            travelled += start.distance(to: end)
        }
        return segments
    }

    private static func circle(
        center: PDFPoint,
        radius: Double,
        color: RGBAColor,
        width: Double
    ) -> [CompiledSegment] {
        let steps = 48
        var points: [PDFPoint] = []
        points.reserveCapacity(steps)
        for step in 0..<steps {
            let angle = 2 * Double.pi * Double(step) / Double(steps)
            points.append(PDFPoint(
                x: center.x + radius * Foundation.cos(angle),
                y: center.y + radius * Foundation.sin(angle)
            ))
        }
        var segments: [CompiledSegment] = []
        var travelled = 0.0
        for index in 0..<steps {
            let start = points[index]
            let end = points[(index + 1) % steps]
            segments.append(CompiledSegment(
                start: start,
                end: end,
                widthPagePoints: width,
                color: color,
                startCap: .round,
                endCap: .round,
                dash: .solid,
                dashOffsetPagePoints: travelled
            ))
            travelled += start.distance(to: end)
        }
        return segments
    }
}
