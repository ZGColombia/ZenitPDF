import CoreGraphics
import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// Carried Scale Regions (U-030), one currency rule (U-031),
/// review readers' budgets and coordinates (U-032, U-033, U-034), Batch Apply ranges (U-035),
/// the double-count guard's cost (U-038), Find Scale Regions on huge coordinates (U-039) and the
/// review file's preview (U-040). Every expected value is derived by hand next to its input.
@Suite("Iteration 4 — misc")
struct Iter4AppCoreMiscTests {

    static let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    static func page(_ documentID: DocumentID, index: Int, label: String) -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: index, label: label,
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
        )
    }

    static func length(on page: ZPDFContracts.PageDescriptor, _ from: PDFPoint, _ to: PDFPoint) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .length,
            subject: "Stair", author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page.id, points: [from, to]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    static func square(on page: ZPDFContracts.PageDescriptor, x: Double, side: Double, label: String) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: page.documentID, pageID: page.id, kind: .measurement, tool: .area,
            subject: "Slab", label: label, author: "A. Berg",
            geometry: MeasurementGeometry(pageID: page.id, polygons: [PolygonGeometry(outer: PolygonRing(points: [
                PDFPoint(x: x, y: 0), PDFPoint(x: x + side, y: 0), PDFPoint(x: x + side, y: side), PDFPoint(x: x, y: side)
            ], isClosed: true))]),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    static func planLength(_ record: ZPDFContracts.MarkupRecord?) -> Decimal? {
        record?.measurement?.values[.planLength]?.value
    }

    // MARK: U-030

    /// A sheet at 100 pt = 5 m (the page scale) with a "Stair" Scale Region over x, y ∈ [0, 400]
    /// at 100 pt = 1 m — five times finer, as a 1:20 detail on a 1:100 plan — and a 200 pt Length
    /// inside it, filed in the region: 2 m. At the page scale the same 200 pt read 10 m.
    static func detailSheet(
        _ session: TakeoffSession, _ page: ZPDFContracts.PageDescriptor
    ) async throws -> (ScaleRegionDefinition, ZPDFContracts.MarkupRecord) {
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 5, knownLengthUnit: .metre
        )
        let detailScale = ScaleID(UUID())
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre,
            scaleID: detailScale
        )
        let region = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()), pageID: page.id, name: "Stair",
            boundary: [PDFPoint(x: 0, y: 0), PDFPoint(x: 400, y: 0), PDFPoint(x: 400, y: 400), PDFPoint(x: 0, y: 400)],
            scaleID: detailScale, priority: 3, colorRGBA: ColorRGBA(red: 0, green: 1, blue: 1, alpha: 1)
        )
        _ = try await session.apply(.setScaleRegions([region]))
        var stair = length(on: page, PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100))
        stair.scaleRegionID = region.id
        stair.scaleID = detailScale
        _ = try await session.apply(.addMarkup(stair))
        #expect(planLength(await session.markup(stair.id)) == 2, "200 pt at 100 pt = 1 m")
        return (region, stair)
    }

    /// Carry Forward: the new revision's sheet stands beside the old one, moved 50 pt right.
    /// Old output: the carried Stair read 10 m — re-measured at the new sheet's page scale.
    @Test("Carry Forward takes the Scale Region along: a 1:20 detail length stays 2 m, not 10 m")
    func carryForwardKeepsTheDetailScale() async throws {
        let documentID = DocumentID(UUID())
        let old = Self.page(documentID, index: 0, label: "A-101")
        let new = Self.page(DocumentID(UUID()), index: 0, label: "A-101 rev B")
        let session = try TakeoffSession(documentID: documentID, pages: [old, new])
        let (region, stair) = try await Self.detailSheet(session, old)
        let state = await session.takeoffState()
        let pairs = [old.id: CarryPair(target: new.id, alignment: PageAlignment(dx: 50))]

        let scales = CarryForwardPlanner.carriedScales(from: state, pairs: pairs, keeping: state.scaleRegions)
        let plan = CarryForwardPlanner.plan(markups: state.markups, pairs: pairs, now: Self.stamp, scales: scales)
        for command in scales.commands + plan.commands { _ = try await session.apply(command) }

        let carried = try #require(plan.items.first?.carriedID)
        let record = await session.markup(carried)
        #expect(Self.planLength(record) == 2, "200 pt at the detail's 100 pt = 1 m, on the new sheet")
        let moved = try #require(scales.regions[region.id])
        #expect(record?.scaleRegionID == moved.id)
        let regions = await session.scaleRegionDefinitions
        #expect(regions.count == 2, "the old sheet keeps its region; the new sheet has its copy")
        let copy = try #require(regions.first { $0.id == moved.id })
        #expect(copy.pageID == new.id && copy.name == "Stair" && copy.priority == 3)
        #expect(copy.boundary == [PDFPoint(x: 50, y: 0), PDFPoint(x: 450, y: 0), PDFPoint(x: 450, y: 400), PDFPoint(x: 50, y: 400)],
                "the boundary moved with the alignment")
        #expect(await session.pageScale(new.id)?.matrix == state.scales.first { $0.id == state.pageScaleIDs[old.id] }?.matrix,
                "the page scale is the new sheet's own; the region's copy did not take its place")
        #expect(Self.planLength(await session.markup(stair.id)) == 2, "the old sheet's measurement is untouched")

        // Without the carried scales the planner measures at the sheet scale — the old behaviour.
        let bare = CarryForwardPlanner.plan(markups: state.markups, pairs: pairs, now: Self.stamp)
        guard case .addMarkup(let unscaled)? = bare.commands.first else { Issue.record("no add"); return }
        #expect(unscaled.scaleRegionID == nil)
    }

    /// Combine Open Drawings: another drawing's takeoff joins this project, whose own sheet already
    /// has a region that must survive `.setScaleRegions`. Old output: 10 m, and no region.
    @Test("Combine Open Drawings carries the other drawing's Scale Regions and keeps this project's")
    func combineKeepsTheDetailScale() async throws {
        let otherID = DocumentID(UUID())
        let otherPage = Self.page(otherID, index: 0, label: "S-201")
        let other = try TakeoffSession(documentID: otherID, pages: [otherPage])
        _ = try await Self.detailSheet(other, otherPage)

        let projectID = DocumentID(UUID())
        let own = Self.page(projectID, index: 0, label: "A-101")
        let joined = Self.page(otherID, index: 0, label: "S-201")
        let project = try TakeoffSession(documentID: projectID, pages: [own, joined])
        let (ownRegion, _) = try await Self.detailSheet(project, own)

        let state = await other.takeoffState()
        let pairs = [otherPage.id: CarryPair(target: joined.id, alignment: .identity)]
        let scales = CarryForwardPlanner.carriedScales(
            from: state, pairs: pairs, keeping: await project.scaleRegionDefinitions
        )
        let plan = CarryForwardPlanner.plan(markups: state.markups, pairs: pairs, now: Self.stamp, scales: scales)
        for command in scales.commands + plan.commands { _ = try await project.apply(command) }

        let carried = try #require(plan.items.first?.carriedID)
        #expect(Self.planLength(await project.markup(carried)) == 2)
        let regions = await project.scaleRegionDefinitions
        #expect(regions.count == 2 && regions.contains { $0.id == ownRegion.id }, "this project's region is kept")
        #expect(plan.heldForScale.isEmpty)
    }

    /// A region whose scale is not on its sheet cannot go: its measurement is held, not re-measured.
    @Test("A measurement whose Scale Region cannot be carried is held and counted")
    func uncarriableRegionHolds() async throws {
        let documentID = DocumentID(UUID())
        let old = Self.page(documentID, index: 0, label: "A-101")
        let new = Self.page(documentID, index: 1, label: "A-102")
        let session = try TakeoffSession(documentID: documentID, pages: [old, new])
        let (region, stair) = try await Self.detailSheet(session, old)
        let full = await session.takeoffState()
        let state = TakeoffSession.TakeoffState(
            pages: full.pages, markups: full.markups, scales: full.scales.filter { $0.id != region.scaleID },
            pageScaleIDs: full.pageScaleIDs, scaleRegions: full.scaleRegions
        )
        let pairs = [old.id: CarryPair(target: new.id, alignment: .identity)]
        let scales = CarryForwardPlanner.carriedScales(from: state, pairs: pairs, keeping: [])
        #expect(scales.regionsLeftBehind == [region.id])
        let plan = CarryForwardPlanner.plan(markups: state.markups, pairs: pairs, now: Self.stamp, scales: scales)
        #expect(plan.heldForScale == [stair.id] && plan.commands.isEmpty)
        let report = CarryForwardReport.make(plan: plan, source: [:], carried: [:])
        #expect(report.heldForScale == 1)
    }

    // MARK: U-031

    /// A German session, no priced row. Old output: USD for the rate list and the Column Manager
    /// (`QuantityFormatter()`'s `en_US_POSIX`), and this Mac's own currency for a spreadsheet.
    @Test("An unpriced project takes the session's currency for rate imports, new columns and spreadsheet amounts")
    @MainActor
    func currencyFollowsTheSession() async throws {
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID, index: 0, label: "A-101")
        let session = try TakeoffSession(documentID: documentID, pages: [page], localeIdentifier: "de_DE")
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        try await environment.commands.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 10, knownLengthUnit: .metre
        )
        await environment.refresh()
        #expect(environment.ledger.defaultCurrencyCode == "EUR")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-it4-rates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        environment.rateLibraryStore = RateLibraryStore(directory: directory)
        let imported = try environment.importRateList("Name,Unit,Rate\nPaint,m2,45.5\n")
        #expect(imported.imported == 1)
        #expect(environment.rateLibraryEntries().map(\.currencyCode) == ["EUR"], "no Currency column: the session's")

        let slab = Self.square(on: page, x: 0, side: 100, label: "S1")
        try await environment.commands.perform(.addMarkup(slab))
        let unitCost = try #require(await session.ledgerColumns.column(standard: .unitCost))
        let receipt = try await environment.applySpreadsheetEdits([
            SpreadsheetCellEdit(markupID: slab.id.rawValue, columnKey: unitCost.key, text: "12.50")
        ])
        #expect(receipt.applied == 1)
        guard case let .currency(amount, code)? = await session.markup(slab.id)?.customValues[unitCost.id] else {
            Issue.record("no amount"); return
        }
        #expect(amount == Decimal(string: "12.50") && code == "EUR")
    }

    // MARK: U-032, U-033 — the PDF reader

    /// Object 4 is a shared coordinate array (the reader skips it in `/Annots`: not a dictionary).
    static func pdf(shared: [Double], annotations: [String]) -> Data {
        let array = "[" + shared.map { String($0) }.joined(separator: " ") + "]"
        return CollaborationImportTests.pdf(annotations: [array] + annotations)
    }

    /// One Ink annotation, 1 000 strokes all naming one 100-point array. Old output: 100 000
    /// points; the documented cap is 10 000 per annotation.
    @Test("An Ink's strokes share one budget of 10 000 points, however many strokes name one array")
    func inkStrokesShareOneBudget() throws {
        let shared = (0..<200).map { Double($0 % 500) }
        let strokes = Array(repeating: "4 0 R", count: 1_000).joined(separator: " ")
        let data = Self.pdf(shared: shared, annotations: [
            "<< /Type /Annot /Subtype /Ink /Rect [0 0 500 500] /InkList [\(strokes)] /NM (ink) >>"
        ])
        let reading = try ReviewAnnotationReader.read(data: data)
        let ink = try #require(reading.annotations.first)
        #expect(ink.inkPaths.reduce(0) { $0 + $1.count } == AnnotationImportPlanner.maximumVertices)
        #expect(ink.inkPaths.count == 100, "10 000 points of 100-point strokes")
        #expect(reading.annotationsOverBudget == 0)
    }

    /// 150 polygons all naming one 10 000-vertex array: 1 500 000 points against a budget of
    /// 1 000 000. Old output: all 150 read. Now the first 100 (exactly 1 000 000) and 50 counted.
    @Test("One file's annotations share a budget of 1 000 000 points; the rest are counted and said")
    func fileSharesOneBudget() throws {
        let shared = (0..<20_000).map { Double($0 % 600) }
        let polygons = (0..<150).map { "<< /Type /Annot /Subtype /Polygon /Rect [0 0 600 600] /Vertices 4 0 R /NM (p\($0)) >>" }
        let reading = try ReviewAnnotationReader.read(data: Self.pdf(shared: shared, annotations: polygons))
        #expect(reading.annotations.count == 100)
        #expect(reading.annotations.allSatisfy { $0.points.count == 10_000 })
        #expect(reading.annotationsOverBudget == 50)

        let page = Self.page(DocumentID(UUID()), index: 0, label: "1")
        let plan = AnnotationImportPlanner.plan(
            annotations: Array(reading.annotations.prefix(1)), pages: [page], documentID: page.documentID,
            existingMarkupIDs: [], existingReplyIDs: [], fileDigest: reading.digest,
            annotationsOverBudget: reading.annotationsOverBudget
        )
        #expect(plan.skipped.contains { $0.hasPrefix("50 annotations past the file's limit") }, "\(plan.skipped)")
    }

    /// Five highlights of 2 500 quads: 12 500 markups against a limit of 10 000. Old output: all
    /// 12 500. Now four highlights (10 000) and the fifth said.
    @Test("One import adds at most 10 000 markups; an annotation past the limit is left out and said")
    func importMarkupLimit() {
        let page = Self.page(DocumentID(UUID()), index: 0, label: "1")
        let quads = (0..<2_500).flatMap { index -> [PDFPoint] in
            let y = Double(index % 700)
            return [PDFPoint(x: 0, y: y + 1), PDFPoint(x: 10, y: y + 1), PDFPoint(x: 0, y: y), PDFPoint(x: 10, y: y)]
        }
        let highlights = (0..<5).map { index in
            ImportedAnnotation(index: index, pageIndex: 0, subtype: "Highlight", name: "h\(index)",
                               rect: PDFRect(x: 0, y: 0, width: 10, height: 700), quadPoints: quads)
        }
        let plan = AnnotationImportPlanner.plan(
            annotations: highlights, pages: [page], documentID: page.documentID,
            existingMarkupIDs: [], existingReplyIDs: [], fileDigest: "it4-u032"
        )
        #expect(plan.newMarkups.count == AnnotationImportPlanner.maximumNewMarkups)
        #expect(plan.skipped == ["1 annotations past the limit of 10000 new markups"])
    }

    /// `/Vertices [10 10 null 20 30 30 40 40]`. Old output: (10,10), (20,30), (30,40) — the null
    /// dropped before pairing, every later x read as a y. Now the one bad point goes.
    @Test("A bad PDF coordinate costs its own point, and a quad with a bad corner is dropped whole")
    func pdfCoordinatesKeepTheirPlaces() throws {
        let data = CollaborationImportTests.pdf(annotations: [
            "<< /Type /Annot /Subtype /Polygon /Rect [0 0 100 100] /Vertices [10 10 null 20 30 30 40 40] /NM (pg) >>",
            "<< /Type /Annot /Subtype /Highlight /Rect [0 0 300 100] /QuadPoints [0 20 /X 20 0 10 100 10 200 60 300 60 200 50 300 50] /NM (hl) >>"
        ])
        let reading = try ReviewAnnotationReader.read(data: data)
        #expect(reading.annotations[0].points == [PDFPoint(x: 10, y: 10), PDFPoint(x: 30, y: 30), PDFPoint(x: 40, y: 40)])
        let page = Self.page(DocumentID(UUID()), index: 0, label: "1")
        let plan = AnnotationImportPlanner.plan(
            annotations: [reading.annotations[1]], pages: [page], documentID: page.documentID,
            existingMarkupIDs: [], existingReplyIDs: [], fileDigest: reading.digest
        )
        // Old output: two highlight boxes, the second built from shifted corners.
        #expect(plan.newMarkups.count == 1, "the first quad has a bad corner and goes whole")
        let box = try #require(plan.newMarkups.first?.geometry?.polygons.first?.outer.points)
        #expect(box == [PDFPoint(x: 200, y: 50), PDFPoint(x: 300, y: 50), PDFPoint(x: 300, y: 60), PDFPoint(x: 200, y: 60)])
    }

    // MARK: U-033, U-034, U-032 — XFDF

    static func xfdf(_ annotations: String) -> Data {
        Data(#"<?xml version="1.0" encoding="UTF-8"?><xfdf xmlns="http://ns.adobe.com/xfdf/"><annots>\#(annotations)</annots></xfdf>"#.utf8)
    }

    /// Old output: (10,10), (20,30), (30,40).
    @Test("A bad XFDF number costs its own point")
    func xfdfCoordinatesKeepTheirPlaces() throws {
        let reading = try XFDF.read(Self.xfdf(#"<polygon page="0" rect="0,0,100,100" name="p"><vertices>10,10;abc,20;30,30;40,40</vertices></polygon>"#))
        #expect(reading.annotations.first?.points == [PDFPoint(x: 10, y: 10), PDFPoint(x: 30, y: 30), PDFPoint(x: 40, y: 40)])
    }

    /// Zenit's own export writes full-precision `String(Double)` pairs, about 36 characters a
    /// vertex. 2 000 vertices are about 72 000 characters. Old output: cut at 64 000 characters,
    /// about 1 780 vertices, the last number possibly half-read.
    @Test("XFDF vertices are bounded by count, not characters, and no half number survives")
    func xfdfVerticesWhole() throws {
        let vertices = (0..<2_000).map { index in PDFPoint(x: 0.123456789012345 + Double(index), y: 700.98765432101234 - Double(index) / 7) }
        let text = vertices.map { "\(String($0.x)),\(String($0.y))" }.joined(separator: ";")
        #expect(text.count > 64_000)
        let reading = try XFDF.read(Self.xfdf(#"<polyline page="0" rect="0,0,2000,800" name="pl"><vertices>\#(text)</vertices></polyline>"#))
        let points = try #require(reading.annotations.first?.points)
        #expect(points.count == 2_000)
        #expect(points == vertices, "every number read whole, the last one included")

        // Past the cap: 10 000 kept, never a partial.
        let many = (0..<10_005).map { "\($0).5,1.25" }.joined(separator: ";")
        let capped = try XFDF.read(Self.xfdf(#"<polyline page="0" rect="0,0,10,10" name="big"><vertices>\#(many)</vertices></polyline>"#))
        #expect(capped.annotations.first?.points.count == AnnotationImportPlanner.maximumVertices)
        #expect(capped.annotations.first?.points.last == PDFPoint(x: 9_999.5, y: 1.25))
    }

    /// Three gestures of 4 000 points. Old output: 12 000 points on one Ink.
    @Test("An XFDF Ink's gestures share 10 000 points")
    func xfdfGesturesShareOneBudget() throws {
        let gesture = "<gesture>" + (0..<4_000).map { "\($0),1" }.joined(separator: ";") + "</gesture>"
        let reading = try XFDF.read(Self.xfdf(#"<ink page="0" rect="0,0,10,10" name="i"><inklist>\#(gesture)\#(gesture)\#(gesture)</inklist></ink>"#))
        let ink = try #require(reading.annotations.first)
        #expect(ink.inkPaths.map(\.count) == [4_000, 4_000, 2_000])
    }

    // MARK: U-035

    /// Drawing A (ten sheets, PDF indices 0-9) then drawing B (five, 0-4). Old output: "Pages 11 to
    /// 15" selected nothing and "Pages 1 to 5" ten sheets (A's and B's indices 0-4).
    @Test("Batch Apply's page range counts positions in the set, across drawings and after a reorder")
    @MainActor
    func pageRangeCountsSetPositions() {
        let a = DocumentID(UUID()), b = DocumentID(UUID())
        let drawingA = (0..<10).map { Self.page(a, index: $0, label: "A-\($0)") }
        let drawingB = (0..<5).map { Self.page(b, index: $0, label: "B-\($0)") }
        let set = (drawingA + drawingB).map { ZPDFUIPresentation.PageDescriptor(domain: $0) }
        func range(_ from: Int, _ through: Int, _ pages: [ZPDFUIPresentation.PageDescriptor]) -> Set<UUID> {
            AppCoreEnvironment.pageIDsInScope(
                request: BatchApplyRequest(scope: .pageRange(from: from, through: through), anchor: .centered), pages: pages
            )
        }
        #expect(range(11, 15, set) == Set(drawingB.map(\.id.rawValue)))
        #expect(range(1, 5, set) == Set(drawingA.prefix(5).map(\.id.rawValue)))
        // Reordered: A-2 first. Old output: "Page 1" stamped A-0, the PDF's first page.
        let reordered = [set[2], set[0], set[1]]
        #expect(range(1, 1, reordered) == [set[2].id])
    }

    // MARK: U-038

    /// Two 100 pt Slab squares overlapping by 50 × 100 pt at 100 pt = 10 m: 5 000 pt² = 50 m².
    /// Old output: every refresh ran the booleans again and re-posted the warning with a new time.
    @Test("A label or colour edit does not re-run the overlap booleans or re-post an unchanged warning")
    @MainActor
    func doubleCountGuardCachesAndPostsOnlyChanges() async throws {
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID, index: 0, label: "A-101")
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        _ = try await session.calibrate(
            page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 10, knownLengthUnit: .metre
        )
        let left = Self.square(on: page, x: 0, side: 100, label: "Room 1")
        let right = Self.square(on: page, x: 50, side: 100, label: "Room 2")
        _ = try await session.apply(.addMarkup(left))
        _ = try await session.apply(.addMarkup(right))
        await environment.refresh()
        await environment.refreshDoubleCountWarnings(enabled: true)
        let first = try #require(environment.document.warnings.first { $0.source == AppCoreEnvironment.doubleCountWarningSource })
        #expect(first.message.contains("Room 1") && first.message.contains("50"))
        #expect(await session.doubleCountCache.evaluations == 1)

        var posts = 0
        environment.document.onWarningsChange = { _ in posts += 1 }
        _ = try await session.apply(.changeStyle(id: left.id, style: MarkupStyle.default))
        await environment.refreshDoubleCountWarnings(enabled: true)
        #expect(posts == 0, "nothing the warning says changed")
        #expect(await session.doubleCountCache.evaluations == 1, "the outlines did not change")

        _ = try await session.apply(.editLabel(id: left.id, label: "Hall"))
        await environment.refreshDoubleCountWarnings(enabled: true)
        #expect(await session.doubleCountCache.evaluations == 1, "a label is read fresh; the booleans are not asked")
        let relabelled = try #require(environment.document.warnings.first { $0.id == first.id })
        #expect(relabelled.message.contains("Hall") && posts == 1)
        #expect(relabelled.timestamp == first.timestamp, "the warning keeps the time it was raised")

        _ = try await session.apply(.moveMarkup(id: right.id, dx: 25, dy: 0))
        await environment.refreshDoubleCountWarnings(enabled: true)
        #expect(await session.doubleCountCache.evaluations == 2, "a moved outline is asked again")
        // 25 × 100 pt = 2 500 pt² = 25 m².
        #expect(environment.document.warnings.first { $0.id == first.id }?.message.contains("25") == true)
    }

    // MARK: U-039

    /// A page box at 1e21. Old output: `Int(Double)` trapped on (1e21 − 12) / 12 ≈ 8.3e19 — the
    /// process died. Counted from the page origin the grid is small.
    @Test("Find Scale Regions groups linework on a page box far from the origin without trapping")
    func viewportClustersOnHugeCoordinates() {
        let origin = 1e21
        let box = PDFRectValue(x: origin, y: origin, width: 1_000, height: 1_000)
        func line(_ id: UInt64, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> VectorPrimitive {
            SymbolCountReviewTests.linePrimitive(id, CGPoint(x: origin + x0, y: origin + y0), CGPoint(x: origin + x1, y: origin + y1))
        }
        // Two strokes far enough apart in page space to stay two drawings even at 1e21's spacing.
        let clusters = ViewportScaleDetector.clusters([line(1, 0, 0, 0, 0), line(2, 900_000_000, 0, 900_000_000, 0)], pageBox: box)
        #expect(clusters.count == 2)
        // A primitive at 1e300 on an ordinary page: left out of the grid, no trap.
        let normal = PDFRectValue(x: 0, y: 0, width: 1_000, height: 1_000)
        let wild = SymbolCountReviewTests.linePrimitive(3, CGPoint(x: 1e300, y: 1e300), CGPoint(x: 1e300, y: 1e300))
        #expect(ViewportScaleDetector.clusters([wild], pageBox: normal).count == 1)
        #expect(ViewportScaleDetector.cell(.infinity) == nil && ViewportScaleDetector.cell(1e300) == nil)
        #expect(ViewportScaleDetector.cell(-1) == -1 && ViewportScaleDetector.cell(24) == 2)
    }
}

// MARK: U-040

extension Iter3AppCoreReviewTests {

    /// Ada moves one markup to a layer (a change this build has no command for) and relabels
    /// another. Old output: "2 changed", and accepting tagged both as changed elsewhere.
    @Test("U-040: the review file preview counts an unapplied change apart and tags only applied ones")
    func reviewFileCountsUnappliedChangesApart() async throws {
        let (a, dbA, dirA) = try await Self.machine()
        let (b, dbB, dirB) = try await Self.machine()
        defer { for url in [dirA, dirB] { try? FileManager.default.removeItem(at: url) } }
        let start = Date()
        let layered = Self.area(sheet: 1)
        let relabelled = Self.area(sheet: 1, x: 300)
        try await a.commands.perform(.addMarkup(layered))
        try await a.commands.perform(.addMarkup(relabelled))
        let fileOne = await a.exportReviewFile(projectID: "P4", projectName: "Tower", author: "Ada", participantID: "ada-mac", now: start)
        try await b.acceptReviewFileImport(try await b.planReviewFileImport(fileOne, projectID: "P4"))
        b.review.restoreChangedElsewhere([])

        let walls = MarkupLayer(id: LayerID(UUID()), name: "Walls", order: -1)
        try await a.commands.perform(.setMarkupLayers(try await a.session.markupLayerList.adding(walls).layers, change: .add))
        try await a.commands.perform(.setMarkupLayer(ids: [layered.id], layerID: walls.id))
        try await a.commands.perform(.editLabel(id: relabelled.id, label: "Level 2"))
        let fileTwo = await a.exportReviewFile(projectID: "P4", projectName: "Tower", author: "Ada", participantID: "ada-mac",
                                               now: start.addingTimeInterval(60))
        let plan = try await b.planReviewFileImport(fileTwo, projectID: "P4")
        #expect(plan.changes.changed.map(\.record.id) == [relabelled.id])
        #expect(plan.notApplied == 1)
        #expect(plan.summary.contains("1 changed") && plan.summary.contains("1 changes this version cannot apply"), "\(plan.summary)")
        try await b.acceptReviewFileImport(plan)
        #expect(b.review.changedElsewhere == [relabelled.id.rawValue])
        #expect(await b.session.markup(relabelled.id)?.label == "Level 2")
        try? await dbA.close()
        try? await dbB.close()
    }
}
