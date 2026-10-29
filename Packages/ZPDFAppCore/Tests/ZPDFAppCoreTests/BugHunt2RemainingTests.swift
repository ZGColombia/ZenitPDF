import CryptoKit
import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFPDFKitBridge
import ZPDFPersistence
import ZPDFQuantityLedger
import ZPDFUIPresentation

/// Bug hunt 2, the remaining medium and low findings with a practical test (BH-101, 425, 436,
/// 448, 451, 456, 464, 465, 466).
@Suite("Bug hunt 2: remaining findings")
struct BugHunt2RemainingTests {

    private static func page(_ documentID: DocumentID) -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: 0, label: "A-101",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792))
        )
    }

    // MARK: BH-101

    @Test("An export carries the filter rules its view could not apply")
    func exportCarriesUnappliedRules() async throws {
        let documentID = DocumentID(UUID())
        let session = try TakeoffSession(documentID: documentID, pages: [Self.page(documentID)])
        let subject = LedgerColumnID(try #require(await session.ledgerColumns.column(standard: .subject)).key)
        let request = LedgerRequest(filter: LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: subject, comparison: .matchesRegex, operand: .regex("^A")),
            LedgerFilterRule(id: UUID(), column: subject, comparison: .contains, operand: .text("Slab"))
        ]))
        // Old output: only the report, whose banner named the surviving rule as the whole filter.
        let export = try await session.exportReportWithDiagnostics(title: "T", request: request)
        #expect(export.unappliedFilterRules.map(\.reason) == [.unsupportedComparison])
        // The report itself carries them, so the PDF cover and the XLSX metadata sheet print
        // them. Old output: [] — the rule was dropped and the banner named only "contains Slab".
        #expect(export.report.metadata.unappliedFilterRules == export.unappliedFilterRules.map(\.message))
        #expect(export.report.metadata.unappliedFilterRules.count == 1)

        // A rule on the display-only Value column is carried too.
        let display = LedgerRequest(filter: LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: LedgerDefaultColumns.valueColumnID, comparison: .greaterThan, operand: .number(10))
        ]))
        let displayReport = try await session.exportReportWithDiagnostics(title: "T", request: display).report
        #expect(displayReport.metadata.unappliedFilterRules.count == 1)
        #expect(try await session.exportReportWithDiagnostics(title: "T").report.metadata.unappliedFilterRules.isEmpty)
    }

    // MARK: BH-425

    @Test("A measure lock on a hidden layer does not snap to linework nobody can see")
    @MainActor
    func lockOnAHiddenLayerStaysHidden() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fixture = try await OpenedFixture.open(.threeLayers, in: directory.url)
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await provider.open(.url(fixture.url), password: nil, limits: .standard)
        let tree = try #require(try await provider.layerTree(of: opened.handle))
        await provider.close(opened.handle)

        let model = DocumentLayerVisibility()
        model.adopt(tree: tree)
        // Grid ships OFF; lock measuring to it.
        let grid = try #require(model.items.first { $0.name == "Grid" })
        model.setMeasureLock(grid.id)
        // Old output: "L2" missing from the snap-hidden set — the hidden layer was forced on.
        #expect(model.snapHiddenMarkedContentNames(onPageIndex: 0).contains("L2"))
        #expect(model.hiddenMarkedContentNames(onPageIndex: 0).contains("L2"))
    }

    // MARK: BH-436

    @Test("A label edit does not move 'measured at'; a re-measure does")
    func labelEditDoesNotMoveMeasuredAt() {
        let markup = UUID().uuidString
        func entry(_ sequence: Int, _ at: String, before: String?, after: String?) -> MeasurementAuditRecord {
            MeasurementAuditRecord(
                id: UUID().uuidString, projectId: "p", markupId: markup, sequence: sequence,
                occurredAt: at, action: "markup_modified", actor: "t",
                beforeValuesJson: before, afterValuesJson: after
            )
        }
        var sources = MeasurementTraceResolver.Sources()
        sources.absorb(auditTrail: [
            MeasurementAuditRecord(id: UUID().uuidString, projectId: "p", markupId: markup, sequence: 1,
                                   occurredAt: "2026-01-01T00:00:00Z", action: "markup_created", actor: "t",
                                   afterValuesJson: #"{"planLength":"1"}"#),
            // A label edit: the values are the same before and after.
            entry(2, "2026-03-01T00:00:00Z", before: #"{"planLength":"1"}"#, after: #"{"planLength":"1"}"#)
        ])
        let key = MarkupID(UUID(uuidString: markup)!)
        // Old output: 2026-03-01, the label edit's time.
        #expect(sources.auditMeasuredAt[key] == PersistenceTimestamp.date(from: "2026-01-01T00:00:00Z"))
        sources.absorb(auditTrail: [
            entry(3, "2026-04-01T00:00:00Z", before: #"{"planLength":"1"}"#, after: #"{"planLength":"2"}"#)
        ])
        #expect(sources.auditMeasuredAt[key] == PersistenceTimestamp.date(from: "2026-04-01T00:00:00Z"))
    }

    // MARK: BH-448

    @Test("A ledger filter does not hide annotations that have no ledger row")
    @MainActor
    func filterLeavesAnnotationsAlone() async throws {
        let documentID = DocumentID(UUID())
        let page = Self.page(documentID)
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let note = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page.id, kind: .text,
            subject: "", author: "t",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 20, y: 10)]),
            createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
        )
        let wall = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: page.id, kind: .rectangle,
            subject: "Walls", author: "t",
            geometry: MeasurementGeometry(pageID: page.id, points: [PDFPoint(x: 50, y: 50), PDFPoint(x: 90, y: 90)]),
            createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
        )
        try await environment.commands.perform(.addMarkup(note))
        try await environment.commands.perform(.addMarkup(wall))
        let subject = LedgerColumnID(try #require(await session.ledgerColumns.column(standard: .subject)).key)
        environment.ledger.setCanvasFilterBehavior(.hideNonMatching)
        environment.ledger.setFilter(LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: subject, comparison: .equals, operand: .text("Doors"))
        ]))
        await environment.ledger.refresh()
        let visible = Set(environment.canvas.visibleMarkups.map(\.id))
        // Old output: the text annotation hidden with the wall, though it failed no rule.
        #expect(visible.contains(note.id.rawValue))
        #expect(!visible.contains(wall.id.rawValue))
    }

    // MARK: BH-451

    @Test("A capped own result set is not reported as capping other drawings' hits")
    @MainActor
    func truncationSummary() {
        // Old output: "First 523 results".
        #expect(AppSearchPresenter.summary(ownCount: 500, externalCount: 23, truncated: true)
            == "First 500 results in this drawing, 23 in other drawings")
        #expect(AppSearchPresenter.summary(ownCount: 12, externalCount: 3, truncated: false) == "15 results")
    }

    // MARK: BH-464, BH-465, BH-466

    @Test("A newer template body is refused; repeated column ids are placed once; digests ignore whitespace")
    @MainActor
    func templateVersioningColumnsAndDigest() async throws {
        let template = JobTemplate(
            id: UUID(), name: "Rig", createdAt: Date(timeIntervalSince1970: 1_756_400_000),
            presets: [], subjects: [], columnPreferences: []
        )
        let encoded = try JobTemplateStore.encoder().encode(template)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["formatVersion"] = JobTemplate.currentFormatVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: object)
        // Old output: decoded as v1 with its new keys silently dropped.
        #expect(throws: (any Error).self) { try JobTemplateStore.decoder().decode(JobTemplate.self, from: newer) }

        // BH-466: the digest is over the compact form, and a pretty-digest file still reads.
        let exported = try JobTemplateFile.export(template)
        #expect(try JobTemplateFile.read(exported) == template)
        var envelope = try #require(try JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let pretty = try JobTemplateFile.legacyPrettyPayload(of: template)
        envelope["payloadSHA256"] = SHA256.hash(data: pretty).map { String(format: "%02x", $0) }.joined()
        let legacyFile = try JSONSerialization.data(withJSONObject: envelope)
        #expect(try JobTemplateFile.read(legacyFile) == template)

        // BH-465: [subject, subject, label] places each once.
        let documentID = DocumentID(UUID())
        let session = try TakeoffSession(documentID: documentID, pages: [Self.page(documentID)])
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        let subject = LedgerColumnID.subject.rawValue
        let label = LedgerColumnID.label.rawValue
        let result = JobTemplateApplier.applyColumnPreferences([
            JobTemplateColumnPreference(columnID: subject, visible: true),
            JobTemplateColumnPreference(columnID: subject, visible: true),
            JobTemplateColumnPreference(columnID: label, visible: true)
        ], to: environment.ledger)
        // Old output: applied [subject, subject, label] and subject pushed out of first place.
        #expect(result.applied == [subject, label])
        #expect(environment.ledger.columns.prefix(2).map(\.id.rawValue) == [subject, label])
    }

    // MARK: BH-428

    @Test("A vertex on a region edge is a cut point, never a micro-segment")
    func vertexOnTheBoundaryIsNotAMicroSegment() throws {
        let page = PageID(UUID())
        let region = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()), pageID: page, name: "R",
            boundary: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0), PDFPoint(x: 100, y: 100), PDFPoint(x: 0, y: 100)],
            scaleID: ScaleID(UUID()), priority: 1, colorRGBA: ColorRGBA(red: 0, green: 0, blue: 0)
        )
        let resolver = try ScaleRegionResolver(pageID: page, regions: [region.geometryRegion])
        // The middle vertex sits exactly on the right edge, reached along a diagonal whose
        // re-derived parameter is not exactly 1 in floating point.
        let chain = [PDFPoint(x: 0.1, y: 0.3), PDFPoint(x: 100, y: 33.3), PDFPoint(x: 170.7, y: 61.9)]
        let parts = try #require(ScaleRegionSplitter.split(polyline: chain, resolver: resolver))
        #expect(parts.count == 2)
        for part in parts {
            let length = zip(part.points, part.points.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
            // Old risk: a ~1e-13 pt piece whose midpoint lies on the boundary.
            #expect(length > 1e-6)
        }
    }

    // MARK: BH-429

    @Test("A text comparison on a Choice column keeps its text operand")
    func choiceColumnTextComparisons() {
        let option = ChoiceOption(id: ChoiceOptionID(UUID()), value: "Open")
        let column = LedgerColumnDefinition(
            id: ColumnID(UUID()), key: "custom.state", title: "State", kind: .choice, choices: [option]
        )
        // Old output: `.choice` for contains too, which matched nothing (and its negation all).
        #expect(LedgerSpecBuilder.filterValue(.text("Open"), column: column, comparison: .contains) == .text("Open"))
        #expect(LedgerSpecBuilder.filterValue(.text("Open"), column: column, comparison: .equals) == .choice(option.id))
    }
}
