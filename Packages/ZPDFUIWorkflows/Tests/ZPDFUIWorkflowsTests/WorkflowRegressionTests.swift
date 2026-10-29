import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

// MARK: - Tool Library ordering and identity

/// CR-168, CR-172 and CR-180: what the Tool Library does to the order and the identities it
/// holds when something other than a plain edit happens to it.
@Suite("Tool Library ordering and identity", .workflowsTierSerialised)
@MainActor
struct ToolLibraryOrderingRegressionTests {

    private func preset(
        _ name: String,
        category: String = "Concrete",
        panel: ToolLibraryPanel = .myTools,
        sortIndex: Int
    ) -> ToolPresetSummary {
        ToolPresetSummary(
            id: UUID(),
            name: name,
            category: category,
            panel: panel,
            markupKind: .measurement,
            measurementKind: .area,
            colorRGBA: ColorRGBA.Zenit.Dark.cyan,
            defaultSubject: name,
            sortIndex: sortIndex
        )
    }

    private func order(_ model: ToolLibraryEditingModel) -> [String] {
        model.presets(in: .myTools).map(\.name)
    }

    // MARK: CR-168

    /// Old output: `["A", "B", "C"]`. `move` rewrites `sortIndex` and never touches the flat
    /// array; `renumber` read the flat array. So the first duplicate after any manual reorder
    /// silently put the order back the way it was — and the ⌥1–9 slots, which are positional,
    /// went with it.
    @Test("A duplicate does not undo a manual reorder")
    func duplicateKeepsTheManualOrder() {
        let a = preset("A", sortIndex: 0)
        let b = preset("B", sortIndex: 1)
        let c = preset("C", sortIndex: 2)
        let model = ToolLibraryEditingModel(presets: [a, b, c])

        model.move(id: c.id, to: 0)
        #expect(order(model) == ["C", "A", "B"])

        model.duplicate(id: a.id)
        #expect(order(model) == ["C", "A", "A copy", "B"], "the manual reorder was reverted")
        #expect(Set(model.presets.map(\.sortIndex)).count == 4, "no two tools are left tied")
    }

    /// The copy lands next to the original wherever the original happens to be.
    @Test("A duplicate lands directly after its original, in sibling order")
    func duplicateLandsAfterItsOriginal() {
        let a = preset("A", sortIndex: 0)
        let b = preset("B", sortIndex: 1)
        let c = preset("C", sortIndex: 2)
        let model = ToolLibraryEditingModel(presets: [a, b, c])

        model.duplicate(id: b.id)
        #expect(order(model) == ["A", "B", "B copy", "C"])
        #expect(model.presets(in: .myTools).map(\.sortIndex) == [0, 1, 2, 3])
    }

    /// Renumbering is per category, so a duplicate in one leaves the other alone.
    @Test("Renumbering one category does not touch another")
    func renumberIsPerCategory() {
        let a = preset("A", sortIndex: 0)
        let b = preset("B", sortIndex: 1)
        let steel = preset("S", category: "Steel", sortIndex: 7)
        let model = ToolLibraryEditingModel(presets: [a, b, steel])

        model.duplicate(id: a.id)
        #expect(model.presets.first { $0.name == "S" }?.sortIndex == 7)
    }

    // MARK: CR-180

    /// Old output: sort indexes `[0, 1, 1, 2]`. Undo inserted at the flat-array index recorded
    /// at delete time and never touched the numbering, so the restored tool came back sharing a
    /// `sortIndex` with the tool that had taken its slot while it was away. Two siblings on one
    /// index means the sidebar's sort has no defined order between them and the ⌥1–9 slots
    /// collide — the "T4 lands before T3" the finding names.
    @Test("Undo restores the sibling numbering, not just the row")
    func undoDeleteRestoresSiblingNumbering() {
        let a = preset("A", sortIndex: 0)
        let b = preset("B", sortIndex: 1)
        let c = preset("C", sortIndex: 2)
        let model = ToolLibraryEditingModel(presets: [a, b, c])

        model.delete(id: b.id)
        #expect(order(model) == ["A", "C"])

        // Anything at all between the delete and the Undo moves the array under the recorded
        // index and takes the slot the deleted tool is holding. A duplicate of the tool above
        // it is the mildest version of that: the copy is given B's own sort index.
        model.duplicate(id: a.id)
        #expect(order(model) == ["A", "A copy", "C"])
        #expect(model.presets(in: .myTools).map(\.sortIndex) == [0, 1, 2])

        model.undoDelete()
        #expect(model.presets.count == 4)
        #expect(model.presets(in: .myTools).map(\.sortIndex) == [0, 1, 2, 3])
        #expect(
            Set(model.presets(in: .myTools).map(\.sortIndex)).count == 4,
            "two tools share a sort index, so the sidebar order between them is undefined"
        )
        #expect(order(model).contains("B"))
        #expect(order(model).first == "A")
        #expect(order(model).last == "C", "B came back outside the pair it sat between")
        #expect(model.pendingDeletion == nil)
    }

    /// The simple case still works, and Undo restores the numbering rather than leaving a gap.
    @Test("Undo with nothing in between restores the numbering too")
    func undoDeleteRestoresNumbering() {
        let a = preset("A", sortIndex: 0)
        let b = preset("B", sortIndex: 1)
        let c = preset("C", sortIndex: 2)
        let model = ToolLibraryEditingModel(presets: [a, b, c])

        model.delete(id: a.id)
        model.undoDelete()
        #expect(order(model) == ["A", "B", "C"])
        #expect(model.presets(in: .myTools).map(\.sortIndex) == [0, 1, 2])
    }

    // MARK: CR-172

    /// Old output: `Set(ids).count == 2` for four presets. `confirmImport` appended the
    /// review's presets with the identities the file declared, so importing the same
    /// `.zpdftools` twice put two presets under one `UUID` into the library. `ForEach` keys on
    /// that id, so delete, favourite and edit all landed on whichever one SwiftUI kept.
    @Test("Importing the same tool set twice does not produce duplicate identities")
    func importingTwiceMintsFreshIdentities() throws {
        let document = ToolSetDocument(
            name: "Site Concrete",
            exporting: [
                preset("Concrete Area", sortIndex: 0),
                preset("Door Count", sortIndex: 1)
            ]
        )
        let data = try document.jsonData()
        let model = ToolLibraryEditingModel()

        model.beginImport(data: data, fileName: "Site Concrete.zpdftools")
        model.confirmImport()
        #expect(model.presets.count == 2)

        model.beginImport(data: data, fileName: "Site Concrete.zpdftools")
        let review = try #require(model.importReview)
        #expect(
            review.findings.contains { $0.code == .duplicateIdentifier },
            "the second import was not described as colliding with the library"
        )
        model.confirmImport()

        #expect(model.presets.count == 4)
        #expect(
            Set(model.presets.map(\.id)).count == 4,
            "two tools share an identity, so ForEach cannot tell them apart"
        )
    }

    /// The validator reports the collision on its own, so a host that does not re-mint still
    /// gets told, and the re-mint does not lose anything off the preset.
    @Test("The validator re-mints against the library it is importing into")
    func validatorSeedsFromTheLibrary() throws {
        let source = preset("Concrete Area", sortIndex: 0)
        let data = try ToolSetDocument(name: "One", exporting: [source]).jsonData()
        let validator = ToolSetImportValidator()

        guard case let .success(clean) = validator.review(data: data, fileName: "One.zpdftools")
        else { Issue.record("the fixture did not review"); return }
        #expect(clean.presets.first?.id == source.id, "an uncontested identity is kept")

        guard case let .success(colliding) = validator.review(
            data: data,
            fileName: "One.zpdftools",
            existingIdentifiers: [source.id]
        ) else { Issue.record("the fixture did not review"); return }
        #expect(colliding.presets.first?.id != source.id)
        #expect(colliding.presets.first?.name == "Concrete Area")
        #expect(colliding.findings.contains { $0.code == .duplicateIdentifier })
    }
}

// MARK: - Tool preset parameter fields

/// CR-183 and CR-184: what the preset editor puts in a length box and reads back out of it.
@Suite("Tool preset parameter fields", .workflowsTierSerialised)
struct ToolPresetParameterRegressionTests {

    /// Old output: "0.65616797900262467191601049868766404". The raw `Decimal` division was put
    /// straight into the text field, so a 0.2 m depth read in feet filled the box with
    /// thirty-five digits.
    @Test("A length reads out rounded, not to thirty-five digits")
    func lengthTextIsRounded() {
        let depth = DecimalQuantity(value: Decimal(string: "0.2")!, dimension: .length)

        let inFeet = ToolPresetLengthField.text(from: depth, unit: .foot)
        #expect(inFeet == "0.656168")
        #expect(inFeet.count <= 10)

        #expect(ToolPresetLengthField.text(from: depth, unit: .metre) == "0.2")
        #expect(ToolPresetLengthField.text(from: nil, unit: .metre) == "")

        let tall = DecimalQuantity(value: Decimal(string: "2.7")!, dimension: .length)
        #expect(ToolPresetLengthField.text(from: tall, unit: .foot) == "8.858268")
    }

    /// Rounding is display only. The stored quantity is what a metric read-out gives back.
    @Test("The stored value is not rounded, only the string is")
    func roundingDoesNotReachTheStoredValue() {
        let depth = DecimalQuantity(value: Decimal(string: "0.2")!, dimension: .length)
        let text = ToolPresetLengthField.text(from: depth, unit: .metre)
        #expect(ToolPresetLengthField.quantity(from: text, unit: .metre)?.value == depth.value)
    }

    /// Old output: under a comma-decimal keyboard `1,234` here was 1.234 while the numeric
    /// field two rows up read the same text as 1234 — a factor of a thousand between two boxes
    /// in one sheet.
    @Test("The two parameter fields read a number the way every other Zenit field does")
    func parameterFieldsShareOneGrammar() {
        #expect(ToolPresetNumberField.number(from: "12,5") == 12.5)
        #expect(ToolPresetNumberField.number(from: "12.5") == 12.5)
        #expect(ToolPresetNumberField.number(from: "1,234") == 1.234)
        #expect(ToolPresetNumberField.number(from: "1 200") == 1200)
        #expect(ToolPresetNumberField.number(from: "1,200.50") == nil)
        #expect(ToolPresetNumberField.number(from: "nan") == nil)
        #expect(ToolPresetNumberField.number(from: "inf") == nil)

        #expect(
            ToolPresetLengthField.quantity(from: "12,5", unit: .metre)?.value
                == Decimal(string: "12.5")
        )
        #expect(ToolPresetLengthField.quantity(from: "1 200", unit: .metre)?.value == Decimal(1200))
        #expect(ToolPresetLengthField.quantity(from: "1,200.50", unit: .metre) == nil)
        #expect(ToolPresetLengthField.quantity(from: "nan", unit: .metre) == nil)

        // The two fields and the shared parser agree, text for text.
        for text in ["12,5", "12.5", "1,234", "1 200", "1,200.50", "nan", "abc", "0", "-3.25"] {
            let shared = ZPDFDecimalParser.double(text, allowingExponent: true)
            #expect((ToolPresetNumberField.number(from: text) == nil) == (shared == nil), "\(text)")
            #expect(
                (ToolPresetLengthField.quantity(from: text, unit: .metre) == nil) == (shared == nil),
                "\(text)"
            )
        }
    }
}

// MARK: - OCR run

/// CR-181 and CR-166: what the recognition sheet's progress bar counts, and what it does with a
/// page number that is not a number.
@Suite("OCR run progress and page bounds", .workflowsTierSerialised)
@MainActor
struct OCRRunRegressionTests {

    private func pages(_ count: Int) -> [PageDescriptor] {
        (0..<count).map { index in
            PageDescriptor(
                id: UUID(),
                index: index,
                label: "A-\(index + 1)",
                mediaBox: PDFRectValue(x: 0, y: 0, width: 842, height: 595),
                cropBox: PDFRectValue(x: 0, y: 0, width: 842, height: 595),
                rotation: .degrees0
            )
        }
    }

    /// Old output: `0.5`. The denominator was recomputed from the live selection, so narrowing
    /// the scope to two pages half way through a ten-page run completed the bar over a run that
    /// was still going. Widening it did the reverse and collapsed the bar.
    @Test("The progress denominator is the run that was started, not the current selection")
    func progressDenominatorIsFrozenAtStart() {
        let model = OCRRunModel(pages: pages(10))
        model.rangeSelection = .allPages
        model.start()
        #expect(model.requestedPageCount == 10)

        for index in 0..<5 {
            model.record(OCRPageStatusSummary(
                id: model.pages[index].id,
                pageLabel: model.pages[index].label,
                pageIndex: index,
                status: .indexed
            ))
        }
        #expect(abs(model.progressFraction - 0.5) < 1e-12)

        // Someone narrows the scope while it is running.
        model.rangeSelection = .range(lowerBound: 1, upperBound: 5)
        model.rangeLowerBound = 1
        model.rangeUpperBound = 5
        #expect(model.resolvedPageIndices.count == 5, "the live selection really did change")
        #expect(
            abs(model.progressFraction - 0.5) < 1e-12,
            "the bar completed over a run that was still going"
        )

        model.finish()
        #expect(model.requestedPageCount == nil)
    }

    /// The scope controls are locked for as long as anything is in flight, which is the other
    /// half of the same fix: the sheet must not offer a control that cannot honestly be used.
    @Test("The scope controls are locked while a run is in flight")
    func scopeIsLockedWhileRunning() {
        let model = OCRRunModel(pages: pages(4))
        #expect(model.isScopeEditable)

        model.start()
        #expect(!model.isScopeEditable)

        model.cancel()
        #expect(!model.isScopeEditable, "still finishing the page in flight")

        model.finish()
        #expect(model.isScopeEditable)
    }

    /// Old output: a trap. `Int($0 ?? 1)` on a `Double` that is NaN crashes with "Double value
    /// cannot be converted to Int because it is either infinite or NaN", and the field's parser
    /// produced exactly that from the text "nan" — typing it into "First page" and pressing
    /// Return took the application down.
    @Test("A page bound is never converted from a value that is not a number")
    func pageBoundsAreSafeToConvert() {
        #expect(OCRRunSheet.pageNumber(.nan, pageCount: 10) == 1)
        #expect(OCRRunSheet.pageNumber(.infinity, pageCount: 10) == 1)
        #expect(OCRRunSheet.pageNumber(-.infinity, pageCount: 10) == 1)
        #expect(OCRRunSheet.pageNumber(nil, pageCount: 10) == 1)
        #expect(OCRRunSheet.pageNumber(1e300, pageCount: 10) == 10)
        #expect(OCRRunSheet.pageNumber(-5, pageCount: 10) == 1)
        #expect(OCRRunSheet.pageNumber(3.4, pageCount: 10) == 3)
        #expect(OCRRunSheet.pageNumber(3.6, pageCount: 10) == 4)
        #expect(OCRRunSheet.pageNumber(7, pageCount: 0) == 1)
    }
}

// MARK: - Batch apply

/// CR-182: what the sheet offers after a run that failed part way through.
@Suite("Batch apply after a failure", .workflowsTierSerialised)
@MainActor
struct BatchApplyFailureRegressionTests {

    /// Old output: `model.canApply == true`. `plan` survived the failure and `isRunning` went
    /// false, so Apply lit up again immediately — over the pre-run plan, against a document the
    /// partial run had already written to. Pressing it a second time would have placed the
    /// stamps the first run did place all over again.
    @Test("A failed run drops the plan, so Apply cannot re-run a stale count")
    func aFailedRunClearsThePlan() async {
        let model = BatchApplyModel()
        model.onPlan = { _ in BatchApplyModelTests.plan(placements: 312) }
        var closes = 0
        model.onClose = { closes += 1 }
        model.onRun = { _, _ in
            BatchApplyReceipt(
                createdMarkupIDs: (0..<40).map { _ in UUID() },
                failureMessage: "The drawing could not be written to after 40 pages."
            )
        }

        model.preview()
        #expect(model.canApply)

        await model.run()

        #expect(model.receipt?.failureMessage != nil)
        #expect(model.plan == nil, "the pre-run plan survived a run that changed the document")
        #expect(!model.canApply, "Apply was live again over a stale count")
        #expect(closes == 0, "a failed run does not close the sheet")

        // Previewing again is the way back, and it re-enables Apply.
        model.preview()
        #expect(model.canApply)
    }

    /// A cancelled run wrote nothing, so its plan still describes the document it was made for.
    @Test("A cancelled run keeps its plan, because nothing was written")
    func aCancelledRunKeepsThePlan() async {
        let model = BatchApplyModel()
        model.onPlan = { _ in BatchApplyModelTests.plan(placements: 12) }
        model.onRun = { _, _ in BatchApplyReceipt.cancelled }

        model.preview()
        await model.run()

        #expect(model.plan != nil)
        #expect(model.canApply)
    }
}

// MARK: - Table import

/// CR-192: a row the engine produced with fewer cells than there are columns.
@Suite("Table import over a ragged grid", .workflowsTierSerialised)
struct TableImportRaggedRowRegressionTests {

    static func raggedSchedule() -> TableImportReviewTable {
        TableImportReviewTable(
            columns: [
                .init(index: 0, title: "Door", headerWasPrinted: true),
                .init(index: 1, title: "Width", headerWasPrinted: true),
                .init(index: 2, title: "Material", headerWasPrinted: true)
            ],
            rows: [
                .init(
                    cells: [.init(text: "D1"), .init(text: "910"), .init(text: "Oak")],
                    sourceText: "D1 910 Oak"
                ),
                // One cell short: the third column never came back from the engine.
                .init(cells: [.init(text: "D2"), .init(text: "PLAN 2")], sourceText: "D2 PLAN 2"),
                // Nothing at all.
                .init(cells: [], sourceText: "")
            ],
            columnOrigin: .ruleLines,
            unplacedTexts: []
        )
    }

    /// Old output: a crash. `rows[r].cells[index]` in `unparsedRowIndexes` and
    /// `model.rows[rowIndex].cells[columnIndex]` in the view both subscripted straight into a
    /// row that was short, and Swift traps on an out-of-range array index — the whole review
    /// panel went down on one ragged row.
    @MainActor
    @Test("A short row is read as a missing cell rather than an index out of range")
    func aRaggedRowDoesNotTrap() {
        let model = TableImportReviewModel(
            table: Self.raggedSchedule(),
            onAccept: { _ in },
            onCancel: {}
        )
        model.columnKinds = [.text, .number, .text]

        // The flag pass walks every row of every column, which is where it used to trap.
        #expect(model.unparsedRowIndexes(forColumn: 2).isEmpty)
        #expect(model.unparsedRowIndexes(forColumn: 1) == [1], "D2's \"PLAN 2\" is the only cell there to flag")
        #expect(model.flaggedCellCount == 1)

        // And the accessor the grid draws through answers for every coordinate it can be asked.
        #expect(model.cell(row: 0, column: 2)?.text == "Oak")
        #expect(model.cell(row: 1, column: 2) == nil)
        #expect(model.cell(row: 2, column: 0) == nil)
        #expect(model.cell(row: 99, column: 0) == nil)
        #expect(model.cell(row: -1, column: 0) == nil)
        #expect(model.cell(row: 0, column: 99) == nil)
    }

    /// A missing cell is not an unread cell and is not a failed number claim; the three are
    /// different facts and the panel says so.
    @MainActor
    @Test("A missing cell is not counted as a cell that failed its number claim")
    func aMissingCellIsNotAFailedClaim() {
        let model = TableImportReviewModel(
            table: Self.raggedSchedule(),
            onAccept: { _ in },
            onCancel: {}
        )
        model.columnKinds = [.text, .text, .number]
        // Row 0 has "Oak" there and it is not a number, so it is flagged. Rows 1 and 2 have no
        // cell in that column at all, and an absent cell makes no claim to fail.
        #expect(model.unparsedRowIndexes(forColumn: 2) == [0])
        #expect(!model.isCellFlagged(row: 1, column: 2))
        #expect(!model.isCellFlagged(row: 2, column: 2))
    }
}

// MARK: - Import validator

/// CR-186: a length that clears every guard and then does not convert.
@Suite("Tool set import: a length that will not convert", .workflowsTierSerialised)
struct ToolSetImportDepthRegressionTests {

    /// Old output: `depth?.value == 0`. `Decimal(string: String(1e-300))` is nil — the `String`
    /// of that `Double` is "1e-300", which `Decimal(string:)` will not read — and the `?? 0`
    /// behind it stored a depth of exactly zero as if the exporter had written one. It passed
    /// the finite check, passed the range check, and produced a volume of nothing.
    @Test("A length that does not convert is dropped and reported, never turned into zero")
    func anUnconvertibleDepthIsNotZeroed() throws {
        let raw = """
        {
          "schemaVersion": 1,
          "name": "Tiny",
          "presets": [{
            "id": "\(UUID().uuidString)",
            "name": "Screed",
            "category": "Floors",
            "markupType": "measurement",
            "measurementTool": "volume",
            "color": "#50D6DE",
            "defaultSubject": "Screed",
            "measurementDefaults": { "depthMetres": 1e-300 }
          }]
        }
        """
        let validator = ToolSetImportValidator()
        guard case let .success(review) = validator.review(
            data: Data(raw.utf8),
            fileName: "Tiny.zpdftools"
        ) else { Issue.record("the fixture did not review"); return }

        let preset = try #require(review.presets.first)
        #expect(preset.measurementDefaults.depth == nil, "a fabricated zero arrived as a depth")
        #expect(
            review.findings.contains { $0.code == .valueOutOfRange },
            "the dropped value was not reported"
        )
    }

    /// A length that does convert still arrives, exactly.
    @Test("A length that converts arrives unchanged")
    func aConvertibleDepthSurvives() throws {
        let raw = """
        {
          "schemaVersion": 1,
          "name": "Slab",
          "presets": [{
            "id": "\(UUID().uuidString)",
            "name": "Slab 200",
            "category": "Concrete",
            "markupType": "measurement",
            "measurementTool": "volume",
            "color": "#50D6DE",
            "defaultSubject": "Slab",
            "measurementDefaults": { "depthMetres": 0.2 }
          }]
        }
        """
        let validator = ToolSetImportValidator()
        guard case let .success(review) = validator.review(
            data: Data(raw.utf8),
            fileName: "Slab.zpdftools"
        ) else { Issue.record("the fixture did not review"); return }

        let preset = try #require(review.presets.first)
        #expect(preset.measurementDefaults.depth?.value == Decimal(string: "0.2"))
    }
}
