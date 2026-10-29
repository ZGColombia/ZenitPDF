import Foundation
import Testing
import ZPDFContracts

/// ADR-0012: every row states its claim — measured, derived, or read.
@Suite("Quantity provenance contract")
struct QuantityProvenanceTests {

    private static func uuid(_ byte: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
    }

    private static func record(
        provenance: QuantityProvenance = .measured,
        derivation: QuantityDerivation? = nil
    ) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(uuid(3)),
            documentID: DocumentID(uuid(1)),
            pageID: PageID(uuid(2)),
            kind: .note,
            subject: "Betong C30/37",
            provenance: provenance,
            derivation: derivation,
            createdAt: Date(timeIntervalSinceReferenceDate: 1000),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 1000)
        )
    }

    private static func readDerivation() -> QuantityDerivation {
        QuantityDerivation(
            sourceMarkupID: nil,
            formulaText: "Betong C30/37  12,5  m3",
            inputs: ["Material": "Betong C30/37", "Volume": "12,5"],
            originIdentifier: "page 00000000-0000-0000-0000-000000000002 rect 40,60 520x180"
        )
    }

    // MARK: - Additive decode (no migration pass)

    /// A stored record from before ADR-0012, as literal JSON. It carries **no `provenance`
    /// key and no `derivation` key** — not a null one, an absent one — because that is what
    /// every existing project actually holds. The fixture is written by hand rather than by
    /// encoding-and-stripping, so it cannot inherit the new encoder's own vocabulary.
    private static let versionThreeFixture = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000003",
          "documentID": "00000000-0000-0000-0000-000000000001",
          "pageID": "00000000-0000-0000-0000-000000000002",
          "kind": "measurement",
          "subject": "Slab",
          "label": "S-01",
          "comment": "",
          "author": "",
          "status": "none",
          "style": {
            "color": {"red": 0, "green": 0, "blue": 0, "alpha": 1},
            "opacity": 1,
            "lineWidth": 1,
            "lineStyle": "solid",
            "startCap": "none",
            "endCap": "none",
            "fontName": "Helvetica",
            "fontSize": 11,
            "textAlignment": "leading"
          },
          "locked": false,
          "hidden": false,
          "printable": true,
          "cutoutMarkupIDs": [],
          "customValues": {},
          "createdAt": 1000,
          "modifiedAt": 1000
        }
        """.utf8)

    @Test("A version-3 record — no provenance key at all — decodes as measured, nil derivation")
    func versionThreeRecordDecodesAsMeasured() throws {
        let decoded = try JSONDecoder().decode(MarkupRecord.self, from: Self.versionThreeFixture)
        #expect(decoded.provenance == .measured)
        #expect(decoded.derivation == nil)
        #expect(decoded.quantityProvenanceViolation() == nil)
        #expect(decoded.subject == "Slab")
    }

    // MARK: - Round trips

    @Test("A read row round-trips with provenance and derivation intact")
    func readRowRoundTrips() throws {
        let original = Self.record(provenance: .read, derivation: Self.readDerivation())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MarkupRecord.self, from: data)
        #expect(decoded == original)
        #expect(decoded.provenance == .read)
        #expect(decoded.derivation == Self.readDerivation())
    }

    @Test("A derived row round-trips with its source markup intact")
    func derivedRowRoundTrips() throws {
        let derivation = QuantityDerivation(
            sourceMarkupID: MarkupID(Self.uuid(9)),
            formulaText: "wallLength / 0.6 + 1",
            inputs: ["wallLength": "12.0"],
            originIdentifier: "assembly 00000000-0000-0000-0000-00000000000A"
        )
        let original = Self.record(provenance: .derived, derivation: derivation)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MarkupRecord.self, from: data)
        #expect(decoded == original)
        #expect(decoded.derivation?.sourceMarkupID == MarkupID(Self.uuid(9)))
    }

    @Test("A measured row still encodes and decodes as itself")
    func measuredRowRoundTrips() throws {
        let original = Self.record()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MarkupRecord.self, from: data)
        #expect(decoded == original)
        #expect(decoded.provenance == .measured)
    }

    // MARK: - The pairing rule, both directions

    @Test(
        "A derived or read row without a derivation is a named violation",
        arguments: [QuantityProvenance.derived, .read]
    )
    func missingDerivationIsRefused(provenance: QuantityProvenance) throws {
        let record = Self.record(provenance: provenance, derivation: nil)
        #expect(record.quantityProvenanceViolation() == .missingDerivation(provenance))
    }

    @Test("A measured row carrying a derivation is a named violation")
    func derivationOnMeasuredIsRefused() throws {
        let record = Self.record(provenance: .measured, derivation: Self.readDerivation())
        #expect(record.quantityProvenanceViolation() == .derivationOnMeasuredRow)
    }

    @Test(
        "A valid pairing has no violation",
        arguments: [
            (QuantityProvenance.measured, false),
            (.derived, true),
            (.read, true)
        ]
    )
    func validPairings(provenance: QuantityProvenance, carriesDerivation: Bool) throws {
        let record = Self.record(
            provenance: provenance,
            derivation: carriesDerivation ? Self.readDerivation() : nil
        )
        #expect(record.quantityProvenanceViolation() == nil)
    }

    @Test("The decoder refuses a read row whose derivation key is absent")
    func decoderRefusesReadWithoutDerivation() throws {
        var object = try #require(
            try JSONSerialization.jsonObject(with: Self.versionThreeFixture) as? [String: Any]
        )
        object["provenance"] = "read"
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MarkupRecord.self, from: data)
        }
    }

    @Test("The decoder refuses a measured row that carries a derivation")
    func decoderRefusesMeasuredWithDerivation() throws {
        var object = try #require(
            try JSONSerialization.jsonObject(with: Self.versionThreeFixture) as? [String: Any]
        )
        // No "provenance" key at all — the absent key decodes as measured, and even that
        // default is held to the pairing rule.
        object["derivation"] = [
            "formulaText": "Betong C30/37  12,5  m3",
            "inputs": [:],
            "originIdentifier": "page 2 rect 40,60 520x180"
        ] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MarkupRecord.self, from: data)
        }
    }

    // MARK: - Derivation value semantics

    @Test("A derivation round-trips byte-stably")
    func derivationRoundTrips() throws {
        let derivation = Self.readDerivation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(derivation)
        let decoded = try JSONDecoder().decode(QuantityDerivation.self, from: data)
        #expect(decoded == derivation)
        #expect(try encoder.encode(decoded) == data)
    }

    // MARK: - The freeze knows the new vocabulary

    @Test("The frozen markup contract carries the provenance enum and both new fields")
    func freezeCarriesProvenance() throws {
        let documents = try ContractCatalog.allDocuments(frozenAt: "2026-08-29T00:00:00Z")
        let markup = try #require(documents.first { $0.contract == "MARKUP_CONTRACT" })

        let enumeration = try #require(markup.types.first { $0.name == "QuantityProvenance" })
        #expect(Set(enumeration.cases.compactMap(\.rawValue)) == Set(["measured", "derived", "read"]))

        let derivation = try #require(markup.types.first { $0.name == "QuantityDerivation" })
        #expect(derivation.fields.count == 4)

        let record = try #require(markup.types.first { $0.name == "MarkupRecord" })
        #expect(record.fields.contains { $0.name == "provenance" })
        #expect(record.fields.contains { $0.name == "derivation" })
        #expect(markup.contractVersion >= 4)  // 5 since ADR-0029, 6 since ADR-0032
    }
}
