import CoreGraphics
import Foundation
import IOSurface
import ZPDFUIPresentation

/// The canvas's raster, kept as tiles (IM-044).
///
/// # What it replaces
///
/// One viewport-sized raster per plan. A pan past the 64-point overscan re-rendered the whole
/// viewport — every pixel, the whole content stream — although most of it was already on
/// screen; zooming back to the previous zoom re-rendered what had been there a second ago;
/// and on a 5K or 6K full-screen canvas the single raster was 60–90 MB, two to three times
/// gate Z7's 32 MiB for one raster (BH-890).
///
/// # How it works
///
/// The page is cut into a grid of ``tileSide``-pixel squares in **device pixels, anchored to
/// the page**, per exact scale. A request asks the cache which tiles the plan needs, draws the
/// ones it has at once, and renders only the missing ones — in **one** call covering their
/// bounding rectangle, because the renderer walks the whole content stream per call and
/// thirty-five small calls for a cold viewport would be thirty-five traversals. The result is
/// cut into tiles, each copied into its own bitmap (a crop would pin the whole rendered
/// region in memory), and stored.
///
/// Each tile is at most ``tileSide``² × 4 bytes (1 MiB), and the cache holds at most
/// ``byteBudget`` — Z7's 256 MiB tile-cache clause — evicting the least recently drawn.
///
/// # Keys
///
/// A tile's pixels depend on the page, the exact scale, the sub-pixel **phase** of the page's
/// device origin (the renderer offsets content by it), the tile's column and row, and the
/// content generation (layer filtering, annotation visibility). The page's integral origin is
/// *not* in the key: tiles carry page-space coverage, so a layout that moves the sheet by whole
/// device pixels reuses every tile.
final class CanvasTileCache {

    /// Tile side, in device pixels.
    static let tileSide: CGFloat = 512

    /// Z7's tile-cache bound: the ceiling, never exceeded on any machine.
    static let byteBudget = 256 * 1024 * 1024

    /// The bound this cache enforces: Z7's 256 MiB, or 4 % of the machine's memory where that is
    /// less (NL-PERF-10), so an 8 GB Mac does not give a quarter of a gigabyte to one canvas.
    static func machineScaledBudget(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let scaled = physicalMemory / 25
        return scaled >= UInt64(byteBudget) ? byteBudget : max(32 * 1024 * 1024, Int(scaled))
    }

    let byteLimit: Int

    init(byteLimit: Int = CanvasTileCache.machineScaledBudget()) {
        self.byteLimit = min(byteLimit, Self.byteBudget)
    }

    struct Key: Hashable, Sendable {
        let pageIndex: Int
        let scaleBits: UInt64
        let phaseX: Int
        let phaseY: Int
        let column: Int
        let row: Int
        let generation: Int
        /// A power-of-two pyramid level tile (NL-PERF-06) rather than an exact-scale tile.
        var level: Bool = false
    }

    /// Where a page sits on the device-pixel grid at one scale.
    struct Grid: Equatable, Sendable {
        let pageIndex: Int
        let scale: CGFloat
        /// The page frame in device pixels.
        let devicePage: CGRect
        let generation: Int

        var anchor: CGPoint { CGPoint(x: devicePage.minX.rounded(.down), y: devicePage.minY.rounded(.down)) }

        private var phase: (Int, Int) {
            (Int(((devicePage.minX - anchor.x) * 1000).rounded()), Int(((devicePage.minY - anchor.y) * 1000).rounded()))
        }

        func key(column: Int, row: Int) -> Key {
            Key(
                pageIndex: pageIndex,
                scaleBits: Double(scale).bitPattern,
                phaseX: phase.0,
                phaseY: phase.1,
                column: column,
                row: row,
                generation: generation
            )
        }

        /// A tile's device rectangle: its grid square, clipped to the page and snapped inward
        /// to whole pixels exactly as ``ViewportRasterPlanner`` snaps a plan.
        func deviceRect(column: Int, row: Int) -> CGRect {
            let side = CanvasTileCache.tileSide
            let square = CGRect(x: anchor.x + CGFloat(column) * side, y: anchor.y + CGFloat(row) * side, width: side, height: side)
            let clipped = square.intersection(devicePage)
            guard !clipped.isNull else { return .null }
            let minX = clipped.minX.rounded(.up)
            let minY = clipped.minY.rounded(.up)
            let maxX = clipped.maxX.rounded(.down)
            let maxY = clipped.maxY.rounded(.down)
            guard maxX > minX, maxY > minY else { return .null }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        /// The (column, row) pairs whose squares meet a device rectangle.
        func cells(covering rect: CGRect) -> [(column: Int, row: Int)] {
            let target = rect.intersection(devicePage)
            guard !target.isNull, target.width > 0, target.height > 0 else { return [] }
            let side = CanvasTileCache.tileSide
            let firstColumn = Int(((target.minX - anchor.x) / side).rounded(.down))
            let lastColumn = Int(((target.maxX - anchor.x) / side).rounded(.up)) - 1
            let firstRow = Int(((target.minY - anchor.y) / side).rounded(.down))
            let lastRow = Int(((target.maxY - anchor.y) / side).rounded(.up)) - 1
            guard lastColumn >= firstColumn, lastRow >= firstRow else { return [] }
            var cells: [(Int, Int)] = []
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn where !deviceRect(column: column, row: row).isNull {
                    cells.append((column, row))
                }
            }
            return cells
        }
    }

    struct Tile {
        let key: Key
        let raster: PageRaster
        let bytes: Int
        var lastUse: UInt64
    }

    private var tiles: [Key: Tile] = [:]
    private var clock: UInt64 = 0

    /// Bytes held.
    private(set) var byteCount = 0
    /// Device pixels rendered into the cache since it was created. The counter that proves a
    /// pan renders only what it exposed.
    private(set) var renderedPixelCount = 0
    /// Tiles answered from the cache.
    private(set) var hitCount = 0

    var tileCount: Int { tiles.count }

    func tile(for key: Key) -> PageRaster? {
        guard var tile = tiles[key] else { return nil }
        clock &+= 1
        tile.lastUse = clock
        tiles[key] = tile
        hitCount += 1
        return tile.raster
    }

    func contains(_ key: Key) -> Bool { tiles[key] != nil }

    /// Files a batch of tiles and evicts once, not once per tile.
    func insert(contentsOf batch: [(Key, PageRaster)]) {
        for (key, raster) in batch { store(raster, for: key) }
        evictIfNeeded()
    }

    func insert(_ raster: PageRaster, for key: Key) {
        store(raster, for: key)
        evictIfNeeded()
    }

    private func store(_ raster: PageRaster, for key: Key) {
        clock &+= 1
        let bytes = raster.image.bytesPerRow * raster.image.height
        if let old = tiles[key] { byteCount -= old.bytes }
        tiles[key] = Tile(key: key, raster: raster, bytes: bytes, lastUse: clock)
        byteCount += bytes
        renderedPixelCount += raster.image.width * raster.image.height
    }

    func removeAll() {
        tiles.removeAll()
        byteCount = 0
    }

    /// Drops every tile except `keep` (NL-PERF-10's memory-pressure response).
    func removeAll(except keep: Set<Key>) {
        for key in Array(tiles.keys) where !keep.contains(key) {
            if let tile = tiles.removeValue(forKey: key) { byteCount -= tile.bytes }
        }
    }

    private func evictIfNeeded() {
        guard byteCount > byteLimit else { return }
        for tile in tiles.values.sorted(by: { $0.lastUse < $1.lastUse }) {
            guard byteCount > byteLimit else { break }
            tiles.removeValue(forKey: tile.key)
            byteCount -= tile.bytes
        }
    }

    /// Cuts a rendered region into tiles, each copied into its own bitmap.
    ///
    /// - Parameters:
    ///   - image: the render, whose top-left pixel is `renderedDeviceRect`'s top-left in the
    ///     flipped view's device space.
    ///   - cells: the cells to cut out of it.
    static func slice(
        _ image: CGImage,
        renderedDeviceRect: CGRect,
        cells: [(column: Int, row: Int)],
        grid: Grid,
        transform: PageDisplayTransform,
        backingScale: CGFloat
    ) -> [(Key, PageRaster)] {
        var output: [(Key, PageRaster)] = []
        for cell in cells {
            let full = grid.deviceRect(column: cell.column, row: cell.row)
            let rect = full.intersection(renderedDeviceRect)
            // Only whole tiles are stored: a partial one under a full tile's key would be
            // treated as complete forever after.
            guard !rect.isNull, rect.width >= 1, rect.height >= 1,
                  abs(rect.width - full.width) < 0.5, abs(rect.height - full.height) < 0.5 else { continue }
            let crop = CGRect(
                x: rect.minX - renderedDeviceRect.minX,
                y: rect.minY - renderedDeviceRect.minY,
                width: rect.width,
                height: rect.height
            ).integral
            guard let cropped = image.cropping(to: crop), let owned = CanvasSurfaceImage.make(cropped) else { continue }
            let viewRect = CGRect(
                x: rect.minX / backingScale,
                y: rect.minY / backingScale,
                width: rect.width / backingScale,
                height: rect.height / backingScale
            )
            output.append((
                grid.key(column: cell.column, row: cell.row),
                PageRaster(
                    image: owned.image,
                    coverage: .region(transform.pageRect(covering: viewRect)),
                    scale: grid.scale,
                    surface: owned.surface
                )
            ))
        }
        return output
    }

    /// A private copy of an image, so a tile does not keep its parent render alive.
    ///
    /// BGRA, premultiplied first, little-endian — the format the bridge renders in — so the
    /// copy is a straight memory copy with no per-pixel conversion, and
    /// it runs off the main actor (NL-PERF-03).
    static func copy(_ image: CGImage) -> CGImage? {
        if let made = CanvasSurfaceImage.make(image) { return made.image }
        return plainCopy(image)
    }

    /// The same copy into ordinary memory, for an image no `IOSurface` can hold.
    static func plainCopy(_ image: CGImage) -> CGImage? {
        let make = { (space: CGColorSpace) in
            CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        }
        guard let context = image.colorSpace.flatMap(make) ?? make(CGColorSpaceCreateDeviceRGB()) else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

/// One power-of-two level of the page pyramid (NL-PERF-06): `2^exponent` device pixels per page
/// point, tiled in 512-pixel squares anchored at the page's own top-left corner.
///
/// The exact-scale grid above is keyed by the scale's bits, so a continuous zoom never hits it.
/// A level is reused across every zoom that maps near it: mid-gesture the canvas shows the
/// smallest resident level at least as sharp as the live scale — a GPU *down*-sample — and
/// renders the missing ones tile by tile, centre-out from the fingers.
struct CanvasLevelGrid: Equatable, Sendable {
    static let exponents = -4...5

    let pageIndex: Int
    let exponent: Int
    let generation: Int
    /// The page at this level, laid out at the origin with a backing scale of 1, so its view
    /// space *is* the level's device space.
    let transform: PageDisplayTransform

    init(pageIndex: Int, exponent: Int, pageBox: PDFRectValue, rotation: Int, generation: Int) {
        self.pageIndex = pageIndex
        self.exponent = exponent
        self.generation = generation
        self.transform = PageDisplayTransform(
            pageBox: pageBox,
            rotation: rotation,
            zoom: Self.scale(exponent),
            origin: .zero
        )
    }

    static func scale(_ exponent: Int) -> CGFloat { CGFloat(pow(2.0, Double(exponent))) }
    var scale: CGFloat { Self.scale(exponent) }

    /// The level for a live device scale: the smallest power of two not below it, so the
    /// picture is never magnified once that level is resident.
    static func exponent(forDeviceScale scale: CGFloat) -> Int {
        guard scale.isFinite, scale > 0 else { return 0 }
        let wanted = Int((log2(Double(scale)) - 1e-9).rounded(.up))
        return min(max(wanted, exponents.lowerBound), exponents.upperBound)
    }

    var grid: CanvasTileCache.Grid {
        CanvasTileCache.Grid(pageIndex: pageIndex, scale: scale, devicePage: transform.pageFrame, generation: generation)
    }

    func key(column: Int, row: Int) -> CanvasTileCache.Key {
        CanvasTileCache.Key(
            pageIndex: pageIndex,
            scaleBits: Double(scale).bitPattern,
            phaseX: 0,
            phaseY: 0,
            column: column,
            row: row,
            generation: generation,
            level: true
        )
    }

    /// The cells whose squares meet a page-space rectangle.
    func cells(covering pageRect: PDFRectValue) -> [(column: Int, row: Int)] {
        grid.cells(covering: transform.viewRect(from: pageRect))
    }

    /// The render plan for one tile: its device square, exactly, at this level's scale.
    func plan(column: Int, row: Int) throws -> ViewportRasterPlan {
        try ViewportRasterPlanner.plan(
            transform: transform,
            visibleViewRect: grid.deviceRect(column: column, row: row),
            backingScale: 1,
            overscanViewPoints: 0
        )
    }
}

/// A private copy of an image in an `IOSurface`, and a `CGImage` over the very same memory
/// (NL-PERF-05). Made off the main actor. A layer given the surface shows it without a copy at
/// commit; everything that reads pixels — the legacy draw path, print, the tests — reads the
/// image. One allocation, two views of it; the image's data provider keeps the surface alive.
enum CanvasSurfaceImage {

    static func make(_ image: CGImage) -> (image: CGImage, surface: IOSurface)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let space: CGColorSpace = {
            if let own = image.colorSpace, own.model == .rgb { return own }
            return CGColorSpaceCreateDeviceRGB()
        }()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .bytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4),
            .pixelFormat: 0x4247_5241 // 'BGRA'
        ]
        guard let surface = IOSurface(properties: properties) else { return nil }
        if let colourSpace = space.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colourSpace)
        }
        surface.lock(options: [], seed: nil)
        let bytesPerRow = surface.bytesPerRow
        let base = surface.baseAddress
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo
        ) else {
            surface.unlock(options: [], seed: nil)
            return nil
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        surface.unlock(options: [], seed: nil)
        guard let provider = CGDataProvider(
            dataInfo: Unmanaged.passRetained(surface).toOpaque(),
            data: base,
            size: bytesPerRow * height,
            releaseData: { info, _, _ in
                guard let info else { return }
                Unmanaged<IOSurface>.fromOpaque(info).release()
            }
        ) else { return nil }
        guard let view = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return (view, surface)
    }

    /// A raster moved into a surface, off the main actor; the raster itself if that fails.
    static func surfaced(_ raster: PageRaster) async -> PageRaster {
        await Task.detached(priority: .userInitiated) {
            guard let made = make(raster.image) else { return raster }
            return PageRaster(image: made.image, coverage: raster.coverage, scale: raster.scale, surface: made.surface)
        }.value
    }
}
