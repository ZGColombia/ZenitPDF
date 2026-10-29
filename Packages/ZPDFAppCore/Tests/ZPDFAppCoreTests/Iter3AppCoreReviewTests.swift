import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
@testable import ZPDFCollaboration
import ZPDFUIPresentation

/// Iteration 3, appcore: Shared Review and review files across removed sheets (T-020) and across
/// zones, Scale Regions and scales one copy does not hold (T-021); measured review annotations in
/// a Scale Region (T-025); highlight quads (T-030).
///
/// Two copies of one project: sheets A-101 and A-102, 1000 pt square, each calibrated on its own
/// machine to 100 pt = 10 m (0.1 m/pt) — so each copy's page-scale identity is its own, as on two
/// real machines. Both copies hold a "Detail" Scale Region on A-101 over x, y ∈ [500, 800] at
/// 100 pt = 1 m (0.01 m/pt), made before the copies parted: same region and scale identity.
@Suite("Iter3 appcore: review")
@MainActor
struct Iter3AppCoreReviewTests {

    static let documentID = DocumentID(UUID(uuidString: "3A000000-0000-0000-0000-000000000001")!)
    static let sheets = [
        PageID(UUID(uuidString: "3B000000-0000-0000-0000-000000000001")!),
        PageID(UUID(uuidString: "3B000000-0000-0000-0000-000000000002")!)
    ]
    static let detailRegion = ScaleRegionID(UUID(uuidString: "3C000000-0000-0000-0000-000000000001")!)
    static let detailScale = ScaleID(UUID(uuidString: "3D000000-0000-0000-0000-000000000001")!)

    static func square(_ corners: [(Double, Double)]) -> [PDFPoint] { corners.map { PDFPoint(x: $0.0, y: $0.1) } }

    static func machine() async throws -> (AppCoreEnvironment, ProjectDatabaseActor, URL) {
        let pages = sheets.enumerated().map { index, id in
            ZPDFContracts.PageDescriptor(
                id: id, documentID: documentID, index: index, label: "A-10\(index + 1)",
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
            )
        }
        let session = try TakeoffSession(documentID: documentID, pages: pages)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        for sheet in sheets {
            try await environment.commands.calibrate(
                page: sheet, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                knownLength: 10, knownLengthUnit: .metre
            )
        }
        try await environment.commands.calibrate(
            page: sheets[0], first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre, scaleID: detailScale
        )
        try await environment.commands.perform(.setScaleRegions([ScaleRegionDefinition(
            id: detailRegion, pageID: sheets[0], name: "Detail",
            boundary: square([(500, 500), (800, 500), (800, 800), (500, 800)]),
            scaleID: detailScale, priority: 1, colorRGBA: ColorRGBA(red: 0, green: 1, blue: 1, alpha: 1)
        )]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zenit-it3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("project.sqlite"))
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        await environment.review.settle()
        return (environment, database, directory)
    }

    static func area(sheet: Int, x: Double = 0, y: Double = 0, width: Double = 100, subject: String = "Slab") -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: sheets[sheet], kind: .measurement, tool: .area,
            subject: subject, author: "Ada",
            geometry: MeasurementGeometry(pageID: sheets[sheet], polygons: [PolygonGeometry(outer: PolygonRing(
                points: square([(x, y), (x + width, y), (x + width, y + 50), (x, y + 50)]), isClosed: true
            ))]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    static func length(sheet: Int = 0, _ from: (Double, Double), _ to: (Double, Double)) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: sheets[sheet], kind: .measurement, tool: .length,
            subject: "Wall", author: "Ada",
            geometry: MeasurementGeometry(pageID: sheets[sheet], points: [PDFPoint(x: from.0, y: from.1), PDFPoint(x: to.0, y: to.1)]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    static func cloud(sheet: Int) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: sheets[sheet], kind: .cloud, author: "Bo",
            geometry: MeasurementGeometry(pageID: sheets[sheet], polygons: [PolygonGeometry(outer: PolygonRing(
                points: square([(300, 300), (400, 300), (400, 400)]), isClosed: true
            ))]),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), modifiedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zenit-it3-folder-\(UUID().uuidString)", isDirectory: true)
    }

    static func planArea(_ environment: AppCoreEnvironment, _ id: MarkupID) async -> Decimal? {
        await environment.session.markup(id)?.measurement?.values[.planArea]?.value
    }

    static func planLength(_ environment: AppCoreEnvironment, _ id: MarkupID) async -> Decimal? {
        await environment.session.markup(id)?.measurement?.values[.planLength]?.value
    }

    /// Every markup identity the document holds, live and set aside, in the order a save writes them.
    static func savedIDs(_ environment: AppCoreEnvironment) async -> [MarkupID] {
        let state = await environment.session.takeoffState()
        return (state.markups + state.setAsideMarkups).map(\.id)
    }

    // MARK: T-020

    /// A draws a 100 × 50 pt slab on A-102 (10 m × 5 m = 50 m²) and one on A-101; B draws a cloud
    /// on A-102. B removes A-102 from its set and syncs. A then relabels the slab and removes the
    /// cloud; B receives both only when A-102 is back.
    @Test("T-020: removing a sheet on one machine deletes nothing for the others; its changes wait for the sheet")
    func removedSheetKeepsEveryonesMarkups() async throws {
        let folderURL = Self.folder()
        let (a, dbA, dirA) = try await Self.machine()
        let (b, dbB, dirB) = try await Self.machine()
        defer { for url in [folderURL, dirA, dirB] { try? FileManager.default.removeItem(at: url) } }
        let syncA = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: nil)
        let syncB = SharedReviewSync(folderURL: folderURL, participantID: "bo-mac", base: nil)
        try syncA.prepare(projectID: "P3", projectName: "Tower")
        try syncB.prepare(projectID: "P3", projectName: "Tower")
        let start = Date()

        let slab = Self.area(sheet: 1)
        let keep = Self.area(sheet: 0, width: 200)
        let cloud = Self.cloud(sheet: 1)
        try await a.commands.perform(.addMarkup(slab))
        try await a.commands.perform(.addMarkup(keep))
        try await b.commands.perform(.addMarkup(cloud))
        try await syncA.sync(core: a, authorName: "Ada", now: start.addingTimeInterval(1))
        try await syncB.sync(core: b, authorName: "Bo", now: start.addingTimeInterval(2))
        try await syncA.sync(core: a, authorName: "Ada", now: start.addingTimeInterval(3))
        #expect(await a.session.orderedMarkups.count == 3)
        #expect(await b.session.orderedMarkups.count == 3)

        try await b.commands.perform(.setPagesExcluded([Self.sheets[1]], excluded: true))
        #expect(await b.session.orderedMarkups.map(\.id) == [keep.id])
        let removal = try await syncB.sync(core: b, authorName: "Bo", now: start.addingTimeInterval(4))
        // Old output: published 2 — a removal for the slab and one for the cloud.
        #expect(removal.published == 0)
        let atA = try await syncA.sync(core: a, authorName: "Ada", now: start.addingTimeInterval(5))
        // Old output: removed 2, and A was left with only the A-101 slab.
        #expect(atA.removed == 0)
        #expect(Set(await a.session.orderedMarkups.map(\.id)) == [slab.id, keep.id, cloud.id])

        try await a.commands.perform(.editLabel(id: slab.id, label: "Level 2"))
        try await a.commands.perform(.removeMarkup(cloud.id))
        try await syncA.sync(core: a, authorName: "Ada", now: start.addingTimeInterval(6))
        let waiting = try await syncB.sync(core: b, authorName: "Bo", now: start.addingTimeInterval(7))
        #expect(waiting.heldForRemovedSheets == 2)
        #expect(waiting.notApplied == 2)
        #expect(waiting.changed == 0 && waiting.removed == 0)
        #expect(await b.session.takeoffState().setAsideMarkups.map(\.id).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
                == [slab.id, cloud.id].sorted { $0.rawValue.uuidString < $1.rawValue.uuidString })
        let stillWaiting = try await syncB.sync(core: b, authorName: "Bo", now: start.addingTimeInterval(8))
        #expect(stillWaiting.published == 0 && stillWaiting.heldForRemovedSheets == 2)

        try await b.commands.perform(.setPagesExcluded([Self.sheets[1]], excluded: false))
        let back = try await syncB.sync(core: b, authorName: "Bo", now: start.addingTimeInterval(9))
        #expect(back.changed == 1 && back.removed == 1 && back.notApplied == 0)
        #expect(await b.session.markup(slab.id)?.label == "Level 2")
        let ids = await b.session.orderedMarkups.map(\.id)
        #expect(Set(ids) == [slab.id, keep.id])
        #expect(ids.count == 2, "no identity twice")
        // 10 m × 5 m and 20 m × 5 m.
        #expect(await Self.planArea(b, slab.id) == 50)
        #expect(await Self.planArea(b, keep.id) == 100)
        #expect(try await syncA.sync(core: a, authorName: "Ada", now: start.addingTimeInterval(10)).isQuiet)
        try? await dbA.close()
        try? await dbB.close()
    }

    @Test("T-020: a review file never puts a second copy of a set-aside markup live, and exports it")
    func reviewFileAcrossARemovedSheet() async throws {
        let (a, dbA, dirA) = try await Self.machine()
        let (b, dbB, dirB) = try await Self.machine()
        defer { for url in [dirA, dirB] { try? FileManager.default.removeItem(at: url) } }
        let start = Date()
        let first = Self.area(sheet: 1)
        let second = Self.area(sheet: 1, x: 300)
        try await a.commands.perform(.addMarkup(first))
        try await a.commands.perform(.addMarkup(second))
        let fileOne = await a.exportReviewFile(projectID: "P3", projectName: "Tower", author: "Ada", participantID: "ada-mac", now: start)
        try await b.acceptReviewFileImport(try await b.planReviewFileImport(fileOne, projectID: "P3"))
        #expect(await b.session.orderedMarkups.count == 2)

        try await b.commands.perform(.setPagesExcluded([Self.sheets[1]], excluded: true))
        // The whole review, set-aside markups included. Old output: an export with no markups.
        let exported = await b.exportReviewFile(projectID: "P3", projectName: "Tower", author: "Bo", participantID: "bo-mac", now: start)
        #expect(MergedReview.merge(exported.operations).records().count == 2)

        let third = Self.area(sheet: 1, x: 600)
        try await a.commands.perform(.addMarkup(third))
        try await a.commands.perform(.editLabel(id: first.id, label: "Level 2"))
        let fileTwo = await a.exportReviewFile(projectID: "P3", projectName: "Tower", author: "Ada", participantID: "ada-mac",
                                               now: start.addingTimeInterval(60))
        let plan = try await b.planReviewFileImport(fileTwo, projectID: "P3")
        // Old output: 3 new markups (both set-aside ones among them) and nothing held.
        #expect(plan.changes.added.isEmpty)
        #expect(plan.changes.changed.isEmpty)
        #expect(plan.onRemovedSheets == 2)
        #expect(plan.summary.contains("2 on sheets removed from the set"))
        try await b.acceptReviewFileImport(plan)

        try await b.commands.perform(.setPagesExcluded([Self.sheets[1]], excluded: false))
        let ids = await b.session.orderedMarkups.map(\.id)
        // Old output: first and second listed twice each after the restore, and the save wrote
        // them twice.
        #expect(ids.count == 2 && Set(ids) == [first.id, second.id])
        let saved = await Self.savedIDs(b)
        #expect(saved.count == Set(saved).count)

        // With the sheet back, the same file brings the rest in.
        let again = try await b.planReviewFileImport(fileTwo, projectID: "P3")
        #expect(again.changes.added.map(\.id) == [third.id] && again.onRemovedSheets == 0)
        try await b.acceptReviewFileImport(again)
        #expect(await b.session.markup(first.id)?.label == "Level 2")
        #expect(await b.session.orderedMarkups.count == 3)
        try? await dbA.close()
        try? await dbB.close()
    }

    @Test("T-020: the session refuses to add a markup under an identity set aside with a removed sheet")
    func sessionRefusesASetAsideIdentity() async throws {
        let (b, dbB, dirB) = try await Self.machine()
        defer { try? FileManager.default.removeItem(at: dirB) }
        let slab = Self.area(sheet: 1)
        try await b.commands.perform(.addMarkup(slab))
        try await b.commands.perform(.setPagesExcluded([Self.sheets[1]], excluded: true))
        // Old output: the add succeeded, the id stood live and set aside at once, and the save
        // listed it twice.
        await #expect(throws: (any Error).self) { try await b.commands.perform(.addMarkup(slab)) }
        #expect(await Self.savedIDs(b) == [slab.id])
        try? await dbB.close()
    }

    // MARK: T-021

    @Test("T-021: a Project Zone only one copy holds never refuses a sync or reaches the other copy's save")
    func foreignZone() async throws {
        let folderURL = Self.folder()
        let (a, dbA, dirA) = try await Self.machine()
        let (b, dbB, dirB) = try await Self.machine()
        let (c, dbC, dirC) = try await Self.machine()
        defer { for url in [folderURL, dirA, dirB, dirC] { try? FileManager.default.removeItem(at: url) } }
        let syncA = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: nil)
        let syncB = SharedReviewSync(folderURL: folderURL, participantID: "bo-mac", base: nil)
        try syncA.prepare(projectID: "P3", projectName: "Tower")
        try syncB.prepare(projectID: "P3", projectName: "Tower")
        let start = Date()

        let slab = Self.area(sheet: 0)
        try await a.commands.perform(.addMarkup(slab))
        try await syncA.sync(core: a, authorName: "Ada", now: start.addingTimeInterval(1))
        try await syncB.sync(core: b, authorName: "Bo", now: start.addingTimeInterval(2))

        // A makes a zone after the copies parted, files the shared slab in it, draws a new one in it.
        let zone = ProjectZoneDefinition(id: ZoneID(UUID()), name: "East", kind: .floor, sortOrder: 0,
                                         colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1))
        try await a.commands.perform(.setProjectZones([zone]))
        try await a.commands.perform(.setMarkupZone(ids: [slab.id], zoneID: zone.id))
        var filed = Self.area(sheet: 0, x: 300)
        filed.zoneID = zone.id
        try await a.commands.perform(.addMarkup(filed))
        try await syncA.sync(core: a, authorName: "Ada", now: start.addingTimeInterval(3))

        // Old output: SyncError.refused("ledger rebuild failed: no Project Zone …"), this sync and
        // every later one.
        let report = try await syncB.sync(core: b, authorName: "Bo", now: start.addingTimeInterval(4))
        #expect(report.added == 1)
        #expect(report.missingZonesOrRegions == 2)
        #expect(await b.session.markup(slab.id)?.zoneID == nil)
        // Old output (the add path): zone \(zone.id) kept, and the next save failed its foreign key.
        #expect(await b.session.markup(filed.id)?.zoneID == nil)
        #expect(await Self.planArea(b, filed.id) == 50)
        let again = try await syncB.sync(core: b, authorName: "Bo", now: start.addingTimeInterval(5))
        #expect(again.published == 0, "the unfiled copy is not published over A's filing")

        // A review file takes the same rule.
        let file = await a.exportReviewFile(projectID: "P3", projectName: "Tower", author: "Ada", participantID: "ada-mac", now: start)
        let plan = try await c.planReviewFileImport(file, projectID: "P3")
        #expect(plan.missingZonesOrRegions == 2)
        try await c.acceptReviewFileImport(plan)
        #expect(await c.session.markup(slab.id)?.zoneID == nil)
        #expect(await c.session.markup(filed.id)?.zoneID == nil)
        try? await dbA.close()
        try? await dbB.close()
        try? await dbC.close()
    }

    /// A's own region "Beam" on A-101 over x ∈ [100, 700], y ∈ [550, 650] at 100 pt = 2 m, which B
    /// never gets. On A: "inBeam" (150, 600)–(250, 600) and "span" (450, 600)–(600, 600) are
    /// measured in Beam; the shared "detail" (550, 600)–(650, 600) is moved out of the Detail
    /// region to the page scale (10 m), so it now names A's own page-scale identity.
    @Test("T-021: another copy's Scale Region and page-scale identity are resolved here, never named in a command")
    func foreignRegionAndScale() async throws {
        let folderURL = Self.folder()
        let (a, dbA, dirA) = try await Self.machine()
        let (b, dbB, dirB) = try await Self.machine()
        defer { for url in [folderURL, dirA, dirB] { try? FileManager.default.removeItem(at: url) } }
        let syncA = SharedReviewSync(folderURL: folderURL, participantID: "ada-mac", base: nil)
        let syncB = SharedReviewSync(folderURL: folderURL, participantID: "bo-mac", base: nil)
        try syncA.prepare(projectID: "P3", projectName: "Tower")
        try syncB.prepare(projectID: "P3", projectName: "Tower")
        let start = Date()

        let detail = Self.length((550, 600), (650, 600))
        await a.commit(detail, family: .measurement)
        // 100 pt in the Detail region: 100 × 0.01 = 1 m.
        #expect(await Self.planLength(a, detail.id) == 1)
        try await syncA.sync(core: a, authorName: "Ada", now: start.addingTimeInterval(1))
        try await syncB.sync(core: b, authorName: "Bo", now: start.addingTimeInterval(2))
        #expect(await b.session.markup(detail.id)?.scaleRegionID == Self.detailRegion)
        #expect(await Self.planLength(b, detail.id) == 1)

        let beamScale = ScaleID(UUID())
        try await a.commands.calibrate(page: Self.sheets[0], first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                       knownLength: 2, knownLengthUnit: .metre, scaleID: beamScale)
        let beam = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()), pageID: Self.sheets[0], name: "Beam",
            boundary: Self.square([(100, 550), (700, 550), (700, 650), (100, 650)]),
            scaleID: beamScale, priority: 2, colorRGBA: ColorRGBA(red: 1, green: 0, blue: 1, alpha: 1))
        try await a.commands.perform(.setScaleRegions(await a.session.scaleRegionDefinitions + [beam]))
        var inBeam = Self.length((150, 600), (250, 600))
        inBeam.scaleRegionID = beam.id
        inBeam.scaleID = beamScale
        var span = Self.length((450, 600), (600, 600))
        span.scaleRegionID = beam.id
        span.scaleID = beamScale
        try await a.commands.perform(.addMarkup(inBeam))
        try await a.commands.perform(.addMarkup(span))
        // 100 pt and 150 pt at 0.02 m/pt.
        #expect(await Self.planLength(a, inBeam.id) == 2)
        #expect(await Self.planLength(a, span.id) == 3)
        try await a.commands.perform(.setMarkupScaleRegion(ids: [detail.id], regionID: nil, scaleID: nil))
        #expect(await Self.planLength(a, detail.id) == 10)
        let aPageScale = try #require(await a.session.pageScale(Self.sheets[0])?.id)
        #expect(await a.session.markup(detail.id)?.scaleID == aPageScale)
        #expect(await b.session.scaleTransform(aPageScale) == nil, "each copy has its own page-scale identity")
        try await syncA.sync(core: a, authorName: "Ada", now: start.addingTimeInterval(3))

        // Old output: SyncError.refused("measurement failed: scale … is not held by this document")
        // for the detail's move, this sync and every later one; had it gone through, inBeam and span
        // were stored naming a region this copy has no row for.
        let report = try await syncB.sync(core: b, authorName: "Bo", now: start.addingTimeInterval(4))
        // Back on the page scale, like on A: 100 pt × 0.1 = 10 m.
        #expect(await b.session.markup(detail.id)?.scaleRegionID == nil)
        #expect(await Self.planLength(b, detail.id) == 10)
        // inBeam lies outside every region B holds: B's page scale, 100 pt × 0.1 = 10 m.
        #expect(await b.session.markup(inBeam.id)?.scaleRegionID == nil)
        #expect(await Self.planLength(b, inBeam.id) == 10)
        // span runs from the bare sheet into Detail: only a person can choose, so it is held.
        #expect(await b.session.markup(span.id) == nil)
        #expect(report.added == 1)
        #expect(report.missingZonesOrRegions == 2)
        let regionIDs = Set(await b.session.scaleRegionDefinitions.map(\.id))
        let scaleIDs = Set(await b.session.allScales.map(\.id))
        for record in await b.session.orderedMarkups {
            if let region = record.scaleRegionID { #expect(regionIDs.contains(region)) }
            if let scale = record.scaleID { #expect(scaleIDs.contains(scale)) }
        }
        // Stable: the next sync applies nothing new, refuses nothing, publishes nothing.
        let again = try await syncB.sync(core: b, authorName: "Bo", now: start.addingTimeInterval(5))
        #expect(again.published == 0 && again.added == 0)
        try? await dbA.close()
        try? await dbB.close()
    }

    // MARK: T-025

    @Test("T-025: a measured review annotation is measured at the scale of the Scale Region it lies in")
    func measuredAnnotationInARegion() async throws {
        let fixture = try await Iter2AppCorePasteRegionTests.fixture()
        func polyline(_ index: Int, _ points: [(Double, Double)], says contents: String = "") -> ImportedAnnotation {
            ImportedAnnotation(index: index, pageIndex: 0, subtype: "PolyLine", contents: contents,
                               rect: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000),
                               points: points.map { PDFPoint(x: $0.0, y: $0.1) }, intent: "PolyLineDimension")
        }
        let reading = ReviewAnnotationReader.Reading(annotations: [
            polyline(0, [(550, 600), (650, 600), (650, 700)], says: "2.00 m"),   // inside Detail: 200 pt × 0.01 = 2 m
            polyline(1, [(100, 100), (200, 100)], says: "10.00 m"),              // bare sheet: 100 pt × 0.1 = 10 m
            polyline(2, [(450, 600), (600, 600)])                                // across the boundary: held
        ], pageCount: 2, pageSizes: [], digest: "it3-t025-\(UUID())")
        let plan = await fixture.environment.planReviewImport(reading)
        #expect(plan.newMarkups.count == 3)
        #expect(plan.measurementsAcrossScaleRegions == 1)
        #expect(plan.summary.contains("1 measurement lies across Scale Regions"))
        let measured = plan.newMarkups.filter { $0.tool != nil }
        #expect(measured.count == 2, "the one across regions comes in as its plain markup")
        try await fixture.environment.acceptReviewImport(plan)
        let inside = try #require(measured.first { $0.geometry?.points.count == 3 })
        let outside = try #require(measured.first { $0.geometry?.points.count == 2 })
        // Old output: 20 m — the page scale, although the annotation lies in the 1:10-finer region.
        #expect(await fixture.session.markup(inside.id)?.measurement?.values[.planLength]?.value == 2)
        #expect(await fixture.session.markup(inside.id)?.scaleRegionID != nil)
        #expect(await fixture.session.markup(outside.id)?.measurement?.values[.planLength]?.value == 10)
        let plain = try #require(plan.newMarkups.first { $0.tool == nil })
        #expect(await fixture.session.markup(plain.id)?.measurement == nil)
        // The note says where the number came from. Old: "Zenit measured it again at this page's
        // scale" on the one measured at the Detail region's 1:10-finer scale.
        for record in [inside, outside] {
            let comment = try #require(await fixture.session.markup(record.id)?.comment)
            #expect(!comment.contains("page's scale") && !comment.contains("page’s scale"), "\(comment)")
            #expect(comment.contains("at the scale where it lies"), "\(comment)")
        }
        #expect(await fixture.session.markup(inside.id)?.comment.contains("The file said: 2.00 m.") == true)
    }

    // MARK: T-030

    @Test("T-030: a highlight's quads are grouped before a bad coordinate is dropped")
    func highlightQuadsStayAligned() {
        func point(_ x: Double, _ y: Double) -> PDFPoint { PDFPoint(x: x, y: y) }
        let quads = [
            point(0, 0), point(10, 0), point(0, 10), point(10, 10),
            point(.nan, 20), point(30, 20), point(20, 30), point(30, 30),
            point(40, 40), point(50, 40), point(40, 50), point(50, 50)
        ]
        let page = ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: Self.documentID, index: 0, label: "A-101",
                                                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000)))
        let plan = AnnotationImportPlanner.plan(
            annotations: [ImportedAnnotation(index: 0, pageIndex: 0, subtype: "Highlight",
                                             rect: PDFRect(x: 0, y: 0, width: 50, height: 50), quadPoints: quads)],
            pages: [page], documentID: Self.documentID, existingMarkupIDs: [], existingReplyIDs: [], fileDigest: "it3-t030"
        )
        func bounds(_ record: ZPDFContracts.MarkupRecord) -> [Double] {
            let points = record.geometry?.polygons.first?.outer.points ?? []
            return [points.map(\.x).min() ?? -1, points.map(\.y).min() ?? -1, points.map(\.x).max() ?? -1, points.map(\.y).max() ?? -1]
        }
        // Old output: two rectangles, [0, 0, 10, 10] and [20, 20, 40, 40] — the second built from
        // quad 2's corners and quad 3's first point, and quad 3 lost.
        #expect(plan.newMarkups.map(bounds) == [[0, 0, 10, 10], [40, 40, 50, 50]])

        // A 10 000-point highlight is 2 500 rectangles, read in one pass.
        let many = (0..<2_500).flatMap { index -> [PDFPoint] in
            let x = Double(index)
            return [point(x, 0), point(x + 1, 0), point(x, 1), point(x + 1, 1)]
        }
        let big = AnnotationImportPlanner.plan(
            annotations: [ImportedAnnotation(index: 0, pageIndex: 0, subtype: "Highlight",
                                             rect: PDFRect(x: 0, y: 0, width: 2_501, height: 1), quadPoints: many)],
            pages: [page], documentID: Self.documentID, existingMarkupIDs: [], existingReplyIDs: [], fileDigest: "it3-t030-big"
        )
        #expect(big.newMarkups.count == 2_500)
    }
}
