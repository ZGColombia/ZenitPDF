import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Loop iteration 1, area ui-workflows-ledger: the Tool Library's render cost (R-120, R-133),
/// its file import (R-134) and blank text in imported sets (R-132).
@Suite("Tool Library, loop iteration 1", .workflowsTierSerialised)
@MainActor
struct Iter1ToolLibraryFixTests {

    private func library(count: Int, categories: Int = 1) -> [ToolPresetSummary] {
        (0..<count).map { index in
            ToolLibraryFixtures.simple(
                "Tool \(index)",
                category: "Category \(index % categories)",
                sortIndex: count - index
            )
        }
    }

    // MARK: - R-120 and R-133

    /// R-120 and R-133. Old output: the header count came from a second full filter-and-sort
    /// (`visiblePresets`), and every tile's badge from its own `ToolSlotOrder.slotNumber` call,
    /// one whole-library sort per tile. The content now carries all three from one pass; this
    /// pins that the badges it hands out are exactly the ones the per-tile calls produced.
    @Test("One pass gives the groups, the header count and every badge the per-tile calls gave")
    func panelContentAgreesWithThePerTileCalls() {
        let model = ToolLibraryEditingModel(presets: library(count: 40, categories: 4))
        for query in ["", "1", "Category 2", "nothing matches this"] {
            let content = model.panelContent(in: .myTools, matching: query)
            #expect(content.groups == model.groupedPresets(in: .myTools, matching: query))
            #expect(content.visibleCount == model.presets(in: .myTools, matching: query).count)
            for preset in model.presets {
                #expect(
                    content.slotNumber(of: preset.id)
                        == ToolSlotOrder.slotNumber(of: preset.id, in: model.presets, panel: .myTools),
                    "\(preset.name) under \"\(query)\""
                )
            }
        }
        // The filter still does not renumber: the ninth slot keeps its badge when a search hides
        // everything but it.
        let ninth = ToolSlotOrder.slots(model.presets, in: .myTools)[8]
        let filtered = model.panelContent(in: .myTools, matching: ninth.name)
        #expect(filtered.groups.flatMap(\.presets).contains { $0.id == ninth.id })
        #expect(filtered.slotNumber(of: ninth.id) == 9)
        #expect(model.panelContent(in: .myTools).slotNumbers.count == ToolSlotOrder.slotCount)
    }

    /// R-120 measurement: badges for every tile of a 600-tool, one-category set, the old way
    /// (one `ToolSlotOrder.slotNumber` per tile) against one `panelContent` pass.
    @Test("Badging a large set is one sort, not one sort per tile")
    func badgingIsLinearInTheTiles() {
        let model = ToolLibraryEditingModel(presets: library(count: 600))
        let clock = ContinuousClock()
        var oldBadges: [UUID: Int] = [:]
        let old = clock.measure {
            for preset in model.presets {
                if let slot = ToolSlotOrder.slotNumber(of: preset.id, in: model.presets, panel: .myTools) {
                    oldBadges[preset.id] = slot
                }
            }
        }
        var content = ToolPresetPanelContent(groups: [], visibleCount: 0, slotNumbers: [:])
        let new = clock.measure { content = model.panelContent(in: .myTools) }
        print("R-120 measurement: 600 tiles, per-tile badges \(old), one pass \(new)")
        #expect(content.slotNumbers == oldBadges)
        #expect(content.visibleCount == 600)
        #expect(new < old, "one pass must beat 600 whole-set sorts")
    }

    // MARK: - R-134

    private func temporaryFile(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-iter1-\(UUID().uuidString)")
            .appendingPathComponent(name)
    }

    /// R-134. Old output: the panel's importer ran `Data(contentsOf:)` on the main actor, read all
    /// 64 MB of this file into memory, and only then did the validator refuse it as too large.
    /// The size is now asked of the file system and nothing is read.
    @Test("An oversized tool set file is refused by its size, before it is read")
    func oversizedFileIsRefusedUnread() async throws {
        let url = temporaryFile(named: "Huge.zpdftools")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        // A sparse file: 64 MB by its size, no disk used and nothing to read.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.close()

        let model = ToolLibraryEditingModel()
        var failures: [ZPDFUserFacingError] = []
        model.onImportFailure = { failures.append($0) }
        await model.reviewImport(fileAt: url)

        #expect(failures.map(\.kind) == [.toolSetFileTooLarge])
        #expect(failures.first?.subject == "Huge.zpdftools")
        #expect(failures.first?.technicalDetail?.contains("It was not read") == true)
        #expect(model.importReview == nil)
        #expect(!model.isReviewingImport)
    }

    @Test("The bounded read stops one byte past the limit, and a small file reads whole")
    func boundedReadRespectsTheLimit() throws {
        let url = temporaryFile(named: "Set.zpdftools")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data(repeating: 0x20, count: 2_048).write(to: url)

        let tight = ToolSetImportValidator(limits: .init(maximumFileByteCount: 1_024))
        guard case let .failure(refusal) = tight.readCandidate(at: url) else {
            Issue.record("a 2 048-byte file passed a 1 024-byte limit")
            return
        }
        #expect(refusal.kind == .toolSetFileTooLarge)
        guard case let .success(data) = ToolSetImportValidator().readCandidate(at: url) else {
            Issue.record("a 2 KB file was refused under the standard limit")
            return
        }
        #expect(data.count == 2_048)
    }

    @Test("A file that cannot be opened is reported as unreadable, and a good one is reviewed")
    func missingAndGoodFiles() async throws {
        let model = ToolLibraryEditingModel()
        var failures: [ZPDFUserFacingError] = []
        model.onImportFailure = { failures.append($0) }

        await model.reviewImport(fileAt: temporaryFile(named: "Gone.zpdftools"))
        #expect(failures.map(\.kind) == [.toolSetFileUnreadable])
        #expect(failures.first?.subject == "Gone.zpdftools")

        let url = temporaryFile(named: "Office.zpdftools")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let presets = library(count: 3)
        try ToolSetDocument(name: "Office", author: "A. Surveyor", exporting: presets).jsonData().write(to: url)
        await model.reviewImport(fileAt: url)
        #expect(failures.count == 1, "the good file raised nothing")
        #expect(model.importReview?.presets.count == 3)
        #expect(model.importReview?.fileName == "Office.zpdftools")
    }

    // MARK: - R-132

    private func review(presetJSON: String) throws -> ToolSetImportReview {
        let data = Data("""
        {"schemaVersion": 1, "name": "Set", "presets": [\(presetJSON)]}
        """.utf8)
        switch ToolSetImportValidator().review(data: data, fileName: "Set.zpdftools") {
        case let .success(review): return review
        case let .failure(error): throw error
        }
    }

    /// R-132. Old output: category "" — the default applied only when the key was missing, and
    /// `boundedText` trimmed "  " to nothing, so the tool sat under a blank section header.
    @Test("A blank category files the tool under Imported and says so")
    func blankCategoryFallsBack() throws {
        let review = try review(presetJSON: """
        {"name": "Door Count", "category": "  \\t ", "markupType": "count", "measurementTool": "count"}
        """)
        let preset = try #require(review.presets.first)
        #expect(preset.category == "Imported")
        #expect(review.findings.contains { $0.code == .missingRequiredField && $0.message.contains("Imported") })
    }

    /// R-132. Old output: name "" — "\u{0007}" passed the whitespace-only blank test, then
    /// `boundedText` turned the bell into a space and trimmed it away: a blank, read-only tile.
    @Test("A name made only of control characters takes the numbered fallback")
    func controlCharacterNameFallsBack() throws {
        let review = try review(presetJSON: """
        {"name": "\\u0007\\u0008", "category": "Doors", "markupType": "count", "measurementTool": "count"}
        """)
        let preset = try #require(review.presets.first)
        #expect(preset.name == "Tool 1")
        #expect(preset.category == "Doors")
        #expect(review.findings.contains { $0.code == .missingRequiredField && $0.presetName == "Tool 1" })
    }

    @Test("A name that is merely absent still falls back quietly, and real text is untouched")
    func absentNameAndRealTextAreUnchanged() throws {
        let absent = try review(presetJSON: """
        {"category": "Doors", "markupType": "count", "measurementTool": "count"}
        """)
        #expect(absent.presets.first?.name == "Tool 1")
        #expect(!absent.findings.contains { $0.code == .missingRequiredField })

        let real = try review(presetJSON: """
        {"name": "Door\\u0007Count", "category": "Doors", "markupType": "count", "measurementTool": "count"}
        """)
        #expect(real.presets.first?.name == "Door Count")
        #expect(!real.findings.contains { $0.code == .missingRequiredField })
    }
}
