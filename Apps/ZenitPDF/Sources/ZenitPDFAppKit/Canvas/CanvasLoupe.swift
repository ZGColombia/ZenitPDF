import AppKit
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation

/// The precision magnifier while placing points (NL-MEASURE-15).
///
/// Measure ▸ Precision Magnifier (⌥⌘M) turns it on; it then follows the pointer whenever a
/// point-placing measurement tool or a calibration is armed, showing the page magnified under a
/// crosshair, the snap it would take, and the page and real-world coordinate. Its picture is a
/// **crop of the rasters the canvas already drew**, stacked as the canvas stacks them — the
/// resident whole-sheet base, the level tiles, the underlay and the stand-ins, and the tiles of
/// the tile cache on top — never a second render. It takes no events.
enum CanvasLoupe {

    /// The preference key; absent means off.
    static let defaultsKey = "ZenitMeasureLoupeEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func setEnabled(_ enabled: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }

    /// How much the lens magnifies what is on screen.
    static let magnification: CGFloat = 4
    /// The lens diameter, in view points.
    static let diameter: CGFloat = 132
    /// How far the lens sits from the pointer, so it never covers the point being picked.
    static let offset: CGFloat = 28
}

/// What the loupe shows: a crop of what the canvas drew, at the view's own backing resolution.
///
/// The lens's ``LoupePictureView`` magnifies it on the way to the screen. Until iteration 4 the
/// crop was magnified here, on the main thread, into a `diameter`-sized bitmap at backing scale —
/// 264 × 264 px re-sampled on every pointer move (Z15, U-005). That resample was bilinear either
/// way: CoreGraphics produced byte-identical crops at `.high`, `.medium`, `.low` and `.none`
/// interpolation for this upscale (measured 2026-09-27), and the layer's linear magnification
/// filter is the same filter, so moving it to the layer loses nothing.
struct LoupeCrop {
    /// The drawn rasters over ``viewRect``, one image pixel per device pixel.
    let image: CGImage
    /// The view-space rectangle the image covers: the source square around the pointer, grown
    /// out to whole device pixels plus one pixel of margin for the lens's filtering. A settled
    /// tile sits on the same pixel grid, so it is copied into the crop 1:1, never re-sampled.
    let viewRect: CGRect
}

extension CanvasPageView {

    /// The crop around `viewPoint` that a lens magnifying `magnification` times at `diameter`
    /// view points shows, from the rasters this view already holds, in the canvas's own stacking
    /// order (`syncRasterLayers`): the resident base under everything, then the level tiles, the
    /// underlay, the page raster and the stale tiles, and the current tiles on top.
    ///
    /// The base and the level tiles were left out until iteration 5, so on a freshly shown sheet
    /// (base only) the crop was `nil` and the lens vanished, and past the rendered tiles it
    /// showed white paper where the canvas showed the drawing (V-008).
    ///
    /// The source is a square of `diameter / magnification` view points centred on the pointer.
    /// `nil` before anything has been drawn.
    func loupeCrop(around viewPoint: CGPoint, magnification: CGFloat, diameter: CGFloat) -> LoupeCrop? {
        guard let transform, magnification > 0, diameter > 0 else { return nil }
        let scale = effectiveBackingScale
        let half = diameter / magnification / 2
        // The source square in device pixels, grown to whole pixels and one pixel of margin.
        let minX = ((viewPoint.x - half) * scale).rounded(.down) - 1
        let minY = ((viewPoint.y - half) * scale).rounded(.down) - 1
        let maxX = ((viewPoint.x + half) * scale).rounded(.up) + 1
        let maxY = ((viewPoint.y + half) * scale).rounded(.up) + 1
        guard minX.isFinite, minY.isFinite, maxX > minX, maxY > minY else { return nil }
        let width = Int(maxX - minX), height = Int(maxY - minY)
        let viewRect = CGRect(x: minX / scale, y: minY / scale, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        var layers: [PageRaster] = []
        if let baseRaster { layers.append(baseRaster) }
        layers.append(contentsOf: levelTileRasters)
        if let underlayRaster { layers.append(underlayRaster) }
        if let pageRaster { layers.append(pageRaster) }
        layers.append(contentsOf: staleTileRasters)
        layers.append(contentsOf: tileRasters)
        guard !layers.isEmpty,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                // Native BGRA avoids Core Animation converting this fresh crop at commit.
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Only a stand-in raster (a stale tile or the page raster at another magnification) is
        // re-sampled here, exactly as the page view re-samples it on screen.
        context.interpolationQuality = .high
        var drew = false
        for raster in layers {
            let destination = raster.placement(in: transform, backingScale: scale).destination
            guard destination.intersects(viewRect), destination.width > 0, destination.height > 0 else { continue }
            // View space is flipped (y down); the bitmap is y up. Device pixels throughout.
            context.draw(raster.image, in: CGRect(
                x: destination.minX * scale - minX,
                y: maxY - destination.maxY * scale,
                width: destination.width * scale,
                height: destination.height * scale
            ))
            drew = true
        }
        guard drew, let image = context.makeImage() else { return nil }
        return LoupeCrop(image: image, viewRect: viewRect)
    }
}

extension PDFCanvasViewController {

    /// Whether the loupe belongs on screen for the armed tool.
    var loupeApplies: Bool {
        guard CanvasLoupe.isEnabled(loupeDefaults) else { return false }
        if isCalibrating { return true }
        guard let kind = core.measurement.activeKind else { return false }
        return ZenitToolMode.measure(kind).gesture.collectsPoints
    }

    /// Keeps the lens honest between pointer moves, from the live lane (every observed change).
    ///
    /// Two things reach the canvas without a pointer move. The tool can end — calibration done,
    /// Escape, Select armed — and the lens used to stay up until the next move (V-006). And the
    /// snap resolve for the sample the lens was drawn for lands after it: the lens is updated
    /// before the resolve starts, so without this it named the previous sample's snap, or none,
    /// while the ring on the canvas showed the new one (V-007). A landing that leaves the chip
    /// as it is costs one comparison; one that changes it re-renders the caption and chip only —
    /// the picture and the position are the same page point's.
    func refreshLoupeInLiveLane() {
        guard let host = loupeHost as? LoupeHostingView else { return }
        guard loupeApplies else {
            loupeHost?.removeFromSuperview()
            loupeHost = nil
            return
        }
        let snap = core.canvas.snapFeedback
        guard let point = host.shownPagePoint, LoupeSnapChip(snap) != host.shownSnapChip else { return }
        loupeChipRefreshCountForTesting &+= 1
        showLoupeCaption(in: host, pagePoint: point, snap: snap)
    }

    /// Re-aims the lens after the page moved under a still pointer: a scroll, a zoom step or a
    /// pinch's commit (V-006). The pointer's window position is the one the lens was last drawn
    /// for, so the page point under it is recomputed through the new transform.
    func refreshLoupeAfterViewportChange() {
        guard let host = loupeHost as? LoupeHostingView, let windowPoint = host.pointerWindowPoint,
              let transform = pageView.transform else { return }
        let local = pageView.convert(windowPoint, from: nil)
        guard transform.pageFrame.contains(local) else {
            updateLoupe(at: nil)
            return
        }
        updateLoupe(at: transform.pagePoint(from: local))
    }

    /// The caption and snap chip for `pagePoint`, and the lens size they need.
    private func showLoupeCaption(in host: LoupeHostingView, pagePoint point: PDFPointValue, snap: SnapFeedbackSnapshot?) {
        let pageID = core.document.currentPageID
        let scale = core.snapshot.scale(onPage: pageID)
        let formatter = MeasurementValueFormatter(lengthUnit: core.snapshot.units.length)
        host.rootView = Self.loupeView(picture: host.picture, pagePoint: point, snap: snap, scale: scale, formatter: formatter)
        host.frame.size = host.size(for: LoupeSizeKey(
            readout: MeasurementLoupeReadout.coordinates(pagePoint: point, scale: scale, formatter: formatter),
            snap: snap
        ))
        host.shownPagePoint = point
        host.shownSnapChip = LoupeSnapChip(snap)
    }

    /// Moves, refreshes or hides the loupe for a pointer at `point` (page space).
    func updateLoupe(at point: PDFPointValue?) {
        guard loupeApplies, let point, let transform = pageView.transform else {
            loupeHost?.removeFromSuperview()
            loupeHost = nil
            return
        }
        let viewPoint = transform.viewPoint(from: point)
        guard let crop = pageView.loupeCrop(around: viewPoint, magnification: CanvasLoupe.magnification, diameter: CanvasLoupe.diameter) else {
            loupeHost?.removeFromSuperview()
            loupeHost = nil
            return
        }
        let host: LoupeHostingView
        if let existing = loupeHost as? LoupeHostingView {
            host = existing
        } else {
            host = LoupeHostingView(rootView: AnyView(EmptyView()))
            view.addSubview(host)
            loupeHost = host
        }
        // The picture goes straight to its layer; SwiftUI rebuilds only the caption and the chip.
        host.picture.show(crop, viewPoint: viewPoint, magnification: CanvasLoupe.magnification)
        showLoupeCaption(in: host, pagePoint: point, snap: core.canvas.snapFeedback)
        // Where the pointer is in the window, so a scroll under it can re-aim the lens (V-006).
        host.pointerWindowPoint = pageView.convert(viewPoint, to: nil)
        let inView = view.convert(viewPoint, from: pageView)
        // Up and to the right of the pointer, flipped to the other side near the edges.
        var origin = CGPoint(x: inView.x + CanvasLoupe.offset, y: inView.y + CanvasLoupe.offset)
        if origin.x + host.frame.width > view.bounds.maxX { origin.x = inView.x - CanvasLoupe.offset - host.frame.width }
        if view.isFlipped {
            origin.y = inView.y - CanvasLoupe.offset - host.frame.height
            if origin.y < view.bounds.minY { origin.y = inView.y + CanvasLoupe.offset }
        } else if origin.y + host.frame.height > view.bounds.maxY {
            origin.y = inView.y - CanvasLoupe.offset - host.frame.height
        }
        host.frame.origin = origin
    }

    /// Where the crop sits inside the lens: its size magnified, and the offset that puts
    /// `viewPoint` — not the crop's pixel-aligned centre — under the crosshair.
    static func loupePlacement(crop viewRect: CGRect, viewPoint: CGPoint, magnification: CGFloat) -> (size: CGSize, offset: CGSize) {
        (
            CGSize(width: viewRect.width * magnification, height: viewRect.height * magnification),
            CGSize(width: (viewRect.midX - viewPoint.x) * magnification, height: (viewRect.midY - viewPoint.y) * magnification)
        )
    }

    /// The lens as SwiftUI: the shared `MeasurementLoupe` — chrome, crosshair, caption and snap
    /// chip — over the picture layer, which the canvas feeds directly.
    ///
    /// The picture used to be a SwiftUI `Image` of a new crop on every move, and SwiftUI's update
    /// of it was the largest cost left in a move with the loupe on: 3.2 to 3.4 ms p50 per lens
    /// update against 1.1 to 1.3 ms with the picture held still (release, default snapping,
    /// 2026-09-27). The layer takes the crop in a few microseconds and SwiftUI never sees it.
    static func loupeView(
        picture: LoupePictureView,
        pagePoint: PDFPointValue,
        snap: SnapFeedbackSnapshot?,
        scale: ScaleSummary?,
        formatter: MeasurementValueFormatter
    ) -> AnyView {
        AnyView(
            MeasurementLoupe(
                pagePoint: pagePoint,
                magnification: Double(CanvasLoupe.magnification),
                snapCandidate: snap,
                scale: scale,
                formatter: formatter,
                diameter: CanvasLoupe.diameter
            ) {
                LoupePicture(view: picture)
                    .frame(width: CanvasLoupe.diameter, height: CanvasLoupe.diameter)
            }
        )
    }
}

/// The lens's picture: the crop in a layer, magnified by the layer's linear filter, clipped to
/// the lens circle. It is fed by ``PDFCanvasViewController/updateLoupe(at:)`` directly, never
/// through a SwiftUI update, and it draws nothing itself and takes no events.
final class LoupePictureView: NSView {

    /// The crop, sized and offset so the pointer's view point sits at the lens centre.
    let imageLayer = CALayer()

    init(diameter: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = diameter / 2
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        // A move is a jump, never an animation: the lens must sit under the pointer (IM-103).
        imageLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        layer?.addSublayer(imageLayer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The frame, in this view's (flipped, y down) coordinates, the crop takes in a lens of
    /// `bounds` size: its view rectangle magnified, offset so `viewPoint` is at the centre.
    func imageFrame(for crop: LoupeCrop, viewPoint: CGPoint, magnification: CGFloat) -> CGRect {
        let placement = PDFCanvasViewController.loupePlacement(crop: crop.viewRect, viewPoint: viewPoint, magnification: magnification)
        return CGRect(
            x: (bounds.width - placement.size.width) / 2 + placement.offset.width,
            y: (bounds.height - placement.size.height) / 2 + placement.offset.height,
            width: placement.size.width,
            height: placement.size.height
        )
    }

    /// Shows `crop` with `viewPoint` under the lens centre.
    func show(_ crop: LoupeCrop, viewPoint: CGPoint, magnification: CGFloat) {
        var frame = imageFrame(for: crop, viewPoint: viewPoint, magnification: magnification)
        // The backing layer is y up unless AppKit flipped its geometry for this flipped view.
        if layer?.isGeometryFlipped == false { frame.origin.y = bounds.height - frame.maxY }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = crop.image
        imageLayer.frame = frame
        CATransaction.commit()
    }
}

/// ``LoupePictureView`` in the SwiftUI lens: always the same view, so a SwiftUI update of the
/// caption or the chip leaves the picture alone.
struct LoupePicture: NSViewRepresentable {
    let view: LoupePictureView
    func makeNSView(context: Context) -> LoupePictureView { view }
    func updateNSView(_ nsView: LoupePictureView, context: Context) {}
}

/// What the lens's size depends on: the caption's shape and the snap chip.
///
/// The caption's figures are tabular (`ZPDFTextStyle.monoNumeric`), so replacing every ASCII
/// digit with `0` keeps exactly what moves its width; the magnification badge and the lens are
/// constant, and the chip is its kind and source label.
struct LoupeSizeKey: Hashable {
    let captionShape: String
    let snapKind: String?
    let snapSource: String?

    init(readout: String, snap: SnapFeedbackSnapshot?) {
        captionShape = String(readout.map { $0.isASCII && $0.isNumber ? "0" : $0 })
        snapKind = snap?.kind.displayName
        snapSource = snap?.sourceLabel
    }
}

/// What the lens's snap chip names: the candidate's kind and source, or nothing.
struct LoupeSnapChip: Equatable {
    let kind: SnapCandidateKind?
    let source: String?

    init(_ snap: SnapFeedbackSnapshot?) {
        kind = snap?.kind
        source = snap?.sourceLabel
    }
}

/// The loupe's host: drawn, never hit — the canvas under it keeps every click.
final class LoupeHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    /// The page point the lens shows, and the snap chip it names for it (V-007).
    var shownPagePoint: PDFPointValue?
    var shownSnapChip = LoupeSnapChip(nil)
    /// The pointer's window position when the lens was last drawn (V-006).
    var pointerWindowPoint: NSPoint?

    /// The lens's picture, one per host for the host's life.
    let picture = LoupePictureView(diameter: CanvasLoupe.diameter)

    private var measuredSizes: [LoupeSizeKey: CGSize] = [:]
    /// How many times the lens was measured (`fittingSize`), for the tests.
    private(set) var measureCountForTesting = 0

    /// The lens's size for `key`, measured once per key.
    ///
    /// `fittingSize` is a SwiftUI layout pass of its own, and it ran on every pointer move —
    /// 0.24 to 0.44 ms of a move with the loupe on (release, 2026-09-27) — for a size that is a
    /// function of the key alone: a pointer crossing x = 100 changes the caption's shape and
    /// crossing back restores it, so the sizes are kept per key, not just the last one. A
    /// handful of keys exist in practice; the table is emptied if it ever reaches 64.
    func size(for key: LoupeSizeKey) -> CGSize {
        if let size = measuredSizes[key] { return size }
        if measuredSizes.count >= 64 { measuredSizes.removeAll(keepingCapacity: true) }
        let size = fittingSize
        measuredSizes[key] = size
        measureCountForTesting += 1
        return size
    }
}
