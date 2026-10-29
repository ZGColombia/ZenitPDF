import CoreGraphics
import Foundation
import PDFKit
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// The thirty-sheet set fixture read back through the bridge (NL-DOCS-01), and page
/// operations that keep the set's structure (documents bug 5).
@Suite("Next level documents — sheet sets")
struct NextLevelDocumentsSetTests {

    private let kind = FixtureKind.set30SheetsTitleBlocks

    private func set() throws -> FixtureSheetSet {
        try #require(try Corpus.manifest(kind).sheetSet)
    }

    @Test("Every page label, bookmark, named destination and link target reads back")
    func readsBackEverything() async throws {
        let truth = try set()
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: Corpus.url(kind))
        let handle = opened.handle

        let labels = try await provider.pageLabels(of: handle)
        #expect(labels.isExplicit)
        #expect(labels.allLabels() == truth.pageLabels)
        #expect(labels.pageIndex(forLabel: "S-205") == 14)

        // Bookmarks: three sections, ten sheets each, two detail entries under A-102.
        let outline = try await provider.outline(of: handle)
        #expect(outline.roots.map(\.label) == truth.outline.map(\.title))
        for (root, expected) in zip(outline.roots, truth.outline) {
            #expect(root.destination?.pageIndex == expected.pageIndex)
            #expect(root.children.map(\.label) == expected.children.map(\.title))
            #expect(root.children.map { $0.destination?.pageIndex } == expected.children.map(\.pageIndex))
        }
        #expect(outline.roots[0].children[1].children.map(\.label) == ["DETAIL 1", "DETAIL 3"])

        let named = try await provider.namedDestinations(of: handle)
        var resolved: [String: Int] = [:]
        for destination in named { resolved[destination.name] = destination.target.pageIndex }
        #expect(resolved == truth.namedDestinations)

        for page in 0..<truth.sheets.count {
            let annotations = try await provider.annotations(of: handle, pageIndex: page)
                .filter { $0.kind == .link }
            let expected = truth.links.filter { $0.pageIndex == page }
            #expect(annotations.count == expected.count, "page \(page)")
            for link in expected {
                let match = annotations.first { annotation in
                    abs(annotation.bounds.minX - link.rect.llx) < 0.01 && abs(annotation.bounds.minY - link.rect.lly) < 0.01
                }
                let action = try #require(match?.action, "page \(page) link at \(link.rect)")
                switch link.target {
                case let .page(index, _, _): #expect(action == .goToPage(pageIndex: index))
                case let .named(name):
                    // Resolved by PDFKit to its page, or kept by name — both land on the sheet.
                    if case let .goToPage(index) = action {
                        #expect(index == truth.namedDestinations[name])
                    } else {
                        #expect(action == .goToNamedDestination(name))
                    }
                case let .uri(target): #expect(action == .uri(target))
                case .javaScript: #expect(action == .javaScript)
                }
            }
        }
        #expect(truth.references.filter { !$0.resolves }.map(\.citedSheet) == ["A-999"])
    }

    @Test("The sheet number and title are in the title-block regions on every sheet")
    func titleBlockText() throws {
        let manifest = try Corpus.manifest(kind)
        let truth = try set()
        for sheet in truth.sheets {
            let number = try #require(manifest.texts.first { $0.id == "p\(sheet.pageIndex)-number" })
            let title = try #require(manifest.texts.first { $0.id == "p\(sheet.pageIndex)-title" })
            #expect(number.string == sheet.number && title.string == sheet.title)
            #expect(truth.numberRegion.llx <= number.origin.x && number.origin.y >= truth.numberRegion.lly
                    && number.origin.y + number.fontSize * 0.75 <= truth.numberRegion.ury)
            #expect(truth.titleRegion.llx <= title.origin.x && title.origin.y >= truth.titleRegion.lly
                    && title.origin.y + title.fontSize * 0.75 <= truth.titleRegion.ury)
        }
        let document = try #require(PDFDocument(url: Corpus.url(kind)))
        #expect(document.page(at: 12)?.string?.contains("S-203") == true)
        #expect(document.page(at: 12)?.string?.contains("FRAMING PLAN LEVEL 2") == true)
    }

    /// Documents bug 5. Before: the extracted file had labels ["1", "2", "3"], no
    /// outline, and the GoTo link on S-201 pointed at a page of the source document.
    @Test("Extracting sheets keeps their labels, bookmarks and links, and says what it could not keep")
    func extractKeepsStructure() async throws {
        let scratch = try Corpus.scratchDirectory("nl-docs-extract")
        let source = scratch.appendingPathComponent(kind.fileName)
        try? FileManager.default.removeItem(at: source)
        try FileManager.default.copyItem(at: Corpus.url(kind), to: source)
        let before = try FileDigestProbe.hex(of: source)
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: source)
        // A-101, A-102 and S-201 (index 10): A-101's "SEE" link goes to S-201 (0 + 10).
        let destination = DocumentDestination(url: scratch.appendingPathComponent("extract-\(UUID().uuidString).pdf"))
        let receipt = try await provider.extractPages([0, 1, 10], of: opened.handle, to: destination)
        #expect(receipt.pageCount == 3)
        #expect(receipt.sourceIsUnchanged)
        #expect(try FileDigestProbe.hex(of: source) == before)
        #expect(!receipt.structureNotCarried.contains(.pageLabels))
        #expect(receipt.structureNotCarried.contains(.namedDestinations))

        let reader = PDFKitDocumentProvider()
        let result = try await reader.open(fileAt: destination.url)
        let labels = try await reader.pageLabels(of: result.handle)
        #expect(labels.allLabels() == ["A-101", "A-102", "S-201"])

        let outline = try await reader.outline(of: result.handle)
        #expect(outline.roots.map(\.label) == ["ARCHITECTURAL", "STRUCTURAL"])
        #expect(outline.roots[0].children.map(\.label) == ["A-101 SITE PLAN", "A-102 FLOOR PLAN LEVEL 1"])
        #expect(outline.roots[0].children.map { $0.destination?.pageIndex } == [0, 1])
        #expect(outline.roots[1].children.map(\.label) == ["S-201 FOUNDATION PLAN"])
        #expect(outline.roots[1].children.first?.destination?.pageIndex == 2)

        // A-101's SEE S-201 link now lands on the extracted S-201 (index 2); a link whose
        // target was not extracted is gone rather than pointing into nothing.
        let links = try await reader.annotations(of: result.handle, pageIndex: 0).filter { $0.kind == .link }
        let goTos = links.compactMap { link -> Int?? in
            if case let .goToPage(index)? = link.action { return index }
            return nil
        }
        #expect(goTos.contains(2), "links: \(links.map { "\($0.bounds) \(String(describing: $0.action))" })")
        #expect(!goTos.contains(where: { $0 == nil }))
    }

    @Test("The page-label update is refused on a file that is not a classic cross-reference PDF")
    func labelUpdateRefusesOddFiles() throws {
        #expect(PageStructureCarrier.pageLabelUpdate(["A"], appendedTo: Data("not a pdf".utf8)) == nil)
        #expect(PageStructureCarrier.pdfString("A-(1)\\") == "(A-\\(1\\)\\\\)")
        #expect(PageStructureCarrier.pdfString("Å-1") == "<FEFF00C5002D0031>")
    }
}
