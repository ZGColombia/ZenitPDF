import Foundation
import Testing
@testable import ZPDFContracts

/// ADR-0029 (markup round 2): the new style and record fields are optional, absent when unused,
/// and a style or record written before them decodes unchanged.
@Suite("ADR-0029 markup round 2 contract")
struct MarkupRound2ContractTests {

    private func sortedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// The style blob a version-4 build wrote for the default style, verbatim.
    static let versionFourStyleJSON = """
        {"color":{"alpha":1,"blue":0,"green":0,"red":0},"endCap":"none","fontName":"Helvetica",\
        "fontSize":11,"lineStyle":"solid","lineWidth":1,"opacity":1,"startCap":"none","textAlignment":"leading"}
        """

    @Test("A version-4 style blob decodes with every ADR-0029 field nil")
    func oldStyleDecodes() throws {
        let style = try JSONDecoder().decode(MarkupStyle.self, from: Data(Self.versionFourStyleJSON.utf8))
        #expect(style == MarkupStyle.default)
        #expect(style.textStyle == nil)
        #expect(style.cloudArcSize == nil)
        #expect(style.rotationDegrees == nil)
        #expect(style.blendMode == nil)
    }

    @Test("A style that uses no ADR-0029 field encodes byte-identically to version 4")
    func unusedFieldsAreNotWritten() throws {
        #expect(try sortedJSON(MarkupStyle.default) == Self.versionFourStyleJSON)
    }

    @Test("The new style fields round-trip")
    func newFieldsRoundTrip() throws {
        var style = MarkupStyle.default
        style.textStyle = MarkupTextStyle(
            bold: true, italic: true,
            textColor: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            boxBorder: true
        )
        style.cloudArcSize = 14
        style.rotationDegrees = 30
        style.blendMode = .multiply
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(MarkupStyle.self, from: data) == style)
    }

    @Test("A partial text style decodes with defaults for the missing keys")
    func partialTextStyle() throws {
        let text = try JSONDecoder().decode(MarkupTextStyle.self, from: Data(#"{"bold":true}"#.utf8))
        #expect(text == MarkupTextStyle(bold: true))
    }

    @Test("Rotation and arc size are read through their clamps")
    func effectiveValues() {
        var style = MarkupStyle.default
        #expect(style.effectiveRotationDegrees == 0)
        #expect(style.effectiveCloudArcSize == nil)
        style.rotationDegrees = -30
        #expect(style.effectiveRotationDegrees == 330)
        style.rotationDegrees = 750
        #expect(style.effectiveRotationDegrees == 30)
        style.rotationDegrees = .nan
        #expect(style.effectiveRotationDegrees == 0)
        style.cloudArcSize = 0.5
        #expect(style.effectiveCloudArcSize == 2)
        style.cloudArcSize = 500
        #expect(style.effectiveCloudArcSize == 72)
        style.cloudArcSize = 12
        #expect(style.effectiveCloudArcSize == 12)
    }

    @Test("A version-4 record — no groupID or link key — decodes with both nil")
    func oldRecordDecodes() throws {
        let record = ContractSamples.markup
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        #expect(object["groupID"] == nil, "an ungrouped record must not write the key")
        #expect(object["link"] == nil)
        object.removeValue(forKey: "groupID")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MarkupRecord.self, from: data)
        #expect(decoded.groupID == nil)
        #expect(decoded.link == nil)
        #expect(decoded == record)
    }

    @Test("Group and link round-trip on the record")
    func recordFieldsRoundTrip() throws {
        var record = ContractSamples.markup
        record.groupID = MarkupGroupID(UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!)
        record.link = MarkupLinkTarget(url: "https://example.org/a")
        let decoded = try JSONDecoder().decode(MarkupRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.groupID == record.groupID)
        #expect(decoded.link == record.link)
    }

    @Test("A link names exactly one destination, with an allowed scheme")
    func linkValidity() {
        #expect(MarkupLinkTarget(pageID: ContractSamples.pageID).isValid)
        #expect(MarkupLinkTarget(url: "https://example.org").isValid)
        #expect(MarkupLinkTarget(url: "mailto:site@example.org").isValid)
        #expect(!MarkupLinkTarget(url: "file:///etc/passwd").isValid)
        #expect(!MarkupLinkTarget(url: "javascript:alert(1)").isValid)
        #expect(!MarkupLinkTarget(url: "https:").isValid)
        #expect(!MarkupLinkTarget(url: "example.org").isValid)
        var both = MarkupLinkTarget(pageID: ContractSamples.pageID)
        both.url = "https://example.org"
        #expect(!both.isValid)
    }

    @Test("The frozen markup document carries the ADR-0029 fields and types")
    func frozenDocument() throws {
        let document = try ContractCatalog.markupContract(frozenAt: "2026-09-01T23:28:48Z")
        #expect(document.contractVersion >= 5)  // 6 since ADR-0032 (markup layers)
        let style = try #require(document.types.first { $0.name == "MarkupStyle" })
        for field in ["textStyle", "cloudArcSize", "rotationDegrees", "blendMode"] {
            #expect(style.fields.contains { $0.name == field }, "MarkupStyle.\(field)")
        }
        let record = try #require(document.types.first { $0.name == "MarkupRecord" })
        #expect(record.fields.contains { $0.name == "groupID" })
        #expect(record.fields.contains { $0.name == "link" })
        for name in ["MarkupTextStyle", "MarkupBlendMode", "MarkupLinkTarget"] {
            #expect(document.types.contains { $0.name == name }, "\(name)")
        }
    }
}
