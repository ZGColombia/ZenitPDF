import Foundation

/// A stable, opaque identifier for a persisted contract entity.
///
/// Identifiers are UUID-backed value types. The generating side is always explicit: nothing in
/// this package ever calls `UUID()` on its own, because determinism requires identifiers to be
/// injected by a caller that owns an id generator (see ``IdentifierGenerating``).
///
/// Conformers encode as a single JSON string (the uppercase UUID string), and can be used
/// directly as dictionary keys in `Codable` containers.
public protocol ContractIdentifier:
    RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible, CodingKeyRepresentable
where RawValue == UUID {
    init(_ rawValue: UUID)
}

/// The `CodingKey` used when a ``ContractIdentifier`` appears as a dictionary key.
public struct ContractIdentifierCodingKey: CodingKey, Sendable {
    public let stringValue: String
    public let intValue: Int? = nil

    public init(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}

extension ContractIdentifier {
    public init?(rawValue: UUID) { self.init(rawValue) }

    /// Parses an identifier from its canonical UUID string, returning `nil` when malformed.
    public init?(uuidString: String) {
        guard let parsed = UUID(uuidString: uuidString) else { return nil }
        self.init(parsed)
    }

    public var description: String { rawValue.uuidString }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }

    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(UUID.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var codingKey: any CodingKey {
        ContractIdentifierCodingKey(stringValue: rawValue.uuidString)
    }

    public init?<Key>(codingKey: Key) where Key: CodingKey {
        guard let parsed = UUID(uuidString: codingKey.stringValue) else { return nil }
        self.init(parsed)
    }
}

/// Injected source of fresh identifiers. Pure calculations never mint their own.
public protocol IdentifierGenerating: Sendable {
    func nextIdentifier() -> UUID
}

/// Injected source of timestamps. Pure calculations never read the wall clock.
public protocol TimestampProviding: Sendable {
    func now() -> Date
}

public struct DocumentID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct PageID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct MarkupID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct LayerID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct ZoneID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct ScaleID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct ScaleRegionID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct ColumnID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct RowID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct ChoiceOptionID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct CountGroupID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

/// A markup group: markups that select, move, restyle and delete as one (ADR-0029).
public struct MarkupGroupID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct CountPointID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct SymbolID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}
