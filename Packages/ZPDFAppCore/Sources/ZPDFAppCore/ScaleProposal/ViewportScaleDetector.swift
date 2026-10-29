import Foundation
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// A scale printed under one drawing on a sheet that holds several, with the region that drawing
/// occupies (NL-AUTO-19).
///
/// A sheet with a 1:100 plan and a 1:20 detail has two scales, and a single page scale measures
/// one of them wrong. Each viewport title — "DETALJ 3 SKALA 1:20", "PLAN 1:100" — sits under the
/// drawing it names; the drawing is the cluster of linework directly above the title. The region
/// is that cluster's extent. It is a proposal for a Scale Region, applied only when a person
/// accepts it, with the title text as its evidence.
public struct ViewportScaleProposal: Sendable, Hashable {
    public let ratio: ScaleRatio
    /// The notation as read, with its bounds.
    public let evidence: ScaleCandidate
    /// The drawing's extent above the title, page space.
    public let region: PDFRectValue

    public init(ratio: ScaleRatio, evidence: ScaleCandidate, region: PDFRectValue) {
        self.ratio = ratio
        self.evidence = evidence
        self.region = region
    }
}

public struct ViewportScaleDetector: Sendable {

    /// Linework longer than this share of the page's larger side is sheet furniture — the frame,
    /// title-block rules, grid lines — never part of one viewport's drawing.
    public static let furnitureShare = 0.3
    /// Primitives whose bounds come within this many points belong to one drawing.
    public static let linkGap = 12.0
    /// How far below the drawing a title may sit, in page points.
    public static let titleGap = 60.0

    public init() {}

    /// One proposal per viewport title outside the title block whose drawing can be found above
    /// it. Deterministic: ordered by the title's position, top to bottom then left to right.
    public func proposals(
        lines: [RecognisedTextLine],
        pageBox: PDFRectValue,
        primitives: [VectorPrimitive],
        titleBlock: PDFRectValue? = nil
    ) -> [ViewportScaleProposal] {
        let zone = titleBlock ?? SheetScaleProposer.defaultTitleBlockZone(of: pageBox)
        let candidates = ScaleNotationParser().candidates(in: BaselineLineMerger.merge(lines))
            .filter { $0.boundsInPageSpace != nil && !SheetScaleProposer.isInside($0.boundsInPageSpace, zone) }
        guard !candidates.isEmpty else { return [] }
        let clusters = Self.clusters(primitives, pageBox: pageBox)
        var result: [ViewportScaleProposal] = []
        for candidate in candidates {
            guard let label = candidate.boundsInPageSpace else { continue }
            // The drawing directly above the title: overlapping it horizontally, starting just
            // above it, the nearest such cluster.
            let above = clusters.filter { cluster in
                cluster.minX <= label.maxX + 20 && cluster.maxX >= label.minX - 20
                    && cluster.minY >= label.maxY - 4 && cluster.minY - label.maxY <= Self.titleGap
            }
            guard let drawing = above.min(by: { ($0.minY - label.maxY) < ($1.minY - label.maxY) }) else { continue }
            result.append(ViewportScaleProposal(
                ratio: candidate.ratio,
                evidence: candidate,
                region: PDFRectValue(x: drawing.minX, y: drawing.minY, width: drawing.maxX - drawing.minX, height: drawing.maxY - drawing.minY)
            ))
        }
        return result.sorted {
            let a = $0.evidence.boundsInPageSpace!, b = $1.evidence.boundsInPageSpace!
            return a.minY != b.minY ? a.minY > b.minY : a.minX < b.minX
        }
    }

    /// ``proposals(lines:pageBox:primitives:titleBlock:)`` on a background thread, so a dense
    /// sheet never holds the main actor while its linework is grouped (V-035). The command that
    /// asks — Find Scale Regions — awaits it from the main actor.
    public func proposalsInBackground(
        lines: [RecognisedTextLine],
        pageBox: PDFRectValue,
        primitives: [VectorPrimitive],
        titleBlock: PDFRectValue? = nil
    ) async -> [ViewportScaleProposal] {
        await Task.detached(priority: .userInitiated) {
            self.proposals(lines: lines, pageBox: pageBox, primitives: primitives, titleBlock: titleBlock)
        }.value
    }

    struct Extent { var minX, minY, maxX, maxY: Double }

    /// The most grid cells one part spans on either axis. On every printed sheet the cell is
    /// ``linkGap`` and no part comes near this (a part is at most ``furnitureShare`` of the
    /// page's larger side: 85 cells on A0); only a page box larger than about 10 m coarsens the
    /// cell so the grid stays bounded (V-035).
    static let maximumCellsPerSide = 256

    /// Drawings on the sheet: primitives linked within ``linkGap``, sheet furniture left out.
    ///
    /// Two parts are linked when their bounds come within ``linkGap`` on both axes; a drawing is
    /// a connected set of linked parts. The grid of ``linkGap`` cells answers that without
    /// rescanning anything (V-035):
    ///
    /// * two parts touching one cell are linked, with no test — both bounds meet a closed
    ///   12 pt square, so they are within 12 pt on both axes. Each cell keeps one representative
    ///   and the extremes of the bounds that touch it, never a list of occupants;
    /// * a part and the cell just beside one of its own cells, in its row or column: the other
    ///   axis is within 12 pt already, so the cell's extreme on this axis decides exactly;
    /// * a part and the cell diagonally past one of its corners: a part lying wholly in that
    ///   quadrant has its nearest corner in that cell; those corners are kept per cell, and one
    ///   link decides for all of them, because they share the cell.
    ///
    /// The old grid registered every part in every cell of its bounds and gap-tested every
    /// earlier occupant of every cell its inflated bounds touched, already-joined ones included:
    /// the cost grew with the square of the occupancy, on the main actor, and a crafted page box
    /// let one part touch about 10⁸ dictionary cells. The result is the same set of drawings on
    /// every printed sheet (``maximumCellsPerSide``); linework farther than ``titleGap`` off the
    /// page is not grouped, since no title on the sheet can sit under it.
    static func clusters(_ primitives: [VectorPrimitive], pageBox: PDFRectValue) -> [Extent] {
        let limit = Swift.max(pageBox.size.width, pageBox.size.height) * furnitureShare
        let parts = primitives.filter { primitive in
            Swift.max(primitive.bounds.width, primitive.bounds.height) <= limit
        }
        guard !parts.isEmpty else { return [] }
        var parent = Array(parts.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        let size = Swift.max(linkGap, limit / Double(maximumCellsPerSide))
        let margin = titleGap + linkGap
        let originX = pageBox.origin.x - margin, originY = pageBox.origin.y - margin
        if size.isFinite, originX.isFinite, originY.isFinite,
           let columns = cell(pageBox.size.width + 2 * margin, size: size).map({ $0 + 1 }),
           let rows = cell(pageBox.size.height + 2 * margin, size: size).map({ $0 + 1 }),
           columns > 0, rows > 0, columns <= 4 * maximumCellsPerSide, rows <= 4 * maximumCellsPerSide {
            linkParts(parts, grid: Grid(originX: originX, originY: originY, size: size, columns: columns, rows: rows),
                      find: find, union: union)
        }
        var extents: [Int: Extent] = [:]
        for (index, part) in parts.enumerated() {
            let root = find(index)
            let b = part.bounds
            if var extent = extents[root] {
                extent.minX = Swift.min(extent.minX, b.minX); extent.minY = Swift.min(extent.minY, b.minY)
                extent.maxX = Swift.max(extent.maxX, b.maxX); extent.maxY = Swift.max(extent.maxY, b.maxY)
                extents[root] = extent
            } else {
                extents[root] = Extent(minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY)
            }
        }
        return Array(extents.values)
    }

    /// The cells over the page box and its margin, counted from the margin's corner.
    struct Grid {
        let originX: Double, originY: Double, size: Double
        let columns: Int, rows: Int

        /// A coordinate's column (or row): `nil` when it is not finite; outside `0..<count`
        /// when it lies off the grid.
        func index(_ value: Double, from origin: Double) -> Int? {
            ViewportScaleDetector.cell(value - origin, size: size)
        }
    }

    /// Links every pair of parts within ``linkGap`` on both axes (see ``clusters(_:pageBox:)``).
    private static func linkParts(
        _ parts: [VectorPrimitive],
        grid: Grid,
        find: (Int) -> Int,
        union: (Int, Int) -> Void
    ) {
        let count = grid.columns * grid.rows
        var representative = [Int32](repeating: -1, count: count)
        var lowX = [Double](repeating: 0, count: count), highX = [Double](repeating: 0, count: count)
        var lowY = [Double](repeating: 0, count: count), highY = [Double](repeating: 0, count: count)
        // The parts whose corner of each kind lies in a cell: bottom-left, bottom-right,
        // top-left, top-right.
        var corners: [[Int: [Int32]]] = Array(repeating: [:], count: 4)
        /// Whether the cell holds a part not yet joined to `index`.
        func holdsOther(_ cell: Int, _ index: Int) -> Bool {
            representative[cell] >= 0 && find(Int(representative[cell])) != find(index)
        }
        for (index, part) in parts.enumerated() {
            let b = part.bounds
            guard let rawX0 = grid.index(b.minX, from: grid.originX), let rawX1 = grid.index(b.maxX, from: grid.originX),
                  let rawY0 = grid.index(b.minY, from: grid.originY), let rawY1 = grid.index(b.maxY, from: grid.originY),
                  rawX1 >= 0, rawX0 < grid.columns, rawY1 >= 0, rawY0 < grid.rows
            else { continue }
            let x0 = Swift.max(rawX0, 0), x1 = Swift.min(rawX1, grid.columns - 1)
            let y0 = Swift.max(rawY0, 0), y1 = Swift.min(rawY1, grid.rows - 1)

            // Beside its own cells: the cell's extreme on the crossing axis decides. A side the
            // grid cut short has nothing beyond it.
            let rightOpen = rawX1 == x1 && x1 + 1 < grid.columns, leftOpen = rawX0 == x0 && x0 > 0
            let topOpen = rawY1 == y1 && y1 + 1 < grid.rows, bottomOpen = rawY0 == y0 && y0 > 0
            if rightOpen {
                for y in y0...y1 {
                    let c = y * grid.columns + x1 + 1
                    if holdsOther(c, index), lowX[c] <= b.maxX + linkGap { union(index, Int(representative[c])) }
                }
            }
            if leftOpen {
                for y in y0...y1 {
                    let c = y * grid.columns + x0 - 1
                    if holdsOther(c, index), highX[c] >= b.minX - linkGap { union(index, Int(representative[c])) }
                }
            }
            if topOpen {
                for x in x0...x1 {
                    let c = (y1 + 1) * grid.columns + x
                    if holdsOther(c, index), lowY[c] <= b.maxY + linkGap { union(index, Int(representative[c])) }
                }
            }
            if bottomOpen {
                for x in x0...x1 {
                    let c = (y0 - 1) * grid.columns + x
                    if holdsOther(c, index), highY[c] >= b.minY - linkGap { union(index, Int(representative[c])) }
                }
            }
            // Past its corners: a part lying wholly in that quadrant, found by its nearest corner.
            for kind in 0..<4 {
                let right = kind == 0 || kind == 2, up = kind == 0 || kind == 1
                guard right ? rightOpen : leftOpen, up ? topOpen : bottomOpen else { continue }
                let c = (up ? y1 + 1 : y0 - 1) * grid.columns + (right ? x1 + 1 : x0 - 1)
                guard holdsOther(c, index), let candidates = corners[kind][c] else { continue }
                let found = candidates.first { candidate in
                    let o = parts[Int(candidate)].bounds
                    let nearX = right ? o.minX <= b.maxX + linkGap : o.maxX >= b.minX - linkGap
                    let nearY = up ? o.minY <= b.maxY + linkGap : o.maxY >= b.minY - linkGap
                    return nearX && nearY
                }
                if let found { union(index, Int(found)) }
            }

            // Its own cells: one representative each, joined without a test.
            for y in y0...y1 {
                for x in x0...x1 {
                    let c = y * grid.columns + x
                    if representative[c] < 0 {
                        representative[c] = Int32(index)
                        lowX[c] = b.minX; highX[c] = b.maxX; lowY[c] = b.minY; highY[c] = b.maxY
                    } else {
                        union(index, Int(representative[c]))
                        lowX[c] = Swift.min(lowX[c], b.minX); highX[c] = Swift.max(highX[c], b.maxX)
                        lowY[c] = Swift.min(lowY[c], b.minY); highY[c] = Swift.max(highY[c], b.maxY)
                    }
                }
            }
            // Its corners, where they lie on the grid, each under the kind a part past it asks
            // for: kind 0 is the bottom-left corner (asked by a part below and to the left),
            // 1 bottom-right, 2 top-left, 3 top-right.
            for kind in 0..<4 {
                let right = kind == 1 || kind == 3, up = kind == 2 || kind == 3
                guard right ? rawX1 == x1 : rawX0 == x0, up ? rawY1 == y1 : rawY0 == y0 else { continue }
                corners[kind][(up ? y1 : y0) * grid.columns + (right ? x1 : x0), default: []].append(Int32(index))
            }
        }
    }

    /// The link-gap grid cell a page-relative coordinate falls in, or `nil` when it is not finite
    /// or its cell is past what the grid key holds (U-039). Checked before converting: `Int(_:)`
    /// of a `Double` past about 9.2e18 traps.
    static func cell(_ offset: Double) -> Int? {
        cell(offset, size: linkGap)
    }

    /// The grid cell of side `size` a coordinate offset falls in, on the same terms.
    static func cell(_ offset: Double, size: Double) -> Int? {
        let floored = (offset / size).rounded(.down)
        guard floored.isFinite, Swift.abs(floored) < Double(Int32.max) else { return nil }
        return Int(floored)
    }
}
