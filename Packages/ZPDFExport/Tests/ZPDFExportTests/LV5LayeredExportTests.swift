import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
@testable import ZPDFExport

/// Live test 5, export area (ADR-0042).
///
/// - **L-22**: Export with Markups as a PDF Layer wrote one optional-content group, "Zenit
///   Markups", for every markup; the user's markup layers were not carried into the file.
/// - **L-23**: after Save Markups into PDF the drawing carries Zenit's own annotations, and the
///   layered (and structure-preserving Marked) export kept them while painting the same markups
///   again, so every markup was drawn twice. The first fix then dropped every owner-marked
///   annotation, a colleague's for markups this project does not hold included, though the
///   canvas still draws those (re-fix: only the project's own markups' annotations go).
@Suite("Live test 5: layered export carries markup layers and drops Zenit's own annotations", .sharedHeap)
struct LV5LayeredExportTests {

    // MARK: - Fixtures

    private static let wallID = UUID()
    private static let reviewID = UUID()
    private static let countID = UUID()

    /// Three markups on the plain fixture's sheet, plus a second fragment of the review markup
    /// (a stamp contour, say) whose identity is derived from its markup's.
    private static func job() -> FlattenPage {
        let review = FlattenedPDFWriterTests.filledTriangle(id: reviewID, at: PDFPoint(x: 120, y: 120), size: 60)
        var reviewContour = FlattenedPDFWriterTests.polyline(from: PDFPoint(x: 130, y: 200), to: PDFPoint(x: 200, y: 200))
        reviewContour = RenderableMarkup(
            id: StampArtworkScene.shapeIdentity(base: MarkupID(reviewID), ordinal: 1),
            zIndex: reviewContour.zIndex,
            shape: reviewContour.shape,
            style: reviewContour.style
        )
        var count = FlattenedPDFWriterTests.countSymbol(at: PDFPoint(x: 320, y: 100))
        count = RenderableMarkup(id: MarkupID(countID), zIndex: count.zIndex, shape: count.shape, style: count.style)
        return FlattenPage(
            page: FlattenedPDFWriterTests.page(),
            sourcePageIndex: 0,
            markups: [
                // Draw order (ADR-0036): the lower layer's markups first.
                FlattenedPDFWriterTests.polyline(id: wallID, from: PDFPoint(x: 60, y: 80), to: PDFPoint(x: 300, y: 250)),
                count,
                review,
                reviewContour
            ]
        )
    }

    /// Two layers, top first: "Review A. Berg" (shown) above "Walls" (hidden), and a third layer
    /// whose markups are not on the exported sheet.
    private static let layers: [LayeredMarkupExporter.Layer] = [
        .init(name: "Review A. Berg", visibleByDefault: true, markupIDs: [MarkupID(reviewID)]),
        .init(name: "Empty Layer", visibleByDefault: true, markupIDs: [MarkupID(UUID())]),
        .init(name: "Walls", visibleByDefault: false, markupIDs: [MarkupID(wallID), MarkupID(countID)])
    ]

    // MARK: - L-22

    @Test("L-22: two markup layers give two named groups in layer order, each markup in its own layer's group")
    func twoLayersGiveTwoNamedGroupsInOrder() throws {
        let job = Self.job()
        let produced = try LayeredMarkupExporter().data(
            source: LayeredSourceFixtures.plain(),
            pages: [job],
            options: .init(layers: Self.layers)
        )
        let inspector = try #require(OptionalContentInspector(data: produced.data))
        // Old output: groupNames == ["Zenit Markups"] — one group for every markup.
        #expect(inspector.groupNames == ["Review A. Berg", "Walls"], "the empty layer must not become a group")
        #expect(inspector.orderNames == ["Review A. Berg", "Walls"], "the layer panel lists the layers top first")
        #expect(inspector.onNames == ["Review A. Berg"])
        #expect(inspector.offNames == ["Walls"], "a hidden layer is exported switched off")

        let page = try #require(inspector.pages.first)
        #expect(page.markedContentIsBalanced)
        #expect(page.spans.count == job.markups.count, "one span per markup, as before")
        let groups = page.spans.map { page.propertyGroupNames[$0.propertyName] }
        // Spans keep the job's draw order; the derived contour goes with its markup's layer.
        #expect(groups == ["Walls", "Walls", "Review A. Berg", "Review A. Berg"])

        #expect(produced.outcome.groups.map(\.name) == ["Review A. Berg", "Walls"])
        #expect(produced.outcome.groups.map(\.markupCount) == [1, 2], "markups, not renderer fragments")
        #expect(produced.outcome.groups.map(\.visibleByDefault) == [true, false])
        #expect(produced.outcome.layeredMarkupCount == 3)
        #expect(!produced.outcome.visibleByDefault)
        #expect(produced.outcome.modificationStatement.contains("\"Review A. Berg\" (on by default), \"Walls\" (off by default)"))
        #expect(produced.data.prefix(LayeredSourceFixtures.plain().count) == LayeredSourceFixtures.plain())
    }

    @Test("L-22: the markup layers are appended after the drawing's own layers, never replacing them")
    func markupLayersFollowTheDrawingsOwnLayers() throws {
        let produced = try LayeredMarkupExporter().data(
            source: LayeredSourceFixtures.withOwnLayer(),
            pages: [Self.job()],
            options: .init(layers: Self.layers)
        )
        let inspector = try #require(OptionalContentInspector(data: produced.data))
        #expect(inspector.groupNames == ["Drawing Layer", "Review A. Berg", "Walls"])
        #expect(inspector.orderNames == ["Drawing Layer", "Review A. Berg", "Walls"])
        #expect(inspector.onNames.contains("Drawing Layer") && inspector.onNames.contains("Review A. Berg"))
        #expect(inspector.offNames == ["Walls"])
    }

    @Test("L-22: a markup no layer names goes to the single fallback group, so nothing is lost")
    func unnamedMarkupGoesToTheFallbackGroup() throws {
        let produced = try LayeredMarkupExporter().data(
            source: LayeredSourceFixtures.plain(),
            pages: [Self.job()],
            options: .init(layers: [Self.layers[0]])
        )
        let inspector = try #require(OptionalContentInspector(data: produced.data))
        #expect(inspector.groupNames == ["Review A. Berg", "Zenit Markups"])
        #expect(produced.outcome.groups.map(\.markupCount) == [1, 2])
        // No layers at all: ADR-0013's one group, exactly as before.
        let single = try LayeredMarkupExporter().data(source: LayeredSourceFixtures.plain(), pages: [Self.job()])
        #expect(try #require(OptionalContentInspector(data: single.data)).groupNames == ["Zenit Markups"])
        #expect(single.outcome.groups.map(\.markupCount) == [3])
    }

    // MARK: - L-23

    /// The plain sheet after Save Markups into PDF: the seven fixture markups as Zenit's own
    /// annotations (plus one review reply), a reviewer's note, and the first export's legacy mark.
    private static func savedInto() throws -> (data: Data, fixture: StandardAnnotationWriterTests.Fixture) {
        let fixture = StandardAnnotationWriterTests.fixture()
        let saved = try StandardAnnotationWriterTests.export(
            fixture, source: StandardAnnotationWriterTests.sourceWithForeignAndLegacyAnnotations()
        )
        #expect(try StandardAnnotationWriterTests.annotations(in: saved.data).count == 9)
        return (saved.data, fixture)
    }

    private static func zenitOwned(_ annotations: [(number: Int?, dictionary: [String: PDFObject])]) -> Int {
        annotations.filter { $0.dictionary[StandardAnnotationWriter.ownerKey] != nil }.count
    }

    @Test("L-23: a layered export of a file saved into keeps the reviewer's note and leaves out Zenit's own annotations")
    func layeredExportDropsZenitsOwnAnnotations() throws {
        let (saved, fixture) = try Self.savedInto()
        let page = FlattenPage(page: fixture.page, sourcePageIndex: 0, markups: fixture.all.flatMap(\.appearance))
        for switchable in [true, false] {
            // The stamp and the count are painted only as fragments, matched to their markup by
            // family; the link paints no ink, so it is named, as the app names every markup of
            // the session.
            let produced = try LayeredMarkupExporter().data(
                source: saved, pages: [page],
                options: .init(asSwitchableLayer: switchable, supersededAnnotationNames: [fixture.link.name])
            )
            let annotations = try StandardAnnotationWriterTests.annotations(in: produced.data)
            // Old output: all 9 kept — the 8 Zenit annotations drew every markup a second time
            // over the layer's ink.
            #expect(Self.zenitOwned(annotations) == 0, "switchable \(switchable)")
            #expect(annotations.map { StandardAnnotationWriter.text($0.dictionary["NM"]) } == ["reviewer-1"])
            #expect(produced.outcome.supersededAnnotationCount == 8)
            #expect(produced.data.prefix(saved.count) == saved, "the saved file stays byte for byte at the front")
            #expect(produced.outcome.modificationStatement.contains("8 annotations Zenit wrote for these markups"))
        }
    }

    @Test("L-23: a sheet whose markups are not painted (hidden, off paper) also loses their annotations; a sheet without any is not touched")
    func sheetWithoutMarkupsLosesZenitsAnnotations() throws {
        let fixture = StandardAnnotationWriterTests.fixture()
        let second = FlattenedPDFWriterTests.page(index: 1)
        let saved = try StandardAnnotationWriter().data(
            source: LayeredSourceFixtures.sharedResourcePair(),
            pages: [StandardAnnotationPage(page: second, sourcePageIndex: 1, annotations: fixture.all)]
        ).data
        let produced = try LayeredMarkupExporter().data(
            source: saved,
            pages: [
                FlattenPage(page: FlattenedPDFWriterTests.page(), sourcePageIndex: 0, markups: [
                    FlattenedPDFWriterTests.polyline(from: PDFPoint(x: 60, y: 80), to: PDFPoint(x: 300, y: 250))
                ]),
                FlattenPage(page: second, sourcePageIndex: 1, markups: [])
            ],
            // The sheet's markups are in the project, on a hidden layer: named, not painted.
            options: .init(supersededAnnotationNames: Set(fixture.all.map(\.name)))
        )
        let scan = try PDFDocumentScan(data: produced.data)
        let pages = try scan.pages()
        // Old output: sheet 2 kept its 8 Zenit annotations though none of its markups is painted.
        #expect(StandardAnnotationWriter.existingAnnotations(of: pages[1], scan: scan).isEmpty)
        #expect(produced.outcome.supersededAnnotationCount == 8)
        #expect(produced.outcome.markedPageCount == 1)

        // A drawing with no Zenit annotations: no sheet without markups is superseded.
        let clean = try LayeredMarkupExporter().data(
            source: LayeredSourceFixtures.sharedResourcePair(),
            pages: [
                FlattenPage(page: FlattenedPDFWriterTests.page(), sourcePageIndex: 0, markups: [
                    FlattenedPDFWriterTests.polyline(from: PDFPoint(x: 60, y: 80), to: PDFPoint(x: 300, y: 250))
                ]),
                FlattenPage(page: second, sourcePageIndex: 1, markups: [])
            ]
        )
        let cleanScan = try PDFDocumentScan(data: clean.data)
        let sourceScan = try PDFDocumentScan(data: LayeredSourceFixtures.sharedResourcePair())
        #expect(try cleanScan.pages()[1].dictionary == sourceScan.pages()[1].dictionary)
        #expect(clean.outcome.supersededAnnotationCount == 0)
    }

    @Test("L-23: a colleague's Zenit annotations for markups this project does not hold are kept, as the canvas shows them")
    func colleaguesAnnotationsForOtherMarkupsAreKept() throws {
        // A colleague saved seven markups into the drawing; this project holds none of them (the
        // restore was not pressed) and adds a markup of its own.
        let (saved, fixture) = try Self.savedInto()
        let own = FlattenPage(page: fixture.page, sourcePageIndex: 0, markups: [
            FlattenedPDFWriterTests.polyline(id: UUID(), from: PDFPoint(x: 60, y: 80), to: PDFPoint(x: 300, y: 250))
        ])
        for switchable in [true, false] {
            let produced = try LayeredMarkupExporter().data(
                source: saved, pages: [own], options: .init(asSwitchableLayer: switchable)
            )
            let annotations = try StandardAnnotationWriterTests.annotations(in: produced.data)
            // Old output (first fix): 0 owner-marked annotations left — the colleague's seven
            // markups and the review reply vanished from the file with no note.
            #expect(Self.zenitOwned(annotations) == 8, "switchable \(switchable)")
            #expect(annotations.count == 9)
            #expect(produced.outcome.supersededAnnotationCount == 0)
            #expect(!produced.outcome.modificationStatement.contains("annotations Zenit wrote"))
        }

        // The same project holding one of those markups (restored, then the rest deleted): only
        // that markup's annotation and the reply pointing at it go.
        let one = try LayeredMarkupExporter().data(
            source: saved, pages: [own], options: .init(supersededAnnotationNames: [fixture.area.name.lowercased()])
        )
        let left = try StandardAnnotationWriterTests.annotations(in: one.data)
        #expect(one.outcome.supersededAnnotationCount == 2, "the area and its review reply")
        #expect(Self.zenitOwned(left) == 6)
        #expect(!left.contains { StandardAnnotationWriter.text($0.dictionary["NM"]) == fixture.area.name })
        #expect(left.contains { StandardAnnotationWriter.text($0.dictionary["NM"]) == "reviewer-1" })
    }
}
