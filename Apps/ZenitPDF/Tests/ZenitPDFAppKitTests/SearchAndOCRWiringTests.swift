import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFExport
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// The honesty suite for the Search panel, the recognition run and the export formats.
///
/// Every test here drives the shipping objects — `ZenitPDFProjectDocument`,
/// `ProjectWindowController`, the real `AppSearchPresenter` over the real FTS5 index — because the
/// defect these exist to prevent was a *presenter substitution*, and a test written against a
/// stand-in would have passed happily while the product fabricated results.
///
/// `.serialized` is load-bearing, not caution: the scratch index root is a static override, so
/// two of these tests running at once would each redirect the other's document mid-open. A
/// shared static plus parallel tests is a flake generator.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct SearchAndOCRWiringTests {

    // MARK: - Fixtures

    /// A one-page PDF with a real text layer, so the index has something true to find.
    ///
    /// The words are deliberately ordinary construction vocabulary and deliberately not the
    /// vocabulary of the old mock hit list: a test that searched for a word the mock also
    /// returned could not tell the two presenters apart.
    static func writeTextFixturePDF(
        text: String = "SCREED BAY 7 THICKNESS 65MM",
        named name: String = "Plan T-201.pdf"
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)

        let content = Data("BT /F1 18 Tf 72 700 Td (\(text)) Tj ET\n".utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("""
            << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R \
            /Resources << /Font << /F1 5 0 R >> >> >>
            """.utf8)
        ]
        var streamData = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        streamData.append(content)
        streamData.append(Data("\nendstream".utf8))
        objects.append(streamData)
        objects.append(Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8))

        var bytes = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n".utf8))
            bytes.append(object)
            bytes.append(Data("\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        bytes.append(Data("""
        trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n
        """.utf8))
        try bytes.write(to: url)
        return url
    }

    /// An image-only drawing: words drawn into a grayscale bitmap that is the page's only
    /// content — no text layer, no font — the shape of a rasterised scan (L-20).
    ///
    /// Built here rather than checked in, so the words are declared next to the picture of them;
    /// 48-point Helvetica at two pixels per point, the size `ZPDFSearch`'s own scanned-sheet
    /// fixture uses so recognition reads it reliably.
    static func writeScannedFixturePDF(
        lines: [String] = ["CORRIDOR", "SCREED BAY 7"],
        named name: String = "Scan C-301.pdf"
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let scale: CGFloat = 2
        let width = Int(mediaBox.width * scale), height = Int(mediaBox.height * scale)
        guard let bitmap = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw AppTestSupport.FixtureError(reason: "no bitmap context") }
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Helvetica", size: 48 * scale) ?? NSFont.systemFont(ofSize: 48 * scale),
            .foregroundColor: NSColor.black
        ]
        var baseline = CGFloat(height) - 160 * scale
        for line in lines {
            (line as NSString).draw(at: CGPoint(x: 72 * scale, y: baseline), withAttributes: attributes)
            baseline -= 96 * scale
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.makeImage(),
              let pdf = CGContext(url as CFURL, mediaBox: &mediaBox, nil)
        else { throw AppTestSupport.FixtureError(reason: "no image or no PDF context") }
        pdf.beginPDFPage(nil)
        pdf.interpolationQuality = .high
        pdf.draw(image, in: mediaBox)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    /// A scratch container for the index, so no test writes into the real Application Support.
    static func withScratchIndexRoot<T>(_ body: () async throws -> T) async rethrows -> T {
        let previous = ZenitPDFProjectDocument.searchIndexRootOverride
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenitpdf-index-\(UUID().uuidString)", isDirectory: true)
        ZenitPDFProjectDocument.searchIndexRootOverride = root
        // The root is left for the system to reclaim rather than deleted here. The override is
        // one process-wide static and three dozen suites run at once: documents belonging to
        // other suites open their index in this directory too, and unlinking it while their
        // SQLite files are open is `disk I/O error` in a test that has nothing to do with
        // search. A uniquely named directory in the per-user temporary directory is the
        // cheaper mistake.
        defer { ZenitPDFProjectDocument.searchIndexRootOverride = previous }
        return try await body()
    }

    /// Opens a document on a text fixture and waits until its index is attached **and filled**.
    ///
    /// The second wait is not politeness. The drawing's text layer is read by a `.utility`
    /// task on the main actor, and this package runs thirty-odd suites in parallel; polling for
    /// a hit with a timeout made this suite pass alone and fail in the full run. `settleTextIndexing()`
    /// awaits the real task, so the assertions below are about the index, never about the
    /// machine's mood.
    static func openIndexedDocument(
        text: String = "SCREED BAY 7 THICKNESS 65MM"
    ) async throws -> (document: ZenitPDFProjectDocument, url: URL) {
        let url = try writeTextFixturePDF(text: text)
        let document = try AppTestSupport.makeDocument(opening: url)
        // A generous bound rather than the default ten seconds. These two waits are for a
        // one-page fixture to finish opening, which takes milliseconds on an idle machine and
        // can take far longer on a loaded one; the assertion is "the shell and the index
        // arrive", not "they arrive quickly", and a deadline tuned to an idle machine turns
        // that into a report on the machine. A drawing that never opens still fails here.
        #expect(await AppTestSupport.wait(upTo: 60) { document.shell != nil })
        #expect(await AppTestSupport.wait(upTo: 60) { document.searchIndex != nil })
        await document.settleTextIndexing()
        return (document, url)
    }

    /// Draws one calibrated length through the shipping measurement palette, so the ledger has a
    /// real row with a real number in it.
    static func commitOneLength(core: AppCoreEnvironment) async throws {
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 72, y: 72),
            second: PDFPoint(x: 372, y: 72),
            knownLength: Decimal(30),
            knownLengthUnit: .metre
        )
        await core.refresh()
        core.measurement.activate(kind: .length)
        core.measurement.placePoint(PDFPointValue(x: 72, y: 272))
        core.measurement.placePoint(PDFPointValue(x: 372, y: 272))
        await core.measurement.settlePlacements()
        core.measurement.commitActiveMeasurement()
        _ = await AppTestSupport.wait { core.ledger.rowCount == 1 }
    }

    /// Runs a query through the shipping presenter and waits for the index to answer.
    static func search(_ presenter: any SearchPresenting, for query: String) async {
        presenter.query = query
        presenter.runSearch()
        _ = await AppTestSupport.wait(upTo: 20) { !presenter.isSearching && !presenter.hits.isEmpty }
    }

    // MARK: - 1. No fabricated results

    @Test("The shipping document binds the real search presenter, never a mock")
    func searchPanelIsNotAMock() async throws {
        try await Self.withScratchIndexRoot {
            let (document, url) = try await Self.openIndexedDocument()
            defer {
                document.close()
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }

            #expect(document.searchPresenter is AppSearchPresenter)
            #expect(!(document.searchPresenter is MockSearchPresenter))

            // And the panel is bound to that same object, not to a second one built for the shell.
            let shell = try #require(document.shell)
            #expect(!(shell.search is MockSearchPresenter))
            #expect(ObjectIdentifier(shell.search as AnyObject)
                    == ObjectIdentifier(document.searchPresenter as AnyObject))
        }
    }

    @Test("A word on the drawing is found, and a word that is not returns an honest empty state")
    func searchFindsRealTextAndRefusesToInventIt() async throws {
        try await Self.withScratchIndexRoot {
            let (document, url) = try await Self.openIndexedDocument()
            defer {
                document.close()
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }

            let presenter = try #require(document.searchPresenter as? AppSearchPresenter)
            presenter.debounce = .milliseconds(1)

            await Self.search(presenter, for: "SCREED")
            #expect(!presenter.hits.isEmpty, "a word printed on the page must be found")
            let hit = try #require(presenter.hits.first)
            #expect(hit.source == .pdfText)
            #expect(hit.snippet.uppercased().contains("SCREED"))
            #expect(presenter.resultSummary.contains("result"))

            // The other half of honesty: a word that is not on the drawing produces nothing.
            // The mock filtered a sample hit list by substring, so it could answer this one too —
            // what it could not do is answer the first query with the page's own words.
            presenter.query = "GALVANISED BALUSTRADE"
            presenter.runSearch()
            _ = await AppTestSupport.wait(upTo: 10) { !presenter.isSearching }
            #expect(presenter.hits.isEmpty)
        }
    }

    @Test("An index that cannot be opened says so instead of reporting no results")
    func unavailableIndexIsStated() {
        let presenter = UnavailableSearchPresenter()
        presenter.query = "screed"
        presenter.runSearch()
        #expect(presenter.hits.isEmpty)
        #expect(presenter.resultSummary.lowercased().contains("unavailable"))
        // "No results" would be a claim that the drawing was searched. It was not.
        #expect(!presenter.resultSummary.lowercased().contains("no results"))
    }

    @Test("A markup subject typed into the takeoff becomes findable")
    func markupTextReachesTheIndex() async throws {
        try await Self.withScratchIndexRoot {
            let (document, url) = try await Self.openIndexedDocument()
            defer {
                document.close()
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            let core = try #require(document.core)
            try await Self.commitOneLength(core: core)
            let markupID = try #require(core.snapshot.markups.first?.id)
            _ = try await core.commands.perform(
                .editSubject(id: MarkupID(markupID), subject: "Perimeter kerb upstand")
            )
            await core.refresh()
            await document.reindexMarkups()

            let presenter = try #require(document.searchPresenter as? AppSearchPresenter)
            presenter.debounce = .milliseconds(1)
            await Self.search(presenter, for: "upstand")
            let hit = try #require(presenter.hits.first)
            #expect(hit.source == .markups)
            #expect(hit.markupID != nil, "a markup hit must resolve to the markup it came from")
        }
    }

    @Test("The index survives closing and reopening the same drawing")
    func indexIsKeyedByTheFileNotBySession() async throws {
        try await Self.withScratchIndexRoot {
            let url = try Self.writeTextFixturePDF()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            let first = try AppTestSupport.makeDocument(opening: url)
            #expect(await AppTestSupport.wait(upTo: 60) { first.searchIndex != nil })
            let firstKey = try #require(first.searchIndex).documentKey
            first.close()

            let second = try AppTestSupport.makeDocument(opening: url)
            #expect(await AppTestSupport.wait(upTo: 60) { second.searchIndex != nil })
            let secondKey = try #require(second.searchIndex).documentKey
            second.close()

            // Same bytes, same key — otherwise every recognition run would be thrown away by
            // closing the window that produced it.
            #expect(firstKey == secondKey)
            #expect(firstKey.count == 64, "the key is the drawing's SHA-256")
        }
    }

    // MARK: - 2. The recognition run

    @Test("The OCR sheet has a caller, and a run reports every requested page")
    func recognitionRunIsReachableAndReportsEveryPage() async throws {
        try await Self.withScratchIndexRoot {
            let (document, url) = try await Self.openIndexedDocument()
            let controller = ProjectWindowController(document: document)
            defer {
                controller.close()
                document.close()
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            let core = try #require(document.core)

            let model = controller.makeOCRRunModel(for: document, pages: core.snapshot.pages)
            model.rangeSelection = .allPages
            #expect(model.canStart)
            #expect(model.resolvedPageIndices.count == core.snapshot.pages.count)

            model.start()
            #expect(model.phase == .running)
            #expect(await AppTestSupport.wait(upTo: 60) {
                model.phase == .finished || model.phase == .cancelled
            })
            #expect(model.phase == .finished)

            // Every requested page came back with a verdict. A page with a real text layer is
            // skipped rather than recognised, and it says "no text found" rather than quietly
            // counting as read — the sheet must never imply coverage the index does not have.
            #expect(model.pageResults.count == core.snapshot.pages.count)
            #expect(model.pageResults.allSatisfy { $0.status != .indexing })
            #expect(model.progressFraction == 1)
        }
    }

    @Test("A recognition run feeds the search index, and its results are labelled as recognised")
    func recognitionFeedsTheSearchIndex() async throws {
        try await Self.withScratchIndexRoot {
            let (document, url) = try await Self.openIndexedDocument()
            let controller = ProjectWindowController(document: document)
            defer {
                controller.close()
                document.close()
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            let core = try #require(document.core)

            let model = controller.makeOCRRunModel(for: document, pages: core.snapshot.pages)
            model.rangeSelection = .allPages
            // Read the page even though it carries a text layer: the fixture is the only page
            // there is, and the point of the test is the path from Vision to the index.
            model.skipsPagesWithText = false
            model.start()
            #expect(await AppTestSupport.wait(upTo: 120) { model.phase == .finished })

            let read = try #require(model.pageResults.first)
            #expect(read.status == .indexed, "recognition wrote no tokens for the page")
            #expect(read.recognizedWordCount > 0)
            let confidence = try #require(read.confidence)
            #expect(confidence > 0 && confidence <= 1)
            #expect(read.confidenceBand != nil, "a page that was read reports how sure it is")

            // The whole reason to run OCR: the words become findable. Scoped to recognised text
            // only, so a hit cannot come from the page's own text layer. (That the default scope
            // finds recognised words, untouched, is the next test's job — L-20.)
            let presenter = try #require(document.searchPresenter as? AppSearchPresenter)
            presenter.debounce = .milliseconds(1)
            presenter.scope = SearchScope(location: .currentDocument, sources: [.ocrText])
            await Self.search(presenter, for: "SCREED")
            let hit = try #require(presenter.hits.first, "recognised text did not reach the index")
            #expect(hit.source == .ocrText)
            // And it says where it came from. A recognised word must never be presented as if it
            // had been read off the drawing's own text layer.
            #expect(presenter.showsOCRDisclaimer)
        }
    }

    @Test("L-20: words recognised on an image-only drawing are found by a search that never touched the scope")
    func recognisedWordsAreFoundWithTheDefaultScope() async throws {
        try await Self.withScratchIndexRoot {
            let url = try Self.writeScannedFixturePDF()
            let document = try AppTestSupport.makeDocument(opening: url)
            let controller = ProjectWindowController(document: document)
            defer {
                controller.close()
                document.close()
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            #expect(await AppTestSupport.wait(upTo: 60) { document.shell != nil })
            #expect(await AppTestSupport.wait(upTo: 60) { document.searchIndex != nil })
            await document.settleTextIndexing()
            let core = try #require(document.core)
            let presenter = try #require(document.searchPresenter as? AppSearchPresenter)
            presenter.debounce = .milliseconds(1)
            // The scope the window made, which this test never assigns.
            let untouched = presenter.scope
            #expect(untouched == SearchScope.default)

            // Non-vacuous fixture: before recognition the scan has no word to find.
            presenter.query = "CORRIDOR"
            presenter.runSearch()
            #expect(await AppTestSupport.wait(upTo: 20) { !presenter.isSearching })
            #expect(presenter.hits.isEmpty, "an image-only page has no text layer: \(presenter.hits.map(\.snippet))")

            // Read every page, exactly as Tools ▸ Read Text from Scanned Pages does. The page has
            // no text layer, so the default "skip pages that already have real text" reads it.
            let model = controller.makeOCRRunModel(for: document, pages: core.snapshot.pages)
            model.rangeSelection = .allPages
            #expect(model.skipsPagesWithText)
            model.start()
            #expect(await AppTestSupport.wait(upTo: 120) { model.phase != .running && model.phase != .cancelling })
            #expect(model.phase == .finished, "\(model.phase)")
            #expect(model.pageResults.map(\.status) == [.indexed], "\(model.pageResults.map(\.status))")
            #expect(model.finishedOutcome == .wordsFound)

            // Old: SearchScope's default sources left `.ocrText` out and nothing added it, so this
            // search reached no recognised row and the panel said "No results".
            await Self.search(presenter, for: "CORRIDOR")
            #expect(presenter.scope == untouched, "the scope was never touched")
            let hit = try #require(
                presenter.hits.first { $0.source == .ocrText },
                "a recognised word was not found by the default search: \(presenter.resultSummary)"
            )
            #expect(hit.snippet.localizedCaseInsensitiveContains("CORRIDOR"))
            #expect(presenter.hits.allSatisfy { $0.source == .ocrText }, "the scan has no other text to find")
            // Still labelled as recognised: the panel shows the search-aid disclaimer beside it.
            #expect(presenter.showsOCRDisclaimer)
        }
    }

    @Test("Recognised text is labelled a search aid, not a transcription")
    func recognitionStatesWhatItIs() {
        #expect(OCRDisclosure.searchAidOnly.contains("not a certified transcription"))
        #expect(OCRDisclosure.localOnly.contains("this Mac"))
    }

    @Test("Read Text from Scanned Pages is in the Tools menu and routes to the sheet")
    func recognitionHasAMenuEntry() throws {
        let bar = ZenitMenuBar.make()
        let tools = try #require(
            bar.items.compactMap(\.submenu).first { $0.title == ZPDFCommandGroup.tools.displayName }
        )
        let item = try #require(
            tools.items.first { ($0.representedObject as? String) == ZenitAppCommand.readScannedText.rawValue }
        )
        #expect(item.action == #selector(ZenitCommandResponding.performZenitCommand(_:)))
        #expect(item.title.contains("Read Text"))
    }

    @Test("The recognition command is offered only when there is an index to write into")
    func recognitionCommandIsValidated() async throws {
        try await Self.withScratchIndexRoot {
            let (document, url) = try await Self.openIndexedDocument()
            let controller = ProjectWindowController(document: document)
            defer {
                controller.close()
                document.close()
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            let item = NSMenuItem()
            item.representedObject = ZenitAppCommand.readScannedText.rawValue
            #expect(controller.validateMenuItem(item))

            let empty = ProjectWindowController(document: ZenitPDFProjectDocument())
            defer { empty.close() }
            #expect(!empty.validateMenuItem(item))
        }
    }

    // MARK: - 3. The export formats

    @Test("The export dialog offers four formats, each with the extension it actually writes")
    func exportDialogOffersEveryFinishedFormat() {
        let formats = ExportAccessoryView.Format.allCases
        #expect(formats.count == 4)
        #expect(formats.map(\.fileExtension) == ["csv", "xlsx", "zpdfjson", "pdf"])
        // The audit trail rides inside the file or it is not offered. A ticked checkbox that
        // does nothing is a claim about what was exported.
        #expect(ExportAccessoryView.Format.xlsx.carriesAuditTrail == false)
        #expect(ExportAccessoryView.Format.zenitJSON.carriesAuditTrail == false)
        #expect(ExportAccessoryView.Format.csv.carriesAuditTrail)
        #expect(ExportAccessoryView.Format.pdfReport.carriesAuditTrail)
    }

    @Test("The save panel's extension follows the chosen format")
    func exportPanelExtensionFollowsFormat() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Takeoff.csv"
        let accessory = ExportAccessoryView(panel: panel)
        accessory.selectForTesting(.xlsx)
        #expect(panel.nameFieldStringValue == "Takeoff.xlsx")
        #expect(panel.allowedContentTypes.first?.preferredFilenameExtension == "xlsx")
        accessory.selectForTesting(.zenitJSON)
        #expect(panel.nameFieldStringValue == "Takeoff.zpdfjson")
    }

    @Test("XLSX and Zenit JSON are written from the same projection as the PDF report")
    func projectedFormatsAgreeDigitForDigit() async throws {
        try await Self.withScratchIndexRoot {
            let (document, url) = try await Self.openIndexedDocument()
            defer {
                document.close()
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            let core = try #require(document.core)
            try await Self.commitOneLength(core: core)

            let projection = try await ProjectWindowController.projection(
                core: core,
                documentName: "Takeoff",
                scaleDescription: core.snapshot.firstPageScale?.displayString,
                request: core.ledger.request
            )

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("zenitpdf-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let workbook = directory.appendingPathComponent("Takeoff.xlsx")
            try XLSXExporter().export(projection, to: workbook)
            let workbookBytes = try Data(contentsOf: workbook)
            #expect(workbookBytes.count > 0)
            #expect(workbookBytes.prefix(2) == Data("PK".utf8), "an .xlsx is a zip archive")

            let jsonURL = directory.appendingPathComponent("Takeoff.zpdfjson")
            let jsonBytes = ZenitJSONExporter().export(projection)
            try jsonBytes.write(to: jsonURL, options: .atomic)

            // Digit for digit: every cell the projection produced is in the interchange file with
            // the same text. One projection, one rounding, one number — which is the reason the
            // projection exists and the reason all three formats go through it.
            let reread = try ZenitJSONImporter().document(from: jsonBytes)
            let projectedDisplay = projection.table.rows.flatMap { $0.cells.map(\.text) }
            let importedDisplay = reread.rows.flatMap { $0.cells.map(Self.displayText) }
            #expect(!projectedDisplay.isEmpty)
            #expect(projectedDisplay == importedDisplay)

            // And the unrounded value the reader is meant to compute from, not just the string
            // the estimator read. QUALITY_BAR A32 keeps `raw` authoritative.
            let projectedRaw = projection.table.rows.flatMap { row in
                row.cells.compactMap { $0.number?.invariantRawText }
            }
            let importedRaw = reread.rows.flatMap { row in
                row.cells.compactMap { cell -> String? in
                    if case .number(let number) = cell { return number.raw }
                    return nil
                }
            }
            #expect(!projectedRaw.isEmpty)
            #expect(projectedRaw == importedRaw)
        }
    }

    /// The one string an interchange cell renders as, matching ``ZPDFExport/ExportCell/text``.
    static func displayText(_ cell: ZenitInterchangeDocument.Cell) -> String {
        switch cell {
        case .blank: return ""
        case .text(let value): return value
        case .number(let number): return number.display
        case .date(let value): return value
        case .boolean(let flag): return flag ? "TRUE" : "FALSE"
        case .refusal(let token): return token
        }
    }

    // MARK: - 4. The launch gate

    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ZenitPDFAppKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Apps/ZenitPDF
        .deletingLastPathComponent()   // Apps
        .deletingLastPathComponent()   // repository root

    @Test("A gate exists that starts the assembled bundle, and CI runs it")
    func launchGateExistsAndIsWiredIntoCI() throws {
        let script = Self.repositoryRoot
            .appendingPathComponent("Scripts/verify-app-launches.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        #expect(FileManager.default.isExecutableFile(atPath: script.path))

        let source = try String(contentsOf: script, encoding: .utf8)
        #expect(source.contains("open -gj"), "the gate must not steal the user's focus")
        #expect(source.contains("pgrep"), "the gate must prove nothing was left running")

        let workflow = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )
        #expect(workflow.contains("Scripts/verify-app-launches.sh"))
    }

    /// The dead-hook gate, held to the same rule as the launch gate: it exists, it is
    /// executable, and CI runs it.
    ///
    /// It is the gate for the third form of the wiring disease this suite already covers twice —
    /// `noMockPresenterInTheApplication` catches a mock in a shipping path, and this one catches
    /// a `public var on…` closure the declaring type calls and nobody installs. A hook like that
    /// compiles, passes every package test, and does nothing at runtime.
    @Test("A gate exists that fails on a hook nothing assigns, and CI runs it")
    func hookWiringGateExistsAndIsWiredIntoCI() throws {
        let script = Self.repositoryRoot.appendingPathComponent("Scripts/verify-hook-wiring.sh")
        #expect(FileManager.default.fileExists(atPath: script.path))
        #expect(FileManager.default.isExecutableFile(atPath: script.path))

        let workflow = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )
        #expect(workflow.contains("Scripts/verify-hook-wiring.sh"))
    }

    /// The live-defect register is the one part of the dead-hook gate that can rot into a hiding
    /// place, so it is pinned from outside the script.
    ///
    /// `verify-hook-wiring.sh` already refuses a register entry that is no longer dead, an entry
    /// with no note, and a register whose size does not match its own declared constant. What it
    /// cannot check is whether the reference on each line points at anything real: a line
    /// reading `see above` would satisfy the script and tell the next reader nothing. This
    /// asks the script for the register — `--print-register`, not a grep over its prose, because
    /// a test that greps a comment dies when someone rewrites the comment —
    /// and holds every row to three things: a `Module.Type.hook` key, a defect ID in the
    /// repository's `ABC-123` form, and a note long enough to say what a person does that does
    /// nothing.
    ///
    /// The ceiling is the count triaged on 2026-08-25. It is a ceiling, not a target: the
    /// register may shrink freely and cannot grow past it without a person changing this number
    /// and saying why in the same diff.
    ///
    /// **The register is empty as of 2026-08-26**, all five wired in one pass, and that changed
    /// what this test's own non-vacuity has to rest on. It used to be `!rows.isEmpty` — "the
    /// register printed nothing; a vacuous pass is a failed check" — which was right while five
    /// entries stood and becomes a demand that the defects come back the moment they are fixed.
    /// The thing that must not be vacuous is *this check*, not the register: so the script is
    /// required to exist, to exit 0, and to declare a `DEFECT_REGISTER_SIZE` that equals the
    /// number of rows it actually printed. A script that printed nothing because it was
    /// truncated, renamed or broken declares nothing either, and fails here.
    @Test("Every live defect the hook gate tolerates names a defect ID and what it breaks")
    func hookGateDefectRegisterIsHonest() throws {
        let script = Self.repositoryRoot.appendingPathComponent("Scripts/verify-hook-wiring.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--print-register"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "--print-register exited \(process.terminationStatus)")

        let rows = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(rows.count <= 5, "the register grew to \(rows.count); it was 5 on 2026-08-25")

        // The non-vacuity floor of this test itself: the script must still declare the size it
        // printed. Zero rows is a legitimate answer — and only when the script says zero.
        let scriptText = try String(contentsOf: script, encoding: .utf8)
        let declared = scriptText
            .split(separator: "\n")
            .compactMap { line -> Int? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("readonly DEFECT_REGISTER_SIZE=") else { return nil }
                return Int(trimmed.dropFirst("readonly DEFECT_REGISTER_SIZE=".count))
            }
            .first
        #expect(declared != nil, "verify-hook-wiring.sh no longer declares DEFECT_REGISTER_SIZE")
        #expect(
            declared == rows.count,
            "the register printed \(rows.count) row(s) and declares DEFECT_REGISTER_SIZE=\(declared.map(String.init) ?? "none")"
        )

        for row in rows {
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            #expect(parts.count == 2, "register row is not key<TAB>note: \(row)")
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let note = parts[1]
            #expect(
                key.split(separator: ".").count >= 3,
                "a register key must be Module.Type.hook, not a bare name: \(key)"
            )
            #expect(
                note.range(of: #"\b[A-Z][A-Z0-9]*-[0-9]+\b"#, options: .regularExpression) != nil,
                "register entry \(key) names no defect ID: \(note)"
            )
            #expect(
                note.count > 40,
                "register entry \(key) must say what a person does that does nothing: \(note)"
            )
        }
    }

    /// One row of `Scripts/verify-app-launches.sh --print-contract`.
    struct LaunchContractRow: Sendable {
        var marker: String
        var check: String
        var mechanism: String
    }

    /// Ask the gate for its contract. This runs the script, not a grep over it: the script prints
    /// the table it actually titles its own checks from, so the answer cannot be stale prose.
    static func launchContract() throws -> [LaunchContractRow] {
        let script = repositoryRoot.appendingPathComponent("Scripts/verify-app-launches.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--print-contract"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "--print-contract must not fail or launch anything")
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return LaunchContractRow(
                marker: String(fields[0]),
                check: String(fields[1]),
                mechanism: String(fields[2])
            )
        }
    }

    /// Every marker the application declares is answered by a check in the gate.
    ///
    /// This used to assert the *contents of a shell script* — that
    /// `Scripts/verify-app-launches.sh` contained the literals `ZENIT-LAUNCH ready` and
    /// `ZENIT-LAUNCH run-loop-serviced` somewhere in its text. Both literals were in a comment,
    /// so rewriting that comment turned the whole application package red on 2026-08-25 while
    /// nothing the gate does had changed. A test that pins prose measures
    /// editing, not behaviour.
    ///
    /// The contract now lives in exactly one place — the `LAUNCH_CONTRACT` table in the script —
    /// and has two readers: the script titles checks 1-3 out of it, and this test asks for it by
    /// running `--print-contract`. The marker column is compared against the product's own
    /// constants, so the failure this test can still produce is the one worth producing: a marker
    /// the application emits that no check answers, or a check for a marker that no longer exists.
    @Test("Every launch marker the application declares is answered by a check in the gate")
    func launchMarkersMatchTheGate() throws {
        let prefix = ZenitApplicationDelegate.LaunchMarker.prefix
        let declared = [
            "\(prefix) \(ZenitApplicationDelegate.LaunchMarker.begin)",
            "\(prefix) \(ZenitApplicationDelegate.LaunchMarker.ready)",
            "\(prefix) \(ZenitApplicationDelegate.LaunchMarker.runLoopServiced)"
        ]
        let contract = try Self.launchContract()

        // A contract that parsed to nothing must fail, not pass quietly.
        #expect(contract.count == declared.count,
                "the gate declares \(contract.count) rows for \(declared.count) markers: \(contract.map(\.marker))")

        for marker in declared {
            #expect(contract.contains { $0.marker == marker },
                    "no check answers \(marker); the gate covers \(contract.map(\.marker))")
        }
        for row in contract {
            #expect(declared.contains(row.marker),
                    "the gate carries a check for \(row.marker), which the application does not emit")
            #expect(!row.check.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!row.mechanism.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(row.marker) names a check with no mechanism behind it")
        }
        // Distinct checks: three markers answered by one check would satisfy every rule above.
        #expect(Set(contract.map(\.check)).count == contract.count)
    }

    @Test("No mock presenter is constructed anywhere in the shipping application")
    func noMockPresenterInTheApplication() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Apps/ZenitPDF/Sources")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        var scanned = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains("Mock"), line.contains("Presenter(") else { continue }
                offenders.append("\(file.lastPathComponent):\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        // A gate that scanned nothing must fail.
        #expect(scanned > 20, "the scan examined \(scanned) files")
        #expect(offenders.isEmpty, "mock presenters in the shipping app: \(offenders)")
    }

    /// The other test-only seam in this application, held to the same rule.
    ///
    /// `DamagedDrawingRepair.clientOverride` exists so the repair suite can supply the
    /// in-process qpdf executor the application must not link (S17-03). The application
    /// itself must never assign it: an assignment in `Sources` would mean repair had quietly
    /// stopped running in `RepairService.xpc`, which is a sandboxing regression that no
    /// behavioural test would notice, because the repaired file would look identical.
    @Test("The repair client's test seam is never assigned by the shipping application")
    func repairClientOverrideIsTestOnly() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Apps/ZenitPDF/Sources")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        var scanned = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // The declaration itself, and the prose above it, are not assignments.
                guard trimmed.contains("clientOverride"), trimmed.contains("=") else { continue }
                guard !trimmed.hasPrefix("///"), !trimmed.hasPrefix("//"),
                      !trimmed.hasPrefix("static var clientOverride"),
                      !trimmed.contains("clientOverride ??") else { continue }
                offenders.append("\(file.lastPathComponent):\(number + 1): \(trimmed)")
            }
        }
        #expect(scanned > 20, "the scan examined \(scanned) files")
        #expect(offenders.isEmpty, "the app assigns the repair test seam: \(offenders)")
    }

    /// The recovery alert's injection point is a **test** seam, and the shipping application
    /// must never set it.
    ///
    /// Every modal path an app-tier test can reach must be injectable. An injection point the application also uses is not a seam, it is a second
    /// behaviour — so the same scan the repair client gets applies here.
    @Test("The recovery prompt's test seam is never assigned by the shipping application")
    func recoveryPromptOverrideIsTestOnly() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Apps/ZenitPDF/Sources")
        let enumerator = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        )
        var offenders: [String] = []
        var scanned = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("decisionOverride"), trimmed.contains("=") else { continue }
                guard !trimmed.hasPrefix("///"), !trimmed.hasPrefix("//"),
                      !trimmed.hasPrefix("public static var decisionOverride"),
                      !trimmed.contains("if let decisionOverride") else { continue }
                offenders.append("\(file.lastPathComponent):\(number + 1): \(trimmed)")
            }
        }
        #expect(scanned > 20, "the scan examined \(scanned) files")
        #expect(offenders.isEmpty, "the app assigns the recovery test seam: \(offenders)")
    }
}
