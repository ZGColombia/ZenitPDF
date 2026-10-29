import Foundation

/// One field of a described contract type.
public struct ContractFieldDescription: Codable, Hashable, Sendable {
    /// Property name, taken from the Swift source by reflection.
    public let name: String
    /// Property type, taken from the Swift source by reflection and printed in Swift's sugared
    /// form (`[PDFPoint]`, `Decimal?`, `[ColumnID: LedgerCellValue]`).
    public let type: String
    /// The unit the value is stored in, or `"-"` for a value that carries no unit.
    public let unit: String?
    /// What must always be true of this field.
    public let invariant: String?

    public init(name: String, type: String, unit: String?, invariant: String?) {
        self.name = name
        self.type = type
        self.unit = unit
        self.invariant = invariant
    }
}

/// One case of a described contract enum.
public struct ContractCaseDescription: Codable, Hashable, Sendable {
    public let name: String
    /// The raw value, where the enum has one.
    public let rawValue: String?
    /// Optional note: a conversion factor, a priority, a dimension.
    public let note: String?

    public init(name: String, rawValue: String? = nil, note: String? = nil) {
        self.name = name
        self.rawValue = rawValue
        self.note = note
    }
}

/// One type in a frozen contract.
public struct ContractTypeDescription: Codable, Hashable, Sendable {
    public let name: String
    /// `struct`, `enum`, or `protocol`.
    public let kind: String
    public let summary: String
    public let fields: [ContractFieldDescription]
    public let cases: [ContractCaseDescription]
    public let invariants: [String]

    public init(
        name: String,
        kind: String,
        summary: String,
        fields: [ContractFieldDescription] = [],
        cases: [ContractCaseDescription] = [],
        invariants: [String] = []
    ) {
        self.name = name
        self.kind = kind
        self.summary = summary
        self.fields = fields
        self.cases = cases
        self.invariants = invariants
    }
}

/// A generated lookup table, for example the exact unit conversion factors.
public struct ContractTable: Codable, Hashable, Sendable {
    public let name: String
    public let columns: [String]
    public let rows: [[String]]

    public init(name: String, columns: [String], rows: [[String]]) {
        self.name = name
        self.columns = columns
        self.rows = rows
    }
}

/// One frozen contract document, as written to `Docs/Contracts/<name>.json`.
public struct ContractDocument: Codable, Hashable, Sendable {
    /// File-stem name, for example `MEASUREMENT_CONTRACT`.
    public let contract: String
    /// Bumped only through an accepted ADR.
    public let contractVersion: Int
    /// ISO 8601 timestamp of the freeze.
    public let frozenAt: String
    /// What produced the file. There is no hand-editing path.
    public let generator: String
    /// The specification sections this contract binds to.
    public let specSections: [String]
    public let summary: String
    public let types: [ContractTypeDescription]
    public let tables: [ContractTable]
    /// The explicit invariant list every later package is bound by.
    public let invariants: [String]

    public init(
        contract: String,
        contractVersion: Int,
        frozenAt: String,
        generator: String,
        specSections: [String],
        summary: String,
        types: [ContractTypeDescription],
        tables: [ContractTable] = [],
        invariants: [String]
    ) {
        self.contract = contract
        self.contractVersion = contractVersion
        self.frozenAt = frozenAt
        self.generator = generator
        self.specSections = specSections
        self.summary = summary
        self.types = types
        self.tables = tables
        self.invariants = invariants
    }
}

/// Raised while building the contract catalogue.
public enum ContractCatalogError: Error, Hashable, Sendable {
    /// A stored property has no unit/invariant annotation. The freeze refuses to describe a
    /// field it cannot say anything true about.
    case unannotatedField(type: String, field: String)
    /// An annotation names a property that no longer exists — the Swift source moved and the
    /// contract description did not.
    case staleAnnotation(type: String, field: String)
    /// A type described as a struct reflected no stored properties.
    case noReflectedFields(type: String)
    /// The output directory could not be written.
    case outputDirectoryUnwritable(String)
}

/// The unit and invariant note attached to one stored property.
public struct ContractFieldAnnotation: Hashable, Sendable {
    public let unit: String
    public let invariant: String

    public init(_ unit: String, _ invariant: String) {
        self.unit = unit
        self.invariant = invariant
    }
}

extension ContractTypeDescription {
    /// Builds a struct description by reflecting a real instance.
    ///
    /// The field names and types therefore come from the Swift source, not from a hand-kept
    /// list: adding a property to a contract struct and forgetting to annotate it fails the
    /// freeze rather than silently producing an incomplete contract.
    public static func reflecting(
        _ sample: Any,
        name: String,
        summary: String,
        annotations: [String: ContractFieldAnnotation],
        invariants: [String] = []
    ) throws -> ContractTypeDescription {
        let mirror = Mirror(reflecting: sample)
        var fields: [ContractFieldDescription] = []
        var seen: Set<String> = []

        for child in mirror.children {
            guard let label = child.label else { continue }
            seen.insert(label)
            guard let annotation = annotations[label] else {
                throw ContractCatalogError.unannotatedField(type: name, field: label)
            }
            fields.append(
                ContractFieldDescription(
                    name: label,
                    type: ContractTypeNaming.sugaredName(of: child.value),
                    unit: annotation.unit,
                    invariant: annotation.invariant
                )
            )
        }

        guard !fields.isEmpty else {
            throw ContractCatalogError.noReflectedFields(type: name)
        }
        for key in annotations.keys where !seen.contains(key) {
            throw ContractCatalogError.staleAnnotation(type: name, field: key)
        }

        return ContractTypeDescription(
            name: name,
            kind: "struct",
            summary: summary,
            fields: fields,
            cases: [],
            invariants: invariants
        )
    }

    /// Builds an enum description from `allCases`, so the case list cannot drift from the source.
    public static func enumeration<Value>(
        _ type: Value.Type,
        name: String,
        summary: String,
        invariants: [String] = [],
        note: (Value) -> String? = { _ in nil }
    ) -> ContractTypeDescription
    where Value: CaseIterable & RawRepresentable, Value.RawValue: CustomStringConvertible {
        let cases = Value.allCases.map { value in
            ContractCaseDescription(
                name: String(describing: value),
                rawValue: value.rawValue.description,
                note: note(value)
            )
        }
        return ContractTypeDescription(
            name: name,
            kind: "enum",
            summary: summary,
            fields: [],
            cases: cases,
            invariants: invariants
        )
    }
}

/// Prints the numbers a contract table freezes exactly as the code holds them.
///
/// The freeze exists to print live guard values, and a value printed through `Int(...)` is
/// not the live value: `4.5` froze as `4` and the drift check could not tell (BH-486). An
/// integral `Double` prints without a fractional part, anything else prints in full, and a
/// non-finite value prints as such rather than trapping.
public enum ContractNumberText: Sendable {
    public static func text(_ value: Double) -> String {
        guard value.isFinite else { return value.description }
        if value == value.rounded(.towardZero), abs(value) < 9_007_199_254_740_992 {
            return String(Int(value))
        }
        return value.description
    }

    public static func range(_ range: ClosedRange<Int>) -> String {
        "\(range.lowerBound)...\(range.upperBound)"
    }

    public static func range(_ lower: Double, _ upper: Double) -> String {
        "\(text(lower))...\(text(upper))"
    }
}

/// Turns a reflected value's dynamic type into Swift's sugared spelling.
public enum ContractTypeNaming: Sendable {
    /// `Swift.Optional<Foundation.Decimal>` becomes `Decimal?`,
    /// `Swift.Array<ZPDFContracts.PDFPoint>` becomes `[PDFPoint]`.
    public static func sugaredName(of value: Any) -> String {
        sugaredName(ofReflected: String(reflecting: Swift.type(of: value)))
    }

    /// The module names stripped from a reflected type name. Each is removed only where it
    /// starts an identifier, so `CoreFoundation.CGFloat` — the spelling `String(reflecting:)`
    /// gives `CGFloat` on Darwin — loses its whole qualifier and not just the `Foundation.`
    /// tail that a substring replace used to eat, leaving `CoreCGFloat` (BH-487).
    static let strippedModules = [
        "ZPDFContracts", "Swift", "Foundation", "CoreFoundation", "CoreGraphics", "__C"
    ]

    /// `sugaredName(of:)` on an already reflected type string, so the qualifier stripping can
    /// be tested without a live value of every type.
    static func sugaredName(ofReflected reflected: String) -> String {
        var name = reflected
        for module in strippedModules {
            name = replace(#"(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: module) + #"\."#,
                           with: "", in: name)
        }
        // `Decimal` reflects through its imported ObjC struct name.
        name = name.replacingOccurrences(of: "NSDecimal", with: "Decimal")
        var previous = ""
        while previous != name {
            previous = name
            name = replace(#"Optional<([^<>]*)>"#, with: "$1?", in: name)
            name = replace(#"Array<([^<>]*)>"#, with: "[$1]", in: name)
            name = replace(#"Dictionary<([^<>,]*), ([^<>]*)>"#, with: "[$1: $2]", in: name)
        }
        return name
    }

    private static func replace(_ pattern: String, with template: String, in input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
