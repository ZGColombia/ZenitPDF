import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Loop iteration 5, area ui-workflows-ledger: V-059 (a copy keeps the round-2 style) and
/// V-060 (a tool set carries the style; Update Matching no longer wipes it).
@Suite("Loop iteration 5 — ui-workflows-ledger Tool Library fixes", .workflowsTierSerialised)
@MainActor
struct Iter5ToolLibraryStyleTests {

    // MARK: - V-059

    /// Old output: `duplicate.style == nil`, so the copy placed
    /// `ToolStyleSelection(stroke: colour, fill: nil)` — 1.5 pt solid, opaque, no blend.
    @Test("V-059: Duplicate keeps line width, dash, fill, opacity and blend")
    func duplicateKeepsStyle() throws {
        let source = ToolLibraryFixtures.everyField()
        let model = ToolLibraryEditingModel(presets: [source])
        let copy = try #require(model.duplicate(id: source.id))
        let style = try #require(copy.style)
        #expect(style == ToolLibraryFixtures.styled)
        #expect(style.lineWidth == 3.5)
        #expect(style.lineStyle == .dashDot)
        #expect(style.fill?.alpha == 0.25)
        #expect(style.opacity == 0.6)
        #expect(style.multiplyBlend)
        #expect(copy.placementStyle == source.placementStyle)
        // The re-mint the import uses goes through the same copy.
        #expect(ToolLibraryEditingModel.reidentified(source).style == source.style)
    }

    /// The tripwire that makes IM-035's promise hold for the *next* field: every stored
    /// property of the fixture must differ from a bare preset's, so a field somebody adds
    /// later fails here until the fixture sets it — and then the copy check below fails if
    /// `copy(id:…)` does not carry it.
    @Test("V-059: a copy carries every stored property, and the fixture covers every one")
    func copyCarriesEveryStoredProperty() throws {
        // The imported-libraries panel is the one where `isReadOnly` is true too.
        let source = ToolLibraryFixtures.everyField(panel: .importedLibraries)
        let bare = ToolPresetSummary(
            id: UUID(), name: "", category: "", panel: .projectTools, markupKind: .measurement,
            colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0, alpha: 1), defaultSubject: ""
        )
        func properties(_ preset: ToolPresetSummary) -> [String: String] {
            var result: [String: String] = [:]
            for child in Mirror(reflecting: preset).children {
                guard let label = child.label else { continue }
                result[label] = String(describing: child.value)
            }
            return result
        }
        let sourceProperties = properties(source)
        let bareProperties = properties(bare)
        #expect(sourceProperties.keys.contains("style"))
        for (label, value) in sourceProperties where label != "id" {
            #expect(value != bareProperties[label], "ToolLibraryFixtures.everyField() leaves `\(label)` at its default")
        }

        let copy = source.copy(id: UUID())
        let copyProperties = properties(copy)
        for (label, value) in sourceProperties where label != "id" && label != "stamp" {
            #expect(copyProperties[label] == value, "copy(id:) dropped `\(label)`")
        }
        #expect(copy.stamp == source.stamp.map { $0.reidentified(as: copy.id) })
    }

    // MARK: - V-067

    /// The same texts and unit as the ledger's `Iter5LedgerWorkflowsFixTests.assemblyParametersFollowTheSharedRule`:
    /// both models now read through `LedgerAssemblySummary.Input`, so they cannot disagree again.
    @Test("V-067: the preset editor's Assembly row reads through the shared input rules")
    func assemblyRowFollowsTheSharedRule() throws {
        let catalog = Iter1RQuantitiesCoreWorkflowsTests.catalog
        var editor = ToolPresetAssemblyEditor(customDefaults: [:], catalog: catalog, lengthUnit: .millimetre)
        editor.selectedID = catalog.recipes.first?.id
        let inputs = editor.inputs(in: catalog)
        let spacing = try #require(inputs.first { $0.name == "Spacing" })
        #expect(editor.unitLabel(for: spacing) == "mm")
        #expect(editor.unitLabel(for: spacing) == spacing.unitLabel(lengthUnit: .millimetre))
        #expect(editor.missingParameters(in: catalog) == ["Spacing"])
        #expect(editor.missingParameters(in: catalog) == LedgerAssemblySummary.Input.missingParameters(inputs, texts: [:]))
        editor.parameterTexts = ["Spacing": "6e2", "Height": "two"]
        #expect(editor.unreadableInputs(in: catalog) == ["Height"])
        editor.parameterTexts["Height"] = "2400"
        var defaults: [String: String] = [:]
        try editor.apply(to: &defaults, catalog: catalog)
        // 6e2 mm = 0.6 m and 2 400 mm = 2.4 m, the values Apply Assembly passes on.
        let stored = try #require(defaults[ToolPresetAssemblyCatalog.defaultKey])
        #expect(stored.hasSuffix("|Height=2.4;Spacing=0.6"), "\(stored)")
    }

    // MARK: - V-060

    @Test("V-060: a tool set carries the style, and the import restores it exactly")
    func styleRoundTrip() throws {
        let source = ToolLibraryFixtures.everyField()
        let model = ToolLibraryEditingModel(presets: [source])
        let data = try model.exportDocument(panel: .myTools, name: "Office").jsonData()
        let text = String(decoding: data, as: UTF8.self)
        // Old output: no "style" key at all.
        #expect(text.contains("\"style\""))
        #expect(text.contains("\"fillOpacity\" : 0.25"))
        guard case let .success(review) = ToolSetImportValidator().review(data: data, fileName: "Office.zpdftools") else {
            Issue.record("expected a review"); return
        }
        let arrived = try #require(review.presets.first)
        // `#RRGGBB` rounds each channel to 1/255; the fixture's channels are chosen so that
        // the round trip is exact except where the hex form must round.
        let style = try #require(arrived.style)
        #expect(style.lineWidth == 3.5)
        #expect(style.fontName == "Menlo")
        #expect(style.fontSize == 14)
        #expect(style.lineStyle == .dashDot)
        #expect(style.opacity == 0.6)
        #expect(style.startCap == .circle)
        #expect(style.endCap == .closedArrow)
        #expect(style.textAlignment == .center)
        #expect(style.multiplyBlend && style.bold && style.italic && style.boxBorder)
        #expect(style.cloudArcSize == 9)
        #expect(style.fill?.hexString == ToolLibraryFixtures.styled.fill?.hexString)
        #expect(style.fill?.alpha == 0.25)
        #expect(style.textColor?.hexString == ToolLibraryFixtures.styled.textColor?.hexString)
        #expect(style.stroke == arrived.colorRGBA, "the stroke is the preset colour")
        #expect(!review.findings.contains { $0.code == .unknownField || $0.code == .valueOutOfRange })
    }

    @Test("V-060: a hostile style block costs only the fields that fail, each reported")
    func hostileStyleIsBounded() throws {
        let raw = """
        {"schemaVersion": 1, "name": "S", "presets": [
          {"name": "A", "markupType": "cloud", "color": "#FF0000",
           "style": {"lineWidth": 1e9, "opacity": 0.5, "lineStyle": "zigzag", "fill": "javascript:x",
                     "fontName": "<script>", "fontSize": 12, "bold": "yes", "cloudArcSize": 500,
                     "textColor": "#00FF00", "shell": "rm"}}]}
        """
        guard case let .success(review) = ToolSetImportValidator().review(data: Data(raw.utf8), fileName: "S.zpdftools") else {
            Issue.record("expected a review"); return
        }
        let style = try #require(review.presets.first?.style)
        let defaults = ToolStyleSelection(stroke: style.stroke)
        #expect(style.lineWidth == defaults.lineWidth, "1e9 pt is dropped, not clamped")
        #expect(style.opacity == 0.5)
        #expect(style.lineStyle == nil)
        #expect(style.fill == nil)
        #expect(style.fontName == defaults.fontName)
        #expect(style.fontSize == 12)
        #expect(style.bold == false)
        #expect(style.cloudArcSize == nil)
        #expect(style.textColor == ColorRGBA(hex: 0x00FF00))
        // lineWidth, lineStyle, fill, fontName, bold, cloudArcSize — six fields refused.
        #expect(review.findings.filter { $0.code == .valueOutOfRange }.count == 6)
        #expect(review.findings.contains { $0.code == .unknownField && $0.message.contains("shell") })
    }

    /// Old output: the matched tool's style became nil — every markup tool reset to
    /// colour-only by re-importing the office set.
    @Test("V-060: Update Matching keeps a tool's style when the file carries none")
    func updateMatchingKeepsStyle() throws {
        let source = ToolLibraryFixtures.everyField()
        let model = ToolLibraryEditingModel(presets: [source])
        let file = """
        {"schemaVersion": 1, "name": "Office", "presets": [
          {"id": "\(source.id.uuidString)", "name": "Retaining wall", "category": "Revised",
           "markupType": "stamp", "measurementTool": "wallArea", "color": "#00AA00"}]}
        """
        model.beginImport(data: Data(file.utf8), fileName: "Office.zpdftools")
        #expect(model.importReview?.libraryMatches.count == 1)
        model.confirmImport(strategy: .updateMatching)
        let updated = try #require(model.presets.first { $0.id == source.id })
        #expect(updated.category == "Revised", "the file's fields still win")
        #expect(updated.style == source.style)

        // A file that does carry a style replaces it.
        var restyled = source
        restyled.style = ToolStyleSelection(stroke: source.colorRGBA, lineWidth: 6)
        let data = try ToolSetDocument(name: "Office", exporting: [restyled]).jsonData()
        model.beginImport(data: data, fileName: "Office.zpdftools")
        model.confirmImport(strategy: .updateMatching)
        #expect(model.presets.first { $0.id == source.id }?.style?.lineWidth == 6)
    }
}
