import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import Testing
import ZPDFContracts
import ZPDFRenderer
@testable import ZPDFExport

/// NL-PDF-01: one standard annotation per markup, with identity, opacity, style and appearance,
/// appended to the drawing as an incremental update.
///
/// Every assertion re-opens the produced bytes — with this package's own object scanner for the
/// dictionaries, with PDFKit for "another reader sees them", and with Core Graphics for pixels.
@Suite("Standard annotation writer (NL-PDF-01)", .sharedHeap)
struct StandardAnnotationWriterTests {

    // MARK: - Fixtures

    static let blue = RGBAColor(red: 0x1A / 255.0, green: 0x55 / 255.0, blue: 0xCF / 255.0, alpha: 1)
    static let blueFill = RGBAColor(red: 0x1A / 255.0, green: 0x55 / 255.0, blue: 0xCF / 255.0, alpha: 0.2)

    struct Fixture {
        let page: PageDescriptor
        let area: StandardAnnotation
        let arrow: StandardAnnotation
        let cloud: StandardAnnotation
        let stamp: StandardAnnotation
        let count: StandardAnnotation
        let text: StandardAnnotation
        let link: StandardAnnotation
        var all: [StandardAnnotation] { [area, arrow, cloud, stamp, count, text, link] }
    }

    /// Seven markups on the 400 x 300 sheet of `LayeredSourceFixtures.plain()`.
    static func fixture(rotation: PageRotation = .degrees0) -> Fixture {
        let page = FlattenedPDFWriterTests.page(rotation: rotation)
        let areaID = UUID()
        let areaOutline = [
            PDFPoint(x: 40, y: 60), PDFPoint(x: 180, y: 60),
            PDFPoint(x: 180, y: 160), PDFPoint(x: 40, y: 160)
        ]
        let area = StandardAnnotation(
            id: areaID,
            geometry: .polygon(areaOutline),
            contents: "Slab\n14.0 m²",
            subject: "Concrete",
            author: "Estimator",
            creationDate: Date(timeIntervalSince1970: 1_790_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_790_000_600),
            stroke: blue,
            fill: blueFill,
            lineWidth: 1.5,
            intent: .polygonDimension,
            reviewState: .accepted,
            appearance: [
                RenderableMarkup(
                    id: MarkupID(areaID),
                    shape: .filledPolygon(RenderPolygon(outer: areaOutline)),
                    style: RenderStyle(stroke: blue, fill: blueFill, lineWidth: 1.5)
                ),
                RenderableMarkup(
                    id: StampArtworkScene.shapeIdentity(base: MarkupID(areaID), ordinal: 1),
                    zIndex: 1,
                    shape: .labelPill(RenderLabelPill(anchorPoint: PDFPoint(x: 110, y: 110), text: "14.0 m²")),
                    style: RenderStyle(stroke: blue, lineWidth: 1)
                )
            ]
        )

        let arrowID = UUID()
        let arrow = StandardAnnotation(
            id: arrowID,
            geometry: .line(start: PDFPoint(x: 220, y: 60), end: PDFPoint(x: 360, y: 120)),
            subject: "Arrow",
            stroke: blue,
            lineWidth: 2,
            dash: [6, 3],
            endEnding: .closedArrow,
            appearance: [RenderableMarkup(
                id: MarkupID(arrowID),
                shape: .polyline(RenderPolyline(
                    points: [PDFPoint(x: 220, y: 60), PDFPoint(x: 360, y: 120)], isClosed: false
                )),
                style: RenderStyle(stroke: blue, lineWidth: 2, dash: .pattern(runs: [6, 3], phase: 0))
            )]
        )

        let cloudID = UUID()
        let cloudOutline = [
            PDFPoint(x: 220, y: 200), PDFPoint(x: 300, y: 200),
            PDFPoint(x: 300, y: 260), PDFPoint(x: 220, y: 260)
        ]
        let cloud = StandardAnnotation(
            id: cloudID,
            geometry: .polygon(cloudOutline),
            subject: "Cloud",
            stroke: RGBAColor(red: 0.9, green: 0.1, blue: 0.1),
            lineWidth: 1.5,
            cloudy: true,
            intent: .polygonCloud,
            appearance: [RenderableMarkup(
                id: MarkupID(cloudID),
                shape: .polyline(RenderPolyline(points: cloudOutline, isClosed: true)),
                style: RenderStyle(stroke: RGBAColor(red: 0.9, green: 0.1, blue: 0.1), lineWidth: 1.5)
            )]
        )

        // A stamp whose artwork compiled to 500 contours: the first annotated export wrote 500
        // polygons for it.
        let stampID = UUID()
        var contours: [RenderableMarkup] = []
        for index in 0..<500 {
            let x = 40 + Double(index % 25) * 3
            let y = 200 + Double(index / 25) * 3
            contours.append(RenderableMarkup(
                id: StampArtworkScene.shapeIdentity(base: MarkupID(stampID), ordinal: index + 1),
                zIndex: index,
                shape: .filledPolygon(RenderPolygon(outer: [
                    PDFPoint(x: x, y: y), PDFPoint(x: x + 2, y: y), PDFPoint(x: x + 2, y: y + 2)
                ])),
                style: RenderStyle(stroke: nil, fill: RGBAColor(red: 0.8, green: 0.1, blue: 0.1), lineWidth: 0)
            ))
        }
        let stamp = StandardAnnotation(
            id: stampID,
            geometry: .stamp,
            contents: "APPROVED",
            subject: "Stamp",
            stroke: RGBAColor(red: 0.8, green: 0.1, blue: 0.1),
            appearance: contours
        )

        // A count group of three crosses: the first export wrote each as a /Square.
        let countID = UUID()
        let count = StandardAnnotation(
            id: countID,
            geometry: .stamp,
            contents: "Outlets\n3 ea",
            subject: "Outlets",
            stroke: RGBAColor(red: 0.1, green: 0.5, blue: 0.1),
            appearance: [PDFPoint(x: 330, y: 200), PDFPoint(x: 350, y: 220), PDFPoint(x: 370, y: 240)]
                .enumerated().map { index, centre in
                    RenderableMarkup(
                        id: StampArtworkScene.shapeIdentity(base: MarkupID(countID), ordinal: index + 1),
                        zIndex: index,
                        shape: .countSymbol(RenderCountSymbol(center: centre, symbol: .cross, size: 12)),
                        style: RenderStyle(
                            stroke: RGBAColor(red: 0.1, green: 0.5, blue: 0.1),
                            fill: RGBAColor(red: 0.1, green: 0.5, blue: 0.1),
                            lineWidth: 1
                        )
                    )
                }
        )

        let textID = UUID()
        let text = StandardAnnotation(
            id: textID,
            geometry: .freeText(PDFRect(x: 40, y: 270, width: 120, height: 20), callout: []),
            contents: "Check with engineer",
            stroke: blue,
            fontSize: 11,
            appearance: [RenderableMarkup(
                id: MarkupID(textID),
                shape: .textLabel(RenderTextLabel(
                    anchorPoint: PDFPoint(x: 40, y: 290), text: "Check with engineer", fontSize: 11, anchor: .topLeading
                )),
                style: RenderStyle(stroke: blue, fill: blue, lineWidth: 1)
            )]
        )

        let link = StandardAnnotation(
            id: UUID(),
            geometry: .link(PDFRect(x: 200, y: 280, width: 80, height: 14), uri: "https://example.org/detail-5"),
            contents: "Detail 5"
        )

        return Fixture(page: page, area: area, arrow: arrow, cloud: cloud, stamp: stamp, count: count, text: text, link: link)
    }

    static func export(
        _ fixture: Fixture,
        source: Data = LayeredSourceFixtures.plain()
    ) throws -> (data: Data, outcome: StandardAnnotationOutcome) {
        try StandardAnnotationWriter().data(
            source: source,
            pages: [StandardAnnotationPage(page: fixture.page, sourcePageIndex: 0, annotations: fixture.all)]
        )
    }

    /// The annotation dictionaries on page 1, resolved.
    static func annotations(in data: Data) throws -> [(number: Int?, dictionary: [String: PDFObject])] {
        let scan = try PDFDocumentScan(data: data)
        let page = try #require(try scan.pages().first)
        return StandardAnnotationWriter.existingAnnotations(of: page, scan: scan).compactMap { element in
            guard let dictionary = scan.object(element)?.dictionaryValue else { return nil }
            return (element.referenceValue?.number, dictionary)
        }
    }

    static func named(_ id: UUID, in annotations: [(number: Int?, dictionary: [String: PDFObject])])
        -> [String: PDFObject]? {
        annotations.first { StandardAnnotationWriter.text($0.dictionary["NM"]) == id.uuidString }?.dictionary
    }

    // MARK: - One annotation per markup, with identity

    @Test("Exactly one annotation per markup, plus one hidden reply for the reviewed one")
    func oneAnnotationPerMarkup() throws {
        let fixture = Self.fixture()
        let produced = try Self.export(fixture)
        let annotations = try Self.annotations(in: produced.data)
        // Seven markups and one review-state reply. The first annotated export mapped renderer
        // fragments, not markups: 1 area polygon + 1 value-pill FreeText + 1 line + 1 cloud +
        // 500 stamp polygons + 3 squares + 1 FreeText = 508 annotations, and no reply.
        #expect(annotations.count == 8)
        #expect(produced.outcome.writtenAnnotationCount == 7)
        #expect(produced.outcome.reviewReplyCount == 1)
        for markup in fixture.all {
            let dictionary = try #require(Self.named(markup.id, in: annotations), "no /NM for \(markup.id)")
            #expect(dictionary[StandardAnnotationWriter.ownerKey] == .boolean(true))
        }
    }

    @Test("A stamp of 500 contours is one /Stamp, and a count group is a /Stamp, not a /Square")
    func stampAndCountAreSingleStamps() throws {
        let fixture = Self.fixture()
        let annotations = try Self.annotations(in: try Self.export(fixture).data)
        let stamp = try #require(Self.named(fixture.stamp.id, in: annotations))
        #expect(stamp["Subtype"]?.nameValue == "Stamp")
        let count = try #require(Self.named(fixture.count.id, in: annotations))
        // Old output: three `/Subtype /Square` annotations, one per cross.
        #expect(count["Subtype"]?.nameValue == "Stamp")
        #expect(!annotations.contains { $0.dictionary["Subtype"]?.nameValue == "Square" })
    }

    // MARK: - Opacity and style

    @Test("The 20 % area keeps its opacity: /CA and /ca are 0.2, /IC is the fill colour")
    func areaOpacityIsWritten() throws {
        let fixture = Self.fixture()
        let annotations = try Self.annotations(in: try Self.export(fixture).data)
        let area = try #require(Self.named(fixture.area.id, in: annotations))
        // Old output (bridge): `/C [r g b]` and `/IC [r g b]`, no `/CA` — an opaque polygon.
        #expect(area["CA"]?.doubleValue == 0.2)
        #expect(area["ca"]?.doubleValue == 0.2)
        #expect(area["IC"]?.arrayValue?.count == 3)
        #expect(area["IT"]?.nameValue == "PolygonDimension")
        #expect(area["Subtype"]?.nameValue == "Polygon")
        #expect(area["Vertices"]?.arrayValue?.count == 8)
        #expect(StandardAnnotationWriter.text(area["Subj"]) == "Concrete")
        #expect(StandardAnnotationWriter.text(area["T"]) == "Estimator")
        #expect(StandardAnnotationWriter.text(area["Contents"]) == "Slab\n14.0 m²")
        #expect(StandardAnnotationWriter.text(area["CreationDate"])?.hasPrefix("D:2026") == true)
    }

    @Test("Dash, line endings and cloud borders are written")
    func styleKeysAreWritten() throws {
        let fixture = Self.fixture()
        let annotations = try Self.annotations(in: try Self.export(fixture).data)
        let arrow = try #require(Self.named(fixture.arrow.id, in: annotations))
        #expect(arrow["Subtype"]?.nameValue == "Line")
        let border = try #require(arrow["BS"]?.dictionaryValue)
        #expect(border["S"]?.nameValue == "D")
        #expect(border["D"]?.arrayValue?.compactMap(\.doubleValue) == [6, 3])
        #expect(arrow["LE"]?.arrayValue?.compactMap(\.nameValue) == ["None", "ClosedArrow"])
        #expect(arrow["L"]?.arrayValue?.compactMap(\.doubleValue) == [220, 60, 360, 120])

        let cloud = try #require(Self.named(fixture.cloud.id, in: annotations))
        let effect = try #require(cloud["BE"]?.dictionaryValue)
        #expect(effect["S"]?.nameValue == "C")

        let text = try #require(Self.named(fixture.text.id, in: annotations))
        #expect(text["Subtype"]?.nameValue == "FreeText")
        #expect(StandardAnnotationWriter.text(text["DA"])?.contains("Tf") == true)

        let link = try #require(Self.named(fixture.link.id, in: annotations))
        #expect(link["Subtype"]?.nameValue == "Link")
        let action = try #require(link["A"]?.dictionaryValue)
        #expect(action["S"]?.nameValue == "URI")
        #expect(StandardAnnotationWriter.text(action["URI"]) == "https://example.org/detail-5")
    }

    @Test("Every painted annotation carries /AP /N, a form placed by the sheet-to-page matrix")
    func everyAnnotationHasAnAppearance() throws {
        let fixture = Self.fixture()
        let data = try Self.export(fixture).data
        let scan = try PDFDocumentScan(data: data)
        let annotations = try Self.annotations(in: data)
        for markup in fixture.all where !markup.appearance.isEmpty {
            let dictionary = try #require(Self.named(markup.id, in: annotations))
            let normal = try #require(dictionary["AP"]?.dictionaryValue?["N"])
            guard case let .stream(form, _)? = scan.object(normal) else {
                Issue.record("the /AP /N of \(markup.id) is not a stream")
                continue
            }
            #expect(form["Subtype"]?.nameValue == "Form")
            // The fixture's crop box starts at (10, 20): sheet space is page space moved by it.
            #expect(form["Matrix"]?.arrayValue?.compactMap(\.doubleValue) == [1, 0, 0, 1, 10, 20])
        }
    }

    @Test("The review state is a hidden reply with /IRT, /StateModel and /State")
    func reviewStateReply() throws {
        let fixture = Self.fixture()
        let data = try Self.export(fixture).data
        let annotations = try Self.annotations(in: data)
        let parent = try #require(annotations.first {
            StandardAnnotationWriter.text($0.dictionary["NM"]) == fixture.area.id.uuidString
        })
        let reply = try #require(annotations.first { $0.dictionary["IRT"] != nil })
        #expect(reply.dictionary["IRT"]?.referenceValue?.number == parent.number)
        #expect(StandardAnnotationWriter.text(reply.dictionary["StateModel"]) == "Review")
        #expect(StandardAnnotationWriter.text(reply.dictionary["State"]) == "Accepted")
        #expect((reply.dictionary["F"]?.integerValue ?? 0) & 2 == 2, "the reply must be hidden")
    }

    @Test("A markup's review thread is written as replies after the state reply (NL-COLLAB-07)")
    func threadRepliesAreWritten() throws {
        var fixture = Self.fixture()
        let first = UUID(), second = UUID()
        fixture = Fixture(
            page: fixture.page,
            area: {
                var area = fixture.area
                area.replies = [
                    .init(id: first, author: "Reviewer", body: "Check the slab edge", createdAt: Date(timeIntervalSince1970: 1_790_001_000)),
                    .init(id: second, author: "Estimator", body: "Done", createdAt: Date(timeIntervalSince1970: 1_790_002_000))
                ]
                return area
            }(),
            arrow: fixture.arrow, cloud: fixture.cloud, stamp: fixture.stamp,
            count: fixture.count, text: fixture.text, link: fixture.link
        )
        let produced = try Self.export(fixture)
        #expect(produced.outcome.reviewReplyCount == 3)
        let annotations = try Self.annotations(in: produced.data)
        let parent = try #require(annotations.first {
            StandardAnnotationWriter.text($0.dictionary["NM"]) == fixture.area.id.uuidString
        })
        for (id, body) in [(first, "Check the slab edge"), (second, "Done")] {
            let reply = try #require(annotations.first { StandardAnnotationWriter.text($0.dictionary["NM"]) == id.uuidString })
            #expect(reply.dictionary["IRT"]?.referenceValue?.number == parent.number)
            #expect(reply.dictionary["RT"]?.nameValue == "R")
            #expect(StandardAnnotationWriter.text(reply.dictionary["Contents"]) == body)
        }
        // Replies are Zenit's: a re-export supersedes them with their parent.
        let again = try Self.export(fixture, source: produced.data)
        #expect(try Self.annotations(in: again.data).count == annotations.count)
    }

    // MARK: - Measurement interop (NL-PDF-02)

    @Test("A 1:100 length of 5.400 m carries /Measure converting to 5.4 m; two Scale Regions are two /VP")
    func measureAndViewports() throws {
        let page = FlattenedPDFWriterTests.page()
        let metresPerPoint = 100 * 0.0254 / 72
        let scale = MeasureScale(ratioLabel: "1:100", metresPerPoint: metresPerPoint)
        // 5.400 m at 1:100 is 54 mm on paper: 54 / 25.4 × 72 = 153.0709 pt.
        let length = 54 / 25.4 * 72
        let start = PDFPoint(x: 40, y: 60), end = PDFPoint(x: 40 + length, y: 60)
        let id = UUID()
        var annotation = StandardAnnotation(
            id: id,
            geometry: .polyLine([start, end]),
            stroke: Self.blue,
            intent: .polyLineDimension,
            appearance: [RenderableMarkup(
                id: MarkupID(id),
                shape: .polyline(RenderPolyline(points: [start, end], isClosed: false)),
                style: RenderStyle(stroke: Self.blue, lineWidth: 1.5)
            )]
        )
        annotation.measure = scale
        let regionA = PDFRect(x: 10, y: 20, width: 200, height: 150)
        let regionB = PDFRect(x: 210, y: 20, width: 200, height: 150)
        let produced = try StandardAnnotationWriter().data(
            source: LayeredSourceFixtures.plain(),
            pages: [StandardAnnotationPage(
                page: page, sourcePageIndex: 0, annotations: [annotation],
                viewports: [
                    MeasureViewport(bounds: regionA, name: "Plan 1:100", measure: scale),
                    MeasureViewport(bounds: regionB, name: "Detail 1:20", measure: MeasureScale(ratioLabel: "1:20", metresPerPoint: 20 * 0.0254 / 72))
                ]
            )]
        )
        #expect(produced.outcome.viewportCount == 2)
        let scan = try PDFDocumentScan(data: produced.data)
        let written = try #require(Self.named(id, in: try Self.annotations(in: produced.data)))
        #expect(written["IT"]?.nameValue == "PolyLineDimension")
        let measure = try #require(written["Measure"]?.dictionaryValue)
        #expect(measure["Subtype"]?.nameValue == "RL")
        #expect(StandardAnnotationWriter.text(measure["R"]) == "1:100")
        let x = try #require(measure["X"]?.arrayValue?.first?.dictionaryValue?["C"]?.doubleValue)
        let d = try #require(measure["D"]?.arrayValue?.first?.dictionaryValue?["C"]?.doubleValue)
        // Length in points × /X (mm per point) × /D (m per mm), hand-derived: 153.0709 × 35.2778 × 0.001.
        let vertices = written["Vertices"]?.arrayValue?.compactMap { $0.doubleValue } ?? []
        try #require(vertices.count == 4)
        let points = abs(vertices[2] - vertices[0])
        #expect(abs(points * x * d - 5.4) < 0.0005, "\(points * x * d) m")

        let pageEntry = try #require(try scan.pages().first)
        let viewports = pageEntry.dictionary["VP"]?.arrayValue ?? []
        #expect(viewports.count == 2)
        let boxes = viewports.compactMap { $0.dictionaryValue?["BBox"]?.arrayValue?.compactMap(\.doubleValue) }
        #expect(boxes.contains([10, 20, 210, 170]))
        #expect(boxes.contains([210, 20, 410, 170]))
    }

    // MARK: - The drawing is not rewritten

    @Test("The artefact begins with the source, byte for byte")
    func sourceIsThePrefix() throws {
        let source = LayeredSourceFixtures.plain()
        let produced = try Self.export(Self.fixture(), source: source)
        #expect(produced.outcome.preservedSourceBytes == source.count)
        #expect(SHA256.hash(data: produced.data.prefix(source.count)) == SHA256.hash(data: source))
        #expect(produced.data.count > source.count)
    }

    @Test("Object streams and cross-reference streams are appended to as well")
    func modernSourcesWork() throws {
        let source = LayeredSourceFixtures.modern()
        let produced = try Self.export(Self.fixture(), source: source)
        #expect(produced.data.prefix(source.count) == source)
        #expect(try Self.annotations(in: produced.data).count == 8)
    }

    // MARK: - Re-export: one set, never two

    @Test("Exporting an export supersedes Zenit's annotations and keeps a reviewer's")
    func reExportDoesNotStack() throws {
        let fixture = Self.fixture()
        let source = Self.sourceWithForeignAndLegacyAnnotations()
        let first = try Self.export(fixture, source: source)
        let firstCount = try Self.annotations(in: first.data).count
        // One foreign annotation kept; the legacy `/Subj (Zenit)` one superseded.
        #expect(first.outcome.keptForeignAnnotationCount == 1)
        #expect(first.outcome.supersededAnnotationCount == 1)
        #expect(firstCount == 8 + 1)

        let second = try Self.export(fixture, source: first.data)
        let annotations = try Self.annotations(in: second.data)
        // Old behaviour (`.append`): 9 + 508 on the second export — two full sets stacked.
        #expect(annotations.count == firstCount)
        #expect(second.outcome.supersededAnnotationCount == 8)
        #expect(annotations.contains { StandardAnnotationWriter.text($0.dictionary["NM"]) == "reviewer-1" })
        for markup in fixture.all {
            #expect(annotations.filter {
                StandardAnnotationWriter.text($0.dictionary["NM"]) == markup.id.uuidString
            }.count == 1)
        }
    }

    @Test("An original a Zenit markup replaced (NL-UX-04) is left out, by name or by subtype and rectangle")
    func adoptedOriginalsAreNotWrittenTwice() throws {
        let fixture = Self.fixture()
        let source = Self.sourceWithForeignAndLegacyAnnotations()
        for original in [
            AdoptedOriginal(name: "reviewer-1", subtype: "Text", rect: .zero),
            AdoptedOriginal(name: nil, subtype: "Text", rect: CGRect(x: 300, y: 250, width: 20, height: 20))
        ] {
            var page = StandardAnnotationPage(page: fixture.page, sourcePageIndex: 0, annotations: fixture.all)
            page.adoptedOriginals = [original]
            let produced = try StandardAnnotationWriter().data(source: source, pages: [page])
            // Old behaviour: the reviewer's note stayed beside the markup made from it — twice.
            #expect(produced.outcome.adoptedOriginalCount == 1)
            #expect(produced.outcome.keptForeignAnnotationCount == 0)
            let annotations = try Self.annotations(in: produced.data)
            #expect(!annotations.contains { StandardAnnotationWriter.text($0.dictionary["NM"]) == "reviewer-1" })
            #expect(annotations.count == 8, "the seven markups and the review reply, nothing else")
            #expect(produced.data.prefix(source.count) == source, "the original stays in the file's earlier revision")
        }
        // An original nobody adopted is kept.
        let untouched = try Self.export(fixture, source: source)
        #expect(untouched.outcome.adoptedOriginalCount == 0)
        #expect(untouched.outcome.keptForeignAnnotationCount == 1)
    }

    // MARK: - Refusals

    @Test("An encrypted drawing is refused with a sentence about annotations")
    func encryptedIsRefused() throws {
        var bytes = LayeredSourceFixtures.plain()
        let text = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "/Root 1 0 R", with: "/Root 1 0 R /Encrypt << /Filter /Standard >>")
        bytes = Data(text.utf8)
        #expect {
            _ = try StandardAnnotationWriter().data(
                source: bytes,
                pages: [StandardAnnotationPage(page: Self.fixture().page, sourcePageIndex: 0, annotations: Self.fixture().all)]
            )
        } throws: { error in
            guard case let .annotationExportRefused(message)? = error as? ExportError else { return false }
            return message.contains("encrypted") && message.contains("annotations")
        }
    }

    @Test("A sheet that differs from the one measured is refused")
    func sheetMismatchIsRefused() throws {
        let page = FlattenedPDFWriterTests.page(width: 500, height: 300)
        #expect(throws: ExportError.self) {
            _ = try StandardAnnotationWriter().data(
                source: LayeredSourceFixtures.plain(),
                pages: [StandardAnnotationPage(page: page, sourcePageIndex: 0, annotations: Self.fixture().all)]
            )
        }
    }

    // MARK: - Another reader

    @Test("PDFKit reads every annotation back with its type and name")
    func pdfKitReadsThem() throws {
        let fixture = Self.fixture()
        let data = try Self.export(fixture).data
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        #expect(page.annotations.count == 8)
        let types = Set(page.annotations.compactMap(\.type))
        #expect(types.isSuperset(of: ["Polygon", "Line", "Stamp", "FreeText", "Link", "Text"]))
    }

    @Test("PDFKit's render of the annotated file matches the flattened render within 1 %")
    func renderMatchesTheFlattenPath() throws {
        let fixture = Self.fixture()
        let annotated = try Self.export(fixture).data
        let flattened = try FlattenedPDFWriter().data(
            shape: .flattened,
            pages: [FlattenPage(
                page: fixture.page,
                sourcePageIndex: 0,
                markups: fixture.all.flatMap(\.appearance)
            )],
            content: try #require(CGPDFPageContentSource(
                url: try LayeredMarkupExportTests.write(LayeredSourceFixtures.plain(), named: "source.pdf")
            ))
        )
        let left = try #require(Self.renderWithPDFKit(annotated, width: 400, height: 300))
        let right = try #require(PageRaster.render(flattened, pageIndex: 0))
        let difference = PageRaster.difference(left, right, tolerance: 32)
        #expect(difference <= 0.01, "PDFKit render differs from the flatten render in \(difference * 100) % of pixels")
        // The comparison can fail: the drawing without its markups is far from the flatten render.
        let bare = try #require(Self.renderWithPDFKit(LayeredSourceFixtures.plain(), width: 400, height: 300))
        #expect(PageRaster.difference(bare, right, tolerance: 32) > 0.05)
    }

    @Test("A rotated sheet's appearance uses the rotated placement, and vertices stay in page space")
    func rotatedSheet() throws {
        let fixture = Self.fixture(rotation: .degrees90)
        let data = try Self.export(fixture, source: LayeredSourceFixtures.plain(rotate: 90)).data
        let scan = try PDFDocumentScan(data: data)
        let area = try #require(Self.named(fixture.area.id, in: try Self.annotations(in: data)))
        #expect(area["Vertices"]?.arrayValue?.compactMap(\.doubleValue).prefix(2) == [40, 60])
        guard case let .stream(form, _)? = scan.object(area["AP"]?.dictionaryValue?["N"]) else {
            Issue.record("no appearance")
            return
        }
        // Sheet 300 wide x 400 tall onto the page: x' = -y + (10 + 400), y' = x + 20.
        #expect(form["Matrix"]?.arrayValue?.compactMap(\.doubleValue) == [0, 1, -1, 0, 410, 20])
        // The form's bounding box, carried through the matrix, is the annotation's /Rect.
        let bbox = form["BBox"]?.arrayValue?.compactMap { $0.doubleValue } ?? []
        let rect = area["Rect"]?.arrayValue?.compactMap { $0.doubleValue } ?? []
        try #require(bbox.count == 4 && rect.count == 4)
        let mapped = CGRect(x: bbox[0], y: bbox[1], width: bbox[2] - bbox[0], height: bbox[3] - bbox[1])
            .applying(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 410, ty: 20))
        #expect(abs(mapped.minX - rect[0]) < 0.01 && abs(mapped.minY - rect[1]) < 0.01)
        #expect(abs(mapped.maxX - rect[2]) < 0.01 && abs(mapped.maxY - rect[3]) < 0.01)
    }

    // MARK: - The takeoff inside the PDF (NL-PDF-03)

    static func takeoff(for source: Data, payload: String = #"{"measurements":[]}"#) -> EmbeddedTakeoff {
        EmbeddedTakeoff(
            payload: Data(payload.utf8),
            sourceByteCount: source.count,
            sourceSHA256: SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        )
    }

    @Test("The takeoff is embedded as an associated file and read back against the untouched prefix")
    func takeoffRoundTrips() throws {
        let fixture = Self.fixture()
        let source = LayeredSourceFixtures.plain()
        let produced = try StandardAnnotationWriter().data(
            source: source,
            pages: [StandardAnnotationPage(page: fixture.page, sourcePageIndex: 0, annotations: fixture.all)],
            takeoff: Self.takeoff(for: source)
        )
        #expect(produced.outcome.takeoffEmbedded)
        #expect(produced.data.prefix(source.count) == source)
        let found = try #require(EmbeddedTakeoffReader.read(produced.data))
        #expect(found.prefixVerified)
        // The drawing's own bytes are the prefix the takeoff names (R-109: no copy kept on Found).
        #expect(produced.data.prefix(found.takeoff.sourceByteCount) == source)
        #expect(String(decoding: found.takeoff.payload, as: UTF8.self) == #"{"measurements":[]}"#)
        // Another reader still opens the file, with every annotation.
        let document = try #require(PDFDocument(data: produced.data))
        #expect(document.page(at: 0)?.annotations.count == 8)
        // A file edited under the takeoff is caught: flip a byte inside the drawing's prefix.
        var tampered = produced.data
        let index = tampered.startIndex + 200
        tampered[index] = tampered[index] == 0x20 ? 0x0A : 0x20
        #expect(EmbeddedTakeoffReader.read(tampered)?.prefixVerified == false)
    }

    @Test("A second save replaces the embedded takeoff and keeps somebody else's attachment")
    func secondSaveSupersedesTheTakeoff() throws {
        let fixture = Self.fixture()
        let source = Self.sourceWithAttachment()
        let pages = [StandardAnnotationPage(page: fixture.page, sourcePageIndex: 0, annotations: fixture.all)]
        let first = try StandardAnnotationWriter().data(source: source, pages: pages, takeoff: Self.takeoff(for: source, payload: "first"))
        let second = try StandardAnnotationWriter().data(source: first.data, pages: pages, takeoff: Self.takeoff(for: source, payload: "second"))
        let found = try #require(EmbeddedTakeoffReader.read(second.data))
        #expect(String(decoding: found.takeoff.payload, as: UTF8.self) == "second")
        #expect(found.prefixVerified, "the prefix is still the original drawing")

        let scan = try PDFDocumentScan(data: second.data)
        let catalog = try #require(scan.dictionary(scan.rootReference))
        let tree = try #require(scan.dictionary(scan.dictionary(catalog["Names"])?["EmbeddedFiles"]))
        let names = try #require(scan.object(tree["Names"])?.arrayValue)
        #expect(names.count == 4, "two entries: the reviewer's attachment and one takeoff")
        let associated = try #require(scan.object(catalog["AF"])?.arrayValue)
        #expect(associated.filter { scan.dictionary($0)?[StandardAnnotationWriter.takeoffKey] != nil }.count == 1)
        #expect(try Self.annotations(in: second.data).count == 8)
    }

    /// `LayeredSourceFixtures.plain()`'s drawing with one embedded file of its own.
    static func sourceWithAttachment() -> Data {
        let content = LayeredSourceFixtures.drawingContent
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles << /Names [(notes.txt) 5 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 340] /CropBox [10 20 410 320]"
                + " /Contents 4 0 R /Resources << /ProcSet [/PDF] >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Filespec /F (notes.txt) /EF << /F 6 0 R >> >>",
            "<< /Type /EmbeddedFile /Length 5 >>\nstream\nnotes\nendstream"
        ]
        var pdf = Data("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    // MARK: - Helpers

    /// `LayeredSourceFixtures.plain()` plus two annotations on page 1: a reviewer's note and an
    /// annotation the first (PDFKit) annotated export wrote, `/Subj (Zenit)` and no `/NM`.
    static func sourceWithForeignAndLegacyAnnotations() -> Data {
        let base = String(decoding: LayeredSourceFixtures.plain(), as: UTF8.self)
        // Rebuilt from scratch rather than patched so the offsets are right.
        _ = base
        let content = LayeredSourceFixtures.drawingContent
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 420 340] /CropBox [10 20 410 320]"
                + " /Contents 4 0 R /Resources << /ProcSet [/PDF] >> /Annots [5 0 R 6 0 R] >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Annot /Subtype /Text /Rect [300 250 320 270] /NM (reviewer-1) /T (Reviewer)"
                + " /Contents (Please check) >>",
            "<< /Type /Annot /Subtype /Square /Rect [50 50 60 60] /Subj (Zenit) >>"
        ]
        var pdf = Data("%PDF-1.6\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xref = pdf.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf.append(Data(table.utf8))
        return pdf
    }

    /// Draws page 1 with PDFKit — content and annotations, the way a PDFKit reader shows it — on
    /// white, at one pixel per point of the crop box.
    static func renderWithPDFKit(_ data: Data, width: Int, height: Int) -> PageRaster.Image? {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .cropBox, to: context)
        guard let buffer = context.data else { return nil }
        let bytes = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return PageRaster.Image(
            width: width,
            height: height,
            pixels: Array(UnsafeBufferPointer(start: bytes, count: width * height * 4))
        )
    }
}
