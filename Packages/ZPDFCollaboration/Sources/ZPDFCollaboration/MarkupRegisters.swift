import Foundation
import ZPDFContracts

/// The independently mergeable parts of a markup (NL-COLLAB-12).
///
/// A markup is split into registers so that two people editing *different* parts of one markup —
/// one its note, the other its status — both keep their edit. Each register is last-writer-wins
/// by ``HLCTimestamp``. The split follows what a person edits as one thing: the shape and
/// everything its quantity depends on travel together, so a merge can never pair one person's
/// vertices with another person's depth.
///
/// The measured values are **not** a register. Every participant recomputes them from the shape
/// and its own scale, so collaborators exchange geometry, never numbers — the rule that keeps the
/// aggregation layer exact.
public enum RegisterKey: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    /// Document, page, kind, tool, author and creation time: fixed when the markup is added.
    case identity
    /// Geometry, parameters, scale and region, cutout and count links.
    case shape
    case style
    case subject
    case label
    case comment
    case caption
    case status
    case locked
    case hidden
    case printable
    case layer
    case zone
    case customValues
    case stamp
    case symbol
    /// Provenance and derivation (ADR-0012), which move together.
    case claim

    public static func < (lhs: RegisterKey, rhs: RegisterKey) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A markup as registers: each value is the register's canonical JSON (sorted keys), so equal
/// values are equal bytes and a change is a byte comparison.
public struct MarkupRegisters: Codable, Hashable, Sendable {
    public var id: MarkupID
    public var values: [RegisterKey: Data]

    public init(id: MarkupID, values: [RegisterKey: Data]) {
        self.id = id
        self.values = values
    }

    // MARK: - Groups

    struct Identity: Codable, Hashable {
        var documentID: DocumentID
        var pageID: PageID
        var kind: MarkupKind
        var tool: MeasurementTool?
        var author: String
        var createdAt: Date
    }

    struct Shape: Codable, Hashable {
        var geometry: MeasurementGeometry?
        var parameters: MeasurementParameters?
        var scaleRegionID: ScaleRegionID?
        var scaleID: ScaleID?
        var scaleVersion: Int?
        var parentMarkupID: MarkupID?
        var cutoutMarkupIDs: [MarkupID]
        var countGroupID: CountGroupID?
    }

    struct Claim: Codable, Hashable {
        var provenance: QuantityProvenance
        var derivation: QuantityDerivation?
    }

    struct Box<Value: Codable & Hashable>: Codable, Hashable {
        var value: Value
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }

    // MARK: - Record ↔ registers

    public init(record: MarkupRecord) {
        id = record.id
        values = [
            .identity: Self.encode(Identity(
                documentID: record.documentID, pageID: record.pageID, kind: record.kind,
                tool: record.tool, author: record.author, createdAt: record.createdAt
            )),
            .shape: Self.encode(Shape(
                geometry: record.geometry, parameters: record.parameters,
                scaleRegionID: record.scaleRegionID, scaleID: record.scaleID, scaleVersion: record.scaleVersion,
                parentMarkupID: record.parentMarkupID, cutoutMarkupIDs: record.cutoutMarkupIDs,
                countGroupID: record.countGroupID
            )),
            .style: Self.encode(record.style),
            .subject: Self.encode(Box(value: record.subject)),
            .label: Self.encode(Box(value: record.label)),
            .comment: Self.encode(Box(value: record.comment)),
            .caption: Self.encode(Box(value: record.caption)),
            .status: Self.encode(Box(value: record.status)),
            .locked: Self.encode(Box(value: record.locked)),
            .hidden: Self.encode(Box(value: record.hidden)),
            .printable: Self.encode(Box(value: record.printable)),
            .layer: Self.encode(Box(value: record.layerID)),
            .zone: Self.encode(Box(value: record.zoneID)),
            .customValues: Self.encode(Box(value: record.customValues)),
            .stamp: Self.encode(Box(value: record.stamp)),
            .symbol: Self.encode(Box(value: record.symbol)),
            .claim: Self.encode(Claim(provenance: record.provenance, derivation: record.derivation))
        ]
    }

    /// The record these registers describe, with no measurement (the caller recomputes it), or
    /// `nil` when the identity register is missing or unreadable.
    public func record(modifiedAt: Date) -> MarkupRecord? {
        let decoder = JSONDecoder()
        func value<T: Decodable>(_ key: RegisterKey, _ type: T.Type) -> T? {
            values[key].flatMap { try? decoder.decode(T.self, from: $0) }
        }
        guard let identity = value(.identity, Identity.self) else { return nil }
        let shape = value(.shape, Shape.self)
        let claim = value(.claim, Claim.self)
        var record = MarkupRecord(
            id: id,
            documentID: identity.documentID,
            pageID: identity.pageID,
            kind: identity.kind,
            tool: identity.tool,
            subject: value(.subject, Box<String>.self)?.value ?? "",
            label: value(.label, Box<String>.self)?.value ?? "",
            comment: value(.comment, Box<String>.self)?.value ?? "",
            author: identity.author,
            status: value(.status, Box<MarkupStatus>.self)?.value ?? .none,
            style: value(.style, MarkupStyle.self) ?? .default,
            caption: value(.caption, Box<String?>.self)?.value,
            layerID: value(.layer, Box<LayerID?>.self)?.value,
            zoneID: value(.zone, Box<ZoneID?>.self)?.value,
            scaleRegionID: shape?.scaleRegionID,
            scaleID: shape?.scaleID,
            scaleVersion: shape?.scaleVersion,
            locked: value(.locked, Box<Bool>.self)?.value ?? false,
            hidden: value(.hidden, Box<Bool>.self)?.value ?? false,
            printable: value(.printable, Box<Bool>.self)?.value ?? true,
            geometry: shape?.geometry,
            parameters: shape?.parameters,
            measurement: nil,
            parentMarkupID: shape?.parentMarkupID,
            cutoutMarkupIDs: shape?.cutoutMarkupIDs ?? [],
            countGroupID: shape?.countGroupID,
            customValues: value(.customValues, Box<[ColumnID: LedgerCellValue]>.self)?.value ?? [:],
            stamp: value(.stamp, Box<StampInstance?>.self)?.value,
            symbol: value(.symbol, Box<MarkupSymbol?>.self)?.value,
            provenance: claim?.provenance ?? .measured,
            derivation: claim?.derivation,
            createdAt: identity.createdAt,
            modifiedAt: modifiedAt
        )
        // A claim that breaks the provenance rule (ADR-0012) is not trusted from a log: it
        // falls back to what the shape alone can vouch for.
        if record.quantityProvenanceViolation() != nil {
            record.provenance = .measured
            record.derivation = nil
        }
        return record
    }

    /// The registers whose bytes differ from `other`'s, including those only one side has.
    public func changedKeys(comparedWith other: MarkupRegisters?) -> [RegisterKey] {
        guard let other else { return values.keys.sorted() }
        let keys = Set(values.keys).union(other.values.keys)
        return keys.filter { key in
            guard values[key] != other.values[key] else { return false }
            if key == .identity { return !Self.sameIdentityAcrossCopies(values[key], other.values[key]) }
            if key == .shape { return !Self.sameShapeAcrossScales(values[key], other.values[key]) }
            return true
        }.sorted()
    }

    /// The shape names the scale identity and version this machine last measured it under. Both
    /// are machine-local — each copy's page scale has its own identity, and a scale change travels
    /// as its own operation (round 2) — so a recalibration is not a change to every shape on the
    /// sheet, and a shape is compared without them.
    static func sameShapeAcrossScales(_ lhs: Data?, _ rhs: Data?) -> Bool {
        guard let lhs, let rhs,
              var a = try? JSONDecoder().decode(Shape.self, from: lhs),
              let b = try? JSONDecoder().decode(Shape.self, from: rhs)
        else { return false }
        a.scaleID = b.scaleID
        a.scaleVersion = b.scaleVersion
        return a == b
    }

    /// Each copy of a project opens its drawing under its own document id, so the same markup
    /// reads with two. Identity is compared without it — otherwise every import and sync saw every
    /// shared markup as changed, and a second import of the same file never came up empty.
    static func sameIdentityAcrossCopies(_ lhs: Data?, _ rhs: Data?) -> Bool {
        guard let lhs, let rhs,
              var a = try? JSONDecoder().decode(Identity.self, from: lhs),
              let b = try? JSONDecoder().decode(Identity.self, from: rhs)
        else { return false }
        a.documentID = b.documentID
        return a == b
    }
}
