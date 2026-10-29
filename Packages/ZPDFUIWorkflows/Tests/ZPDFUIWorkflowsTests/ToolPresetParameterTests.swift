import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// The measurement parameters a preset carries, along the three paths that used to drop them:
/// capture from a selection, duplicate, and export to `.zpdftools`.
///
/// All three are the same failure wearing different clothes — precisely the mistake that makes
/// a tool library feel useless — and all three are invisible until somebody
/// measures a slab and gets no volume.
@Suite("Tool preset measurement parameters", .workflowsTierSerialised)
struct ToolPresetParameterTests {

    private static var slabDefaults: ToolPresetMeasurementDefaults {
        ToolPresetMeasurementDefaults(
            depth: .metres(Decimal(string: "0.2") ?? 0),
            wallHeightAtEnd: .metres(Decimal(string: "3.6") ?? 0),
            slopePercent: 50,
            slopeAzimuthDegrees: 90,
            volumeDepthReference: .perpendicularThickness,
            cutoutPolicy: .ignore,
            perimeterPolicy: .outerPlusCutoutEdges
        )
    }

    private static func slabPreset() -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: "Slab 200 mm",
            category: "Concrete",
            panel: .myTools,
            markupKind: .measurement,
            measurementKind: .volume,
            colorRGBA: ColorRGBA(red: 0.9, green: 0.7, blue: 0.2, alpha: 1),
            defaultSubject: "Slab",
            measurementDefaults: slabDefaults,
            labelPattern: "S-1",
            defaultStatus: .open
        )
    }

    // MARK: Capture

    @Test("Saving a selected markup as a tool captures the maths, not only the ink")
    func captureFromMarkupKeepsTheParameters() {
        let summary = MarkupSummary(
            id: UUID(),
            kind: .measurement,
            measurementKind: .volume,
            subject: "Screed",
            label: "L-4",
            pageLabel: "A-101",
            pageID: UUID(),
            pageIndex: 0,
            status: .open,
            author: "test",
            colorRGBA: ColorRGBA(red: 0.2, green: 0.4, blue: 0.6, alpha: 1),
            created: Date(),
            modified: Date(),
            boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 10, height: 10),
            measurementDefaults: Self.slabDefaults
        )

        let draft = ToolPresetDraft(from: summary)
        #expect(draft.measurementDefaults == Self.slabDefaults)
        #expect(draft.labelPattern == "L-4")
        #expect(draft.defaultStatus == .open)
        #expect(draft.makePreset().measurementDefaults == Self.slabDefaults)
    }

    @Test("Duplicating a tool copies every parameter and records that it is a duplicate")
    @MainActor
    func duplicateKeepsTheParameters() throws {
        let model = ToolLibraryEditingModel(presets: [Self.slabPreset()])
        let original = try #require(model.presets.first)
        let copy = try #require(model.duplicate(id: original.id))
        #expect(copy.id != original.id)
        #expect(copy.measurementDefaults == Self.slabDefaults)
        #expect(copy.labelPattern == "S-1")
        #expect(copy.defaultStatus == .open)
        #expect(copy.provenance.origin == .duplicated)
    }

    // MARK: Export and import

    @Test("A tool set exported and read back keeps every measurement parameter")
    func toolSetFileRoundTripsTheParameters() throws {
        let preset = Self.slabPreset()
        let document = ToolSetDocument(name: "Concrete", exporting: [preset])
        let data = try document.jsonData()

        let review = try ToolSetImportValidator().review(data: data, fileName: "Concrete.zpdftools").get()
        #expect(review.isSafeToImport)
        let imported = try #require(review.presets.first)
        #expect(imported.measurementDefaults == Self.slabDefaults, "got \(imported.measurementDefaults)")
        #expect(imported.labelPattern == "S-1")
        #expect(imported.defaultStatus == .open)
        #expect(imported.provenance.origin == .imported)
        #expect(imported.provenance.sourceFileName == "Concrete.zpdftools")
    }

    @Test("A preset with no parameters exports no measurement block at all")
    func plainPresetCarriesNoMeasurementBlock() throws {
        let preset = ToolPresetSummary(
            id: UUID(),
            name: "Red Cloud",
            category: "Review",
            panel: .myTools,
            markupKind: .cloud,
            colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
            defaultSubject: ""
        )
        let record = ToolSetPresetRecord(summary: preset)
        #expect(record.measurementDefaults == nil)
        let text = String(decoding: try ToolSetDocument(name: "R", exporting: [preset]).jsonData(), as: UTF8.self)
        #expect(!text.contains("measurementDefaults"))
    }

    @Test("A hostile depth is refused by that one field, and the rest of the tool still imports")
    func hostileParameterIsDroppedNotFatal() throws {
        // Infinity cannot be written by `JSONEncoder`, so a file carrying one was produced by
        // something other than Zenit — which is the case the review exists for. An absurd but
        // representable number is the same class of input and can be written down here.
        let json = """
        {
          "schemaVersion": 1,
          "name": "Hostile",
          "presets": [
            {
              "id": "\(UUID().uuidString)",
              "name": "Deep Slab",
              "category": "Concrete",
              "markupType": "measurement",
              "measurementTool": "volume",
              "color": "#112233",
              "defaultSubject": "Slab",
              "displayLengthUnit": "metre",
              "customDefaults": {},
              "measurementDefaults": { "depthMetres": 1e18, "cutoutPolicy": "ignore" }
            }
          ]
        }
        """
        let review = try ToolSetImportValidator()
            .review(data: Data(json.utf8), fileName: "Hostile.zpdftools").get()
        let imported = try #require(review.presets.first)
        #expect(imported.name == "Deep Slab", "the tool itself still arrives")
        #expect(imported.measurementDefaults.depth == nil, "the absurd depth was left out, not clamped")
        #expect(imported.measurementDefaults.cutoutPolicy == .ignore, "the sane field beside it survived")
        #expect(review.findings.contains { $0.code == .valueOutOfRange })
    }

    // MARK: Storage shape

    @Test("A preset stored before the parameters existed still decodes its depth and height")
    func legacyPresetJSONStillDecodes() throws {
        // The exact key names a build before this one wrote. `defaultDepth` and `defaultHeight`
        // are forwarders now, so a synthesized decoder would have dropped both.
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "schemaVersion": 1,
          "name": "Old Slab",
          "category": "Concrete",
          "panel": "myTools",
          "markupKind": "measurement",
          "measurementKind": "volume",
          "colorRGBA": { "red": 0.1, "green": 0.2, "blue": 0.3, "alpha": 1 },
          "defaultSubject": "Slab",
          "defaultDepth": { "value": 0.25, "dimension": { "lengthPower": 1, "angle": false } },
          "defaultHeight": { "value": 2.4, "dimension": { "lengthPower": 1, "angle": false } },
          "displayLengthUnit": "m",
          "customDefaults": {},
          "isFavorite": false,
          "isReadOnly": false,
          "sortIndex": 3
        }
        """
        let preset = try JSONDecoder().decode(ToolPresetSummary.self, from: Data(json.utf8))
        #expect(preset.defaultDepth?.value == Decimal(string: "0.25"))
        #expect(preset.measurementDefaults.depth?.value == Decimal(string: "0.25"))
        #expect(preset.defaultHeight?.value == Decimal(string: "2.4"))
        #expect(preset.measurementDefaults.wallHeight?.value == Decimal(string: "2.4"))
        #expect(preset.sortIndex == 3)
    }

    @Test("A round trip through JSON is lossless for the whole preset")
    func presetJSONRoundTrip() throws {
        let preset = Self.slabPreset()
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(ToolPresetSummary.self, from: data)
        #expect(decoded == preset)
    }
}
