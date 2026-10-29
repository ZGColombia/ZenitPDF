import Foundation

/// Limits on an untrusted DXF.
public struct DXFLimits: Sendable, Equatable {
    public var maximumBytes: Int
    /// Entities after block expansion.
    public var maximumEntities: Int
    public var maximumBlockDepth: Int
    /// Entities *visited* inside blocks during expansion — drawn, skipped or not drawn at all —
    /// and block instances placed (R-192). ``maximumEntities`` counts only what is drawn, so nested
    /// arrays of empty blocks, or of entity types that are only counted as skipped, used to run
    /// 10^6 iterations per nesting level with nothing drawn and nothing refused: 10^12 at two
    /// levels. Four times the entity cap by default.
    public var maximumExpansionSteps: Int
    /// Points in the drawn geometry, model space included: polyline and spline vertices, the
    /// samples of arcs, circles, ellipses and bulges flattened under a non-uniform scale, one per
    /// arc, circle or ellipse kept as a curve, and one per UTF-8 byte of a text's string, which
    /// the sheet writes out for every instance (R-192, re-fix). The entity cap and the step budget
    /// count entities, but the work and memory behind one entity grow with its vertices: a 25 KB
    /// file placing one 2 000-vertex polyline in a 1 000 × 1 000 array passed both, at 2 × 10^9
    /// points. 50 million by default — at the cap the reader holds about 1.2 GB of points and
    /// bulges, and an array that cannot fit is refused before its first placement.
    public var maximumPoints: Int

    public init(maximumBytes: Int = 128 * 1024 * 1024, maximumEntities: Int = 1_000_000, maximumBlockDepth: Int = 16,
                maximumExpansionSteps: Int? = nil, maximumPoints: Int = 50_000_000) {
        self.maximumBytes = maximumBytes
        self.maximumEntities = maximumEntities
        self.maximumBlockDepth = maximumBlockDepth
        let (fourTimes, overflow) = maximumEntities.multipliedReportingOverflow(by: 4)
        self.maximumExpansionSteps = maximumExpansionSteps ?? (overflow ? .max : fourTimes)
        self.maximumPoints = maximumPoints
    }

    public static let standard = DXFLimits()
}

/// Reads an ASCII DXF: HEADER (`$INSUNITS`), TABLES (layers), BLOCKS and ENTITIES.
///
/// Drawn: LINE, LWPOLYLINE, POLYLINE (2D), CIRCLE, ARC, ELLIPSE, SPLINE (evaluated, then drawn as a
/// fine polyline), TEXT, MTEXT (formatting codes stripped), INSERT (with arrays, nested to a cap)
/// and DIMENSION (its block). Anything else is counted in ``DXFDrawing/skipped`` and not drawn.
///
/// The drawing is the plan, seen from above. CIRCLE, ARC, LWPOLYLINE, 2D POLYLINE, TEXT and INSERT
/// are placed by their extrusion direction (X-048): along −Z mirrored, on a tilted plane as their
/// plan view, and on a vertical plane not at all (counted as skipped, "<type> (edge-on)").
public enum DXFReader {

    public static func read(_ data: Data, limits: DXFLimits = .standard) throws -> DXFDrawing {
        try readCounting(data, limits: limits).drawing
    }

    /// ``read(_:limits:)`` with the expansion's own counts, for tests.
    static func readCounting(_ data: Data, limits: DXFLimits) throws -> (drawing: DXFDrawing, statistics: ExpansionStatistics) {
        guard data.count <= limits.maximumBytes else { throw DXFError.tooLarge(bytes: data.count, limit: limits.maximumBytes) }
        if data.starts(with: Data("AutoCAD Binary DXF".utf8)) { throw DXFError.binaryDXF }
        let pairs = tokenize(data)
        guard pairs.contains(where: { $0.code == 0 && $0.value == "SECTION" }) else { throw DXFError.notDXF }

        var unit = DXFUnit.unitless
        var unitDeclared = false
        var layers: [String] = []
        // Membership by set, not by scanning the list: a table of 30 000 layers took a minute.
        var knownLayers: Set<String> = []
        var blocks: [String: (base: DXFPoint, entities: [RawEntity])] = [:]
        var modelEntities: [RawEntity] = []
        var skipped: [String: Int] = [:]

        var index = 0
        while index < pairs.count {
            guard pairs[index].code == 0, pairs[index].value == "SECTION", index + 1 < pairs.count else { index += 1; continue }
            let name = pairs[index + 1].value
            index += 2
            switch name {
            case "HEADER":
                while index < pairs.count, !(pairs[index].code == 0 && pairs[index].value == "ENDSEC") {
                    if pairs[index].code == 9, pairs[index].value == "$INSUNITS", index + 1 < pairs.count,
                       let raw = Int(pairs[index + 1].value) {
                        unit = DXFUnit(rawValue: raw) ?? .unitless
                        unitDeclared = true
                    }
                    index += 1
                }
            case "TABLES":
                var inLayerTable = false
                while index < pairs.count, !(pairs[index].code == 0 && pairs[index].value == "ENDSEC") {
                    let pair = pairs[index]
                    if pair.code == 0, pair.value == "TABLE", index + 1 < pairs.count {
                        inLayerTable = pairs[index + 1].value == "LAYER"
                    } else if pair.code == 0, pair.value == "ENDTAB" {
                        inLayerTable = false
                    } else if inLayerTable, pair.code == 0, pair.value == "LAYER" {
                        var cursor = index + 1
                        while cursor < pairs.count, pairs[cursor].code != 0 {
                            if pairs[cursor].code == 2 {
                                let name = boundedName(pairs[cursor].value)
                                if knownLayers.insert(name).inserted { layers.append(name) }
                            }
                            cursor += 1
                        }
                    }
                    index += 1
                }
            case "BLOCKS":
                while index < pairs.count, !(pairs[index].code == 0 && pairs[index].value == "ENDSEC") {
                    guard pairs[index].code == 0, pairs[index].value == "BLOCK" else { index += 1; continue }
                    let header = collect(pairs, from: &index)   // BLOCK's own group codes
                    let blockName = header.string(2) ?? ""
                    let base = DXFPoint(x: header.double(10) ?? 0, y: header.double(20) ?? 0)
                    var members: [RawEntity] = []
                    while index < pairs.count, !(pairs[index].code == 0 && (pairs[index].value == "ENDBLK" || pairs[index].value == "ENDSEC")) {
                        members.append(collect(pairs, from: &index))
                    }
                    if !blockName.isEmpty { blocks[blockName] = (base, members) }
                }
            case "ENTITIES":
                while index < pairs.count, !(pairs[index].code == 0 && pairs[index].value == "ENDSEC") {
                    guard pairs[index].code == 0 else { index += 1; continue }
                    modelEntities.append(collect(pairs, from: &index))
                }
            default:
                break
            }
        }

        var expander = Expander(blocks: blocks, limits: limits)
        var entities: [DXFEntity] = []
        try expander.expandModelSpace(modelEntities, into: &entities, skipped: &skipped)
        guard !entities.isEmpty else { throw DXFError.nothingToDraw }
        var used: Set<String> = []
        for entity in entities where used.insert(entity.layer).inserted {
            if knownLayers.insert(entity.layer).inserted { layers.append(entity.layer) }
        }
        layers = layers.filter { used.contains($0) }
        let drawing = DXFDrawing(unit: unit, unitDeclared: unitDeclared, layers: layers, entities: entities, skipped: skipped)
        return (drawing, expander.statistics)
    }

    /// The longest layer or entity-type name kept, in Unicode scalars; CAD programs stop at 255.
    /// Every drawn entity's layer is hashed, and every skipped instance's type: a 1 MB name placed
    /// a million times would otherwise be 10^12 bytes of hashing with nothing refused.
    static let maximumNameScalars = 255

    static func boundedName(_ name: String) -> String {
        guard name.utf8.count > maximumNameScalars else { return name }
        return String(String.UnicodeScalarView(name.unicodeScalars.prefix(maximumNameScalars)))
    }

    // MARK: - Tokens

    struct Pair: Sendable { let code: Int; let value: String }

    static func tokenize(_ data: Data) -> [Pair] {
        let text = String(decoding: data, as: UTF8.self)
        var lines: [Substring] = []
        lines.reserveCapacity(data.count / 6)
        // "\r\n" is one Character in Swift, so split on every line-ending grapheme.
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .forEach { lines.append($0) }
        var pairs: [Pair] = []
        pairs.reserveCapacity(lines.count / 2)
        var index = 0
        while index + 1 < lines.count {
            let codeText = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(lines[index + 1])
            if value.hasSuffix("\r") { value.removeLast() }
            if let code = Int(codeText) {
                // Group values are trimmed of leading space except text (1, 3) where spacing matters.
                let trimmed = (code == 1 || code == 3) ? value : value.trimmingCharacters(in: .whitespaces)
                pairs.append(Pair(code: code, value: trimmed))
            }
            index += 2
        }
        return pairs
    }

    /// One entity's group codes: from the `0` that names it to the next `0`.
    struct RawEntity: Sendable {
        let type: String
        let pairs: [Pair]
        func string(_ code: Int) -> String? { pairs.first { $0.code == code }?.value }
        func double(_ code: Int) -> Double? { pairs.first { $0.code == code }.flatMap { Double($0.value) }.flatMap { $0.isFinite ? $0 : nil } }
        func int(_ code: Int) -> Int? { pairs.first { $0.code == code }.flatMap { Int($0.value) } }
        func doubles(_ code: Int) -> [Double] { pairs.filter { $0.code == code }.compactMap { Double($0.value) }.filter(\.isFinite) }
        var layer: String { DXFReader.boundedName(string(8) ?? "0") }

        /// The extrusion direction, groups 210/220/230, each defaulting to (0, 0, 1) as the
        /// format defines; `nil` when none of the three is given. One pass, first value of each.
        var extrusion: (x: Double, y: Double, z: Double)? {
            var x: Double?, y: Double?, z: Double?
            for pair in pairs where pair.code == 210 || pair.code == 220 || pair.code == 230 {
                guard let value = Double(pair.value), value.isFinite else { continue }
                switch pair.code {
                case 210: if x == nil { x = value }
                case 220: if y == nil { y = value }
                default: if z == nil { z = value }
                }
            }
            guard x != nil || y != nil || z != nil else { return nil }
            return (x ?? 0, y ?? 0, z ?? 1)
        }
    }

    /// Where an entity's object coordinate system lands in the plan (X-048).
    enum ObjectCoordinates: Equatable {
        /// The OCS is the plan itself: no extrusion given, or one along +Z.
        case plan
        /// OCS x/y (at the entity's elevation) to plan x/y: the arbitrary-axis basis, seen from
        /// above. Along −Z this is exactly the mirror x → −x.
        case projected(Affine)
        /// The entity's plane is within about a degree of vertical (|Nz| < 1/64): it has no area
        /// in the plan, so it is not drawn and is counted as skipped.
        case edgeOn
    }

    /// The format's arbitrary-axis algorithm for an extrusion `n`, as a plan transform.
    ///
    /// CIRCLE, ARC, LWPOLYLINE, 2D POLYLINE, TEXT and INSERT store their points in the OCS that
    /// the extrusion defines, not in the world. For N = (0, 0, −1) the rule gives Ax = (−1, 0, 0)
    /// and Ay = (0, 1, 0), so a point stored at (x, y) is drawn at (−x, y). The reader used to
    /// take the stored x/y as world coordinates whatever the extrusion, and drew such entities
    /// mirrored about the Y axis. A malformed extrusion (zero length) reads as the default.
    static func objectCoordinates(extrusion: (x: Double, y: Double, z: Double)?, elevation: Double) -> ObjectCoordinates {
        guard let n = extrusion else { return .plan }
        if n.x == 0, n.y == 0, n.z > 0 { return .plan }
        let length = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
        guard length.isFinite, length > 0 else { return .plan }
        let (nx, ny, nz) = (n.x / length, n.y / length, n.z / length)
        guard abs(nz) >= 1.0 / 64 else { return .edgeOn }
        // Ax = Wy × N near the poles, Wz × N elsewhere; Ay = N × Ax.
        var (ax, ay, az) = abs(nx) < 1.0 / 64 && abs(ny) < 1.0 / 64 ? (nz, 0.0, -nx) : (-ny, nx, 0.0)
        let axLength = (ax * ax + ay * ay + az * az).squareRoot()
        (ax, ay, az) = (ax / axLength, ay / axLength, az / axLength)
        let (bx, by) = (ny * az - nz * ay, nz * ax - nx * az)
        let elevationOffset = elevation == 0 ? (0.0, 0.0) : (nx * elevation, ny * elevation)
        return .projected(Affine(a: ax, b: ay, c: bx, d: by, tx: elevationOffset.0, ty: elevationOffset.1))
    }

    static func collect(_ pairs: [Pair], from index: inout Int) -> RawEntity {
        let type = index < pairs.count ? pairs[index].value : ""
        index += 1
        var members: [Pair] = []
        while index < pairs.count, pairs[index].code != 0 {
            members.append(pairs[index])
            index += 1
        }
        return RawEntity(type: type, pairs: members)
    }
}

// MARK: - Transforms

struct Affine: Sendable, Equatable {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0
    static let identity = Affine()

    func apply(_ p: DXFPoint) -> DXFPoint { DXFPoint(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty) }
    func applyVector(_ p: DXFPoint) -> DXFPoint { DXFPoint(x: a * p.x + c * p.y, y: b * p.x + d * p.y) }
    /// self ∘ other (apply other first).
    func concatenating(_ other: Affine) -> Affine {
        Affine(a: a * other.a + c * other.b, b: b * other.a + d * other.b,
               c: a * other.c + c * other.d, d: b * other.c + d * other.d,
               tx: a * other.tx + c * other.ty + tx, ty: b * other.tx + d * other.ty + ty)
    }
    static func translation(_ x: Double, _ y: Double) -> Affine { Affine(tx: x, ty: y) }
    static func rotation(_ radians: Double) -> Affine { Affine(a: cos(radians), b: sin(radians), c: -sin(radians), d: cos(radians)) }
    static func scale(_ sx: Double, _ sy: Double) -> Affine { Affine(a: sx, d: sy) }

    var determinant: Double { a * d - b * c }
    /// Rotation plus uniform scale, possibly mirrored: circles stay circles.
    var isSimilarity: Bool {
        let tolerance = 1e-9 * max(1, abs(a) + abs(b) + abs(c) + abs(d))
        return (abs(a - d) < tolerance && abs(b + c) < tolerance) || (abs(a + d) < tolerance && abs(b - c) < tolerance)
    }
    var uniformScale: Double { sqrt(abs(determinant)) }
    var rotationAngle: Double { atan2(b, a) }
}

// MARK: - Expansion

/// An entity decoded once from its group codes (R-192, re-fix). A block placed a million times
/// used to parse its members' group codes a million times — every vertex of a long polyline, or
/// 20 000 values of one that draws nothing at all — so the work behind a single step grew with
/// the entity. A block is decoded the first time it is placed and kept; a placement transforms.
/// Model space is decoded as it is reached and never held twice.
struct PreparedEntity: Sendable {
    enum Kind: Sendable {
        case line(DXFPoint, DXFPoint)
        case polyline(points: [DXFPoint], bulges: [Double], closed: Bool, hasBulge: Bool)
        case circle(center: DXFPoint, radius: Double)
        /// Angles in radians.
        case arc(center: DXFPoint, radius: Double, start: Double, end: Double)
        /// `minorAxis` is given only for an ellipse whose plane is tilted out of the plan (X-048):
        /// its projected axes are no longer perpendicular, so it is drawn sampled. `nil` is the
        /// plan's own minor axis, the major axis turned a quarter counter-clockwise times `ratio`.
        case ellipse(center: DXFPoint, majorAxis: DXFPoint, ratio: Double, start: Double, end: Double, minorAxis: DXFPoint?)
        /// Evaluated on first placement and kept by `id`: up to 2 000 samples, so evaluating before
        /// the points are charged holds at most one spline's worth uncharged.
        case spline(id: Int, source: DXFReader.RawEntity, closed: Bool)
        /// Rotation in radians, the MTEXT codes already stripped.
        case text(anchor: DXFPoint, height: Double, rotation: Double, string: String)
        case insert(block: String, insertion: DXFPoint, scaleX: Double, scaleY: Double, rotation: Double,
                    columns: Int, rows: Int, columnSpacing: Double, rowSpacing: Double)
        case dimension(block: String)
        case skipped(String)
    }
    let layer: String
    let kind: Kind
    /// The entity's object coordinate system in the plan, applied before the placement's
    /// transform (X-048). `nil` when the OCS is the plan.
    var ocs: Affine? = nil
}

/// What an expansion did, for tests.
struct ExpansionStatistics: Sendable, Equatable {
    var steps = 0
    var points = 0
    /// Group-code records decoded into a ``PreparedEntity``, VERTEX runs included in their POLYLINE.
    var decoded = 0
}

struct Expander {
    let blocks: [String: (base: DXFPoint, entities: [DXFReader.RawEntity])]
    let limits: DXFLimits
    var produced = 0
    /// Steps against ``DXFLimits/maximumExpansionSteps``, points against ``DXFLimits/maximumPoints``.
    var statistics = ExpansionStatistics()
    /// Blocks decoded on first placement.
    var prepared: [String: (base: DXFPoint, entities: [PreparedEntity])] = [:]
    var splineSamples: [Int: [DXFPoint]] = [:]
    var nextSplineID = 0
    /// Fewest points one placement of a block emits, by name.
    var minimumPointsByBlock: [String: Int] = [:]
    /// Steps and points since the last cancellation check.
    var workSinceCancellationCheck = 0
    static let cancellationInterval = 4_096

    init(blocks: [String: (base: DXFPoint, entities: [DXFReader.RawEntity])], limits: DXFLimits) {
        self.blocks = blocks
        self.limits = limits
    }

    // MARK: Budgets

    /// One entity visited inside a block, or one block instance placed (R-192).
    mutating func step() throws {
        statistics.steps += 1
        guard statistics.steps <= limits.maximumExpansionSteps else { throw DXFError.tooManyEntities(limit: limits.maximumEntities) }
        try work(1)
    }

    /// `count` points about to be made, charged before they are (R-192, re-fix).
    mutating func charge(_ count: Int) throws {
        let (total, overflow) = statistics.points.addingReportingOverflow(count)
        guard !overflow, total <= limits.maximumPoints else { throw DXFError.tooManyPoints(limit: limits.maximumPoints) }
        statistics.points = total
        try work(count)
    }

    /// A cancellation point every 4 096 units of work, a step and a point each counting one, so
    /// the geometry service's cancel — and the in-process fallback's — stops a file of long
    /// polylines as promptly as one of many small entities.
    mutating func work(_ units: Int) throws {
        workSinceCancellationCheck += units
        guard workSinceCancellationCheck >= Self.cancellationInterval else { return }
        workSinceCancellationCheck = 0
        try Task.checkCancellation()
    }

    mutating func countEntity() throws {
        produced += 1
        guard produced <= limits.maximumEntities else { throw DXFError.tooManyEntities(limit: limits.maximumEntities) }
    }

    /// One drawn entity of `points` points: counted and charged, then made.
    mutating func emit(points: Int, layer: String, into output: inout [DXFEntity], _ shape: () -> DXFShape) throws {
        try countEntity()
        try charge(points)
        output.append(DXFEntity(layer: layer, shape: shape()))
    }

    /// Refuses `instances` placements of `name` before the first one when even the fewest points
    /// they could draw do not fit in what is left of the budget. The outcome is the one the
    /// placements would reach — the figure is a lower bound — only reached at once.
    mutating func reserve(instances: Int, ofBlock name: String, depth: Int) throws {
        let (needed, overflow) = instances.multipliedReportingOverflow(by: minimumPoints(ofBlock: name, depth: depth))
        guard !overflow, needed <= limits.maximumPoints - statistics.points else {
            throw DXFError.tooManyPoints(limit: limits.maximumPoints)
        }
    }

    /// Fewest points one placement of `name` draws whatever its transform: line and polyline
    /// vertices, one per circle, text bytes, nested arrays multiplied out. Arcs, ellipses and
    /// splines count nothing (a non-finite angle or a degenerate spline draws nothing), and
    /// nesting past the depth cap counts nothing, so the figure never exceeds what is drawn.
    mutating func minimumPoints(ofBlock name: String, depth: Int) -> Int {
        if let known = minimumPointsByBlock[name] { return known }
        guard depth <= limits.maximumBlockDepth, let block = block(named: name) else { return 0 }
        var total = 0
        for entity in block.entities {
            var each = 0
            switch entity.kind {
            case .line: each = 2
            case let .polyline(points, _, _, _): each = points.count
            case .circle: each = 1
            case let .text(_, _, _, string): each = max(1, string.utf8.count)
            case let .insert(nested, _, _, _, _, columns, rows, _, _):
                let (product, overflow) = (columns * rows).multipliedReportingOverflow(by: minimumPoints(ofBlock: nested, depth: depth + 1))
                each = overflow ? .max : product
            case let .dimension(nested): each = minimumPoints(ofBlock: nested, depth: depth + 1)
            case .arc, .ellipse, .spline, .skipped: each = 0
            }
            let (sum, overflow) = total.addingReportingOverflow(each)
            total = overflow ? .max : sum
        }
        minimumPointsByBlock[name] = total
        return total
    }

    // MARK: Decoding

    /// A block's members, decoded the first time it is asked for.
    mutating func block(named name: String) -> (base: DXFPoint, entities: [PreparedEntity])? {
        if let ready = prepared[name] { return ready }
        guard let source = blocks[name] else { return nil }
        var entities: [PreparedEntity] = []
        var index = 0
        while index < source.entities.count {
            if let entity = decode(source.entities, at: &index) { entities.append(entity) }
        }
        prepared[name] = (source.base, entities)
        return (source.base, entities)
    }

    /// The entity at `index`, advancing past it (and a POLYLINE's VERTEX run). `nil` for what draws
    /// nothing wherever it is placed: incomplete data, VERTEX, SEQEND, attributes, viewports, and
    /// an INSERT of a block that does not exist.
    mutating func decode(_ raws: [DXFReader.RawEntity], at index: inout Int) -> PreparedEntity? {
        let raw = raws[index]
        index += 1
        statistics.decoded += 1
        let layer = raw.layer
        func make(_ kind: PreparedEntity.Kind) -> PreparedEntity { PreparedEntity(layer: layer, kind: kind) }
        /// An entity whose points are in its OCS (X-048), placed by its extrusion at `elevation`.
        func placed(_ kind: PreparedEntity.Kind, elevationCode: Int) -> PreparedEntity {
            switch DXFReader.objectCoordinates(extrusion: raw.extrusion, elevation: raw.double(elevationCode) ?? 0) {
            case .plan: return make(kind)
            case .projected(let ocs): return PreparedEntity(layer: layer, kind: kind, ocs: ocs)
            case .edgeOn: return make(.skipped(DXFReader.boundedName(raw.type) + " (edge-on)"))
            }
        }
        switch raw.type {
        case "LINE":
            guard let x1 = raw.double(10), let y1 = raw.double(20), let x2 = raw.double(11), let y2 = raw.double(21) else { return nil }
            return make(.line(.init(x: x1, y: y1), .init(x: x2, y: y2)))
        case "LWPOLYLINE":
            let xs = raw.doubles(10), ys = raw.doubles(20)
            let count = min(xs.count, ys.count)
            guard count >= 2 else { return nil }
            // Bulges follow their vertex; walk the pairs in order to keep them aligned.
            var bulges = [Double](repeating: 0, count: count)
            var vertex = -1
            for pair in raw.pairs {
                if pair.code == 10 { vertex += 1 } else if pair.code == 42, vertex >= 0, vertex < count, let value = Double(pair.value), value.isFinite {
                    bulges[vertex] = value
                }
            }
            return placed(.polyline(points: (0..<count).map { DXFPoint(x: xs[$0], y: ys[$0]) }, bulges: bulges,
                                    closed: ((raw.int(70) ?? 0) & 1) != 0, hasBulge: bulges.contains { $0 != 0 }),
                          elevationCode: 38)
        case "POLYLINE":
            let flags = raw.int(70) ?? 0
            let closed = (flags & 1) != 0
            var points: [DXFPoint] = [], bulges: [Double] = []
            while index < raws.count, raws[index].type == "VERTEX" {
                let vertex = raws[index]
                if let x = vertex.double(10), let y = vertex.double(20) {
                    points.append(.init(x: x, y: y)); bulges.append(vertex.double(42) ?? 0)
                }
                index += 1
            }
            if index < raws.count, raws[index].type == "SEQEND" { index += 1 }
            guard points.count >= 2 else { return nil }
            let polyline = PreparedEntity.Kind.polyline(points: points, bulges: bulges, closed: closed, hasBulge: bulges.contains { $0 != 0 })
            // A 3D polyline (8), a mesh (16) and a polyface (64) keep their vertices in the world;
            // only a 2D polyline's are in its OCS, at the elevation its own 30 carries.
            return flags & (8 | 16 | 64) != 0 ? make(polyline) : placed(polyline, elevationCode: 30)
        case "CIRCLE":
            guard let x = raw.double(10), let y = raw.double(20), let r = raw.double(40), r > 0 else { return nil }
            return placed(.circle(center: .init(x: x, y: y), radius: r), elevationCode: 30)
        case "ARC":
            guard let x = raw.double(10), let y = raw.double(20), let r = raw.double(40), r > 0,
                  let s = raw.double(50), let e = raw.double(51) else { return nil }
            return placed(.arc(center: .init(x: x, y: y), radius: r, start: s * .pi / 180, end: e * .pi / 180), elevationCode: 30)
        case "ELLIPSE":
            guard let x = raw.double(10), let y = raw.double(20), let mx = raw.double(11), let my = raw.double(21),
                  let ratio = raw.double(40), ratio > 0 else { return nil }
            let start = raw.double(41) ?? 0, end = raw.double(42) ?? 2 * .pi
            let center = DXFPoint(x: x, y: y), major = DXFPoint(x: mx, y: my)
            // Centre and major axis are in the world; the extrusion says which way the minor axis
            // turns, N × major (X-048). Along −Z it turns clockwise, which is the plan ellipse run
            // backwards: parameter t is −t, so (start, end) is (2π − end, 2π − start).
            switch DXFReader.objectCoordinates(extrusion: raw.extrusion, elevation: 0) {
            case .plan:
                return make(.ellipse(center: center, majorAxis: major, ratio: ratio, start: dxfAngle(start), end: end, minorAxis: nil))
            case .edgeOn:
                return make(.skipped("ELLIPSE (edge-on)"))
            case .projected:
                guard let n = raw.extrusion else { return nil }
                if n.x == 0, n.y == 0 {
                    return make(.ellipse(center: center, majorAxis: major, ratio: ratio,
                                         start: dxfAngle(2 * .pi - end), end: 2 * .pi - start, minorAxis: nil))
                }
                let length = (n.x * n.x + n.y * n.y + n.z * n.z).squareRoot()
                let (nx, ny, nz) = (n.x / length, n.y / length, n.z / length)
                let mz = raw.double(31) ?? 0
                let minor = DXFPoint(x: (ny * mz - nz * my) * ratio, y: (nz * mx - nx * mz) * ratio)
                return make(.ellipse(center: center, majorAxis: major, ratio: ratio, start: dxfAngle(start), end: end, minorAxis: minor))
            }
        case "SPLINE":
            defer { nextSplineID += 1 }
            return make(.spline(id: nextSplineID, source: raw, closed: ((raw.int(70) ?? 0) & 1) != 0))
        case "TEXT", "MTEXT":
            guard let x = raw.double(10), let y = raw.double(20) else { return nil }
            let height = raw.double(40) ?? 2.5
            let string = raw.type == "MTEXT"
                ? DXFReader.plainMText(raw.pairs.filter { $0.code == 3 }.map(\.value).joined() + (raw.string(1) ?? ""))
                : raw.string(1) ?? ""
            guard !string.trimmingCharacters(in: .whitespaces).isEmpty, height > 0 else { return nil }
            // Justified TEXT is anchored at its alignment point (11/21) when one is given.
            var anchor = DXFPoint(x: x, y: y)
            if raw.type == "TEXT", (raw.int(72) ?? 0) != 0 || (raw.int(73) ?? 0) != 0,
               let ax = raw.double(11), let ay = raw.double(21) { anchor = .init(x: ax, y: ay) }
            let text = PreparedEntity.Kind.text(anchor: anchor, height: height, rotation: (raw.double(50) ?? 0) * .pi / 180, string: string)
            // TEXT is placed in its OCS; MTEXT's insertion point is in the world.
            return raw.type == "TEXT" ? placed(text, elevationCode: 30) : make(text)
        case "INSERT":
            guard let name = raw.string(2), blocks[name] != nil else { return nil }
            return placed(.insert(block: name, insertion: .init(x: raw.double(10) ?? 0, y: raw.double(20) ?? 0),
                                  scaleX: raw.double(41) ?? 1, scaleY: raw.double(42) ?? 1, rotation: (raw.double(50) ?? 0) * .pi / 180,
                                  columns: max(1, min(raw.int(70) ?? 1, 10_000)), rows: max(1, min(raw.int(71) ?? 1, 10_000)),
                                  columnSpacing: raw.double(44) ?? 0, rowSpacing: raw.double(45) ?? 0),
                          elevationCode: 30)
        case "DIMENSION":
            guard let name = raw.string(2), blocks[name] != nil else { return make(.skipped("DIMENSION (no block)")) }
            return make(.dimension(block: name))
        case "VERTEX", "SEQEND", "ATTDEF", "ATTRIB", "VIEWPORT", "":
            return nil
        default:
            return make(.skipped(DXFReader.boundedName(raw.type)))
        }
    }

    // MARK: Expansion

    /// Model space: each entity decoded as it is reached and drawn once. Model-space entities are
    /// bounded by the file's size, so they are not steps; their points are charged all the same.
    mutating func expandModelSpace(_ raws: [DXFReader.RawEntity], into output: inout [DXFEntity], skipped: inout [String: Int]) throws {
        var index = 0
        while index < raws.count {
            guard let entity = decode(raws, at: &index) else { continue }
            try draw(entity, transform: .identity, inheritedLayer: "0", depth: 0, into: &output, skipped: &skipped)
        }
    }

    /// One placement of a block's decoded members; every member visited is a step.
    mutating func expand(_ entities: [PreparedEntity], transform: Affine, inheritedLayer: String, depth: Int,
                         into output: inout [DXFEntity], skipped: inout [String: Int]) throws {
        guard depth <= limits.maximumBlockDepth else { throw DXFError.blockNestingTooDeep(limit: limits.maximumBlockDepth) }
        for entity in entities {
            try step()
            try draw(entity, transform: transform, inheritedLayer: inheritedLayer, depth: depth, into: &output, skipped: &skipped)
        }
    }

    mutating func draw(_ entity: PreparedEntity, transform: Affine, inheritedLayer: String, depth: Int,
                       into output: inout [DXFEntity], skipped: inout [String: Int]) throws {
        let layer = entity.layer == "0" ? inheritedLayer : entity.layer
        // OCS first, then the placement (X-048); an INSERT's own transform is in its OCS too.
        let transform = entity.ocs.map(transform.concatenating) ?? transform
        switch entity.kind {
        case let .line(p, q):
            try emit(points: 2, layer: layer, into: &output) {
                .polyline(points: [transform.apply(p), transform.apply(q)], bulges: [0], closed: false)
            }
        case let .polyline(points, bulges, closed, hasBulge):
            try emitPolyline(points, bulges: bulges, closed: closed, hasBulge: hasBulge, transform: transform, layer: layer, into: &output)
        case let .circle(center, radius):
            if transform.isSimilarity {
                try emit(points: 1, layer: layer, into: &output) {
                    .circle(center: transform.apply(center), radius: radius * transform.uniformScale)
                }
            } else {
                try emitFlattenedArc(center: center, radius: radius, start: 0, end: 2 * .pi, closed: true,
                                     transform: transform, layer: layer, into: &output)
            }
        case let .arc(center, radius, start, end):
            if transform.isSimilarity {
                let rotation = transform.rotationAngle
                // A mirror reverses direction: the image runs from mirror(end) to mirror(start).
                let (from, to) = transform.determinant >= 0 ? (start + rotation, end + rotation) : (rotation - end, rotation - start)
                try emit(points: 1, layer: layer, into: &output) {
                    .arc(center: transform.apply(center), radius: radius * transform.uniformScale, start: from, end: to)
                }
            } else {
                try emitFlattenedArc(center: center, radius: radius, start: start, end: end, closed: false,
                                     transform: transform, layer: layer, into: &output)
            }
        case let .ellipse(center, major, ratio, start, end, minorAxis):
            if minorAxis == nil, transform.isSimilarity, transform.determinant >= 0 {
                try emit(points: 1, layer: layer, into: &output) {
                    .ellipse(center: transform.apply(center), majorAxis: transform.applyVector(major), ratio: ratio, start: start, end: end)
                }
            } else {
                // Sample in model space, transform the samples.
                let minor = minorAxis ?? DXFPoint(x: -major.y * ratio, y: major.x * ratio)
                let sweep = dxfSweep(from: start, to: end)
                guard sweep > 0 else { return }
                let samples = max(8, Int(ceil(sweep / (.pi / 64))))
                try emit(points: samples + 1, layer: layer, into: &output) {
                    let points = (0...samples).map { i -> DXFPoint in
                        let t = start + sweep * Double(i) / Double(samples)
                        return transform.apply(.init(x: center.x + major.x * cos(t) + minor.x * sin(t),
                                                     y: center.y + major.y * cos(t) + minor.y * sin(t)))
                    }
                    return .polyline(points: points, bulges: [Double](repeating: 0, count: points.count), closed: false)
                }
            }
        case let .spline(id, source, closed):
            let points: [DXFPoint]
            if let known = splineSamples[id] {
                points = known
            } else {
                points = try Self.evaluateSpline(source)
                // Model space is drawn once; only a block's spline is placed again.
                if depth > 0 { splineSamples[id] = points }
            }
            guard points.count >= 2 else { return }
            try emit(points: points.count, layer: layer, into: &output) {
                .polyline(points: points.map(transform.apply), bulges: [Double](repeating: 0, count: points.count), closed: closed)
            }
        case let .text(anchor, height, rotation, string):
            // The angle is where the baseline points once placed (X-048 re-fix). Adding the
            // transform's own angle is right only for a rotation: a mirror — extrusion −Z, a
            // negative INSERT scale — turns angles the other way, so under x → −x a baseline at
            // r runs at π − r, and `r + π` drew it upside down. Mapping the baseline's direction
            // holds for a mirror, a non-uniform scale and a tilted plane's plan view alike.
            let baseline = transform.applyVector(DXFPoint(x: cos(rotation), y: sin(rotation)))
            try emit(points: max(1, string.utf8.count), layer: layer, into: &output) {
                .text(position: transform.apply(anchor), height: height * transform.uniformScale,
                      rotation: atan2(baseline.y, baseline.x), string: string)
            }
        case let .insert(name, insertion, sx, sy, rotation, columns, rows, columnSpacing, rowSpacing):
            guard let block = block(named: name) else { return }
            guard columns * rows <= limits.maximumEntities else { throw DXFError.tooManyEntities(limit: limits.maximumEntities) }
            try reserve(instances: columns * rows, ofBlock: name, depth: depth + 1)
            for row in 0..<rows {
                for column in 0..<columns {
                    // An instance of an empty block draws nothing and visits nothing, so it
                    // is a step of its own.
                    try step()
                    let offset = Affine.rotation(rotation).applyVector(.init(x: Double(column) * columnSpacing, y: Double(row) * rowSpacing))
                    let local = Affine.translation(insertion.x + offset.x, insertion.y + offset.y)
                        .concatenating(.rotation(rotation))
                        .concatenating(.scale(sx, sy))
                        .concatenating(.translation(-block.base.x, -block.base.y))
                    try expand(block.entities, transform: transform.concatenating(local), inheritedLayer: layer,
                               depth: depth + 1, into: &output, skipped: &skipped)
                }
            }
        case let .dimension(name):
            // A dimension's block is already in model coordinates.
            guard let block = block(named: name) else { return }
            try reserve(instances: 1, ofBlock: name, depth: depth + 1)
            try expand(block.entities, transform: transform, inheritedLayer: layer, depth: depth + 1, into: &output, skipped: &skipped)
        case let .skipped(type):
            skipped[type, default: 0] += 1
        }
    }

    mutating func emitPolyline(_ points: [DXFPoint], bulges: [Double], closed: Bool, hasBulge: Bool, transform: Affine,
                               layer: String, into output: inout [DXFEntity]) throws {
        if !hasBulge || transform.isSimilarity {
            let sign = transform.determinant < 0 ? -1.0 : 1.0
            try emit(points: points.count, layer: layer, into: &output) {
                .polyline(points: points.map(transform.apply), bulges: bulges.map { $0 * sign }, closed: closed)
            }
            return
        }
        // A bulge under a non-uniform scale is an elliptical arc: sample it. Up to 129 samples a
        // segment, so each segment's are charged before they are made, not the whole at the end.
        try countEntity()
        var sampled: [DXFPoint] = []
        let segmentCount = closed ? points.count : points.count - 1
        for i in 0..<segmentCount {
            let p = points[i], q = points[(i + 1) % points.count]
            let bulge = i < bulges.count ? bulges[i] : 0
            if sampled.isEmpty { try charge(1); sampled.append(p) }
            if bulge == 0 { try charge(1); sampled.append(q); continue }
            let arc = Self.bulgeSamples(from: p, to: q, bulge: bulge)
            try charge(arc.count - 1)
            sampled.append(contentsOf: arc.dropFirst())
        }
        output.append(DXFEntity(layer: layer, shape: .polyline(points: sampled.map(transform.apply),
                                                               bulges: [Double](repeating: 0, count: sampled.count), closed: false)))
    }

    mutating func emitFlattenedArc(center: DXFPoint, radius: Double, start: Double, end: Double, closed: Bool,
                                   transform: Affine, layer: String, into output: inout [DXFEntity]) throws {
        let sweep = dxfSweep(from: start, to: end)
        guard sweep > 0 else { return }
        let samples = max(8, Int(ceil(sweep / (.pi / 64))))
        let startAngle = dxfAngle(start)
        try emit(points: samples + 1, layer: layer, into: &output) {
            let points = (0...samples).map { i -> DXFPoint in
                let t = startAngle + sweep * Double(i) / Double(samples)
                return transform.apply(.init(x: center.x + radius * cos(t), y: center.y + radius * sin(t)))
            }
            return .polyline(points: points, bulges: [Double](repeating: 0, count: points.count), closed: closed)
        }
    }

    /// Points along a bulged segment, first and last included.
    static func bulgeSamples(from p: DXFPoint, to q: DXFPoint, bulge: Double) -> [DXFPoint] {
        let theta = 4 * atan(bulge)
        let chord = hypot(q.x - p.x, q.y - p.y)
        guard chord > 0, theta.isFinite, abs(theta) > 1e-12 else { return [p, q] }
        let radius = chord / (2 * sin(abs(theta) / 2))
        let mid = DXFPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
        let offset = radius * cos(abs(theta) / 2)
        let normal = DXFPoint(x: -(q.y - p.y) / chord, y: (q.x - p.x) / chord)
        let direction = theta > 0 ? 1.0 : -1.0
        let center = DXFPoint(x: mid.x + normal.x * offset * direction, y: mid.y + normal.y * offset * direction)
        let startAngle = atan2(p.y - center.y, p.x - center.x)
        let steps = max(4, Int(ceil(abs(theta) / (.pi / 64))))
        return (0...steps).map { i in
            let t = startAngle + theta * Double(i) / Double(steps)
            return DXFPoint(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
        }
    }

    /// De Boor evaluation of a (possibly rational) B-spline, or the fit points when there are no
    /// control points. At most 2 000 samples.
    ///
    /// O(samples + control points), with a cancellation point every 256 samples and every
    /// 4 096 steps of the knot-span search (S-122). The span search restarted at `degree` for
    /// every sample, about n/2 steps each, so one SPLINE of millions of control points — cheap in
    /// a 128 MB file — cost 10^9 to 10^10 steps before a single point was charged, with no
    /// cancellation point, and held the geometry worker until the watchdog killed it. The
    /// samples' parameter only grows, so the span only moves forward.
    static func evaluateSpline(_ raw: DXFReader.RawEntity) throws -> [DXFPoint] {
        var spanSteps = 0
        return try evaluateSpline(raw, spanSteps: &spanSteps)
    }

    /// ``evaluateSpline(_:)``, counting the knot-span search's steps for the tests.
    static func evaluateSpline(_ raw: DXFReader.RawEntity, spanSteps: inout Int) throws -> [DXFPoint] {
        let degree = max(1, min(raw.int(71) ?? 3, 10))
        let knots = raw.doubles(40)
        let cx = raw.doubles(10), cy = raw.doubles(20)
        let weights = raw.doubles(41)
        let control = (0..<min(cx.count, cy.count)).map { DXFPoint(x: cx[$0], y: cy[$0]) }
        if control.count < degree + 1 || knots.count != control.count + degree + 1 {
            let fx = raw.doubles(11), fy = raw.doubles(21)
            let fit = (0..<min(fx.count, fy.count)).map { DXFPoint(x: fx[$0], y: fy[$0]) }
            return fit.count >= 2 ? fit : control
        }
        let w = weights.count == control.count ? weights : [Double](repeating: 1, count: control.count)
        let low = knots[degree], high = knots[control.count]
        guard high > low else { return control }
        let samples = min(2_000, max(16, control.count * 16))
        var result: [DXFPoint] = []
        result.reserveCapacity(samples + 1)
        var span = degree
        for i in 0...samples {
            if i & 255 == 255 { try Task.checkCancellation() }
            let t = low + (high - low) * Double(i) / Double(samples)
            while span < control.count - 1, t >= knots[span + 1] {
                span += 1
                spanSteps += 1
                if spanSteps & 4_095 == 0 { try Task.checkCancellation() }
            }
            var dx = [Double](), dy = [Double](), dw = [Double]()
            for j in 0...degree {
                let k = span - degree + j
                guard k >= 0, k < control.count else { return control }
                dw.append(w[k]); dx.append(control[k].x * w[k]); dy.append(control[k].y * w[k])
            }
            if degree >= 1 {
                for r in 1...degree {
                    for j in stride(from: degree, through: r, by: -1) {
                        let k = span - degree + j
                        let denominator = knots[k + degree - r + 1] - knots[k]
                        let alpha = denominator == 0 ? 0 : (t - knots[k]) / denominator
                        dx[j] = (1 - alpha) * dx[j - 1] + alpha * dx[j]
                        dy[j] = (1 - alpha) * dy[j - 1] + alpha * dy[j]
                        dw[j] = (1 - alpha) * dw[j - 1] + alpha * dw[j]
                    }
                }
            }
            guard dw[degree] != 0 else { continue }
            result.append(DXFPoint(x: dx[degree] / dw[degree], y: dy[degree] / dw[degree]))
        }
        return result
    }
}

extension DXFReader {
    /// MTEXT with its inline formatting removed: `\P` becomes a line break, `{\f…;` font and
    /// `\H…;` height codes and the braces around them go, `\~` is a space, `\\` a backslash.
    static func plainMText(_ text: String) -> String {
        var output = ""
        var characters = Array(text)
        var index = 0
        func skipTo(_ terminator: Character) {
            while index < characters.count, characters[index] != terminator { index += 1 }
            index += 1
        }
        while index < characters.count {
            let character = characters[index]
            if character == "{" || character == "}" { index += 1; continue }
            if character == "\\", index + 1 < characters.count {
                let code = characters[index + 1]
                index += 2
                switch code {
                case "P", "X": output.append("\n")
                case "~": output.append(" ")
                case "\\", "{", "}": output.append(code)
                case "f", "F", "H", "W", "Q", "T", "A", "C", "c", "p": skipTo(";")
                case "S":
                    // Stacked text a^b or a/b: keep both parts, joined by '/'.
                    var stacked = ""
                    while index < characters.count, characters[index] != ";" {
                        stacked.append(characters[index] == "^" || characters[index] == "#" ? "/" : characters[index])
                        index += 1
                    }
                    index += 1
                    output.append(stacked)
                default: break   // \L \O \K toggles: drop
                }
                continue
            }
            output.append(character)
            index += 1
        }
        characters.removeAll()
        return output
    }
}
