import Foundation

/// Puts optional-content groups into a document catalog's `/OCProperties`, **appending** to
/// whatever is already there.
///
/// ADR-0013 §2 is explicit about this: a drawing that already carries layers — and a
/// contractor's federated model usually does — keeps every one of them. The groups are added to
/// `/OCGs` and to the default configuration's `/Order`, each to `/ON` or `/OFF` by its own default
/// state, in the order given (ADR-0042: one group per markup layer, top layer first); nothing
/// existing is replaced, reordered or switched off. If the catalog is shaped in a way this editor
/// cannot append to, the export fails with a sentence naming why rather than producing a file
/// whose layer panel has quietly lost the drawing's own layers.
enum OptionalContentCatalog {

    /// The dictionary of a new group. The name is stored verbatim, as the ADR requires.
    static func group(named name: String) -> PDFObject {
        .dictionary([
            "Type": .name("OCG"),
            "Name": textString(name)
        ])
    }

    /// `name` as a PDF *text string* (ISO 32000-1 §7.9.2.2).
    ///
    /// Printable ASCII is the same byte in PDFDocEncoding, so it stays a readable literal. Anything
    /// else — "Markeringar på ritning", a localised build's layer name — is written as UTF-16BE
    /// behind the `FE FF` byte-order mark. Raw UTF-8 in a literal is read as PDFDocEncoding and
    /// the layer panel shows "pÃ¥".
    static func textString(_ text: String) -> PDFObject {
        let utf8 = Array(text.utf8)
        if utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return .string(utf8)
        }
        var bytes: [UInt8] = [0xFE, 0xFF]
        for unit in text.utf16 {
            bytes.append(UInt8(unit >> 8))
            bytes.append(UInt8(unit & 0xFF))
        }
        return .hexString(bytes)
    }

    /// One group to add: its reference, and whether it is on when the file is opened.
    struct Entry {
        var reference: PDFObject
        var visible: Bool
    }

    /// Adds `groupReference` to the catalog's optional-content properties, writing whichever
    /// objects need to change into `update`.
    static func attach(
        group groupReference: PDFObject,
        visible: Bool,
        in scan: PDFDocumentScan,
        to update: inout PDFIncrementalUpdate
    ) throws {
        try attach([Entry(reference: groupReference, visible: visible)], in: scan, to: &update)
    }

    /// Adds every group in `entries` to the catalog's optional-content properties, in order, in
    /// one edit — the catalog is read from the source once, so a second call would supersede the
    /// first one's objects rather than add to them.
    static func attach(
        _ entries: [Entry],
        in scan: PDFDocumentScan,
        to update: inout PDFIncrementalUpdate
    ) throws {
        guard !entries.isEmpty else { return }
        guard let rootReference = scan.rootReference,
              let catalogNumber = rootReference.referenceValue?.number,
              var catalog = scan.dictionary(rootReference)
        else {
            throw ExportError.layeredCatalogUnreachable(
                "the drawing has no readable document catalog, so the optional-content group "
                    + "that makes the markups a switchable layer cannot be recorded and the "
                    + "export would be a flattened file pretending to be a layered one."
            )
        }

        switch catalog["OCProperties"] {
        case let .some(existing) where existing.referenceValue != nil:
            guard var properties = scan.dictionary(existing),
                  let number = existing.referenceValue?.number
            else {
                throw Self.failure("its /OCProperties entry does not resolve to a dictionary")
            }
            try edit(&properties, entries: entries, scan: scan, update: &update)
            update.objects[number] = .dictionary(properties)
            return
        case let .some(.dictionary(existing)):
            var properties = existing
            try edit(&properties, entries: entries, scan: scan, update: &update)
            catalog["OCProperties"] = .dictionary(properties)
        case .none:
            catalog["OCProperties"] = .dictionary([
                "OCGs": .array(entries.map(\.reference)),
                "D": .dictionary(defaultConfiguration(entries))
            ])
        case .some:
            throw Self.failure("its /OCProperties entry is not a dictionary")
        }
        update.objects[catalogNumber] = .dictionary(catalog)
    }

    private static func defaultConfiguration(_ entries: [Entry]) -> [String: PDFObject] {
        [
            "Order": .array(entries.map(\.reference)),
            "ON": .array(entries.filter(\.visible).map(\.reference)),
            "OFF": .array(entries.filter { !$0.visible }.map(\.reference))
        ]
    }

    private static func edit(
        _ properties: inout [String: PDFObject],
        entries: [Entry],
        scan: PDFDocumentScan,
        update: inout PDFIncrementalUpdate
    ) throws {
        properties["OCGs"] = try appending(
            entries.map(\.reference),
            to: properties["OCGs"],
            named: "/OCGs",
            scan: scan,
            update: &update
        )

        switch properties["D"] {
        case let .some(existing) where existing.referenceValue != nil:
            guard var configuration = scan.dictionary(existing),
                  let number = existing.referenceValue?.number
            else {
                throw Self.failure("its default optional-content configuration is unreadable")
            }
            try editConfiguration(&configuration, entries: entries, scan: scan, update: &update)
            update.objects[number] = .dictionary(configuration)
        case let .some(.dictionary(existing)):
            var configuration = existing
            try editConfiguration(&configuration, entries: entries, scan: scan, update: &update)
            properties["D"] = .dictionary(configuration)
        case .none:
            properties["D"] = .dictionary(defaultConfiguration(entries))
        case .some:
            throw Self.failure("its default optional-content configuration is not a dictionary")
        }
    }

    private static func editConfiguration(
        _ configuration: inout [String: PDFObject],
        entries: [Entry],
        scan: PDFDocumentScan,
        update: inout PDFIncrementalUpdate
    ) throws {
        configuration["Order"] = try appending(
            entries.map(\.reference), to: configuration["Order"], named: "/D /Order", scan: scan, update: &update
        )
        // Each group is named in /ON or /OFF by its own default state; a key with nothing to add
        // is left exactly as the drawing wrote it (or absent).
        for (key, visible) in [("ON", true), ("OFF", false)] {
            let named = entries.filter { $0.visible == visible }.map(\.reference)
            guard !named.isEmpty else { continue }
            configuration[key] = try appending(
                named, to: configuration[key], named: "/D /\(key)", scan: scan, update: &update
            )
        }
        // `/BaseState /OFF` means "everything is off unless it is named in /ON", so an explicit
        // entry in /ON is what makes a group visible under either base state. Nothing else in
        // the drawing's configuration is touched.
    }

    /// Appends to an array that may be written inline or as its own object.
    ///
    /// - Returns: the value the parent dictionary should hold. When the array was an indirect
    ///   reference, that object is superseded instead and the same reference comes back, so the
    ///   parent is left exactly as the drawing wrote it.
    private static func appending(
        _ values: [PDFObject],
        to existing: PDFObject?,
        named name: String,
        scan: PDFDocumentScan,
        update: inout PDFIncrementalUpdate
    ) throws -> PDFObject {
        switch existing {
        case .none, .some(.null):
            return .array(values)
        case let .some(.array(current)):
            return .array(current + values)
        case let .some(reference) where reference.referenceValue != nil:
            guard let current = scan.object(reference)?.arrayValue,
                  let number = reference.referenceValue?.number
            else {
                throw Self.failure("its \(name) entry does not resolve to an array")
            }
            update.objects[number] = .array(current + values)
            return reference
        case .some:
            throw Self.failure("its \(name) entry is not an array")
        }
    }

    private static func failure(_ detail: String) -> ExportError {
        .layeredCatalogUnreachable(
            "the drawing's optional-content catalog cannot be added to because \(detail); the "
                + "layered export refuses rather than replacing the layers the drawing already "
                + "has, and rather than falling back to a flattened file."
        )
    }
}
