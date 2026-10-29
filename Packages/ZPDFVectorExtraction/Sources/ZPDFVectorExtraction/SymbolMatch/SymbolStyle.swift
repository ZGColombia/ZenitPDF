import Foundation

/// A drawing attribute a symbol search can require of every candidate (NL-AUTO-13).
public enum SymbolStyleAttribute: String, Sendable, Hashable, CaseIterable, Codable {
    /// The exemplar's majority stroke colour, exactly (8-bit channels).
    case strokeColor
    /// The exemplar's median stroke width, within ±10 %.
    case strokeWidth
    /// Dashed or solid, as the exemplar's majority is.
    case dash
    /// The exemplar's majority layer.
    case layer
}

/// The exemplar's majority style: what "the same style" means for a symbol search.
///
/// A red "new" door and a grey "existing" door are the same shape and different quantities. The
/// matcher is shape-only by design; the person may add "and the same style", and this value is
/// what the candidates are held to. Majorities rather than unanimity, because an exemplar box
/// often catches one stray stroke of another style.
public struct SymbolStyle: Sendable, Hashable, Codable {
    public let strokeColor: VectorColor?
    public let strokeWidth: Double?
    public let isDashed: Bool
    public let layerID: String?

    private enum CodingKeys: String, CodingKey { case strokeColor, strokeWidth, isDashed, layerID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        strokeColor = try container.decodeIfPresent(UInt32.self, forKey: .strokeColor).map { VectorColor(rgba: $0) }
        strokeWidth = try container.decodeIfPresent(Double.self, forKey: .strokeWidth)
        isDashed = try container.decode(Bool.self, forKey: .isDashed)
        layerID = try container.decodeIfPresent(String.self, forKey: .layerID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(strokeColor?.rgba, forKey: .strokeColor)
        try container.encodeIfPresent(strokeWidth, forKey: .strokeWidth)
        try container.encode(isDashed, forKey: .isDashed)
        try container.encodeIfPresent(layerID, forKey: .layerID)
    }

    /// The relative stroke-width tolerance ``SymbolStyleAttribute/strokeWidth`` allows.
    public static let widthTolerance = 0.10

    public init(members: [VectorPrimitive]) {
        func majority<T: Hashable>(_ values: [T]) -> T? {
            var counts: [T: Int] = [:]
            var order: [T] = []
            for value in values {
                if counts[value] == nil { order.append(value) }
                counts[value, default: 0] += 1
            }
            // Ties go to the first seen in primitive order, so the answer is deterministic.
            var best: T?
            var bestCount = 0
            for value in order where (counts[value] ?? 0) > bestCount {
                best = value
                bestCount = counts[value] ?? 0
            }
            return best
        }
        let stroked = members.filter { $0.paint.contains(.stroked) }
        strokeColor = majority(stroked.compactMap(\.strokeColor))
        let widths = stroked.map(\.strokeWidth).filter { $0.isFinite && $0 > 0 }.sorted()
        strokeWidth = widths.isEmpty ? nil : widths[widths.count / 2]
        isDashed = (majority(stroked.map(\.strokeIsDashed)) ?? false)
        layerID = majority(members.compactMap(\.layerID))
    }

    /// Whether `primitive` carries this style on every attribute in `gate`. An attribute the
    /// exemplar does not state (no colour, no width, no layer) gates nothing.
    public func admits(_ primitive: VectorPrimitive, gate: Set<SymbolStyleAttribute>) -> Bool {
        if gate.contains(.strokeColor), let strokeColor, primitive.strokeColor != strokeColor { return false }
        if gate.contains(.strokeWidth), let strokeWidth {
            guard abs(primitive.strokeWidth - strokeWidth) <= strokeWidth * Self.widthTolerance else { return false }
        }
        if gate.contains(.dash), primitive.strokeIsDashed != isDashed { return false }
        if gate.contains(.layer), let layerID, primitive.layerID != layerID { return false }
        return true
    }
}
