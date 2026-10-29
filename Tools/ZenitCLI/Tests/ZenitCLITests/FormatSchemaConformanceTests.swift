import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFExtensions
import ZPDFSpreadsheet
import ZPDFTestingSupport
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZenitCLICore

/// NL-PLAT-14: the published JSON Schemas in `Docs/Formats` describe what the exporters really
/// write. Each exporter's output validates against its schema, a hand-written minimal file per
/// format imports through the shipping reader, and a drifted file is caught by the validator.
@Suite("Published format schemas — NL-PLAT-14", .serialized)
struct FormatSchemaConformanceTests {

    static let formats = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Docs/Formats", isDirectory: true)

    static func validator(_ name: String) throws -> JSONSchemaValidator {
        try JSONSchemaValidator(schema: Data(contentsOf: formats.appendingPathComponent(name)))
    }

    static func expectValid(_ data: Data, _ schema: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let violations = try validator(schema).validate(data)
        #expect(violations.isEmpty, "\(schema): \(violations.prefix(8).map(\.description).joined(separator: "; "))", sourceLocation: sourceLocation)
    }

    /// A real ledger: the end-to-end fixture's saved takeoff.
    static func projection() async throws -> (ExportProjection, ZenitCLIEndToEndTests.Saved) {
        let saved = try await ZenitCLIEndToEndTests.makeSaved()
        return (try await ZenitCLIEndToEndTests.applicationProjection(saved.session, name: saved.name), saved)
    }

    @Test("Every schema file is valid JSON and names draft 2020-12")
    func schemasParse() throws {
        for name in ["zpdfjson", "zpdfoverlay", "zpdftools", "zpdftemplate", "zpdfprofile", "zpdfpack"] {
            let data = try Data(contentsOf: Self.formats.appendingPathComponent("\(name).schema.json"))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")
            _ = try Self.validator("\(name).schema.json")
        }
        #expect(FileManager.default.fileExists(atPath: Self.formats.appendingPathComponent("zpdfproj.md").path))
    }

    @Test(".zpdfjson: the exporter's output validates; a minimal hand-written ledger imports; drift is caught")
    func ledgerJSON() async throws {
        let (projection, saved) = try await Self.projection()
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let data = ZenitJSONExporter().export(projection)
        try Self.expectValid(data, "zpdfjson.schema.json")

        let minimal = #"""
        {"format":"zenit.ledger.export","schemaVersion":1,"generatedAt":"2026-09-26T10:00:00Z",
         "producer":{"application":"Hand","package":"none","ledgerContractVersion":1,"formulaGrammarVersion":1},
         "document":{},"ledger":{"title":"L","grouping":[],"sort":[],"filter":"ALL","rowCount":1,"rowCountBeforeFilter":1},
         "numberLocale":{"identifier":"invariant","decimalSeparator":"."},
         "columns":[{"key":"subject","title":"Subject","kind":"text","unit":""},{"key":"planArea","title":"Plan Area","kind":"number","unit":"m²","decimalPlaces":2}],
         "groups":[],
         "rows":[{"markupID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","index":0,"groupPath":[],"cells":[{"type":"text","value":"Slab"},{"type":"number","raw":"2.5","display":"2.50","unit":"m²"}]}],
         "grandTotals":[{"function":"Sum","cells":[{"type":"blank"},{"type":"number","raw":"2.5","display":"2.50","unit":"m²"}]}]}
        """#
        try Self.expectValid(Data(minimal.utf8), "zpdfjson.schema.json")
        let (document, _) = try ZenitInterchangeImport.read(Data(minimal.utf8), fileName: "hand.zpdfjson")
        #expect(document.rows.count == 1)

        let drifted = minimal.replacingOccurrences(of: #""raw":"2.5""#, with: #""raw":2.5"#)
        #expect(try !Self.validator("zpdfjson.schema.json").validate(Data(drifted.utf8)).isEmpty, "a number raw value must be a decimal string")
    }

    @Test(".zpdfoverlay: the exporter's output (with geometry and placement) validates; a minimal overlay imports")
    func overlay() async throws {
        let (projection, saved) = try await Self.projection()
        defer { try? FileManager.default.removeItem(at: saved.directory) }
        let markups = await saved.session.takeoffState().markups
        var geometry: [String: MeasurementGeometry] = [:]
        var placements: [String: ZenitOverlayDocument.Placement] = [:]
        for markup in markups {
            geometry[markup.id.rawValue.uuidString] = markup.geometry
            placements[markup.id.rawValue.uuidString] = .init(pageIndex: 0, tool: markup.tool?.rawValue, parametersJSON: nil)
        }
        let source = ZenitOverlayDocument.Source(fileName: "plan.pdf", pageCount: 1,
                                                 digestSHA256: String(repeating: "0a", count: 32), digestByteCount: 1000)
        try Self.expectValid(ZenitOverlayExporter().export(projection, source: source, geometry: geometry, placements: placements),
                             "zpdfoverlay.schema.json")

        let minimal = #"""
        {"format":"zenit.measurement.overlay","schemaVersion":1,"generatedAt":"2026-09-26T10:00:00Z",
         "producer":{"application":"Hand","package":"none","ledgerContractVersion":1,"formulaGrammarVersion":1},
         "source":{"fileName":"plan.pdf","pageCount":1,"digest":{"algorithm":"SHA-256","sha256":"0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a","byteCount":1000}},
         "columns":[{"key":"subject","title":"Subject","kind":"text","unit":""}],
         "numberLocale":{"identifier":"invariant","decimalSeparator":"."},
         "measurements":[{"row":{"markupID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","index":0,"groupPath":[],"cells":[{"type":"text","value":"Wall"}]},
           "geometry":{"pageID":"7F9619FF-8B86-D011-B42D-00C04FC964FF","points":[{"x":"0","y":"0"},{"x":"100","y":"0"}],"segments":[],"polygons":[],"arcs":[],"circles":[],"countPoints":[]}}]}
        """#
        try Self.expectValid(Data(minimal.utf8), "zpdfoverlay.schema.json")
        let read = try ZenitOverlayImporter().document(from: Data(minimal.utf8))
        #expect(read.measurements.first?.geometry?.points.count == 2)
    }

    @Test(".zpdfprofile: a profile with units and grouping validates; a minimal hand-written profile reads")
    func profile() throws {
        var profile = LedgerExportProfile(name: "Cost codes", columns: [.init(key: "subject"), .init(key: "planArea", decimals: 2, unit: "m²")])
        profile.grouping = .init(key: "costCode", grandTotal: true)
        try Self.expectValid(try profile.encoded(), "zpdfprofile.schema.json")
        let minimal = #"{"formatVersion":1,"name":"Min","columns":[{"key":"subject"}],"delimiter":";","decimalSeparator":",","quoteAllFields":false,"includeHeader":true,"encoding":"utf8","lineEnding":"lf","fileNamePattern":"{project}"}"#
        try Self.expectValid(Data(minimal.utf8), "zpdfprofile.schema.json")
        #expect(try LedgerExportProfile.read(Data(minimal.utf8)).name == "Min")
    }

    @Test(".zpdfprofile: the schema's unit list is exactly the units the reader accepts, and a column in each validates and reads")
    func profileUnits() throws {
        let data = try Data(contentsOf: Self.formats.appendingPathComponent("zpdfprofile.schema.json"))
        let schema = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let columns = try #require(properties["columns"] as? [String: Any])
        let items = try #require(columns["items"] as? [String: Any])
        let unit = try #require((items["properties"] as? [String: Any])?["unit"] as? [String: Any])
        let published = try #require(unit["enum"] as? [String])
        // U-050: ProfileUnit's table was rebuilt from the contract's units, and the schema kept the
        // old hand-typed list, so a profile in acres read fine and failed the published schema.
        // Old: mi, km2, km², in2, in², acre, mi2, mi², cm3, cm³, in3 and in³ missing here.
        #expect(Set(published) == Set(ProfileUnit.allSpellings),
                "only in the schema: \(Set(published).subtracting(ProfileUnit.allSpellings).sorted()); only in the reader: \(Set(ProfileUnit.allSpellings).subtracting(published).sorted())")
        #expect(published.count == Set(published).count, "the schema lists a unit twice")

        // One column per spelling: the file validates against the schema and the reader takes it.
        let profile = LedgerExportProfile(
            name: "Every unit",
            columns: ProfileUnit.allSpellings.map { .init(key: "planArea", decimals: 3, unit: $0) }
        )
        let encoded = try profile.encoded()
        try Self.expectValid(encoded, "zpdfprofile.schema.json")
        let read = try LedgerExportProfile.read(encoded)
        #expect(read.columns.map(\.unit) == ProfileUnit.allSpellings)
        #expect(read.columns.allSatisfy { ProfileUnit(symbol: $0.unit ?? "") != nil })
    }

    @Test(".zpdftemplate: every starter template (and one carrying a profile) validates; a minimal template imports")
    func template() throws {
        for starter in StarterJobTemplates.all {
            try Self.expectValid(try JobTemplateFile.export(starter), "zpdftemplate.schema.json")
        }
        var withProfile = StarterJobTemplates.all[0]
        withProfile.exportProfiles = [JobTemplateAttachedFile(name: "Min", json: "{}")]
        try Self.expectValid(try JobTemplateFile.export(withProfile), "zpdftemplate.schema.json")
        // The envelope's digest is computed over the canonical form, so the minimal file is the
        // minimal template's body wrapped by the shipping writer.
        let body = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","formatVersion":1,"name":"Minimal"}"#
        let decoded = try JSONDecoder().decode(JobTemplate.self, from: Data(body.utf8))
        let file = try JobTemplateFile.export(decoded)
        try Self.expectValid(file, "zpdftemplate.schema.json")
        #expect(try JobTemplateFile.read(file).name == "Minimal")
    }

    @Test(".zpdftools: the exporter's output validates; a minimal hand-written tool set passes the import validator")
    func toolSet() throws {
        let set = ToolSetDocument(name: "Office", author: "Estimating", exportedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                  exporting: StarterJobTemplates.all.flatMap(\.presets))
        try Self.expectValid(try set.jsonData(), "zpdftools.schema.json")
        let minimal = ##"{"schemaVersion":1,"name":"Min","presets":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Slab","category":"Concrete","markupType":"measurement","measurementTool":"area","color":"#2166CC","defaultSubject":"Slab","displayLengthUnit":"m"}]}"##
        try Self.expectValid(Data(minimal.utf8), "zpdftools.schema.json")
        guard case let .success(review) = ToolSetImportValidator().review(data: Data(minimal.utf8), fileName: "min.zpdftools") else {
            Issue.record("the minimal tool set did not read")
            return
        }
        #expect(review.isSafeToImport)
        #expect(review.presets.map(\.name) == ["Slab"])
    }

    @Test(".zpdfpack: the pack writer's manifest validates; a minimal hand-written pack reads")
    func pack() throws {
        let tools = try ToolSetDocument(name: "Office", exporting: StarterJobTemplates.all[0].presets).jsonData()
        let data = try ZenitPack.write(manifest: .init(name: "Office", version: "3", author: "Estimating", items: [
            .init(path: "tools/Office.zpdftools", kind: .toolSet),
        ]), files: ["tools/Office.zpdftools": tools])
        let manifest = try ZipArchiveReader(data: data).contents(of: "pack.json")
        try Self.expectValid(manifest, "zpdfpack.schema.json")

        let hand = #"{"format":"zenit-pack","formatVersion":1,"name":"Min","version":"1","items":[{"path":"a.zpdftools","kind":"toolSet"}]}"#
        try Self.expectValid(Data(hand.utf8), "zpdfpack.schema.json")
        var writer = ZipStoredWriter()
        try writer.add("pack.json", data: Data(hand.utf8))
        try writer.add("a.zpdftools", data: tools)
        #expect(try ZenitPack.read(try writer.archive()).items.count == 1)
        let escaping = hand.replacingOccurrences(of: "a.zpdftools", with: "../a.zpdftools")
        #expect(try !Self.validator("zpdfpack.schema.json").validate(Data(escaping.utf8)).isEmpty)
    }
}
