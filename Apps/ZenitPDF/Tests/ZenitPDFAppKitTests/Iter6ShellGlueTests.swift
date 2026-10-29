import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Loop iteration 6 (cycle 1), area app-shell-glue: W-016 … W-023. Every test states the old
/// output it fails with. Headless throughout: no window is ordered front, every modal is
/// answered by injection, and every store, index root and fixture is a temporary one.
/// Hand-derived values: the stroked-rectangle fixture is calibrated 100 pt = 1 m.
@MainActor
@Suite("Iteration 6 — app shell glue", .appTierSerialised, .serialized)
struct Iter6ShellGlueTests {

    // MARK: - Helpers

    static func eventually(upTo seconds: Double = 15, _ condition: @MainActor () async -> Bool) async -> Bool {
        await Iter2ShellGlueTests.eventually(upTo: seconds, condition)
    }

    static func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("it6-shell-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A length of `points` on `page`, straight through the command bus.
    static func length(on page: ZPDFContracts.PageDescriptor, from x: Double = 100, points: Double, y: Double = 100, subject: String) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID()),
            documentID: page.documentID,
            pageID: page.id,
            kind: .measurement,
            tool: .length,
            subject: subject,
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: x, y: y), PDFPoint(x: x + points, y: y)]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    /// 100 pt = 1 m on `page`.
    static func calibrate(_ core: AppCoreEnvironment, page: PageID) async throws {
        _ = try await core.commands.calibrate(
            page: page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
    }

    /// The harness's Quick PDF saved as a project, then a second drawing added to it at the
    /// front of the set: a project of two drawings whose first sheets both carry PDF index 0.
    static func twoDrawings(
        _ harness: Fix2Harness, added: URL, project: String
    ) async throws -> (set: DrawingSet, added: LoadedDrawing) {
        _ = try await Iter1ShellGlueTests.saveAsProject(harness, name: project)
        #expect(await harness.document.addDrawingToSet(fileAt: added, at: 0))
        let set = try #require(harness.document.drawingSet)
        let drawing = try #require(set.members.last?.drawing)
        await harness.core.refresh()
        return (set, drawing)
    }

    /// An earlier revision of the harness's drawing, dropped on it, as Set Compare needs.
    static func addRevision(_ harness: Fix2Harness, named name: String = "Rev B.pdf") async throws -> URL {
        let drawing = try #require(harness.document.drawing?.url)
        let revision = harness.directory.appendingPathComponent(name)
        try Data(contentsOf: drawing).write(to: revision)
        var added = false
        harness.document.addRevision(fromDroppedFile: revision) { added = $0 }
        #expect(await AppTestSupport.wait(upTo: 30) { added })
        #expect(harness.document.newestRevision != nil)
        return revision
    }

    // MARK: - W-016

    @Test("W-016: Read Text from Scanned Pages… over two drawings opens, reads each sheet into its own drawing's index, and This page is the sheet on screen")
    func recognitionOverTwoDrawings() async throws {
        try await SearchAndOCRWiringTests.withScratchIndexRoot {
            let primaryPDF = try SearchAndOCRWiringTests.writeTextFixturePDF(text: "PRIMARY SCREED 65MM", named: "W016 A.pdf")
            let harness = try await Fix2Harness.make("W016 A.pdf", calibrate: false, fixture: primaryPDF)
            defer { harness.tearDown() }
            let addedPDF = try SearchAndOCRWiringTests.writeTextFixturePDF(text: "ADDED GROUT BAY 9", named: "W016 B.pdf")
            defer { try? FileManager.default.removeItem(at: addedPDF.deletingLastPathComponent()) }
            let (set, added) = try await Self.twoDrawings(harness, added: addedPDF, project: "W016.zpdfproj")
            #expect(await Self.eventually(upTo: 60) { harness.document.searchIndex != nil })
            #expect(await Self.eventually(upTo: 60) { set.searchIndexes[added.documentID] != nil })
            let primaryIndex = try #require(harness.document.searchIndex)
            let addedIndex = try #require(set.searchIndexes[added.documentID])
            await harness.document.settleTextIndexing()

            let pages = harness.core.snapshot.pages
            #expect(pages.count == 2)
            #expect(pages.map(\.index) == [0, 0], "page 0 of the added drawing, then page 0 of the primary")
            #expect(pages[0].id == added.pages[0].id.rawValue)

            // The primary sheet is on screen: set position 1, PDF index 0.
            harness.core.document.goToPage(id: pages[1].id)
            // Old: `Dictionary(uniqueKeysWithValues:)` keyed by PDF index trapped here on the
            // duplicate key 0, and the application crashed from a menu item.
            let model = harness.controller.makeOCRRunModel(for: harness.document, pages: pages)
            model.rangeSelection = .currentPage
            // Old: the viewport's PDF index 0 was taken as a set position — the added sheet.
            #expect(model.resolvedPages.map(\.id) == [pages[1].id])

            model.rangeSelection = .allPages
            model.skipsPagesWithText = false
            model.start()
            #expect(await AppTestSupport.wait(upTo: 180) { model.phase != .running && model.phase != .cancelling })
            #expect(model.phase == .finished, "\(model.phase)")
            #expect(Set(model.pageResults.map(\.id)) == Set(pages.map(\.id)))
            #expect(model.pageResults.allSatisfy { $0.status == .indexed }, "\(model.pageResults.map(\.status))")

            // Each sheet's words are in its own drawing's index. Old: both PDF indices 0 went to
            // the primary index, so the added sheet's words were never read and the primary
            // sheet was read twice.
            let primaryWords = (try await primaryIndex.recognisedWords()[0] ?? []).map(\.text).joined(separator: " ")
            let addedWords = (try await addedIndex.recognisedWords()[0] ?? []).map(\.text).joined(separator: " ")
            #expect(primaryWords.contains("PRIMARY") && !primaryWords.contains("ADDED"), "\(primaryWords)")
            #expect(addedWords.contains("ADDED") && !addedWords.contains("PRIMARY"), "\(addedWords)")
        }
    }

    @Test("W-016: recognition batches group the asked pages by drawing, keyed by identity")
    func recognitionBatchesByDrawing() async throws {
        let harness = try await Fix2Harness.make("W016b A.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        let addedPDF = try AppTestSupport.writeFixturePDF(named: "W016b B.pdf", pageCount: 2)
        defer { try? FileManager.default.removeItem(at: addedPDF.deletingLastPathComponent()) }
        let (_, added) = try await Self.twoDrawings(harness, added: addedPDF, project: "W016b.zpdfproj")
        let primary = try #require(harness.document.drawing)
        let asked = [primary.pages[1].id.rawValue, added.pages[0].id.rawValue, primary.pages[0].id.rawValue, added.pages[1].id.rawValue, UUID()]
        let batches = harness.document.recognitionBatches(for: asked)
        #expect(batches.map(\.documentID) == [primary.documentID, added.documentID])
        #expect(batches[0].pageIndices == [1, 0])
        #expect(batches[1].pageIndices == [0, 1])
        #expect(batches[0].pageIDByIndex[0] == primary.pages[0].id.rawValue)
        #expect(batches[1].pageIDByIndex[0] == added.pages[0].id.rawValue, "index 0 of each drawing names its own sheet")
    }

    // MARK: - W-017

    /// A Quick PDF of two same-size sheets, a length on each, written into a copy with Save
    /// Markups into PDF after `arrange` rearranged the set.
    static func savedIntoCopy(
        _ label: String, arrange: (Fix2Harness, [ZPDFContracts.PageDescriptor]) async throws -> Void
    ) async throws -> (harness: Fix2Harness, copy: URL, onFilePage: [UUID: Int]) {
        let harness = try await Fix2Harness.make("\(label).pdf", pageCount: 2, calibrate: false)
        let drawing = try #require(harness.document.drawing)
        let pages = drawing.pages
        var onFilePage: [UUID: Int] = [:]
        for page in pages {
            try await Self.calibrate(harness.core, page: page.id)
            let record = Self.length(on: page, points: 100 + 100 * Double(page.index), subject: "Sheet \(page.index)")
            _ = try await harness.core.commands.perform(.addMarkup(record))
            onFilePage[record.id.rawValue] = page.index
        }
        try await arrange(harness, pages)
        await harness.core.commands.settle()
        await harness.core.refresh()
        let job = try await StandardAnnotationExport.job(for: harness.document)
        let copy = harness.directory.appendingPathComponent("\(label) — With Markups.pdf")
        let result = try await harness.controller.saveIntoPDF(job: job, document: harness.document, destination: copy, inPlace: false)
        #expect(result.outcome.takeoffEmbedded)
        #expect(result.leftOut == nil, "one drawing: nothing is left out")
        return (harness, copy, onFilePage)
    }

    @Test("W-017: after a reorder, a restored takeoff puts every markup back on the sheet it was drawn on")
    func restoreAfterReorderKeepsSheets() async throws {
        let saved = try await Self.savedIntoCopy("W017 Reorder") { harness, _ in
            _ = try await harness.core.commands.perform(.reorderPage(from: 0, to: 1))
            await harness.core.refresh()
            #expect(harness.core.snapshot.pages.map(\.index) == [1, 0], "the set shows file page 2 first")
        }
        defer { saved.harness.tearDown() }

        let reopened = try AppTestSupport.makeDocument(opening: saved.copy)
        defer { Task { await reopened.drawing?.rasterSource.close(); reopened.close() } }
        #expect(await AppTestSupport.wait { reopened.core != nil && reopened.drawing != nil })
        let drawing = try #require(reopened.drawing)
        let inspected = EmbeddedTakeoffRestore.inspect(fileAt: saved.copy, pages: drawing.pages, documentID: drawing.documentID)
        #expect(inspected.finding == .restorable(markups: 2, sheets: 2))
        let archive = try #require(inspected.archive)
        let restored = try #require(await EmbeddedTakeoffRestore.restore(archive, into: reopened))
        #expect(restored.count == 2)
        let core = try #require(reopened.core)
        let markups = await core.session.takeoffState().markups
        let pageIndex = Dictionary(drawing.pages.map { ($0.id, $0.index) }, uniquingKeysWith: { first, _ in first })
        for markup in markups {
            // Old: the archive named the pages in set order and the restore paired them with the
            // file's by position, so each markup landed on the other sheet (index 1 ↔ 0).
            #expect(pageIndex[markup.pageID] == saved.onFilePage[markup.id.rawValue], "\(markup.subject)")
        }
        // Each scale went with its sheet too: 1 m and 2 m read back on their own sheets.
        await core.refresh()
        #expect(core.ledger.grandTotals.total("planLength")?.value == Decimal(3))
    }

    @Test("W-017: with a sheet removed from the set, the saved PDF still offers its takeoff")
    func restoreAfterRemovalIsOffered() async throws {
        let saved = try await Self.savedIntoCopy("W017 Remove") { harness, pages in
            _ = try await harness.core.commands.perform(.setPagesExcluded([pages[1].id], excluded: true))
            await harness.core.refresh()
            #expect(harness.core.snapshot.pages.count == 1)
        }
        defer { saved.harness.tearDown() }
        let reopened = try AppTestSupport.makeDocument(opening: saved.copy)
        defer { Task { await reopened.drawing?.rasterSource.close(); reopened.close() } }
        #expect(await AppTestSupport.wait { reopened.core != nil && reopened.drawing != nil })
        let drawing = try #require(reopened.drawing)
        // Old: 1 page id in the archive against the file's 2 pages → .differentDrawing → `.none`,
        // no offer, although the result note promised "a takeoff Zenit can read back". The
        // removed sheet's length is set aside, out of the takeoff and out of the annotations
        // written, so the archive carries the one on the sheet still in the set.
        let inspected = EmbeddedTakeoffRestore.inspect(fileAt: saved.copy, pages: drawing.pages, documentID: drawing.documentID)
        #expect(inspected.finding == .restorable(markups: 1, sheets: 1))
        let core = try #require(reopened.core)
        #expect(await AppTestSupport.wait { core.document.warnings.contains { $0.actionTitle == "Restore Takeoff" } },
                "the tray offers the restore")
    }

    @Test("W-017: in a project of two drawings the archive holds the primary drawing's takeoff, and the confirmation and note say what stays out")
    func archiveOfOneDrawing() async throws {
        let harness = try await Fix2Harness.make("W017 Set A.pdf", calibrate: false)
        defer { harness.tearDown() }
        let addedPDF = try AppTestSupport.writeFixturePDF(named: "W017 Set B.pdf")
        defer { try? FileManager.default.removeItem(at: addedPDF.deletingLastPathComponent()) }
        let (set, added) = try await Self.twoDrawings(harness, added: addedPDF, project: "W017.zpdfproj")
        let primary = try #require(harness.document.drawing)
        for page in [primary.pages[0], added.pages[0]] {
            try await Self.calibrate(harness.core, page: page.id)
            _ = try await harness.core.commands.perform(.addMarkup(Self.length(on: page, points: 200, subject: "On \(page.documentID == primary.documentID ? "A" : "B")")))
        }
        await harness.core.refresh()
        let state = await harness.core.session.takeoffState()
        let data = try EmbeddedSessionArchive.encode(state, pages: primary.pages, documentID: primary.documentID)
        let archive = try JSONDecoder().decode(EmbeddedSessionArchive.self, from: data)
        // Old: every sheet of the set (2 ids, the added one first) and both markups.
        #expect(archive.pageIDs == primary.pages.map(\.id.rawValue))
        #expect(archive.markups.map(\.subject) == ["On A"])
        #expect(archive.scales.allSatisfy { $0.pageID == nil || $0.pageID == primary.pages[0].id })
        #expect(archive.pageScaleIDs.keys.allSatisfy { $0 == primary.pages[0].id })

        let sentence = try #require(harness.document.primaryDrawingOnlySentence())
        #expect(sentence == "Only “\(set.primary.displayName)” is written. The sheets and markups of the project's other drawing are not in this file.")
        let alert = SaveMarkupsIntoPDF.confirmation(fileName: "A.pdf", annotationCount: 1, inPlace: false, leftOut: sentence)
        #expect(alert.informativeText.hasSuffix(sentence))
        var outcome = StandardAnnotationOutcome(pageCount: 1, preservedSourceBytes: 1)
        outcome.writtenAnnotationCount = 1
        outcome.takeoffEmbedded = true
        let note = SaveMarkupsIntoPDF.resultNote(for: .init(
            outcome: outcome, destination: URL(fileURLWithPath: "/tmp/A.pdf"), wroteInPlace: false, leftOut: sentence
        ))
        #expect(note.message.contains(sentence))
    }

    // MARK: - W-018

    @Test("W-018: a quit whose review is cancelled thaws every window it froze and answers every scripted quit with -128")
    func cancelledQuitReviewThawsAndAnswers() async throws {
        let harness = try await Fix2Harness.make("W018.pdf", calibrate: false)
        defer { harness.tearDown() }
        harness.document.fileURL = harness.directory.appendingPathComponent("W018.pdf")
        let store = Iter1ShellGlueTests.CountingStore()
        let previous = ZenitProcessDefaults.override
        ZenitProcessDefaults.override = store
        defer { ZenitProcessDefaults.override = previous }
        harness.document.updateChangeCount(.changeCleared)

        let delegate = ZenitApplicationDelegate()
        var resumed: [(id: Int, granted: Bool)] = []
        delegate.resumeQuitEvent = { suspension, granted in resumed.append((Int(bitPattern: suspension), granted)) }
        // Two scripted quits suspended while the quit is decided: the second joins the first.
        delegate.pendingQuitEvents = [OpaquePointer(bitPattern: 0x10)!, OpaquePointer(bitPattern: 0x20)!]

        // The production wiring, with only the review and the sweep's reach replaced: the sweep
        // freezes this window alone (nothing else is brought forward), and the review answers
        // Cancel. The cancelled hook is ZenitApplication's own.
        var flow = ZenitApplication.terminationFlow(
            application: NSApplication.shared,
            delegate: delegate,
            terminateNow: { Issue.record("AppKit's terminate ran after Cancel") }
        )
        flow.hasSheet = { false }
        flow.prepareWindows = { harness.controller.prepareForTermination() }
        flow.needsReview = { true }
        var frozenDuringReview = false
        flow.review = { answer in
            frozenDuringReview = harness.controller.isSessionFrozen
            answer(false)
        }
        flow.terminate()

        #expect(frozenDuringReview, "the sweep froze the window before the review")
        // Old: the cancelled review returned with nothing more — the window stayed frozen and
        // neither suspension was resumed (osascript timed out instead of getting -128).
        #expect(!harness.controller.isSessionFrozen, "the cancelled quit thawed the window")
        #expect(resumed.map(\.id) == [0x10, 0x20])
        #expect(resumed.allSatisfy { !$0.granted }, "-128 for each")
        #expect(delegate.pendingQuitEvents.isEmpty)

        // A tab change after the cancelled quit is recorded again.
        let renamed = harness.directory.appendingPathComponent("W018 renamed.pdf")
        harness.document.fileURL = renamed
        harness.controller.syncTabs()
        #expect(WindowSessionStore.load(defaults: store)?.paths == [renamed.path])
    }

    @Test("W-018: a granted quit resolves every suspended event without an error")
    func grantedQuitResolvesEverySuspension() {
        let delegate = ZenitApplicationDelegate()
        var resumed: [Bool] = []
        delegate.resumeQuitEvent = { _, granted in resumed.append(granted) }
        delegate.pendingQuitEvents = [OpaquePointer(bitPattern: 0x30)!, OpaquePointer(bitPattern: 0x40)!]
        delegate.resolvePendingQuitEvent(granted: true)
        #expect(resumed == [true, true])
        delegate.resolvePendingQuitEvent(granted: false)
        #expect(resumed == [true, true], "nothing left to resolve")
    }

    // MARK: - W-019

    @Test("W-019: an added drawing's index file is keyed by the project and its package row, so recognised text survives a reopen")
    func addedDrawingIndexSurvivesReopen() async throws {
        try await SearchAndOCRWiringTests.withScratchIndexRoot {
            let primaryPDF = try SearchAndOCRWiringTests.writeTextFixturePDF(text: "PRIMARY SCREED 65MM", named: "W019 A.pdf")
            let harness = try await Fix2Harness.make("W019 A.pdf", calibrate: false, fixture: primaryPDF)
            defer { try? FileManager.default.removeItem(at: harness.directory) }
            let addedPDF = try SearchAndOCRWiringTests.writeTextFixturePDF(text: "ADDED GROUT BAY 9", named: "W019 B.pdf")
            defer { try? FileManager.default.removeItem(at: addedPDF.deletingLastPathComponent()) }
            let package = harness.directory.appendingPathComponent("W019.zpdfproj")
            let (set, added) = try await Self.twoDrawings(harness, added: addedPDF, project: "W019.zpdfproj")
            #expect(await Self.eventually(upTo: 60) { set.searchIndexes[added.documentID] != nil })
            let index = try #require(set.searchIndexes[added.documentID])
            let row = try #require(set.members.last?.row)
            let projectPackage = try #require(harness.document.projectPackage)
            let projectID = await projectPackage.manifest.projectId
            #expect(index.databaseURL.deletingPathExtension().lastPathComponent
                    == ZenitPDFProjectDocument.addedDrawingSearchIndexKey(digest: added.digest.sha256, projectID: "\(projectID)", row: row))

            var finished = false
            harness.document.runTextRecognition(
                pageIDs: [added.pages[0].id.rawValue], languageIDs: ["en-US"], skipsPagesWithText: false,
                onPage: { _, _ in }, onFinish: { _ in finished = true }
            )
            #expect(await AppTestSupport.wait(upTo: 120) { finished })
            #expect(!((try await index.recognisedWords())[0] ?? []).isEmpty, "recognition stored words")
            try await Iter1ShellGlueTests.save(harness.document, to: package, .saveOperation)
            let databaseURL = index.databaseURL
            harness.controller.window?.close()
            harness.document.close()

            let reopened = ZenitPDFProjectDocument()
            try reopened.read(from: package, ofType: ZenitAppInfo.projectTypeIdentifier)
            reopened.startLoadingIfNeeded()
            defer { reopened.close() }
            #expect(await AppTestSupport.wait(upTo: 30) { reopened.core != nil })
            reopened.openDrawingSetSearch()
            let reopenedSet = try #require(reopened.drawingSet)
            let reopenedAdded = try #require(reopenedSet.members.last?.drawing)
            #expect(await Self.eventually(upTo: 60) { reopenedSet.searchIndexes[reopenedAdded.documentID] != nil })
            let again = try #require(reopenedSet.searchIndexes[reopenedAdded.documentID])
            // Old: "<digest>-set-<document>-<drawing>" with both identities minted per open — a
            // new, empty file on every reopen.
            #expect(again.databaseURL == databaseURL)
            #expect(!((try await again.recognisedWords())[0] ?? []).isEmpty, "the recognised text was found again")
            let retired = try FileManager.default.contentsOfDirectory(atPath: databaseURL.deletingLastPathComponent().path)
                .filter { $0.contains(ZenitPDFProjectDocument.retiredSetSearchIndexMarker) }
            #expect(retired.isEmpty, "no file under the per-open key")
        }
    }

    @Test("W-019: the sweep removes only retired added-drawing index files; the privacy delete removes this project's")
    func retiredIndexFilesAreSwept() async throws {
        let root = try Self.scratch("w019-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        let retiredMine = "\(mine)-set-\(UUID().uuidString)-\(UUID().uuidString).sqlite"
        let retiredOther = "\(other)-set-\(UUID().uuidString)-\(UUID().uuidString).sqlite"
        let keep = [
            "\(mine)-project-\(UUID().uuidString).sqlite",              // the primary drawing's
            "\(mine)-project-\(UUID().uuidString)-row-1.sqlite",        // an added drawing's, new key
            "not-a-digest-set-\(UUID().uuidString).sqlite",             // not ours
            "notes.txt"
        ]
        for name in [retiredMine, retiredMine + "-wal", retiredMine + "-shm", retiredOther] + keep {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        // The privacy delete's form: this project's digests only.
        let removedMine = ZenitPDFProjectDocument.removeRetiredSetSearchIndexes(in: root, digests: [mine])
        #expect(Set(removedMine.map(\.lastPathComponent)) == [retiredMine, retiredMine + "-wal", retiredMine + "-shm"])
        // The one-time sweep: every retired file.
        let removedRest = ZenitPDFProjectDocument.removeRetiredSetSearchIndexes(in: root)
        #expect(removedRest.map(\.lastPathComponent) == [retiredOther])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == Set(keep))
    }

    // MARK: - W-020

    @Test("W-020: Set Compare Report writes the one file the panel granted — PDF, or CSV by its name — and no sibling")
    func setCompareReportWritesOneFile() async throws {
        let harness = try await Fix2Harness.make("W020 Set.pdf", calibrate: false)
        let presenter = ZenitPDFProjectDocument.sheetMatchReviewPresenter
        ZenitPDFProjectDocument.sheetMatchReviewPresenter = { _, _, _ in {} }
        defer {
            ZenitPDFProjectDocument.sheetMatchReviewPresenter = presenter
            harness.tearDown()
        }
        _ = try await Self.addRevision(harness)
        let out = try Self.scratch("w020")
        defer { try? FileManager.default.removeItem(at: out) }

        let pdf = out.appendingPathComponent("Report.pdf")
        #expect(await harness.document.writeSetCompareReport(to: pdf))
        #expect(CGPDFDocument(pdf as CFURL)?.numberOfPages ?? 0 >= 1)
        // Old: a "Report.csv" beside it, a sibling the sandbox never granted — in the shipped
        // application that write was refused and its error was the only note.
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("Report.csv").path))
        #expect(harness.core.status.snapshot.activeToolNote?.hasPrefix("Set compare report written") == true)

        let csv = out.appendingPathComponent("Changes.csv")
        #expect(await harness.document.writeSetCompareReport(to: csv))
        let text = try String(contentsOf: csv, encoding: .utf8)
        // Old: PDF bytes under the .csv name, and the CSV written over them beside it.
        #expect(text.hasPrefix("Sheet,Revision sheet,Status,Differences,Affected measurements,Pairing\n"))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("Changes.pdf").path))
    }

    // MARK: - W-021

    @Test("W-021: Shortcuts' Get Totals and AppleScript's totals are the whole project's, whatever filter the ledger shows")
    func automationTotalsAreUnfiltered() async throws {
        let harness = try await Fix2Harness.make("W021.pdf")
        defer { harness.tearDown() }
        // 250 pt + 150 pt at 100 pt = 1 m: 2.5 m + 1.5 m = 4 m of length in all.
        _ = try await Iter2ShellGlueTests.length(harness, from: 0, to: 250, y: 10, subject: "Wall")
        _ = try await Iter2ShellGlueTests.length(harness, from: 0, to: 150, y: 60, subject: "Slab")
        let whole = try await ZenitShortcutsBridge.totals(of: harness.document)
        #expect(whole.contains(": 4"), "\(whole)")
        harness.core.ledger.setFilter(Iter2ShellGlueTests.subjectFilter("Wall"))
        #expect(await AppTestSupport.wait { harness.core.ledger.rowCount == 1 })
        // Old: "…: 2.5…" — the filtered subset reported as the project's totals, unmarked.
        #expect(try await ZenitShortcutsBridge.totals(of: harness.document) == whole)
        #expect(try await ZenitScripting.totals(document: harness.document) == whole)
    }

    // MARK: - W-022

    @Test("W-022: in a project of two drawings the overlay carries the primary drawing's rows, each with geometry, and every primary-only output names its drawing")
    func primaryOnlyOutputsSaySo() async throws {
        let harness = try await Fix2Harness.make("W022 A.pdf", calibrate: false)
        defer { harness.tearDown() }
        // One drawing: nothing to leave out, so no sentence.
        let base = MeasurementOverlayTransfer.exportPanelMessage(for: harness.document)
        #expect(harness.document.primaryDrawingOnlySentence() == nil)
        #expect(SearchableCopyExport.panelMessage(for: harness.document).hasSuffix("The drawing itself is not changed."))

        let addedPDF = try AppTestSupport.writeFixturePDF(named: "W022 B.pdf")
        defer { try? FileManager.default.removeItem(at: addedPDF.deletingLastPathComponent()) }
        let (set, added) = try await Self.twoDrawings(harness, added: addedPDF, project: "W022.zpdfproj")
        let primary = try #require(harness.document.drawing)
        var onPrimary: MarkupRecord?
        for page in [primary.pages[0], added.pages[0]] {
            try await Self.calibrate(harness.core, page: page.id)
            let record = Self.length(on: page, points: 200, subject: page.documentID == primary.documentID ? "A" : "B")
            if page.documentID == primary.documentID { onPrimary = record }
            _ = try await harness.core.commands.perform(.addMarkup(record))
        }
        await harness.core.commands.settle()
        await harness.core.refresh()
        let primaryRecord = try #require(onPrimary)

        let data = try #require(try await MeasurementOverlayTransfer.overlayData(for: harness.document))
        let source = try #require(MeasurementOverlayTransfer.source(of: harness.document))
        let overlay = try ZenitOverlayImporter().import(data, onto: source)
        // Old: two rows — the added sheet's length travelled without geometry, under the
        // primary drawing's fingerprint, for an import to skip as `.noGeometry`.
        #expect(overlay.document.measurements.map(\.row.markupID) == [primaryRecord.id.rawValue.uuidString])
        #expect(overlay.document.measurements.allSatisfy { $0.geometry != nil })

        let sentence = try #require(harness.document.primaryDrawingOnlySentence())
        #expect(sentence.hasPrefix("Only “\(set.primary.displayName)” is written."))
        // Old: none of these named the drawing.
        #expect(MeasurementOverlayTransfer.exportPanelMessage(for: harness.document) == base + " " + sentence)
        #expect(MeasurementOverlayTransfer.exportNote(for: harness.document, fileName: "A.zpdfoverlay").message.hasSuffix(sentence))
        #expect(SearchableCopyExport.panelMessage(for: harness.document).hasSuffix(sentence))
        let written = try SearchableTextLayerWriter().data(
            source: try Data(contentsOf: primary.url),
            pages: [.init(sourcePageIndex: 0, rotation: 0, tokens: [.init(text: "GRID", bounds: CGRect(x: 50, y: 50, width: 40, height: 12))])]
        )
        let note = SearchableCopyExport.resultNote(
            for: written.outcome,
            destination: URL(fileURLWithPath: "/tmp/A — Searchable.pdf"),
            leftOut: harness.document.primaryDrawingOnlySentence()
        )
        #expect(note.message.hasSuffix(sentence))
    }

    // MARK: - W-023

    @Test("W-023: Export Arranged Set, Extract Page(s)… and New PDF from Documents refuse a file the document is made of")
    func derivedOutputsRefuseDocumentFiles() async throws {
        let harness = try await Fix2Harness.make("W023.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        let revision = try await Self.addRevision(harness, named: "W023 Rev B.pdf")
        let revisionBytes = try Data(contentsOf: revision)
        let drawing = try #require(harness.document.drawing)
        let drawingBytes = try Data(contentsOf: drawing.url)

        func refusalNoted(_ source: String) -> Bool {
            harness.core.document.warnings.contains {
                $0.source == source && $0.message.contains("“W023 Rev B.pdf” is the drawing it is made from")
            }
        }

        // Export Arranged Set / Extract Page(s)… over a set: the composed writer.
        let pages = await harness.document.setExportPages()
        #expect(pages.count == 2)
        // Old: PDFKit composed the set over the revision — the only copy of it in a Quick PDF.
        #expect(await harness.document.writeComposed(pages, sheetBookmarks: false, to: revision) == nil)
        #expect(try Data(contentsOf: revision) == revisionBytes)
        #expect(refusalNoted("Export Arranged Set"))

        // Extract Page(s)… of one drawing: the raw extract.
        // Old: PDFKit's extract replaced the revision; only the drawing it had opened was refused.
        #expect(await harness.document.writeExtract(indices: [1], from: drawing.url, password: nil, to: revision) == nil)
        #expect(try Data(contentsOf: revision) == revisionBytes)
        #expect(refusalNoted("Extract Pages"))

        // New PDF from Documents: the front drawing itself.
        let text = harness.directory.appendingPathComponent("Notes.txt")
        try Data("Site notes".utf8).write(to: text)
        // Old: the text's PDF was written over the open drawing, or over the revision.
        for target in [drawing.url, revision] {
            do {
                _ = try CreatePDFFromDocuments.convert([text], to: target, refusingFilesOf: [harness.document])
                Issue.record("New PDF from Documents wrote over \(target.lastPathComponent)")
            } catch is DerivedCopyGuard.Refusal {
            } catch {
                Issue.record("not the refusal: \(error)")
            }
        }
        #expect(try Data(contentsOf: drawing.url) == drawingBytes)
        #expect(try Data(contentsOf: revision) == revisionBytes)

        // The control: an ordinary name is written by each.
        let out = try Self.scratch("w023")
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(await harness.document.writeComposed(pages, sheetBookmarks: false, to: out.appendingPathComponent("Set.pdf")) != nil)
        #expect(await harness.document.writeExtract(indices: [1], from: drawing.url, password: nil, to: out.appendingPathComponent("Extract.pdf")) != nil)
        #expect(try CreatePDFFromDocuments.convert([text], to: out.appendingPathComponent("Notes.pdf"), refusingFilesOf: [harness.document]) == 1)
    }
}
