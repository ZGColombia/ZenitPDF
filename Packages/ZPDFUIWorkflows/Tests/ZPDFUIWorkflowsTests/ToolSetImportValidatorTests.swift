import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Asserts that the tool set import validator describes a file honestly and refuses to be
/// talked into anything by its contents.
///
/// Every hostile case here is a way a file could try to reach outside itself: a script in a name,
/// a path in a default, an image name that is really a file path, a size that would exhaust
/// memory. In each one the assertion is the same shape — the file is *described*, the dangerous
/// part is neutralised or left out, and the person is told.
@Suite("Tool set import validator", .workflowsTierSerialised)
struct ToolSetImportValidatorTests {

    private let validator = ToolSetImportValidator()

    // MARK: - Helpers

    private func json(_ raw: String) -> Data {
        Data(raw.utf8)
    }

    private func review(_ raw: String, fileName: String = "Set.zpdftools") throws -> ToolSetImportReview {
        switch validator.review(data: json(raw), fileName: fileName) {
        case let .success(review): return review
        case let .failure(error): throw error
        }
    }

    private func preset(
        name: String = "Concrete Area",
        extra: String = ""
    ) -> String {
        """
        {
          "id": "\(UUID().uuidString)",
          "name": "\(name)",
          "category": "Concrete",
          "markupType": "measurement",
          "measurementTool": "area",
          "color": "#50D6DE",
          "defaultSubject": "Concrete",
          "displayLengthUnit": "m",
          "customDefaults": { "Material": "Concrete" }\(extra.isEmpty ? "" : ",\n  " + extra)
        }
        """
    }

    private func document(presets: [String], schemaVersion: Int = 1, extra: String = "") -> String {
        """
        {
          "schemaVersion": \(schemaVersion),
          "name": "Site Concrete",
          "author": "A. Surveyor",
          "presets": [\(presets.joined(separator: ","))]\(extra.isEmpty ? "" : ",\n  " + extra)
        }
        """
    }

    private func codes(_ review: ToolSetImportReview) -> Set<ToolSetImportFindingCode> {
        Set(review.findings.map(\.code))
    }

    // MARK: - The happy path

    /// CR-193: "reads back as exactly what went in" used to be asserted with counts — two
    /// presets, one of each kind, one symbol name — over a fixture that carried no measurement
    /// parameters at all. A depth that came back as zero, which is exactly what CR-186's
    /// `Decimal(string:) ?? 0` produced, would not have moved a single one of those numbers.
    /// The fixture now carries the parameters a takeoff preset exists for, and the assertion is
    /// value-by-value.
    @Test("A set Zenit exported reads back as exactly what went in")
    func exportRoundTrip() throws {
        let depth = DecimalQuantity(value: Decimal(string: "0.2")!, dimension: .length)
        let wallHeight = DecimalQuantity(value: Decimal(string: "2.7")!, dimension: .length)
        let summaries = [
            ToolPresetSummary(
                id: UUID(),
                name: "Concrete Area",
                category: "Concrete",
                panel: .myTools,
                markupKind: .measurement,
                measurementKind: .area,
                colorRGBA: ColorRGBA(hex: 0x50D6DE),
                defaultSubject: "Concrete",
                measurementDefaults: ToolPresetMeasurementDefaults(
                    depth: depth,
                    wallHeight: wallHeight
                ),
                labelPattern: "C#",
                displayLengthUnit: .foot,
                customDefaults: ["Material": "C30/37"]
            ),
            ToolPresetSummary(
                id: UUID(),
                name: "Door Count",
                category: "Openings",
                panel: .myTools,
                markupKind: .count,
                measurementKind: .count,
                colorRGBA: ColorRGBA(hex: 0x4FD095),
                defaultSubject: "Door",
                countSymbolName: "circle"
            )
        ]
        let document = ToolSetDocument(name: "Site Concrete", exporting: summaries)
        let review = validator.review(document: document, fileName: "Site Concrete.zpdftools")

        #expect(review.isSafeToImport)
        #expect(review.presets.count == 2)
        #expect(review.declaredPresetCount == 2)
        #expect(review.droppedPresetCount == 0)
        #expect(review.blockingFindings.isEmpty)
        #expect(review.markupKindCounts[.measurement] == 1)
        #expect(review.markupKindCounts[.count] == 1)
        #expect(review.measurementKindCounts[.area] == 1)
        #expect(review.countSymbolNames == ["circle"])
        #expect(review.customDefaultKeys == ["Material"])

        // The values, one at a time. A tool set that arrives with the right *number* of tools
        // and the wrong numbers in them is the failure this whole validator is for.
        let area = try #require(review.presets.first { $0.name == "Concrete Area" })
        #expect(area.measurementDefaults.depth == depth, "the depth did not survive the round trip")
        #expect(area.measurementDefaults.wallHeight == wallHeight)
        #expect(area.measurementDefaults.depth?.value != 0, "a fabricated zero is not a depth")
        #expect(area.category == "Concrete")
        #expect(area.defaultSubject == "Concrete")
        #expect(area.labelPattern == "C#")
        #expect(area.displayLengthUnit == .foot)
        #expect(area.customDefaults == ["Material": "C30/37"])
        #expect(area.colorRGBA == ColorRGBA(hex: 0x50D6DE))

        let door = try #require(review.presets.first { $0.name == "Door Count" })
        #expect(door.countSymbolName == "circle")
        #expect(door.category == "Openings")
        #expect(door.measurementKind == .count)
    }

    @Test("Imported tools land in a read-only set")
    func importedToolsAreReadOnly() throws {
        let review = try review(document(presets: [preset()]))
        #expect(review.presets.allSatisfy { $0.isReadOnly })
        #expect(review.presets.allSatisfy { $0.panel == .importedLibraries })
    }

    @Test("The same file always reviews the same way")
    func reviewIsDeterministic() throws {
        let raw = document(presets: [preset(name: "<b>Bold</b>"), preset(name: "https://example.com")])
        let first = try review(raw)
        let second = try review(raw)
        #expect(first.findings.map(\.id) == second.findings.map(\.id))
        #expect(first.findings.map(\.code) == second.findings.map(\.code))
    }

    // MARK: - Files that are not tool sets

    @Test("Bytes that are not JSON are refused with copy, not a parser message")
    func malformedJSONIsRefused() {
        switch validator.review(data: json("this is not a tool set"), fileName: "Whatever.zpdftools") {
        case .success:
            Issue.record("Malformed JSON was accepted")
        case let .failure(error):
            #expect(error.kind == .toolSetFileUnreadable)
            #expect(error.subject == "Whatever.zpdftools")
            let copy = ZPDFErrorCopyTable.copy(for: error)
            #expect(!copy.recovery.isEmpty)
        }
    }

    @Test("A JSON array at the top level is not a tool set")
    func topLevelArrayIsRefused() {
        switch validator.review(data: json("[]"), fileName: "Set.zpdftools") {
        case .success: Issue.record("A top-level array was accepted")
        case let .failure(error): #expect(error.kind == .toolSetFileUnreadable)
        }
    }

    @Test("A file larger than the limit is never parsed at all")
    func oversizeFileIsRefusedBeforeParsing() {
        var limits = ToolSetImportValidator.Limits.standard
        limits.maximumFileByteCount = 32
        let small = ToolSetImportValidator(limits: limits)
        let payload = json(document(presets: [preset()]))
        #expect(payload.count > 32)
        switch small.review(data: payload, fileName: "Big.zpdftools") {
        case .success: Issue.record("An oversize file was parsed")
        case let .failure(error): #expect(error.kind == .toolSetFileTooLarge)
        }
    }

    // MARK: - Blocking findings

    @Test("A set from a format this build does not read is blocked, and says so")
    func unsupportedSchemaVersionBlocks() throws {
        let review = try review(document(presets: [preset()], schemaVersion: 99))
        #expect(!review.isSafeToImport)
        #expect(codes(review).contains(.unsupportedSchemaVersion))
        #expect(review.blockingFindings.allSatisfy { !$0.message.isEmpty })
    }

    @Test("A set with no tools in it is blocked")
    func emptySetBlocks() throws {
        let review = try review(document(presets: []))
        #expect(!review.isSafeToImport)
        #expect(codes(review).contains(.emptySet))
    }

    @Test("A set with more tools than the limit is blocked and none are read")
    func tooManyPresetsBlocks() throws {
        var limits = ToolSetImportValidator.Limits.standard
        limits.maximumPresetCount = 1
        let strict = ToolSetImportValidator(limits: limits)
        let payload = json(document(presets: [preset(name: "One"), preset(name: "Two")]))
        guard case let .success(review) = strict.review(data: payload, fileName: "Set.zpdftools") else {
            Issue.record("Expected a review")
            return
        }
        #expect(!review.isSafeToImport)
        #expect(codes(review).contains(.tooManyPresets))
        #expect(review.presets.isEmpty)
    }

    // MARK: - Content that tries to be more than data

    @Test("Script-shaped text is kept as text, flagged, and never treated as markup")
    func scriptLikeTextIsFlaggedAndKeptLiteral() throws {
        let hostile = "<script>alert(1)</script>"
        let review = try review(document(presets: [preset(name: hostile)]))
        #expect(codes(review).contains(.markupLikeText))
        #expect(review.presets.count == 1)
        #expect(review.presets[0].name == hostile)
        #expect(review.isSafeToImport)
    }

    @Test("Text that points somewhere else is flagged and never followed")
    func externalReferencesAreFlagged() throws {
        let raw = """
        {
          "schemaVersion": 1,
          "name": "Remote",
          "presets": [{
            "id": "\(UUID().uuidString)",
            "name": "Fetcher",
            "category": "Misc",
            "markupType": "measurement",
            "measurementTool": "area",
            "color": "#50D6DE",
            "defaultSubject": "https://example.com/payload",
            "displayLengthUnit": "m"
          }]
        }
        """
        let review = try review(raw)
        #expect(codes(review).contains(.externalReference))
        #expect(review.presets[0].defaultSubject == "https://example.com/payload")
    }

    @Test("A symbol name that is really a path is replaced with a neutral symbol")
    func suspiciousSymbolNameIsReplaced() throws {
        let review = try review(document(
            presets: [preset(extra: "\"countSymbolName\": \"../../../etc/passwd\"")]
        ))
        #expect(codes(review).contains(.suspiciousSymbolName))
        #expect(review.presets[0].countSymbolName == "circle")
    }

    @Test("A plain symbol name is left alone")
    func plainSymbolNameSurvives() throws {
        let review = try review(document(presets: [preset(extra: "\"countSymbolName\": \"square.fill\"")]))
        #expect(!codes(review).contains(.suspiciousSymbolName))
        #expect(review.presets[0].countSymbolName == "square.fill")
    }

    @Test("Fields this build does not know are reported and changed nothing")
    func unknownFieldsAreReported() throws {
        let review = try review(document(
            presets: [preset(extra: "\"onOpen\": \"do something\"")],
            extra: "\"macros\": [1, 2, 3]"
        ))
        #expect(codes(review).contains(.unknownField))
        #expect(review.presets.count == 1)
        #expect(review.isSafeToImport)
    }

    // MARK: - Values that have to be bounded

    @Test("Text longer than the limit is shortened rather than carried into the interface")
    func overlongTextIsTruncated() throws {
        let long = String(repeating: "A", count: 500)
        let review = try review(document(presets: [preset(name: long)]))
        #expect(codes(review).contains(.overlongText))
        #expect(review.presets[0].name.count == ToolSetImportValidator.Limits.standard.maximumTextLength)
    }

    @Test("A colour that is not six hex digits falls back to the default measurement colour")
    func invalidColorFallsBack() throws {
        let raw = """
        {
          "schemaVersion": 1,
          "name": "Colours",
          "presets": [{
            "id": "\(UUID().uuidString)",
            "name": "Odd",
            "category": "Misc",
            "markupType": "measurement",
            "color": "rebeccapurple",
            "defaultSubject": "",
            "displayLengthUnit": "m"
          }]
        }
        """
        let review = try review(raw)
        #expect(codes(review).contains(.invalidColor))
        #expect(review.presets[0].colorRGBA == ColorRGBA.Zenit.Dark.cyan)
    }

    @Test("A markup family this build does not have makes the tool be left out, not guessed at")
    func unknownMarkupTypeDropsThePreset() throws {
        let raw = """
        {
          "schemaVersion": 1,
          "name": "Future",
          "presets": [{
            "id": "\(UUID().uuidString)",
            "name": "Wormhole",
            "category": "Misc",
            "markupType": "wormhole",
            "color": "#50D6DE",
            "defaultSubject": "",
            "displayLengthUnit": "m"
          }]
        }
        """
        let review = try review(raw)
        #expect(codes(review).contains(.unknownMarkupType))
        #expect(review.presets.isEmpty)
        #expect(review.declaredPresetCount == 1)
        #expect(review.droppedPresetCount == 1)
        #expect(!review.isSafeToImport)
    }

    @Test("A measurement tool this build does not have keeps the tool but disarms it")
    func unknownMeasurementToolKeepsThePreset() throws {
        let raw = """
        {
          "schemaVersion": 1,
          "name": "Future",
          "presets": [{
            "id": "\(UUID().uuidString)",
            "name": "Hypervolume",
            "category": "Misc",
            "markupType": "measurement",
            "measurementTool": "hypervolume",
            "color": "#50D6DE",
            "defaultSubject": "",
            "displayLengthUnit": "m"
          }]
        }
        """
        let review = try review(raw)
        #expect(codes(review).contains(.unknownMeasurementTool))
        #expect(review.presets.count == 1)
        #expect(review.presets[0].measurementKind == nil)
    }

    @Test("Two tools claiming one identity are separated instead of overwriting each other")
    func duplicateIdentifiersAreSeparated() throws {
        let shared = UUID().uuidString
        let raw = """
        {
          "schemaVersion": 1,
          "name": "Twins",
          "presets": [
            {"id": "\(shared)", "name": "First", "category": "A", "markupType": "measurement",
             "measurementTool": "area", "color": "#50D6DE", "defaultSubject": "", "displayLengthUnit": "m"},
            {"id": "\(shared)", "name": "Second", "category": "A", "markupType": "measurement",
             "measurementTool": "area", "color": "#50D6DE", "defaultSubject": "", "displayLengthUnit": "m"}
          ]
        }
        """
        let review = try review(raw)
        #expect(codes(review).contains(.duplicateIdentifier))
        #expect(review.presets.count == 2)
        #expect(review.presets[0].id != review.presets[1].id)
    }

    // MARK: - Embedded pictures

    @Test("An oversize picture is described, left out, and does not take the tool with it")
    func oversizeImageIsLeftOut() throws {
        var limits = ToolSetImportValidator.Limits.standard
        limits.maximumEmbeddedImageByteCount = 64
        let strict = ToolSetImportValidator(limits: limits)
        let base64 = String(repeating: "QQ==", count: 200)
        let raw = document(presets: [preset(extra: """
        "embeddedImage": {
          "fileName": "symbol.png", "format": "png",
          "pixelWidth": 64, "pixelHeight": 64,
          "base64Data": "\(base64)"
        }
        """)])
        guard case let .success(review) = strict.review(data: json(raw), fileName: "Set.zpdftools") else {
            Issue.record("Expected a review")
            return
        }
        #expect(codes(review).contains(.embeddedImageTooLarge))
        #expect(review.embeddedImages.count == 1)
        #expect(review.embeddedImages[0].isAccepted == false)
        #expect(review.presets.count == 1)
        #expect(review.isSafeToImport)
    }

    @Test("A picture in a format Zenit does not read is left out")
    func unsupportedImageFormatIsLeftOut() throws {
        let raw = document(presets: [preset(extra: """
        "embeddedImage": {
          "fileName": "symbol.svg", "format": "svg",
          "pixelWidth": 32, "pixelHeight": 32,
          "base64Data": "QQ=="
        }
        """)])
        let review = try review(raw)
        #expect(codes(review).contains(.unsupportedImageFormat))
        #expect(review.embeddedImages[0].isAccepted == false)
    }

    @Test("A picture with more pixels than the limit is left out")
    func oversizeImagePixelsAreLeftOut() throws {
        let raw = document(presets: [preset(extra: """
        "embeddedImage": {
          "fileName": "huge.png", "format": "png",
          "pixelWidth": 8000, "pixelHeight": 8000,
          "base64Data": "QQ=="
        }
        """)])
        let review = try review(raw)
        #expect(codes(review).contains(.embeddedImageTooManyPixels))
        #expect(review.embeddedImages[0].isAccepted == false)
    }

    @Test("A picture inside the limits is reported as one Zenit will keep")
    func acceptableImageIsKept() throws {
        let raw = document(presets: [preset(extra: """
        "embeddedImage": {
          "fileName": "symbol.png", "format": "png",
          "pixelWidth": 32, "pixelHeight": 32,
          "base64Data": "QQ=="
        }
        """)])
        let review = try review(raw)
        #expect(review.embeddedImages.count == 1)
        #expect(review.embeddedImages[0].isAccepted)
        #expect(review.embeddedImages[0].declaredFormat == "png")
        #expect(!review.embeddedImages[0].detailLine.isEmpty)
    }

    // MARK: - Findings themselves

    @Test("Every finding says something a person can act on")
    func findingsAreReadable() throws {
        let raw = document(
            presets: [
                preset(name: "<script>x</script>", extra: "\"countSymbolName\": \"/etc/passwd\""),
                preset(name: String(repeating: "B", count: 400))
            ],
            extra: "\"unexpected\": true"
        )
        let review = try review(raw)
        #expect(!review.findings.isEmpty)
        for finding in review.findings {
            #expect(!finding.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!finding.id.isEmpty)
            #expect(!finding.accessibilityLabel.isEmpty)
        }
        // Most serious first, so the blocking reason is never below the fold.
        let severities = review.findings.map(\.severity)
        #expect(severities == severities.sorted(by: >))
    }

    @Test("The review's summary line describes what would actually be added")
    func summaryDescribesTheOutcome() throws {
        let review = try review(document(presets: [preset(name: "A"), preset(name: "B")]))
        #expect(!review.summaryLine.isEmpty)
        #expect(!ToolSetImportReview.dataOnlyStatement.isEmpty)
    }

    @Test("Text inspection recognises the two shapes it is looking for")
    func textInspectionWorks() {
        #expect(ToolSetImportValidator.looksLikeMarkupOrScript("<script>x</script>"))
        #expect(ToolSetImportValidator.looksLikeMarkupOrScript("JAVASCRIPT:alert(1)"))
        #expect(!ToolSetImportValidator.looksLikeMarkupOrScript("Concrete C30/37"))
        #expect(ToolSetImportValidator.looksLikeExternalReference("https://example.com"))
        #expect(ToolSetImportValidator.looksLikeExternalReference("/Users/someone/secret"))
        #expect(!ToolSetImportValidator.looksLikeExternalReference("Level 2 slab"))
    }
}
