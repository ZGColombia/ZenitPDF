import Foundation
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// BH-313, IM-034 and IM-153: the table import review's number flags are computed once, and
/// the review suggests Number and a subject column instead of making the person click them.
@Suite("Table import review, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2TableImportTests {

    private func table(rows: Int, columns: Int, cell: (Int, Int) -> String) -> TableImportReviewTable {
        TableImportReviewTable(
            columns: (0..<columns).map { .init(index: $0, title: "C\($0)", headerWasPrinted: true) },
            rows: (0..<rows).map { row in
                .init(cells: (0..<columns).map { .init(text: cell(row, $0)) }, sourceText: "")
            },
            columnOrigin: .ruleLines,
            unplacedTexts: []
        )
    }

    /// Old output: every `isCellFlagged` call re-ran `unparsedRowIndexes`, parsing the whole
    /// column — 500 × 500 × 8 = 2 000 000 parses to draw one 500 × 8 grid once. Now every read
    /// cell is parsed exactly once, at construction, whatever the grid asks afterwards.
    @Test("Drawing a 500 x 8 grid of number columns parses each cell once")
    func flagCacheIsLinear() {
        let model = TableImportReviewModel(
            table: table(rows: 500, columns: 8) { row, _ in row % 50 == 0 ? "PLAN" : "\(row)" },
            onAccept: { _ in },
            onCancel: {}
        )
        model.columnKinds = Array(repeating: .number, count: 8)
        var flagged = 0
        for row in 0..<500 {
            for column in 0..<8 where model.isCellFlagged(row: row, column: column) {
                flagged += 1
            }
        }
        #expect(flagged == 80)
        #expect(model.flaggedCellCount == 80)
        #expect(model.unparsedRowIndexes(forColumn: 3) == stride(from: 0, to: 500, by: 50).map { $0 })
        #expect(model.cellParseCount == 4_000, "one parse per read cell, not per cell per cell")
        // The flags still follow the kind: a text column claims nothing.
        model.columnKinds[3] = .text
        #expect(!model.isCellFlagged(row: 0, column: 3))
        #expect(model.unparsedRowIndexes(forColumn: 3).isEmpty)
        #expect(model.flaggedCellCount == 70)
    }

    /// Old output: `columnKinds == [.text, .text]` and `subjectColumnIndex == 0` whatever the
    /// schedule held.
    @Test("A quantity column starts as Number and the subject starts on the mark column")
    func suggestsNumberAndSubject() throws {
        var received: TableImportReviewOutcome?
        let model = TableImportReviewModel(
            table: table(rows: 10, columns: 3) { row, column in
                switch column {
                case 0: return "\(row + 1)"           // a position number: numeric
                case 1: return "D\(row)"              // the mark: text
                default: return row == 9 ? "" : "\(row * 2),5" // quantities, one unread
                }
            },
            onAccept: { received = $0 },
            onCancel: {}
        )
        #expect(model.columnKinds == [.number, .text, .number])
        #expect(model.subjectColumnIndex == 1)
        model.subjectColumnIndex = 2
        model.accept()
        let outcome = try #require(received)
        #expect(outcome.subjectColumnIndex == 2)
        #expect(outcome.columns.map(\.kind) == [.number, .text, .number])
    }

    @Test("A column under nine in ten parsing stays Text")
    func mostlyTextStaysText() {
        let model = TableImportReviewModel(
            table: table(rows: 10, columns: 1) { row, _ in row < 8 ? "\(row)" : "N/A" },
            onAccept: { _ in },
            onCancel: {}
        )
        #expect(model.columnKinds == [.text])
        #expect(model.subjectColumnIndex == 0)
    }
}

/// BH-314: the review legend promises nothing the Quantity Ledger does not do.
@Suite("Table import legend, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2TableImportLegendTests {
    /// Old output: "…The ⌐ mark stays on these rows in the Quantity Ledger and in every export."
    @Test("The legend does not promise a ledger mark the ledger never draws")
    func legendIsTrue() {
        let text = TableImportReviewModel.readRowLegendText
        #expect(!text.contains("Quantity Ledger"))
        #expect(text.contains("⌐"))
        #expect(text.contains("not measured"))
    }
}

/// IM-146: tool-set file failures say what went wrong and offer an action that exists.
@Suite("Tool set file errors, bug hunt 2", .workflowsTierSerialised)
struct BugHunt2ToolSetFileErrorTests {

    /// Old output: `.toolSetImportRejected` for every failure — a message hiding the size in
    /// the technical detail and a primary action "Review What the File Contains" with no review.
    @Test("An oversize file names the limit; no file failure offers a review that does not exist")
    func fileErrorsAreActionable() {
        var limits = ToolSetImportValidator.Limits.standard
        limits.maximumFileByteCount = 1_000_000
        guard case let .failure(big) = ToolSetImportValidator(limits: limits)
            .review(data: Data(repeating: 32, count: 1_000_001), fileName: "Big.zpdftools") else {
            Issue.record("expected a failure"); return
        }
        let limit = ByteCountFormatter.string(fromByteCount: 1_000_000, countStyle: .file)
        let bigCopy = ZPDFErrorCopyTable.copy(for: big)
        #expect(big.kind == .toolSetFileTooLarge)
        #expect(bigCopy.message.contains(limit))
        #expect(bigCopy.message.contains("Big.zpdftools"))

        guard case let .failure(bad) = ToolSetImportValidator()
            .review(data: Data("nope".utf8), fileName: "X.zpdftools") else {
            Issue.record("expected a failure"); return
        }
        #expect(bad.kind == .toolSetFileUnreadable)
        for kind in [ZPDFErrorKind.toolSetFileTooLarge, .toolSetFileUnreadable, .toolSetImportRejected] {
            let copy = ZPDFErrorCopyTable.copy(for: ZPDFUserFacingError(kind: kind))
            #expect(copy.primaryActionTitle == "Choose Another File")
            #expect(!copy.primaryActionTitle.contains("Review"))
        }
        let picture = ZPDFErrorCopyTable.copy(for: ZPDFUserFacingError(kind: .toolSetPictureNotKept, subject: "dot.png"))
        #expect(picture.message.contains("added without it"))
        #expect(!picture.isBlocking)
    }
}

/// BH-833: a fallback noun substituted mid-sentence is not capitalised.
@Suite("Error copy fallback nouns, bug hunt 2", .workflowsTierSerialised)
struct BugHunt2ErrorFallbackTests {
    /// Old output: "The scale on This page was calibrated…", "The disk holding The folder you
    /// chose filled up…".
    @Test("A fallback noun that lands mid-sentence starts in lower case")
    func midSentenceFallbacksAreLowerCase() {
        for kind in ZPDFErrorKind.allCases {
            let copy = ZPDFErrorCopyTable.copy(for: ZPDFUserFacingError(kind: kind, subject: " "))
            let fallback = ZPDFErrorCopyTable.fallbackSubject(for: kind)
            guard !copy.message.hasPrefix(fallback), let first = fallback.first else { continue }
            #expect(!first.isUppercase, "\(kind.rawValue): \(copy.message)")
        }
        let stale = ZPDFErrorCopyTable.copy(for: ZPDFUserFacingError(kind: .scaleStale))
        #expect(stale.message.hasPrefix("The scale on this page"))
        let full = ZPDFErrorCopyTable.copy(for: ZPDFUserFacingError(kind: .exportInsufficientSpace))
        #expect(full.message.hasPrefix("The disk holding the folder you chose"))
    }
}

/// BH-834: leaving every mode terminates even when an exit route re-enters a mode.
@Suite("Mode exit, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2ModeExitTests {
    /// Old output: `exitAll()` never returned — each exit registered the mode again.
    @Test("exitAll ends empty when an exit route re-registers a mode")
    func exitAllIsBounded() {
        let registry = ZPDFModeExitRegistry()
        var exits = 0
        func route() -> ZPDFModeExitRoute {
            ZPDFModeExitRoute(menuTitle: "Close Overlay", keyboardHint: "Esc") {
                exits += 1
                registry.register(id: "overlay", displayName: "Overlay", exitRoute: route())
            }
        }
        registry.register(id: "overlay", displayName: "Overlay", exitRoute: route())
        registry.register(id: "split", displayName: "Split", exitRoute: ZPDFModeExitRoute(menuTitle: "Close Split", keyboardHint: "Esc") {})
        registry.exitAll()
        #expect(!registry.hasActiveMode)
        #expect(exits > 0 && exits <= 2 + ZPDFModeExitRegistry.reentryAllowance)
    }
}

/// BH-845: every markup family has a chosen glyph, and text markups read as text.
@Suite("Workflow glyphs, bug hunt 2", .workflowsTierSerialised)
struct BugHunt2WorkflowGlyphTests {
    /// Old output: highlight, underline and strikeout fell into `default` and drew as shapes.
    @Test("Text markups get the text glyph; shape markups the shapes glyph")
    func textMarkupsReadAsText() {
        for kind in [MarkupKind.highlight, .underline, .strikeout] {
            #expect(WorkflowGlyphs.glyph(for: kind) == .symbol(.text))
        }
        for kind in [MarkupKind.line, .arrow, .polygon, .freehand] {
            #expect(WorkflowGlyphs.glyph(for: kind) == .symbol(.shapes))
        }
    }
}

/// IM-228: blocking-ness is a property of the situation, not of built copy.
@Suite("Error blocking classification, bug hunt 2", .workflowsTierSerialised)
struct BugHunt2ErrorBlockingTests {
    @Test("isBlocking is stated per kind and the copy table agrees")
    @MainActor
    func blockingIsAKindProperty() {
        // The set the copy table carried as literals before IM-228.
        let blocking: Set<ZPDFErrorKind> = [
            .documentUnreadable, .documentEncrypted, .documentPasswordRejected, .scaleMissing,
            .exportPathNotWritable, .exportInsufficientSpace, .toolSetImportRejected,
            .revisionAlignmentRejected
        ]
        for kind in ZPDFErrorKind.allCases {
            #expect(kind.isBlocking == blocking.contains(kind), "\(kind.rawValue)")
            #expect(kind.isBlocking == ZPDFErrorCopyTable.copy(for: ZPDFUserFacingError(kind: kind)).isBlocking)
        }
    }
}

/// IM-231: a long schedule's rows are built lazily.
@Suite("Table import lazy rows, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2TableImportLazyTests {

    private func model(rows: Int) -> TableImportReviewModel {
        TableImportReviewModel(
            table: TableImportReviewTable(
                columns: (0..<6).map { .init(index: $0, title: "Column \($0)", headerWasPrinted: true) },
                rows: (0..<rows).map { row in
                    .init(cells: (0..<6).map { .init(text: "R\(row)C\($0) value") }, sourceText: "")
                },
                columnOrigin: .ruleLines,
                unplacedTexts: []
            ),
            onAccept: { _ in },
            onCancel: {}
        )
    }

    @Test("Past the threshold the grid is lazy, with fixed widths that fit the text")
    func longSchedulesAreLazy() {
        #expect(!model(rows: 200).usesLazyRows)
        let long = model(rows: 1_000)
        #expect(long.usesLazyRows)
        #expect(long.columnWidth(forColumn: 0) >= 96 && long.columnWidth(forColumn: 0) <= 320)
        #expect(long.columnWidth(forColumn: 99) == 96)
    }

    /// Offscreen render (ImageRenderer, no window) of a 1 000-row proposal, eager Grid versus
    /// lazy rows. The eager grid builds all 6 000 cells before the first frame.
    @Test("Rendering a 1 000-row review is faster with lazy rows")
    func lazyRowsRenderFaster() {
        let clock = ContinuousClock()
        func renderTime(_ model: TableImportReviewModel) -> Duration {
            clock.measure {
                let renderer = ImageRenderer(content: TableImportReviewView(model: model).frame(width: 560, height: 600))
                _ = renderer.cgImage
            }
        }
        let eager = model(rows: 1_000)
        eager.lazyRowThreshold = .max
        let lazy = model(rows: 1_000)
        let eagerTime = renderTime(eager)
        let lazyTime = renderTime(lazy)
        print("IM-231 measurement: 1000-row first render, eager Grid \(eagerTime) vs lazy rows \(lazyTime)")
        #expect(lazyTime < eagerTime)
    }
}
