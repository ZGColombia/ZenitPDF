import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

// MARK: - Fixtures

@MainActor
enum ToolLibraryFixtures {

    static let artwork = StampArtworkDescriptor(
        kind: .vector,
        digest: String(repeating: "b", count: 64),
        byteCount: 1024,
        sourceName: "Seal.pdf",
        sourcePageIndex: 0
    )

    static func metres(_ text: String) -> DecimalQuantity {
        DecimalQuantity(value: Decimal(string: text)!, dimension: .length)
    }

    /// A preset with every field set to something other than its default.
    static func everyField(panel: ToolLibraryPanel = .myTools, sortIndex: Int = 3) -> ToolPresetSummary {
        let id = UUID()
        return ToolPresetSummary(
            id: id,
            schemaVersion: 2,
            name: "Retaining wall",
            category: "Walls",
            panel: panel,
            markupKind: .stamp,
            measurementKind: .wallArea,
            colorRGBA: ColorRGBA.Zenit.Dark.green,
            defaultSubject: "Wall",
            measurementDefaults: ToolPresetMeasurementDefaults(
                depth: metres("0.2"),
                wallHeight: metres("1.2"),
                wallHeightAtEnd: metres("0"),
                slopePercent: 12,
                slopeAzimuthDegrees: 90,
                volumeDepthReference: ToolPresetVolumeDepthReference.allCases.last,
                cutoutPolicy: ToolPresetCutoutPolicy.allCases.last!,
                perimeterPolicy: ToolPresetPerimeterPolicy.allCases.last!
            ),
            labelPattern: "RW#",
            defaultStatus: MarkupStatus.allCases.last!,
            displayLengthUnit: .foot,
            customDefaults: ["Material": "C30/37"],
            countSymbolName: "star.fill",
            stamp: StampTemplate(id: id, widthPoints: 90, heightPoints: 30, artwork: artwork, fields: []),
            provenance: ToolPresetProvenance(
                origin: .imported, sourceFileName: "Office.zpdftools", recordedAt: Date(timeIntervalSince1970: 1_000)
            ),
            isFavorite: true,
            isReadOnly: panel == .importedLibraries,
            shortcutDisplayString: "⌥4",
            sortIndex: sortIndex,
            // V-059: the round-2 look is a field too; the fixture used to leave it nil, which
            // is how a copy that dropped it went unnoticed.
            style: styled
        )
    }

    /// A round-2 look with every field away from its default (V-059).
    static let styled = ToolStyleSelection(
        stroke: ColorRGBA.Zenit.Dark.green,
        fill: ColorRGBA(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.25),
        lineWidth: 3.5,
        fontName: "Menlo",
        fontSize: 14,
        lineStyle: .dashDot,
        opacity: 0.6,
        startCap: .circle,
        endCap: .closedArrow,
        textAlignment: .center,
        multiplyBlend: true,
        cloudArcSize: 9,
        bold: true,
        italic: true,
        textColor: ColorRGBA(red: 0.9, green: 0.1, blue: 0.1, alpha: 1),
        boxBorder: true
    )

    static func simple(_ name: String, category: String = "Walls", panel: ToolLibraryPanel = .myTools, sortIndex: Int) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: name,
            category: category,
            panel: panel,
            markupKind: .measurement,
            measurementKind: .length,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            defaultSubject: name,
            isReadOnly: !panel.isEditable,
            sortIndex: sortIndex
        )
    }

    static func markup(zone: String?) -> MarkupSummary {
        MarkupSummary(
            id: UUID(),
            kind: .measurement,
            measurementKind: .area,
            subject: "Slab",
            label: "S1",
            pageLabel: "A-101",
            pageID: UUID(),
            pageIndex: 0,
            zone: zone,
            author: "Test",
            colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            created: Date(),
            modified: Date(),
            boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 10, height: 10)
        )
    }

    /// Everything two summaries share, minus the fields a copy may legitimately change.
    static func sharedFields(_ preset: ToolPresetSummary) -> [AnyHashable] {
        [
            preset.schemaVersion, preset.category, preset.markupKind, preset.measurementKind,
            preset.colorRGBA, preset.defaultSubject, preset.measurementDefaults, preset.labelPattern,
            preset.defaultStatus, preset.displayLengthUnit, preset.customDefaults, preset.countSymbolName,
            preset.stamp?.artwork, preset.stamp?.fields, preset.stamp?.widthPoints, preset.stamp?.heightPoints,
            preset.stamp?.revision, preset.style
        ]
    }
}

// MARK: - Copy helper, duplicate, re-mint (IM-035, BH-847, BH-848)

@Suite("Tool Library copies, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2ToolLibraryCopyTests {

    @Test("A copy differs from its source only in the fields a copy changes")
    func copyCarriesEveryField() {
        let source = ToolLibraryFixtures.everyField()
        let model = ToolLibraryEditingModel(presets: [source])
        let duplicate = try! #require(model.duplicate(id: source.id))
        let reminted = ToolLibraryEditingModel.reidentified(source)

        for copy in [duplicate, reminted] {
            #expect(copy.id != source.id)
            #expect(ToolLibraryFixtures.sharedFields(copy) == ToolLibraryFixtures.sharedFields(source))
            // BH-847. Old output: `copy.stamp?.id == source.id`, so a batch of the copy
            // skipped every page carrying the original's stamps.
            #expect(copy.stamp?.id == copy.id)
        }
        #expect(duplicate.name == "Retaining wall copy")
        #expect(duplicate.provenance.origin == .duplicated)
        #expect(!duplicate.isFavorite && !duplicate.isReadOnly)
        #expect(duplicate.shortcutDisplayString == nil)
        // A re-mint is the same preset under a new identity, nothing else.
        #expect(reminted.name == source.name)
        #expect(reminted.isFavorite == source.isFavorite)
        #expect(reminted.sortIndex == source.sortIndex)
        #expect(reminted.provenance == source.provenance)
    }

    /// Old output: the copy took `source.sortIndex + 1` = 2 and landed between My Tools' W1
    /// and W2, shifting W2…W4 and their number-key slots.
    @Test("A copy of a read-only preset lands at the end of its My Tools category")
    func readOnlyCopyGoesToTheEnd() throws {
        let mine = (0..<5).map { ToolLibraryFixtures.simple("W\($0)", sortIndex: $0) }
        let imported = ToolLibraryFixtures.simple("Imported", panel: .importedLibraries, sortIndex: 1)
        let model = ToolLibraryEditingModel(presets: mine + [imported])

        let copy = try #require(model.duplicate(id: imported.id))
        #expect(copy.panel == .myTools)
        let order = model.presets(in: .myTools).filter { $0.category == "Walls" }.map(\.name)
        #expect(order == ["W0", "W1", "W2", "W3", "W4", "Imported copy"])
        #expect(model.presets(in: .myTools).first { $0.name == "W2" }?.sortIndex == 2)
    }

    @Test("Saving an edit keeps the stored shortcut text")
    func editKeepsShortcut() {
        let source = ToolLibraryFixtures.everyField()
        let model = ToolLibraryEditingModel(presets: [source])
        model.beginEditing(id: source.id)
        model.draft?.name = "Renamed"
        model.commitDraft()
        #expect(model.presets[0].name == "Renamed")
        #expect(model.presets[0].shortcutDisplayString == "⌥4")
    }
}

// MARK: - Draft rules (BH-846, BH-317, BH-318, BH-850, BH-851, IM-036, IM-157, IM-232, IM-234)

@Suite("Tool preset draft rules, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2ToolPresetDraftTests {

    private func draft(kind: MeasurementKind? = .area, markup: MarkupKind = .measurement) -> ToolPresetDraft {
        ToolPresetDraft(
            isNew: true,
            panel: .myTools,
            name: "Tool",
            category: "Walls",
            markupKind: markup,
            measurementKind: kind,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            defaultSubject: ""
        )
    }

    /// Old output: `isValid == true` with a blank category, and the panel drew a nameless
    /// section; a markup with a blank zone became a preset with category "".
    @Test("A blank category cannot be saved and a blank zone becomes Uncategorised")
    func blankCategory() {
        var blank = draft()
        blank.category = "   "
        #expect(!blank.isValid)
        let captured = ToolPresetDraft(from: ToolLibraryFixtures.markup(zone: "  "))
        #expect(captured.category == "Uncategorised")
        #expect(captured.isValid)
    }

    /// Old output: the picker wrote `measurementKind` alone, so a new Count tool kept
    /// `markupKind == .measurement` and never reached the Count palette, and a Count preset
    /// re-tooled to Area stayed in it.
    @Test("Choosing Count makes a count preset, and leaving Count makes a measurement")
    func toolPickerKeepsFamilyInStep() {
        var value = draft()
        value.setMeasurementKind(.count)
        #expect(value.markupKind == .count)
        #expect(value.makePreset().markupKind == .count)
        value.setMeasurementKind(.area)
        #expect(value.markupKind == .measurement)
        var stamp = draft(kind: nil, markup: .stamp)
        stamp.setMeasurementKind(.count)
        #expect(stamp.markupKind == .stamp, "a stamp keeps its family")
    }

    /// Old output: Remove left `stamp == StampTemplate(artwork: nil, fields: [])` on the saved
    /// Count preset, which Batch Apply then treated as a stamp to place.
    @Test("Removing a Count preset's picture removes its template; a stamp keeps its fields")
    func removeArtwork() {
        var count = draft(kind: .count, markup: .count)
        count.adoptArtwork(ToolLibraryFixtures.artwork)
        #expect(count.stamp != nil)
        count.removeArtwork()
        #expect(count.stamp == nil)
        #expect(count.makePreset().stamp == nil)
        // BH-850. Old output: "Fields only" for a Count preset with an artwork-less template.
        var emptied = draft(kind: .count, markup: .count)
        emptied.stamp = StampTemplate(id: emptied.id, widthPoints: 12, heightPoints: 12, artwork: nil, fields: [])
        #expect(ToolPresetEditorSheet.artworkDescription(for: emptied) == "The chosen symbol")

        var stamp = draft(kind: nil, markup: .stamp)
        stamp.adoptArtwork(ToolLibraryFixtures.artwork)
        let revision = stamp.stamp!.revision
        stamp.removeArtwork()
        #expect(stamp.stamp != nil)
        #expect(stamp.stamp?.artwork == nil)
        #expect(stamp.stamp!.revision == revision + 1)
        #expect(ToolPresetEditorSheet.artworkDescription(for: stamp) == "Fields only")
    }

    /// Old output: Return in the Column field reached Save, which closed the sheet; the typed
    /// pair lived in view state and was dropped.
    @Test("While a column default is typed, Return does not save, and Save keeps the pair")
    func pendingColumnDefault() {
        #expect(!ToolPresetEditorSheet.saveTakesReturn(pendingColumnName: "Material"))
        #expect(ToolPresetEditorSheet.saveTakesReturn(pendingColumnName: "  "))
        var value = draft()
        let added = value.addColumnDefault(key: " Material ", value: "Oak")
        #expect(added)
        #expect(value.customDefaults == ["Material": "Oak"])
        let blank = value.addColumnDefault(key: " ", value: "x")
        #expect(!blank)
    }

    /// Old output: "abc" set the depth to nil (the saved depth vanished) and "0" saved a
    /// depth of zero; neither raised anything.
    @Test("Unreadable or zero parameters raise an issue and block Save, as the importer would")
    func sharedParameterRule() throws {
        #expect(ToolPresetLengthField.reading("abc", unit: .metre) == .unparsed)
        #expect(ToolPresetLengthField.reading("  ", unit: .metre) == .empty)
        #expect(ToolPresetLengthField.reading("0,2", unit: .metre) == .value(ToolLibraryFixtures.metres("0.2")))

        var value = draft(kind: .volume)
        value.measurementDefaults.depth = ToolLibraryFixtures.metres("0.2")
        value.unparsedFields = [.depth]
        #expect(!value.isValid)
        #expect(value.parameterIssue(for: .depth)?.message == ToolPresetParameterRule.unparsedMessage)
        #expect(value.measurementDefaults.depth == ToolLibraryFixtures.metres("0.2"), "the stored depth survives the typo")

        value.unparsedFields = []
        value.measurementDefaults.depth = ToolLibraryFixtures.metres("0")
        #expect(!value.isValid)
        #expect(value.parameterIssue(for: .depth) != nil)

        // A wall tapering to grade is a real shape on both sides of the file (BH-321).
        value.measurementDefaults.depth = nil
        value.measurementDefaults.wallHeightAtEnd = ToolLibraryFixtures.metres("0")
        #expect(value.isValid)

        // The same zero depth in a file is refused by the importer with a finding.
        let raw = """
        {"schemaVersion": 1, "name": "S", "presets": [{"id": "\(UUID().uuidString)", "name": "Slab",
         "markupType": "measurement", "measurementTool": "volume",
         "measurementDefaults": {"depthMetres": 0, "wallHeightAtEndMetres": 0}}]}
        """
        guard case let .success(review) = ToolSetImportValidator().review(data: Data(raw.utf8), fileName: "S.zpdftools") else {
            Issue.record("expected a review"); return
        }
        #expect(review.presets[0].measurementDefaults.depth == nil)
        #expect(review.presets[0].measurementDefaults.wallHeightAtEnd == ToolLibraryFixtures.metres("0"))
        #expect(review.findings.filter { $0.code == .valueOutOfRange }.count == 1)
    }

    @Test("Switching tools drops the unreadable flag of a field the new tool hides")
    func switchingToolsClearsHiddenUnparsed() {
        var value = draft(kind: .volume)
        value.unparsedFields = [.depth]
        value.setMeasurementKind(.length)
        #expect(value.unparsedFields.isEmpty)
        #expect(value.isValid)
    }

    @Test("The editor shows only the parameters the chosen tool uses")
    func displayedFieldsFollowTheTool() {
        typealias F = ToolPresetParameterRule.Field
        #expect(ToolPresetParameterRule.displayedFields(for: .length).isEmpty)
        #expect(ToolPresetParameterRule.displayedFields(for: .count).isEmpty)
        #expect(ToolPresetParameterRule.displayedFields(for: nil).isEmpty)
        #expect(ToolPresetParameterRule.displayedFields(for: .volume) == [F.depth, .volumeDepthReference, .cutoutPolicy, .perimeterPolicy])
        #expect(ToolPresetParameterRule.displayedFields(for: .wallArea).isSuperset(of: [F.wallHeight, .wallHeightAtEnd]))
        #expect(!ToolPresetParameterRule.displayedFields(for: .wallArea).contains(.depth))
        #expect(ToolPresetParameterRule.displayedFields(for: .trueSlopedArea).isSuperset(of: [F.slopePercent, .slopeAzimuthDegrees]))
    }

    @Test("A new preset reads in the project's display unit")
    func newPresetUsesProjectUnit() {
        let model = ToolLibraryEditingModel()
        model.beginCreating(displayLengthUnit: .foot)
        #expect(model.draft?.displayLengthUnit == .foot)
        model.beginCreating(from: ToolLibraryFixtures.markup(zone: "L1"), displayLengthUnit: .foot)
        #expect(model.draft?.displayLengthUnit == .foot)
    }

    @Test("The count symbol menu speaks names, not SF Symbols identifiers")
    func symbolNamesAreWords() {
        let names = ToolPresetSymbolPicker.allowedSymbolNames.map(ToolPresetSymbolPicker.displayName(forSymbol:))
        #expect(Set(names).count == ToolPresetSymbolPicker.allowedSymbolNames.count)
        for (identifier, name) in zip(ToolPresetSymbolPicker.allowedSymbolNames, names) {
            #expect(name != identifier)
            #expect(!name.contains("."))
        }
    }
}

// MARK: - Model: undo, import, export, move, grouping (IM-154, IM-155, BH-320, BH-849, BH-316, IM-156)

@Suite("Tool Library model, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2ToolLibraryModelTests {

    private func setFile(presets: Int, withPicture: Bool = false) -> Data {
        let entries = (0..<presets).map { index in
            """
            {"id": "\(UUID().uuidString)", "name": "Tool \(index)", "category": "Set",
             "markupType": "count", "measurementTool": "count"\(withPicture ? """
            , "embeddedImage": {"fileName": "dot.png", "format": "png", "pixelWidth": 8,
               "pixelHeight": 8, "base64Data": "iVBORw0KGgo="}
            """ : "")}
            """
        }
        return Data("""
        {"schemaVersion": 1, "name": "Set", "presets": [\(entries.joined(separator: ","))]}
        """.utf8)
    }

    /// Old output: no step was reported for an edit, an import or a favourite; only delete had
    /// a (single, in-model) undo.
    @Test("Edits, imports and favourites report a step that reverts them")
    func undoSteps() throws {
        let original = ToolLibraryFixtures.simple("A", sortIndex: 0)
        let model = ToolLibraryEditingModel(presets: [original])
        var steps: [ToolLibraryUndoStep] = []
        model.onUndoableChange = { steps.append($0) }

        model.beginEditing(id: original.id)
        model.draft?.name = "A edited"
        model.commitDraft()
        model.revert(try #require(steps.last))
        #expect(model.presets.first?.name == "A")

        model.toggleFavorite(id: original.id)
        #expect(model.presets.first?.isFavorite == true)
        model.revert(try #require(steps.last))
        #expect(model.presets.first?.isFavorite == false)

        model.beginImport(data: setFile(presets: 5), fileName: "Set.zpdftools")
        model.confirmImport()
        #expect(model.presets.count == 6)
        let importStep = try #require(steps.last)
        #expect(importStep.actionName == "Import 5 Tools")
        model.revert(importStep)
        #expect(model.presets.map(\.id) == [original.id])
        model.revert(importStep.inverse)
        #expect(model.presets.count == 6, "redo puts all five back")

        model.delete(id: original.id)
        model.revert(try #require(steps.last))
        #expect(model.presets.contains { $0.id == original.id })
        #expect(model.pendingDeletion == nil, "the Undo bar cannot put it back a second time")
        #expect(steps.count == 4, "revert itself reports no new step")
    }

    @Test("An import is reviewed off the main actor with the same result")
    func asyncImportMatchesSync() async {
        let data = setFile(presets: 40)
        let sync = ToolLibraryEditingModel()
        sync.beginImport(data: data, fileName: "Set.zpdftools")
        let async = ToolLibraryEditingModel()
        await async.reviewImport(data: data, fileName: "Set.zpdftools")
        #expect(async.isReviewingImport == false)
        #expect(async.importReview?.presets.map(\.id) == sync.importReview?.presets.map(\.id))
        #expect(async.importReview?.findings == sync.importReview?.findings)
        #expect(async.importReview?.presets.count == 40)
    }

    /// Old output: `confirmImport` appended `review.presets` alone; the picture's base64 was
    /// discarded and the sheet had said "Will be kept".
    @Test("An accepted picture is attached to its tool after the import is confirmed")
    func acceptedPictureIsKept() async throws {
        let model = ToolLibraryEditingModel()
        var choices: [ArtworkImportChoice] = []
        var bytesSeen: [Data] = []
        model.onImportArtwork = { choice in
            choices.append(choice)
            if case let .image(url) = choice, let data = try? Data(contentsOf: url) { bytesSeen.append(data) }
            return .imported(ToolLibraryFixtures.artwork)
        }
        #expect(model.canKeepImportedPictures)
        model.beginImport(data: setFile(presets: 1, withPicture: true), fileName: "Set.zpdftools")
        let review = try #require(model.importReview)
        #expect(review.embeddedImages.first?.isAccepted == true)
        model.confirmImport()
        for _ in 0..<200 where model.presets.first?.stamp == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(choices.count == 1)
        #expect(bytesSeen.first == Data(base64Encoded: "iVBORw0KGgo="))
        #expect(model.presets.first?.stamp?.artwork == ToolLibraryFixtures.artwork)
        #expect(model.presets.first?.stamp?.id == model.presets.first?.id)

        #expect(ToolSetImportReviewSheet.imageStatus(isAccepted: true, canKeepPictures: true) == "Will be kept")
        #expect(ToolSetImportReviewSheet.imageStatus(isAccepted: true, canKeepPictures: false) == "Cannot be kept here")
        #expect(ToolSetImportReviewSheet.imageStatus(isAccepted: false, canKeepPictures: true) == "Will be left out")
        #expect(!ToolLibraryEditingModel().canKeepImportedPictures)
    }

    /// Old output: "Export This Set…" was disabled on the filtered list, although the export
    /// writes the whole panel.
    @Test("Whether a set can be exported ignores the search")
    func exportIgnoresFilter() {
        let model = ToolLibraryEditingModel(presets: [ToolLibraryFixtures.simple("Wall", sortIndex: 0)])
        #expect(model.presets(in: .myTools, matching: "zzz").isEmpty)
        #expect(model.canExport(panel: .myTools))
        #expect(!model.canExport(panel: .projectTools))
    }

    /// Old output: Move Down on W1 with only W1 and W4 visible gave W2, W1, W3, W4 — no visible
    /// change, and the number-key slots shifted.
    @Test("Move Down under a search moves past the next visible sibling")
    func moveUnderFilter() {
        let walls = (1...4).map { ToolLibraryFixtures.simple("W\($0)", sortIndex: $0 - 1) }
        let model = ToolLibraryEditingModel(presets: walls)
        let visible = [walls[0].id, walls[3].id]
        model.move(id: walls[0].id, by: 1, among: visible)
        #expect(model.presets(in: .myTools).map(\.name) == ["W2", "W3", "W4", "W1"])
        // On screen the order is now W4, W1.
        model.move(id: walls[0].id, by: -1, among: [walls[3].id, walls[0].id])
        #expect(model.presets(in: .myTools).map(\.name) == ["W2", "W3", "W1", "W4"])
        model.move(id: walls[0].id, by: -1, among: visible)
        #expect(model.presets(in: .myTools).map(\.name) == ["W2", "W3", "W1", "W4"], "already first on screen")
    }

    /// The old panel asked for `categories(in:)` and then `presets(in:)` twice per category.
    /// With 2 000 presets in 40 categories that is 81 filter-and-sort passes against one.
    @Test("Grouping once gives the old grouping, far cheaper")
    func groupingOnce() {
        var library: [ToolPresetSummary] = []
        for index in 0..<2_000 {
            library.append(ToolLibraryFixtures.simple("Tool \(index)", category: "Cat \(index % 40)", sortIndex: index / 40))
        }
        let model = ToolLibraryEditingModel(presets: library)

        let clock = ContinuousClock()
        var old: [(String, [ToolPresetSummary])] = []
        let oldTime = clock.measure {
            for category in model.categories(in: .myTools, matching: "tool") {
                _ = model.presets(in: .myTools, matching: "tool").filter { $0.category == category }.count
                old.append((category, model.presets(in: .myTools, matching: "tool").filter { $0.category == category }))
            }
        }
        var groups: [ToolPresetGroup] = []
        let newTime = clock.measure {
            groups = model.groupedPresets(in: .myTools, matching: "tool")
        }
        #expect(groups.map(\.category) == old.map(\.0))
        #expect(groups.map(\.presets) == old.map(\.1))
        #expect(newTime * 10 < oldTime, "grouped \(newTime) vs per-category \(oldTime)")
        print("IM-156 measurement: per-category \(oldTime), grouped once \(newTime)")
    }
}

// MARK: - Importer (BH-852, BH-853, BH-854, BH-855)

@Suite("Tool set importer, bug hunt 2", .workflowsTierSerialised)
struct BugHunt2ToolSetImporterTests {

    private func review(_ presetJSON: String) throws -> ToolSetImportReview {
        let raw = """
        {"schemaVersion": 1, "name": "S", "presets": [\(presetJSON)]}
        """
        switch ToolSetImportValidator().review(data: Data(raw.utf8), fileName: "S.zpdftools") {
        case let .success(review): return review
        case let .failure(error): throw error
        }
    }

    /// Old output: "PNG · 1 × 32 px · …" for a declared width of 4294967297.
    @Test("Pixel counts above 2^31 print whole")
    func pixelCountsPrintWhole() {
        let image = ToolSetEmbeddedImageReview(
            id: "i", presetName: "p", fileName: "f", declaredFormat: "png",
            declaredByteCount: 10, pixelWidth: 4_294_967_297, pixelHeight: 32, isAccepted: false
        )
        #expect(image.detailLine.contains("4294967297 × 32 px"))
    }

    @Test("The too-many-pixels finding names the declared size whole")
    func tooManyPixelsFindingPrintsWhole() throws {
        let review = try review("""
        {"name": "Dot", "markupType": "count", "measurementTool": "count",
         "embeddedImage": {"fileName": "d.png", "format": "png", "pixelWidth": 4294967297,
                           "pixelHeight": 8, "base64Data": "QQ=="}}
        """)
        let finding = try #require(review.findings.first { $0.code == .embeddedImageTooManyPixels })
        #expect(finding.message.contains("4294967297"))
    }

    /// Old output: "…until you pick a tool for it" / "…until you change it" on a preset that
    /// arrives read-only and cannot be edited.
    @Test("Findings on a read-only import point at Duplicate")
    func findingsPointAtDuplicate() throws {
        let review = try review("""
        {"name": "Odd", "markupType": "measurement", "measurementTool": "volume2", "displayLengthUnit": "feet"}
        """)
        #expect(review.presets[0].isReadOnly)
        let messages = review.findings
            .filter { $0.code == .unknownMeasurementTool || $0.code == .unknownDisplayUnit }
            .map(\.message)
        #expect(messages.count == 2)
        for message in messages {
            #expect(message.contains("duplicate it into My Tools"))
            #expect(!message.contains("until you"))
        }
    }

    /// Old output: no finding at all; the tool arrived without its depth and the review was
    /// silent. A fractional pixel width became 0 and passed every check.
    @Test("A parameter written as text, or a fractional pixel size, is reported")
    func nonNumericIsReported() throws {
        let review = try review("""
        {"name": "Slab", "markupType": "count", "measurementTool": "count",
         "measurementDefaults": {"depthMetres": "0.2", "slopePercent": true},
         "embeddedImage": {"fileName": "d.png", "format": "png", "pixelWidth": 100.5,
                           "pixelHeight": 8, "base64Data": "QQ=="}}
        """)
        let messages = review.findings.filter { $0.code == .valueOutOfRange }.map(\.message)
        #expect(messages.contains { $0.contains("depthMetres") && $0.contains("not a number") })
        #expect(messages.contains { $0.contains("slopePercent") && $0.contains("not a number") })
        #expect(messages.contains { $0.contains("not a whole number") })
        #expect(review.embeddedImages.first?.isAccepted == false)
        #expect(review.presets[0].measurementDefaults.depth == nil)
    }

    /// Old output: `.failure` — "The file is not valid JSON" — for the whole file.
    @Test("One number outside Double range costs that field, not the file")
    func hugeNumberCostsOneField() throws {
        let review = try review("""
        {"name": "Roof", "markupType": "measurement", "measurementTool": "trueSlopedArea",
         "measurementDefaults": {"slopePercent": 1e400, "slopeAzimuthDegrees": 90}},
        {"name": "Note \\"1e400\\"", "markupType": "measurement", "measurementTool": "length"}
        """)
        #expect(review.presets.count == 2)
        #expect(review.presets[0].measurementDefaults.slopePercent == nil)
        #expect(review.presets[0].measurementDefaults.slopeAzimuthDegrees == 90)
        #expect(review.presets[1].name == "Note \"1e400\"", "text inside a string is never touched")
        #expect(review.findings.contains { $0.code == .valueOutOfRange && $0.message.contains("slopePercent") })
    }

    @Test("Bytes that are not JSON are still refused")
    func garbageIsStillRefused() {
        #expect(throws: (any Error).self) { try ToolSetJSONValue.parse(Data("{1e400".utf8)) }
        #expect(ToolSetJSONValue.quotingUnrepresentableNumbers(in: Data("[1, 2.5, -3e2]".utf8)) == nil)
    }
}

// MARK: - Export round trip of a stamp (BH-319)

@Suite("Tool set export of stamps, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2ToolSetStampExportTests {

    private func stampPreset() -> ToolPresetSummary {
        let id = UUID()
        return ToolPresetSummary(
            id: id,
            name: "Approved",
            category: "Stamps",
            panel: .myTools,
            markupKind: .stamp,
            colorRGBA: ColorRGBA.Zenit.Dark.green,
            defaultSubject: "Approval",
            stamp: StampTemplate(
                id: id,
                widthPoints: 144,
                heightPoints: 48,
                rotationDegrees: 15,
                artwork: ToolLibraryFixtures.artwork,
                fields: [
                    StampFieldDefinition(kind: .date, dateFormat: "yyyy-MM-dd"),
                    StampFieldDefinition(kind: .freeText, slot: 1, prompt: "Checked by",
                                         normalizedFrame: PDFRectValue(x: 0.1, y: 0.5, width: 0.8, height: 0.4),
                                         fontSizeFraction: 0.3, alignment: .center)
                ]
            )
        )
    }

    /// Old output: the file carried no stamp and no finding — the recipient's preset had
    /// `stamp == nil` and the review listed nothing.
    @Test("A stamp's box and fields survive export, and a picture left behind is reported")
    func stampRoundTrip() throws {
        let source = stampPreset()
        let model = ToolLibraryEditingModel(presets: [source])
        #expect(model.presetsLeavingArtworkBehind(panel: .myTools) == ["Approved"])
        let data = try model.exportDocument(panel: .myTools, name: "Stamps").jsonData()
        guard case let .success(review) = ToolSetImportValidator().review(data: data, fileName: "Stamps.zpdftools") else {
            Issue.record("expected a review"); return
        }
        let arrived = try #require(review.presets.first?.stamp)
        #expect(arrived.id == review.presets.first?.id)
        #expect(arrived.widthPoints == 144 && arrived.heightPoints == 48 && arrived.rotationDegrees == 15)
        #expect(arrived.artwork == nil)
        #expect(arrived.fields.map(\.kind) == [.date, .freeText])
        #expect(arrived.fields[1].prompt == "Checked by")
        #expect(arrived.fields[1].normalizedFrame == PDFRectValue(x: 0.1, y: 0.5, width: 0.8, height: 0.4))
        #expect(arrived.fields[1].alignment == .center)
        #expect(arrived.fields[0].dateFormat == "yyyy-MM-dd")
        let finding = try #require(review.findings.first { $0.code == .artworkNotIncluded })
        #expect(finding.message.contains("Seal.pdf"))
        #expect(!review.findings.contains { $0.code == .unknownField })
    }

    @Test("A picture the host can supply travels as the embedded image")
    func pictureTravelsWithExporter() throws {
        let model = ToolLibraryEditingModel(presets: [stampPreset()])
        model.artworkExporter = { _ in
            ToolSetEmbeddedImageRecord(fileName: "seal.png", format: "png", pixelWidth: 8, pixelHeight: 8, base64Data: "iVBORw0KGgo=")
        }
        #expect(model.presetsLeavingArtworkBehind(panel: .myTools).isEmpty)
        let data = try model.exportDocument(panel: .myTools, name: "Stamps").jsonData()
        guard case let .success(review) = ToolSetImportValidator().review(data: data, fileName: "Stamps.zpdftools") else {
            Issue.record("expected a review"); return
        }
        #expect(review.embeddedImages.first?.isAccepted == true)
        #expect(!review.findings.contains { $0.code == .artworkNotIncluded })
    }

    @Test("An implausible stamp box or field is left out and reported")
    func hostileStampIsBounded() throws {
        let raw = """
        {"schemaVersion": 1, "name": "S", "presets": [
          {"name": "A", "markupType": "stamp", "stamp": {"widthPoints": 1e9, "heightPoints": 10}},
          {"name": "B", "markupType": "stamp", "stamp": {"widthPoints": 100, "heightPoints": 40,
            "fields": [{"kind": "date", "frameX": 0.5, "frameY": 0, "frameWidth": 0.9, "frameHeight": 0.2,
                        "fontSizeFraction": 0.2}, {"kind": "shellCommand"}]}}]}
        """
        guard case let .success(review) = ToolSetImportValidator().review(data: Data(raw.utf8), fileName: "S.zpdftools") else {
            Issue.record("expected a review"); return
        }
        #expect(review.presets[0].stamp == nil)
        #expect(review.presets[1].stamp?.fields.isEmpty == true)
        #expect(review.findings.filter { $0.code == .invalidStamp }.count == 3)
    }
}

// MARK: - Re-import: update matching tools (IM-233)

@Suite("Tool set re-import, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2ToolSetReimportTests {

    private func file(_ presets: [(UUID, String)]) -> Data {
        let entries = presets.map { id, category in
            """
            {"id": "\(id.uuidString)", "name": "Tool \(id.uuidString.prefix(4))", "category": "\(category)",
             "markupType": "measurement", "measurementTool": "area"}
            """
        }
        return Data("{\"schemaVersion\": 1, \"name\": \"Office\", \"presets\": [\(entries.joined(separator: ","))]}".utf8)
    }

    @Test("Update Matching refreshes tools in place; Keep Both adds copies; one undo step")
    func updateMatching() throws {
        let ids = (0..<3).map { _ in UUID() }
        let model = ToolLibraryEditingModel()
        var steps: [ToolLibraryUndoStep] = []
        model.onUndoableChange = { steps.append($0) }
        model.beginImport(data: file(ids.map { ($0, "Old") }), fileName: "Office.zpdftools")
        model.confirmImport()
        #expect(model.presets.count == 3)
        model.toggleFavorite(id: ids[1])

        // The revised file: same three tools recategorised, plus one new one.
        let newID = UUID()
        model.beginImport(data: file(ids.map { ($0, "Revised") } + [(newID, "Revised")]), fileName: "Office.zpdftools")
        let review = try #require(model.importReview)
        #expect(review.libraryMatches.count == 3)
        #expect(ToolSetImportReviewSheet.offersStrategy(review: review, canChoose: true))
        #expect(!ToolSetImportReviewSheet.offersStrategy(review: review, canChoose: false))
        model.confirmImport(strategy: .updateMatching)

        #expect(model.presets.count == 4, "three updated in place, one added")
        #expect(Set(model.presets.map(\.id)).isSuperset(of: ids))
        #expect(model.presets.filter { ids.contains($0.id) }.allSatisfy { $0.category == "Revised" })
        #expect(model.presets.first { $0.id == ids[1] }?.isFavorite == true, "the favourite survives")

        let step = try #require(steps.last)
        model.revert(step)
        #expect(model.presets.count == 3)
        #expect(model.presets.allSatisfy { $0.category == "Old" })

        // Keep Both is still the default and still adds a second copy of each.
        model.beginImport(data: file(ids.map { ($0, "Revised") }), fileName: "Office.zpdftools")
        model.confirmImport()
        #expect(model.presets.count == 6)
    }
}
