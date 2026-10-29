import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFCompare
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFUIPresentation

/// History, review, carry-forward, table import and the
/// spreadsheet round trip (R-052, R-053, R-055, R-056, R-068).
@Suite("Iteration 1 — history, review and imports")
@MainActor
struct Iter1AppCoreMiscTests {

    static let stamp = Date(timeIntervalSince1970: 1_790_000_000)

    func makeEnvironment() async throws -> (AppCoreEnvironment, TakeoffSession, ZPDFContracts.PageDescriptor, ProjectDatabaseActor, URL) {
        let documentID = DocumentID(UUID())
        let page = Iter1AppCoreSessionTests.page(documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-it1-misc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await ProjectDatabaseActor.open(at: directory.appendingPathComponent("project.sqlite"))
        environment.history.attach(database: database, projectID: documentID.rawValue.uuidString)
        try await environment.commands.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                                 knownLength: 10, knownLengthUnit: .metre)
        return (environment, session, page, database, directory)
    }

    // MARK: R-052

    /// Old output: every append re-read and re-rendered the whole trail (30 rows → 31 rendered
    /// for one new row), and a newly added markup rendered it all once more through its new name.
    @Test("An audit append renders only the rows it added, and the trail equals a full read")
    func auditAppendIsIncremental() async throws {
        let (environment, _, page, database, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<30 {
            try await environment.commands.perform(.addMarkup(
                Iter1AppCoreArchiveTests.rectangle(on: page, subject: "Slab \(index)", width: 10, height: 10)
            ))
        }
        await environment.history.settle()
        let rowsBefore = environment.history.events.count
        #expect(rowsBefore >= 30)
        let renderedBefore = environment.history.renderedRowCount

        let last = Iter1AppCoreArchiveTests.rectangle(on: page, subject: "Wall", width: 20, height: 10)
        try await environment.commands.perform(.addMarkup(last))
        await environment.history.settle()
        let added = environment.history.events.count - rowsBefore
        #expect(added == 1)
        #expect(environment.history.renderedRowCount - renderedBefore == added, "only the new row was rendered")
        #expect(environment.history.events.last?.markupSubject == "Wall", "the new markup's name reached its row")

        // A rename patches that markup's rows, and renders nothing.
        let renderedBeforeRename = environment.history.renderedRowCount
        try await environment.commands.perform(.editSubject(id: last.id, subject: "Wall A"))
        await environment.history.settle()
        #expect(environment.history.events.filter { $0.markupID == last.id.rawValue }.allSatisfy { $0.markupSubject == "Wall A" })
        #expect(environment.history.renderedRowCount - renderedBeforeRename == 1, "only the rename's own row")

        // The incremental trail is exactly what a fresh read of the database gives.
        let fresh = AppHistoryPresenter()
        fresh.attach(database: database, projectID: (await environment.session.documentID).rawValue.uuidString)
        await fresh.settle()
        #expect(fresh.events.map(\.sequence) == environment.history.events.map(\.sequence))
        #expect(fresh.events.map(\.changes) == environment.history.events.map(\.changes))
    }

    // MARK: R-053

    @Test("A thread lists only its markup's events and replies, and follows new ones")
    func threadIndexFollowsChanges() async throws {
        let (environment, _, page, database, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        environment.review.attach(database: database, projectID: (await environment.session.documentID).rawValue.uuidString)
        let a = Iter1AppCoreArchiveTests.rectangle(on: page, subject: "A", width: 10, height: 10)
        let b = Iter1AppCoreArchiveTests.rectangle(on: page, subject: "B", width: 10, height: 10)
        try await environment.commands.perform(.addMarkup(a))
        try await environment.commands.perform(.addMarkup(b))
        #expect(environment.review.addReply("On A", to: a.id.rawValue) != nil)
        #expect(environment.review.addReply("On B", to: b.id.rawValue) != nil)
        await environment.history.settle()
        await environment.review.settle()
        await environment.refresh()
        func summary(_ id: MarkupID) throws -> MarkupSummary { try #require(environment.snapshot.markups.first { $0.id == id.rawValue }) }

        let threadA = environment.review.thread(for: try summary(a.id))
        #expect(threadA.items.map(\.text) == ["On A"])
        #expect(threadA.history.allSatisfy { $0.markupID == a.id.rawValue } && !threadA.history.isEmpty)

        // A new reply (the thread revision) and a new status change (the trail) both show.
        #expect(environment.review.addReply("Again on A", to: a.id.rawValue) != nil)
        try await environment.commands.perform(.batchStatusChange(ids: [a.id], status: .accepted))
        await environment.history.settle()
        await environment.review.settle()
        let again = environment.review.thread(for: try summary(a.id))
        #expect(again.items.filter { $0.kind == .reply }.map(\.text) == ["On A", "Again on A"])
        #expect(again.items.contains { if case .statusChange = $0.kind { return true } else { return false } })
        #expect(again.history.count > threadA.history.count)
        #expect(environment.review.thread(for: try summary(b.id)).items.map(\.text) == ["On B"])
    }

    // MARK: R-055

    /// The batch Import Table now performs: the columns first, then the rows. Old output: the
    /// columns were added on the session outside the step, so one ⌘Z removed the rows and left
    /// the empty columns in the ledger.
    @Test("One undo removes an imported table's rows and its columns; redo brings both back")
    func tableImportIsOneStep() async throws {
        let (environment, session, page, _, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        let room = LedgerColumnDefinition(id: ColumnID(UUID()), key: "custom.room", title: "Room", kind: .text)
        var row = Iter1AppCoreArchiveTests.rectangle(on: page, subject: "Door D1", width: 10, height: 10)
        row.customValues = [room.id: .text("101")]
        try await environment.commands.performBatch([.addCustomColumns([room]), .addMarkup(row)], actionName: "Import Table")
        #expect(await session.ledgerColumns.column(key: "custom.room") != nil)
        #expect(await session.markup(row.id)?.customValues[room.id] == .text("101"))

        await environment.commands.undo()
        #expect(await session.ledgerColumns.column(key: "custom.room") == nil, "no empty column left behind")
        #expect(await session.markup(row.id) == nil)
        await environment.commands.redo()
        #expect(await session.ledgerColumns.column(key: "custom.room") != nil)
        #expect(await session.markup(row.id)?.customValues[room.id] == .text("101"))
    }

    // MARK: R-056

    /// Old output: every carried copy kept its source's `groupID` and `countGroupID`, so a group
    /// selection expanded over both revisions whenever both were live.
    @Test("A carried markup never shares a group, a count group or a count point with its source")
    func carriedGroupsAreFresh() {
        let documentID = DocumentID(UUID())
        let old = Iter1AppCoreSessionTests.page(documentID)
        let new = Iter1AppCoreSessionTests.page(documentID, index: 1)
        let group = MarkupGroupID(UUID())
        let countGroup = CountGroupID(UUID())
        var first = Iter1AppCoreArchiveTests.rectangle(on: old, subject: "A", width: 10, height: 10)
        first.groupID = group
        var second = Iter1AppCoreArchiveTests.rectangle(on: old, subject: "B", width: 10, height: 10)
        second.groupID = group
        let point = CountPoint(id: CountPointID(UUID()), position: PDFPoint(x: 5, y: 5), sequenceNumber: 1, groupID: countGroup)
        let count = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: old.id, kind: .count, tool: .count, subject: "Outlet",
            geometry: MeasurementGeometry(pageID: old.id, countPoints: [point]), countGroupID: countGroup,
            createdAt: Self.stamp, modifiedAt: Self.stamp
        )
        let plan = CarryForwardPlanner.plan(
            markups: [first, second, count], pairs: [old.id: CarryPair(target: new.id, alignment: .identity)], now: Self.stamp
        )
        let carried = plan.commands.compactMap { command -> ZPDFContracts.MarkupRecord? in
            if case .addMarkup(let record) = command { return record }
            return nil
        }
        #expect(carried.count == 3)
        let groups = Set(carried.prefix(2).compactMap(\.groupID))
        #expect(groups.count == 1, "the two carried members stay one group with each other")
        #expect(!groups.contains(group), "but not with their sources")
        let carriedCount = carried[2]
        #expect(carriedCount.countGroupID != nil && carriedCount.countGroupID != countGroup)
        let carriedPoint = try? #require(carriedCount.geometry?.countPoints.first)
        #expect(carriedPoint?.id != point.id)
        #expect(carriedPoint?.groupID == carriedCount.countGroupID)
        #expect(carriedPoint?.position == point.position)
    }

    // MARK: R-068

    /// 400 unit costs typed into a column that holds no amount yet all take one currency, the
    /// same the old per-cell scan found. The scan ran once per cell over every markup
    /// (400 × 400 record lookups); it runs once per column now.
    @Test("Currency cells of one column take one code, looked up once")
    func currencyCodeOncePerColumn() async throws {
        let (environment, session, page, _, directory) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: directory) }
        var ids: [MarkupID] = []
        var batch: [DocumentCommand] = []
        for index in 0..<400 {
            let record = Iter1AppCoreArchiveTests.rectangle(on: page, subject: "Slab \(index)", width: 10, height: 10)
            ids.append(record.id)
            batch.append(.addMarkup(record))
        }
        try await environment.commands.performBatch(batch, actionName: "Add")
        let unitCost = try #require(await session.ledgerColumns.column(standard: .unitCost))
        let edits = ids.map { SpreadsheetCellEdit(markupID: $0.rawValue, columnKey: unitCost.key, text: "12.50") }
        // U-031: the one currency rule, read before any amount is stored.
        let expected = environment.ledger.defaultCurrencyCode
        let receipt = try await environment.applySpreadsheetEdits(edits)
        #expect(receipt.applied == 400)
        for id in ids {
            guard case let .currency(amount, code)? = await session.markup(id)?.customValues[unitCost.id] else {
                Issue.record("no amount on \(id)"); return
            }
            #expect(amount == Decimal(string: "12.50"))
            #expect(code == expected)
        }
    }
}

/// NL-DOCS-12: Revision Compare's change regions reach carry-forward.
@Suite("Iteration 1 — carry-forward reads Revision Compare")
struct Iter1AppCoreCarryCompareTests {

    /// A one-page 612 × 792 PDF stroking `lines` (each `x0 y0 x1 y1`) 2 pt wide.
    static func writeLinePDF(_ lines: [(Double, Double, Double, Double)], to url: URL) throws {
        var content = "0 G 2 w\n"
        for (x0, y0, x1, y1) in lines { content += "\(x0) \(y0) m \(x1) \(y1) l S\n" }
        let stream = Data(content.utf8)
        var objects: [Data] = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>".utf8)
        ]
        var body = Data("<< /Length \(stream.count) >>\nstream\n".utf8)
        body.append(stream)
        body.append(Data("\nendstream".utf8))
        objects.append(body)
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
        for offset in offsets { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try bytes.write(to: url)
    }

    @Test("Regions pass through an identity alignment; an aligned or failed comparison reviews everything")
    func pairFromAlignment() {
        let target = PageID(UUID())
        let region = CGRect(x: 390, y: 395, width: 120, height: 30)
        let same = CarryForwardComparison.pair(target: target, revisedToBaseline: .identity, baselineRegions: [region])
        #expect(same.alignment.isIdentity)
        #expect(!same.reviewsEverything)
        #expect(same.changedRegions == [PDFRect(x: 390, y: 395, width: 120, height: 30)])
        let shifted = AlignmentTransform(a: 1, b: 0, c: 0, d: 1, tx: 12, ty: 0)
        let moved = CarryForwardComparison.pair(target: target, revisedToBaseline: shifted, baselineRegions: [region])
        #expect(moved.alignment.isIdentity, "an automatic alignment never moves the carried geometry")
        #expect(moved.reviewsEverything)
    }

    /// A re-plot from ARCH D (2592 × 1728 pt) to A1 (2384 × 1684 pt): the comparison has to scale
    /// the new sheet by 2592 / 2384 to lay it over the old one, so the alignment is not the
    /// identity. The carry never moves geometry, so a line at x 2450–2550 is carried to x 2450–2550
    /// on a sheet 2384 pt wide — beyond its right edge by 66 pt. Old output: the pair's changed
    /// region was the new sheet's rectangle (0, 0, 2384, 1684), the line's bounds [2450, 2550]
    /// missed it, and the line read `unchanged` although no part of the old sheet was known to
    /// be unchanged. A line at x 100–200 (inside the new sheet) was `needsReview` either way.
    @Test("An aligned or blind comparison onto a smaller sheet flags a measurement beyond that sheet too")
    func reviewEverythingBeyondTheNewSheet() async {
        let oldPage = PageID(UUID())
        let newPage = PageID(UUID())
        let documentID = DocumentID(UUID())
        func line(_ x0: Double, _ x1: Double) -> ZPDFContracts.MarkupRecord {
            ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: documentID, pageID: oldPage, kind: .measurement, tool: .length,
                subject: "Wall", geometry: MeasurementGeometry(pageID: oldPage, points: [PDFPoint(x: x0, y: 800), PDFPoint(x: x1, y: 800)]),
                createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
            )
        }
        let inside = line(100, 200)
        let beyond = line(2450, 2550)
        let scale = 2592.0 / 2384.0
        let aligned = CarryForwardComparison.pair(
            target: newPage,
            revisedToBaseline: AlignmentTransform(a: scale, b: 0, c: 0, d: scale, tx: 0, ty: 0),
            baselineRegions: []
        )
        #expect(aligned.reviewsEverything)
        let plan = CarryForwardPlanner.plan(markups: [inside, beyond], pairs: [oldPage: aligned], now: Date(timeIntervalSince1970: 0))
        let classes = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.sourceID, $0.classification) })
        #expect(classes[inside.id] == .needsReview)
        #expect(classes[beyond.id] == .needsReview, "carried unmoved to x 2450–2550, off a 2384 pt sheet, and still flagged")
        // Carried unmoved: the geometry is exactly where it was drawn.
        let carried = plan.commands.compactMap { command -> PDFPoint? in
            if case .addMarkup(let record) = command, record.id == plan.items.first(where: { $0.sourceID == beyond.id })?.carriedID {
                return record.geometry?.points.first
            }
            return nil
        }
        #expect(carried == [PDFPoint(x: 2450, y: 800)])

        // No comparison at all (the comparator cannot read either sheet): the same.
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let comparator = RevisionComparator(source: InProcessRevisionDocumentSource(provider: provider))
        let unreadable = RevisionPageReference(document: DocumentHandle(rawValue: 987_655), pageIndex: 0,
                                               fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).pdf"), label: "?")
        let blind = await CarryForwardComparison.pair(target: newPage, baseline: unreadable, revised: unreadable, comparator: comparator)
        #expect(blind.reviewsEverything)
        let blindPlan = CarryForwardPlanner.plan(markups: [inside, beyond], pairs: [oldPage: blind], now: Date(timeIntervalSince1970: 0))
        #expect(blindPlan.items.map(\.classification) == [.needsReview, .needsReview])

        // A comparison with the identity and one changed region still flags only what lies under it.
        let compared = CarryForwardComparison.pair(target: newPage, revisedToBaseline: .identity,
                                                   baselineRegions: [CGRect(x: 90, y: 790, width: 20, height: 20)])
        let comparedPlan = CarryForwardPlanner.plan(markups: [inside, beyond], pairs: [oldPage: compared], now: Date(timeIntervalSince1970: 0))
        let comparedClasses = Dictionary(uniqueKeysWithValues: comparedPlan.items.map { ($0.sourceID, $0.classification) })
        #expect(comparedClasses[inside.id] == .needsReview)
        #expect(comparedClasses[beyond.id] == .unchanged)
    }

    /// Old sheet: a line (100,100)–(200,100) and a line (400,400)–(500,400). New revision: the
    /// first unchanged, the second redrawn at y = 420. A measurement along each is carried. Old
    /// output: both `unchanged` (the pair had no changed regions). Now the second is `needsReview`.
    @Test("A measurement under redrawn linework is carried as needs review; one elsewhere stays unchanged")
    func carryFlagsChangedLinework() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-it1-carry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("A-101 rev A.pdf")
        let newURL = directory.appendingPathComponent("A-101 rev B.pdf")
        try Self.writeLinePDF([(100, 100, 200, 100), (400, 400, 500, 400)], to: oldURL)
        try Self.writeLinePDF([(100, 100, 200, 100), (400, 420, 500, 420)], to: newURL)

        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let oldDocument = try await provider.open(fileAt: oldURL)
        let newDocument = try await provider.open(fileAt: newURL)
        let comparator = RevisionComparator(source: InProcessRevisionDocumentSource(provider: provider))
        let newPage = PageID(UUID())
        let pair = await CarryForwardComparison.pair(
            target: newPage,
            baseline: RevisionPageReference(document: oldDocument.handle, pageIndex: 0, fileURL: oldURL, label: "A"),
            revised: RevisionPageReference(document: newDocument.handle, pageIndex: 0, fileURL: newURL, label: "B"),
            comparator: comparator
        )
        await provider.closeAll()
        #expect(pair.alignment.isIdentity)
        #expect(!pair.reviewsEverything)
        #expect(!pair.changedRegions.isEmpty)
        #expect(pair.changedRegions.allSatisfy { $0.origin.y >= 380 }, "only the redrawn line differs: \(pair.changedRegions)")

        let documentID = DocumentID(UUID())
        let oldPage = PageID(UUID())
        func line(_ y: Double, _ x0: Double, _ x1: Double) -> ZPDFContracts.MarkupRecord {
            ZPDFContracts.MarkupRecord(
                id: MarkupID(UUID()), documentID: documentID, pageID: oldPage, kind: .measurement, tool: .length,
                subject: "Wall", geometry: MeasurementGeometry(pageID: oldPage, points: [PDFPoint(x: x0, y: y), PDFPoint(x: x1, y: y)]),
                createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
            )
        }
        let kept = line(100, 100, 200)
        let redrawn = line(400, 400, 500)
        let plan = CarryForwardPlanner.plan(markups: [kept, redrawn], pairs: [oldPage: pair], now: Date(timeIntervalSince1970: 0))
        let classes = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.sourceID, $0.classification) })
        #expect(classes[kept.id] == .unchanged)
        #expect(classes[redrawn.id] == .needsReview)

        // No comparison can be made (a document the source cannot read): the pair reviews
        // everything, and every carried measurement asks for review.
        let unreadable = RevisionPageReference(document: DocumentHandle(rawValue: 987_654), pageIndex: 0,
                                               fileURL: directory.appendingPathComponent("missing.pdf"), label: "?")
        let blind = await CarryForwardComparison.pair(
            target: newPage, baseline: unreadable, revised: unreadable, comparator: comparator
        )
        #expect(blind.reviewsEverything)
        let blindPlan = CarryForwardPlanner.plan(markups: [kept], pairs: [oldPage: blind], now: Date(timeIntervalSince1970: 0))
        #expect(blindPlan.items.first?.classification == .needsReview)
    }
}
