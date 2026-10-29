import Foundation
import ZPDFContracts

/// `MeasurementGeometry` as ordered JSON, coordinates as strings.
///
/// # Why not `Codable`
///
/// Two reasons, and both are already the interchange format's reasons. `JSONEncoder` emits object
/// keys in hash order (or alphabetically, with `.sortedKeys`), so a synthesised encoding would
/// make every property rename a silent file-format change and would not be byte-stable. And it
/// writes `Double` as a JSON number, which `JSONReader` refuses on purpose: a JSON number is
/// parsed into binary floating point by almost every consumer there is, and a vertex that shifts
/// in the last bits is a vertex in the wrong place.
///
/// So every coordinate travels as a string, written with `Swift.Double`'s own shortest
/// round-trippable description and read back with `Double(_: String)`. That pair is exact: the
/// value decoded is the value encoded, bit for bit.
enum OverlayGeometryCodec {

    // MARK: - Encoding

    static func json(_ geometry: MeasurementGeometry) -> JSONValue {
        .object([
            ("pageID", .string(geometry.pageID.rawValue.uuidString)),
            ("points", .array(geometry.points.map(json))),
            ("segments", .array(geometry.segments.map(json))),
            ("polygons", .array(geometry.polygons.map(json))),
            ("arcs", .array(geometry.arcs.map(json))),
            ("circles", .array(geometry.circles.map(json))),
            ("countPoints", .array(geometry.countPoints.map(json)))
        ])
    }

    private static func json(_ point: PDFPoint) -> JSONValue {
        .object([("x", .string(text(point.x))), ("y", .string(text(point.y)))])
    }

    private static func json(_ segment: SegmentGeometry) -> JSONValue {
        .object([("start", json(segment.start)), ("end", json(segment.end))])
    }

    private static func json(_ ring: PolygonRing) -> JSONValue {
        .object([
            ("points", .array(ring.points.map(json))),
            ("isClosed", .boolean(ring.isClosed))
        ])
    }

    private static func json(_ polygon: PolygonGeometry) -> JSONValue {
        .object([
            ("outer", json(polygon.outer)),
            ("holes", .array(polygon.holes.map(json)))
        ])
    }

    private static func json(_ arc: ArcGeometry) -> JSONValue {
        .object([
            ("center", json(arc.center)),
            ("radius", .string(text(arc.radius))),
            ("startAngle", .string(text(arc.startAngle))),
            ("sweepAngle", .string(text(arc.sweepAngle)))
        ])
    }

    private static func json(_ circle: CircleGeometry) -> JSONValue {
        .object([("center", json(circle.center)), ("radius", .string(text(circle.radius)))])
    }

    private static func json(_ point: CountPoint) -> JSONValue {
        .object([
            ("id", .string(point.id.rawValue.uuidString)),
            ("position", json(point.position)),
            ("sequenceNumber", point.sequenceNumber.map(JSONValue.integer) ?? .null),
            ("groupID", point.groupID.map { .string($0.rawValue.uuidString) } ?? .null),
            ("symbolID", point.symbolID.map { .string($0.rawValue.uuidString) } ?? .null)
        ])
    }

    /// `Double`'s own description is the shortest decimal that round-trips back to the same bits.
    static func text(_ value: Double) -> String { String(value) }

    // MARK: - Decoding

    static func geometry(_ value: JSONValue, _ path: String) throws -> MeasurementGeometry {
        MeasurementGeometry(
            pageID: PageID(try uuid(value["pageID"], "\(path).pageID")),
            points: try each(value["points"], "\(path).points", point),
            segments: try each(value["segments"], "\(path).segments", segment),
            polygons: try each(value["polygons"], "\(path).polygons", polygon),
            arcs: try each(value["arcs"], "\(path).arcs", arc),
            circles: try each(value["circles"], "\(path).circles", circle),
            countPoints: try each(value["countPoints"], "\(path).countPoints", countPoint)
        )
    }

    private static func each<T>(
        _ value: JSONValue?,
        _ path: String,
        _ element: (JSONValue, String) throws -> T
    ) throws -> [T] {
        guard let values = value?.arrayValue else {
            throw ExportError.malformedOverlay("\"\(path)\" is not an array")
        }
        return try values.enumerated().map { try element($0.element, "\(path)[\($0.offset)]") }
    }

    private static func point(_ value: JSONValue, _ path: String) throws -> PDFPoint {
        PDFPoint(
            x: try number(value["x"], "\(path).x"),
            y: try number(value["y"], "\(path).y")
        )
    }

    private static func segment(_ value: JSONValue, _ path: String) throws -> SegmentGeometry {
        SegmentGeometry(
            start: try point(try require(value["start"], "\(path).start"), "\(path).start"),
            end: try point(try require(value["end"], "\(path).end"), "\(path).end")
        )
    }

    private static func ring(_ value: JSONValue, _ path: String) throws -> PolygonRing {
        guard let closed = value["isClosed"]?.booleanValue else {
            throw ExportError.malformedOverlay("\"\(path).isClosed\" is not a boolean")
        }
        return PolygonRing(
            points: try each(value["points"], "\(path).points", point),
            isClosed: closed
        )
    }

    private static func polygon(_ value: JSONValue, _ path: String) throws -> PolygonGeometry {
        PolygonGeometry(
            outer: try ring(try require(value["outer"], "\(path).outer"), "\(path).outer"),
            holes: try each(value["holes"], "\(path).holes", ring)
        )
    }

    private static func arc(_ value: JSONValue, _ path: String) throws -> ArcGeometry {
        ArcGeometry(
            center: try point(try require(value["center"], "\(path).center"), "\(path).center"),
            radius: try number(value["radius"], "\(path).radius"),
            startAngle: try number(value["startAngle"], "\(path).startAngle"),
            sweepAngle: try number(value["sweepAngle"], "\(path).sweepAngle")
        )
    }

    private static func circle(_ value: JSONValue, _ path: String) throws -> CircleGeometry {
        CircleGeometry(
            center: try point(try require(value["center"], "\(path).center"), "\(path).center"),
            radius: try number(value["radius"], "\(path).radius")
        )
    }

    private static func countPoint(_ value: JSONValue, _ path: String) throws -> CountPoint {
        CountPoint(
            id: CountPointID(try uuid(value["id"], "\(path).id")),
            position: try point(try require(value["position"], "\(path).position"), "\(path).position"),
            sequenceNumber: try optionalInteger(value["sequenceNumber"], "\(path).sequenceNumber"),
            groupID: try optionalUUID(value["groupID"], "\(path).groupID").map(CountGroupID.init),
            symbolID: try optionalUUID(value["symbolID"], "\(path).symbolID").map(SymbolID.init)
        )
    }

    // MARK: - Scalars

    private static func require(_ value: JSONValue?, _ path: String) throws -> JSONValue {
        guard let value else { throw ExportError.malformedOverlay("missing \"\(path)\"") }
        return value
    }

    /// A coordinate. Refused rather than defaulted: a vertex that reads as zero because its
    /// string was malformed is a measurement moved to the corner of the page.
    private static func number(_ value: JSONValue?, _ path: String) throws -> Double {
        guard let text = value?.stringValue, let number = Double(text), number.isFinite else {
            throw ExportError.malformedOverlay("\"\(path)\" is not a finite decimal string")
        }
        return number
    }

    private static func uuid(_ value: JSONValue?, _ path: String) throws -> UUID {
        guard let text = value?.stringValue, let id = UUID(uuidString: text) else {
            throw ExportError.malformedOverlay("\"\(path)\" is not a UUID")
        }
        return id
    }

    /// Absent or `null` is "none"; any other type is corruption and is refused, the same as a
    /// malformed coordinate. Reading `"groupID": 12` as "no group" would silently drop a count
    /// point out of its group on import.
    private static func optionalUUID(_ value: JSONValue?, _ path: String) throws -> UUID? {
        guard let value, value != .null else { return nil }
        guard case .string(let text) = value, let id = UUID(uuidString: text) else {
            throw ExportError.malformedOverlay("\"\(path)\" is not a UUID")
        }
        return id
    }

    /// Absent or `null` is "unnumbered"; `"7"` or `7.5` is refused rather than dropped, so a
    /// count group cannot lose its numbering on import.
    private static func optionalInteger(_ value: JSONValue?, _ path: String) throws -> Int? {
        guard let value, value != .null else { return nil }
        guard let number = value.integerValue else {
            throw ExportError.malformedOverlay("\"\(path)\" is not an integer")
        }
        return number
    }
}
