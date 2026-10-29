import Foundation
import ZPDFContracts

/// Deterministic identifiers for the built-in ledger furniture.
///
/// The built-in columns and the status choice options exist in every project and must carry the
/// *same* `ColumnID` in every project, on every machine and in every process, or a saved layout,
/// a formula and an export from one machine would not match another. `UUID()` cannot provide
/// that, and 47 hand-typed UUID literals would be 47 chances to type one wrong, so the ids are
/// derived from a fixed namespace string and a fixed name string by a fixed mixing function.
///
/// This is deliberately *not* RFC 4122 v5 — it does not depend on CryptoKit and makes no claim
/// of collision resistance against an adversary. It only has to be stable and injective over the
/// few dozen fixed names below, which a unit test checks by enumerating them.
public enum LedgerIdentifiers: Sendable {

    /// Namespace for the built-in ledger columns of spec 15.2.
    public static let standardColumnNamespace = "zenit.pdf/ledger/standard-column/v1"
    /// Namespace for the markup-status choice options.
    public static let statusChoiceNamespace = "zenit.pdf/ledger/status-choice/v1"

    /// A stable UUID for `namespace` + `name`.
    public static func deterministicUUID(namespace: String, name: String) -> UUID {
        var state = splitMix64(seed: fnv1a64(namespace))
        let nameHash = fnv1a64(name)
        var bytes = [UInt8](repeating: 0, count: 16)
        var stream = state ^ nameHash
        for index in 0..<16 {
            if index % 8 == 0 {
                state = splitMix64(seed: state &+ nameHash &+ UInt64(index))
                stream = state
            }
            bytes[index] = UInt8(truncatingIfNeeded: stream)
            stream >>= 8
        }
        // Version 8 (custom) and RFC 4122 variant, so the value is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// The stable id of a built-in column.
    public static func columnID(for column: StandardLedgerColumn) -> ColumnID {
        ColumnID(deterministicUUID(namespace: standardColumnNamespace, name: column.rawValue))
    }

    /// The stable id of the choice option that represents a markup status.
    public static func choiceOptionID(for status: MarkupStatus) -> ChoiceOptionID {
        ChoiceOptionID(deterministicUUID(namespace: statusChoiceNamespace, name: status.rawValue))
    }

    private static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    private static func splitMix64(seed: UInt64) -> UInt64 {
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The status column's choice options (spec 14.3, 15.2).
///
/// `MarkupStatus` is a frozen enum, so the ledger's Status column is a Choice column whose
/// options are exactly its cases, with ids from ``LedgerIdentifiers``. Modelling it this way
/// rather than as free text is what lets a Status filter compare option ids instead of localised
/// strings.
public enum LedgerStatusChoices: Sendable {

    public static let options: [ChoiceOption] = MarkupStatus.allCases.enumerated().map {
        index, status in
        ChoiceOption(
            id: LedgerIdentifiers.choiceOptionID(for: status),
            value: status.rawValue,
            color: nil,
            order: index,
            isRetired: false
        )
    }

    public static let statusByOptionID: [ChoiceOptionID: MarkupStatus] = Dictionary(
        uniqueKeysWithValues: MarkupStatus.allCases.map {
            (LedgerIdentifiers.choiceOptionID(for: $0), $0)
        }
    )

    public static func optionValue(_ id: ChoiceOptionID) -> String? {
        statusByOptionID[id]?.rawValue
    }
}
