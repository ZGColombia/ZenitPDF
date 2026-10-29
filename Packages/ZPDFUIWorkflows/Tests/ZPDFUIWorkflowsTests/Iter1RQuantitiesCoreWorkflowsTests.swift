import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Quality-loop iteration 1, re-fix of area "quantities-core" in the Tool Library (NL-QTY-07,
/// ADR-0035 §4): the preset editor's Assembly row, and a tool's assembly surviving a tool set's
/// export and import.
@Suite("Iteration 1 re-fix quantities-core (Tool Library assemblies)", .workflowsTierSerialised)
struct Iter1RQuantitiesCoreWorkflowsTests {

    static let wallID = UUID(uuidString: "5A504446-4153-4D42-0000-000000000001")!

    /// The shape of the text AppCore writes for a timber wall at 2.4 m / 0.6 m — 195 characters,
    /// well past the 120 every other column default is held to.
    static let assignment = #"{"assemblyID":"5A504446-4153-4D42-0000-000000000001","parameters":{"Height":{"dimension":{"angle":false,"lengthPower":1},"value":2.4},"Spacing":{"dimension":{"angle":false,"lengthPower":1},"value":0.6}}}"#

    static func preset(customDefaults: [String: String]) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(), name: "Timber wall", category: "Walls", panel: .myTools,
            markupKind: .measurement, measurementKind: .length,
            colorRGBA: ColorRGBA(hex: 0x50D6DE), defaultSubject: "Wall W1",
            customDefaults: customDefaults
        )
    }

    static func review(_ presets: [ToolPresetSummary]) throws -> ToolSetImportReview {
        let data = try ToolSetDocument(name: "Walls", exportedAt: Date(timeIntervalSince1970: 1_700_000_000), exporting: presets).jsonData()
        return try ToolSetImportValidator().review(data: data, fileName: "Walls.zpdftools").get()
    }

    // MARK: - Export and import

    /// Old: `boundedDefaults` cut the assignment to 120 characters, the JSON no longer parsed,
    /// `LedgerAssemblyAssignment(cell:)` returned nil and the imported tool drew walls with no
    /// derived rows, behind only an "overlong text" notice.
    @Test("A tool's assembly survives export and import byte for byte")
    func assemblySurvivesRoundTrip() throws {
        #expect(Self.assignment.count > ToolSetImportValidator.Limits.standard.maximumTextLength)
        let long = String(repeating: "x", count: 150)
        let review = try Self.review([Self.preset(customDefaults: [
            ToolPresetAssemblyCatalog.defaultKey: Self.assignment,
            "Grade": long
        ])])
        let imported = try #require(review.presets.first)
        #expect(imported.customDefaults[ToolPresetAssemblyCatalog.defaultKey] == Self.assignment)
        #expect(!review.findings.contains { $0.code == .invalidAssembly })
        // Every other default is still held to the text limit, and says so.
        #expect(imported.customDefaults["Grade"] == String(long.prefix(120)))
        #expect(review.findings.filter { $0.code == .overlongText }.count == 1)
    }

    @Test("An unreadable or oversized assembly is left out whole, with a finding, never shortened")
    func badAssemblyIsLeftOut() throws {
        let cases = [
            String(Self.assignment.prefix(120)),                            // what the old cut left
            #"{"assemblyID":"not-a-uuid","parameters":{}}"#,
            #"{"assemblyID":"5A504446-4153-4D42-0000-000000000001","parameters":{"Height":2.4}}"#,
            #"["5A504446-4153-4D42-0000-000000000001"]"#,
            #"{"assemblyID":"5A504446-4153-4D42-0000-000000000001","note":""# + String(repeating: "y", count: 17_000) + #""}"#
        ]
        for text in cases {
            let review = try Self.review([Self.preset(customDefaults: [ToolPresetAssemblyCatalog.defaultKey: text, "Grade": "C30"])])
            let imported = try #require(review.presets.first)
            #expect(imported.customDefaults[ToolPresetAssemblyCatalog.defaultKey] == nil, "left out: \(text.prefix(60))")
            #expect(imported.customDefaults["Grade"] == "C30")
            #expect(review.findings.filter { $0.code == .invalidAssembly }.count == 1)
            #expect(!review.findings.contains { $0.code == .overlongText })
        }
        // A carried office recipe is an object too, and a script-like value is still reported.
        let office = #"{"assemblyID":"5A504446-4153-4D42-0000-0000000000AA","definition":{"name":"<script>"},"parameters":{}}"#
        let review = try Self.review([Self.preset(customDefaults: [ToolPresetAssemblyCatalog.defaultKey: office])])
        #expect(review.presets.first?.customDefaults[ToolPresetAssemblyCatalog.defaultKey] == office)
        #expect(review.findings.contains { $0.code == .markupLikeText })
    }

    // MARK: - The Assembly row

    /// A stand-in for AppCore's conversions: "id|Name=value;…" in SI base units.
    static let catalog = ToolPresetAssemblyCatalog(
        recipes: [
            LedgerAssemblySummary(
                id: wallID, name: "Timber stud wall", note: "Studs and boards from one wall.",
                inputs: [
                    .init(name: "Length", dimension: .length, isFreeParameter: false, note: nil),
                    .init(name: "Height", dimension: .length, isFreeParameter: false, note: nil),
                    .init(name: "Spacing", dimension: .length, isFreeParameter: true, note: nil)
                ],
                lines: []
            )
        ],
        encode: { id, parameters in
            guard id == wallID else { return nil }
            return id.uuidString + "|" + parameters.keys.sorted().map { "\($0)=\(parameters[$0]!.value)" }.joined(separator: ";")
        },
        decode: { text in
            let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = UUID(uuidString: parts[0]) else { return nil }
            var parameters: [String: DecimalQuantity] = [:]
            for pair in parts[1].split(separator: ";") {
                let field = pair.split(separator: "=").map(String.init)
                guard field.count == 2, let value = Decimal(string: field[1]) else { return nil }
                parameters[field[0]] = DecimalQuantity(value: value, dimension: .length)
            }
            return (id, parameters)
        }
    )

    /// Old: the editor offered only a raw key and a text field, so giving a tool an assembly meant
    /// typing the assignment JSON by hand. Now: pick the recipe, type its inputs in the preset's
    /// length unit, and the row writes the `zenit.assembly` default; it reads back on reopening.
    @Test("NL-QTY-07: the Assembly row picks a recipe, takes its inputs and writes zenit.assembly")
    func assemblyRowWritesTheDefault() throws {
        var editor = ToolPresetAssemblyEditor(customDefaults: [:], catalog: Self.catalog, lengthUnit: .millimetre)
        #expect(editor.selectedID == nil)
        #expect(editor.refusal(in: Self.catalog) == nil)

        editor.selectedID = Self.wallID
        #expect(editor.inputs(in: Self.catalog).map(\.name) == ["Length", "Height", "Spacing"])
        #expect(editor.unitLabel(for: editor.inputs(in: Self.catalog)[2]) == "mm")
        // Spacing is the estimator's; Save waits for it.
        #expect(editor.refusal(in: Self.catalog) == .missingParameters(["Spacing"]))
        var defaults = ["Grade": "C24"]
        #expect(throws: ToolPresetAssemblyEditor.Refusal.missingParameters(["Spacing"])) {
            try editor.apply(to: &defaults, catalog: Self.catalog)
        }
        editor.parameterTexts["Spacing"] = "six hundred"
        #expect(editor.refusal(in: Self.catalog) == .unreadableInputs(["Spacing"]))

        // 600 mm and 2 400 mm are stored as exactly 0.6 m and 2.4 m.
        editor.parameterTexts["Spacing"] = "600"
        editor.parameterTexts["Height"] = "2 400"
        try editor.apply(to: &defaults, catalog: Self.catalog)
        #expect(defaults["Grade"] == "C24")
        let storedText = try #require(defaults[ToolPresetAssemblyCatalog.defaultKey])
        let stored = try #require(Self.catalog.decode(storedText))
        #expect(stored.recipeID == Self.wallID)
        #expect(stored.parameters.mapValues(\.value) == ["Height": Decimal(string: "2.4")!, "Spacing": Decimal(string: "0.6")!])

        // Reopened, the row reads the stored values back in the preset's unit.
        var reopened = ToolPresetAssemblyEditor(customDefaults: defaults, catalog: Self.catalog, lengthUnit: .millimetre)
        #expect(reopened.selectedID == Self.wallID)
        #expect(reopened.parameterTexts == ["Height": "2400", "Spacing": "600"])
        // Untouched, Save leaves the text exactly as it was.
        var untouched = defaults
        try reopened.apply(to: &untouched, catalog: Self.catalog)
        #expect(untouched == defaults)
        // None removes the default and nothing else.
        reopened.selectedID = nil
        try reopened.apply(to: &untouched, catalog: Self.catalog)
        #expect(untouched == ["Grade": "C24"])
    }

    @Test("An assembly this copy cannot read is kept untouched unless another is chosen")
    func unreadableAssemblyIsKept() throws {
        let foreign = ["zenit.assembly": "an office recipe from another library"]
        var editor = ToolPresetAssemblyEditor(customDefaults: foreign, catalog: Self.catalog, lengthUnit: .metre)
        #expect(editor.selectedID == nil)
        #expect(editor.unreadableStoredText == foreign["zenit.assembly"])
        var defaults = foreign
        try editor.apply(to: &defaults, catalog: Self.catalog)
        #expect(defaults == foreign)
        editor.selectedID = Self.wallID
        editor.parameterTexts["Spacing"] = "0.45"
        try editor.apply(to: &defaults, catalog: Self.catalog)
        let storedText = try #require(defaults["zenit.assembly"])
        let stored = try #require(Self.catalog.decode(storedText))
        #expect(stored.recipeID == Self.wallID)
        #expect(stored.parameters.mapValues(\.value) == ["Spacing": Decimal(string: "0.45")!])
    }
}
