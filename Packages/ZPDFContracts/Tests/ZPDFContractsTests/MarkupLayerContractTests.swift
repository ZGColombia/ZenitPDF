import Foundation
import Testing
@testable import ZPDFContracts

/// ADR-0032: markup layers in the frozen markup contract.
@Suite("Markup layers in the contract (ADR-0032)")
struct MarkupLayerContractTests {

    @Test("A record with no layer id belongs to the default layer; one with an id belongs to it")
    func effectiveLayer() {
        var record = ContractSamples.markup
        #expect(record.layerID == nil)
        #expect(record.effectiveLayerID == MarkupLayer.defaultID)
        let walls = LayerID(UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!)
        record.layerID = walls
        #expect(record.effectiveLayerID == walls)
    }

    @Test("A version-5 record — layerID absent — decodes unchanged onto the default layer")
    func versionFiveRecordDecodes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ContractSamples.markup)
        // The sample has no layer, so the key is absent exactly as in every file written
        // before ADR-0032.
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("\"layerID\""))
        let decoded = try JSONDecoder().decode(MarkupRecord.self, from: data)
        #expect(decoded == ContractSamples.markup)
        #expect(decoded.effectiveLayerID == MarkupLayer.defaultID)
    }

    @Test("A layer round-trips through JSON with every flag")
    func layerRoundTrips() throws {
        let layer = MarkupLayer(
            id: LayerID(UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!),
            name: "Electrical",
            order: 3,
            visible: false,
            locked: true,
            printable: false
        )
        let data = try JSONEncoder().encode(layer)
        #expect(try JSONDecoder().decode(MarkupLayer.self, from: data) == layer)
    }

    @Test("The default layer is first, visible, unlocked, printable and keeps its fixed id")
    func defaultLayer() {
        let layer = MarkupLayer.makeDefault()
        #expect(layer.id == MarkupLayer.defaultID)
        #expect(layer.name == "Default")
        #expect(layer.order == 0)
        #expect(layer.visible && !layer.locked && layer.printable)
        #expect(layer.isDefault)
        // The constant is the same in every process: files written anywhere agree on it.
        #expect(MarkupLayer.defaultID.rawValue.uuidString == "5A1E0000-0000-4000-8000-00000000DEF0")
    }

    @Test("The frozen markup document is version 6 and carries MarkupLayer and the layer invariant")
    func frozenDocument() throws {
        let document = try ContractCatalog.markupContract(frozenAt: "2026-09-01T23:28:48Z")
        #expect(document.contractVersion == 6)
        let layer = try #require(document.types.first { $0.name == "MarkupLayer" })
        for field in ["id", "name", "order", "visible", "locked", "printable"] {
            #expect(layer.fields.contains { $0.name == field }, "MarkupLayer.\(field)")
        }
        let record = try #require(document.types.first { $0.name == "MarkupRecord" })
        #expect(record.invariants.contains { $0.contains("exactly one markup layer") })
        #expect(record.invariants.contains { $0.contains("never change a quantity") })
        // ADR-0036: the layer list stacks the layers. Old text: "Draw order is the document's
        // markup order", which no longer described the canvas, print or any export.
        #expect(record.invariants.contains { $0.contains("then the document's markup order within that layer") })
        #expect(!record.invariants.contains { $0.hasPrefix("Draw order is the document's markup order") })
    }
}
