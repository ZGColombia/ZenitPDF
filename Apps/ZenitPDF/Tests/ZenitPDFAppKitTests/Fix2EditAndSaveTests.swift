import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// Bug hunt 2: one-gesture-one-undo edits, change counting, the light autosave paths and the
/// CSV field policy.
@MainActor
@Suite(.appTierSerialised)
struct Fix2EditAndSaveTests {

    private func addLengths(_ harness: Fix2Harness, count: Int) async throws -> [ZPDFContracts.MarkupRecord] {
        var records: [ZPDFContracts.MarkupRecord] = []
        for index in 0..<count {
            let y = 100 + Double(index) * 30
            records.append(try await harness.addMarkup(tool: .length) { page in
                MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: y), PDFPoint(x: 200, y: y)])
            })
        }
        return records
    }

    private func save(_ document: ZenitPDFProjectDocument, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: url, ofType: ZenitAppInfo.projectTypeIdentifier, for: .saveAsOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // MARK: - IM-051 / BH-373 / BH-908 / BH-375 Delete

    @Test("IM-051 / BH-373 / BH-908: deleting five markups is one batch — one ⌘Z brings all five back")
    func deleteIsOneUndoStep() async throws {
        let harness = try await Fix2Harness.make("IM051.pdf")
        defer { harness.tearDown() }
        let records = try await addLengths(harness, count: 5)
        harness.core.canvas.select(markupIDs: Set(records.map(\.id.rawValue)), additive: false)
        let item = NSMenuItem(title: "", action: #selector(ZenitCommandResponding.performZenitCommand(_:)), keyEquivalent: "")
        item.representedObject = ZPDFCommandID.deleteSelection.rawValue
        harness.controller.performZenitCommand(item)
        // Cleared at once, so a key-repeat reads nothing (BH-908).
        #expect(harness.core.canvas.selectedMarkupIDs.isEmpty)
        harness.controller.performZenitCommand(item)
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.isEmpty })
        #expect(!harness.core.status.warnings.contains { $0.title == "That edit was not made." },
                "a second Delete reported a false refusal")
        let undoManager = try #require(harness.document.undoManager)
        undoManager.undo()
        // Old: five removeMarkup commands, five undo groups — one ⌘Z restored one markup.
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.count == 5 },
                "one ⌘Z restored \(harness.core.snapshot.markups.count) of 5")
        #expect(ProjectWindowController.deleteCommands(for: Set(records.map(\.id.rawValue)), parents: [:]).count == 5)
    }

    @Test("BH-375: calibrate on a clean drawing, then ⌘Z, and the document is clean again")
    func undoReturnsToClean() async throws {
        let harness = try await Fix2Harness.make("BH375.pdf", calibrate: false)
        defer { harness.tearDown() }
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/ZenitPDFAppKit/Window/ProjectWindowController.swift"),
            encoding: .utf8
        )
        // Old: `if removed > 0 { document.updateChangeCount(.changeDone) }` and the same after a
        // calibration, on top of the undo manager's own count — ⌘Z never got back to zero.
        #expect(!source.contains("if removed > 0 { document.updateChangeCount(.changeDone) }"))
        let page = try #require(await harness.core.session.firstPageID)
        #expect(!harness.document.isDocumentEdited)
        _ = try await harness.core.commands.calibrate(
            page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        #expect(await AppTestSupport.wait { harness.document.isDocumentEdited })
        harness.document.undoManager?.undo()
        #expect(await AppTestSupport.wait { !harness.document.isDocumentEdited },
                "the undo manager's own count must bring the document back to clean")
    }

    // MARK: - BH-357 / IM-180 Inspector subject over a selection

    @Test("BH-357 / IM-180: a subject edit over three markups is one ⌘Z")
    func subjectEditIsOneUndoStep() async throws {
        let harness = try await Fix2Harness.make("BH357.pdf")
        defer { harness.tearDown() }
        let records = try await addLengths(harness, count: 3)
        await ZenitPDFProjectDocument.applySubjectEdit(
            markupIDs: Set(records.map(\.id.rawValue)), subject: "Wall B", core: harness.core
        )
        await harness.core.commands.settle()
        #expect(await harness.records().allSatisfy { $0.subject == "Wall B" })
        harness.document.undoManager?.undo()
        // Old: one `perform(.editSubject)` per markup — ⌘Z restored one of the three.
        #expect(await AppTestSupport.wait {
            harness.core.snapshot.markups.allSatisfy { $0.subject != "Wall B" }
        }, "one ⌘Z did not restore all three subjects")
    }

    // MARK: - IM-048 / IM-049 light autosave

    @Test("IM-048: the Quick PDF container autosave does one full package save per session, not one per edit")
    func quickAutosaveIsLight() async throws {
        let harness = try await Fix2Harness.make("IM048.pdf")
        defer { harness.tearDown() }
        #expect(harness.document.mode == .quickPDF)
        for index in 0..<4 {
            try await harness.addMarkup(tool: .length) { page in
                MeasurementGeometry(pageID: page, points: [PDFPoint(x: 50, y: 100 + Double(index) * 20), PDFPoint(x: 150, y: 100 + Double(index) * 20)])
            }
            _ = try await harness.document.performQuickPDFAutosave()
        }
        // Old: `package.save()` after every edit — re-hash the PDF, rewrite the manifest,
        // integrity and a version rotation, one second after each click.
        #expect(harness.document.fullPackageSaveCountForTesting == 1)
        #expect(harness.document.lightAutosaveCountForTesting == 3)
        let package = try #require(harness.document.quickAutosavePackageForTesting)
        let stored = try #require(try await TakeoffArchive.read(from: package))
        #expect(stored.markups.count == 4, "the container's live database must hold every edit")
    }

    @Test("IM-049: a periodic autosave writes the recovery snapshot, not a full save")
    func periodicAutosaveIsLight() async throws {
        let harness = try await Fix2Harness.make("IM049.pdf")
        defer { harness.tearDown() }
        let package = harness.directory.appendingPathComponent("Periodic.zpdfproj")
        try await save(harness.document, to: package)
        let fullSaves = harness.document.fullPackageSaveCountForTesting
        let manifestDate = try package.appendingPathComponent(ProjectPackageLayout.manifest)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 90, y: 10)])
        }
        try await harness.document.performLightAutosaveForTesting()
        // Old: every periodic autosave ran the nine-step package save and rotated versions.
        #expect(harness.document.fullPackageSaveCountForTesting == fullSaves)
        #expect(harness.document.lightAutosaveCountForTesting == 1)
        #expect(FileManager.default.fileExists(
            atPath: package.appendingPathComponent(ProjectPackageLayout.autosaveDatabase).path
        ), "no recovery snapshot was written")
        let after = try package.appendingPathComponent(ProjectPackageLayout.manifest)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(after == manifestDate, "the manifest was rewritten by an autosave")
        let livePackage = try #require(harness.document.projectPackage)
        let stored = try #require(try await TakeoffArchive.read(from: livePackage))
        #expect(stored.markups.count == 1)
    }

    // MARK: - BH-382 / BH-383 / BH-915 CSV

    @Test("BH-382 / BH-383 / BH-915: the CSV guards formulas, quotes CRLF, and splits on ; where decimals are commas")
    func csvFieldPolicy() {
        // Old: written as-is — executed as a formula when the tender CSV was opened.
        #expect(LedgerCSVExport.field("=HYPERLINK(\"x\")").hasPrefix("\"'="))
        #expect(LedgerCSVExport.field("@SUM(A1)") == "'@SUM(A1)")
        #expect(LedgerCSVExport.field("+1") == "'+1")
        #expect(LedgerCSVExport.field("-3.2 m", isNumber: true) == "-3.2 m", "a displayed negative quantity is a number")
        // X-013: a number is told by the cell, not by a digit after the minus; text is guarded.
        #expect(LedgerCSVExport.field("-3.2 m") == "'-3.2 m")
        #expect(LedgerCSVExport.field("-x") == "'-x")
        // Old: "\r\n" is one Character, so it matched neither test and went out unquoted.
        #expect(LedgerCSVExport.field("line one\r\nline two") == "\"line one\r\nline two\"")
        #expect(LedgerCSVExport.delimiter(for: Locale(identifier: "sv_SE")) == ";")
        #expect(LedgerCSVExport.delimiter(for: Locale(identifier: "en_US")) == ",")
        #expect(LedgerCSVExport.field("5,04 m", delimiter: ";") == "5,04 m")
        #expect(LedgerCSVExport.field("a;b", delimiter: ";") == "\"a;b\"")
    }
}
