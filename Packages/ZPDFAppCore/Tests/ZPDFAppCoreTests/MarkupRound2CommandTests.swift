import Foundation
import GRDB
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFPersistence
import ZPDFUIPresentation

/// ADR-0029 (round 2, markup unit): arrange (NL-MARKUP-13), group (NL-MARKUP-11), link
/// (NL-MARKUP-17), and the `style_blob` carriage of group and link. Expected orders are derived
/// by hand in each comment.
@MainActor
struct MarkupRound2CommandTests {

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func environment(pages count: Int) async throws -> (AppCoreEnvironment, TakeoffSession, [ZPDFContracts.PageDescriptor]) {
        let documentID = DocumentID(UUID())
        let pages = (0..<count).map { index in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()), documentID: documentID, index: index, label: "A-\(index + 1)",
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
            )
        }
        let session = try TakeoffSession(documentID: documentID, pages: pages, units: .metric)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, session, pages)
    }

    private static func rectangle(on page: PageID, documentID: UUID, x: Double = 100, kind: ZPDFContracts.MarkupKind = .rectangle) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(documentID), pageID: page, kind: kind,
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(
                points: [PDFPoint(x: x, y: 100), PDFPoint(x: x + 50, y: 100), PDFPoint(x: x + 50, y: 150), PDFPoint(x: x, y: 150)],
                isClosed: true
            ))]),
            createdAt: now, modifiedAt: now
        )
    }

    // MARK: Arrangement, pure

    @Test("Arrangement reorders one page's order, moved markups keeping their relative order")
    func arrangementIsPure() {
        let order = ["A", "B", "C", "D", "E"]
        // To front: the unmoved A, C, E then the moved B, D.
        #expect(MarkupArrangement.bringToFront.reorder(order, moving: ["B", "D"]) == ["A", "C", "E", "B", "D"])
        #expect(MarkupArrangement.sendToBack.reorder(order, moving: ["B", "D"]) == ["B", "D", "A", "C", "E"])
        // Forward one step: B passes C, D passes E.
        #expect(MarkupArrangement.bringForward.reorder(order, moving: ["B", "D"]) == ["A", "C", "B", "E", "D"])
        // Backward one step: B passes A, D passes C.
        #expect(MarkupArrangement.sendBackward.reorder(order, moving: ["B", "D"]) == ["B", "A", "D", "C", "E"])
        // A block moves as one: B, C forward past D.
        #expect(MarkupArrangement.bringForward.reorder(order, moving: ["B", "C"]) == ["A", "D", "B", "C", "E"])
        // Already on top / bottom: no change.
        #expect(MarkupArrangement.bringForward.reorder(order, moving: ["E"]) == order)
        #expect(MarkupArrangement.sendBackward.reorder(order, moving: ["A"]) == order)
        #expect(MarkupArrangement.bringToFront.reorder(order, moving: []) == order)
    }

    // MARK: Arrange, on the session

    @Test("Send to Back reorders only its page, is one undo step, and survives save and reopen")
    func sendToBackOnSession() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 2)
        let doc = environment.snapshot.documentID
        let a = Self.rectangle(on: pages[0].id, documentID: doc, x: 10)
        let other = Self.rectangle(on: pages[1].id, documentID: doc, x: 20)
        let b = Self.rectangle(on: pages[0].id, documentID: doc, x: 30)
        let c = Self.rectangle(on: pages[0].id, documentID: doc, x: 40)
        for record in [a, other, b, c] { _ = try await environment.commands.perform(.addMarkup(record)) }

        _ = try await environment.commands.perform(.arrangeMarkups(ids: [c.id], arrangement: .sendToBack))
        // Page 0's slots are 0, 2, 3; its new order C, A, B fills them; page 1's markup stays at 1.
        #expect(await session.orderedMarkups.map(\.id) == [c.id, other.id, a.id, b.id])
        #expect(await session.orderedMarkups.filter { $0.pageID == pages[0].id }.map(\.id) == [c.id, a.id, b.id])
        #expect(environment.commands.undoManager.undoActionName == "Send to Back")

        await environment.commands.undo()
        #expect(await session.orderedMarkups.map(\.id) == [a.id, other.id, b.id, c.id])
    }

    @Test("Arranging a markup already in place registers nothing")
    func arrangeNoOp() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 1)
        let a = Self.rectangle(on: pages[0].id, documentID: environment.snapshot.documentID)
        _ = try await environment.commands.perform(.addMarkup(a))
        let outcome = try await session.apply(.arrangeMarkups(ids: [a.id], arrangement: .bringToFront))
        #expect(outcome.inverse.isEmpty)
    }

    // MARK: Group

    @Test("Group sets one group on every member in one undo step; Ungroup clears it; locked refuses")
    func groupAndUngroup() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 1)
        let doc = environment.snapshot.documentID
        let records = (0..<3).map { Self.rectangle(on: pages[0].id, documentID: doc, x: Double($0) * 60) }
        for record in records { _ = try await environment.commands.perform(.addMarkup(record)) }
        let group = MarkupGroupID(UUID())
        _ = try await environment.commands.perform(.setMarkupGroup(ids: records.map(\.id), groupID: group))
        for record in records { #expect(await session.markup(record.id)?.groupID == group) }
        #expect(environment.commands.undoManager.undoActionName == "Group")

        await environment.commands.undo()
        for record in records { #expect(await session.markup(record.id)?.groupID == nil) }

        _ = try await environment.commands.perform(.setMarkupGroup(ids: records.map(\.id), groupID: group))
        _ = try await environment.commands.perform(.setMarkupGroup(ids: records.map(\.id), groupID: nil))
        #expect(environment.commands.undoManager.undoActionName == "Ungroup")
        for record in records { #expect(await session.markup(record.id)?.groupID == nil) }

        _ = try await environment.commands.perform(.setLocked(ids: [records[0].id], locked: true))
        await #expect(throws: DocumentCommandError.markupLocked(records[0].id)) {
            _ = try await session.apply(.setMarkupGroup(ids: records.map(\.id), groupID: group))
        }
    }

    // MARK: Link

    @Test("A link is set on a hyperlink markup only")
    func linkOnHyperlinkOnly() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 2)
        let doc = environment.snapshot.documentID
        let link = Self.rectangle(on: pages[0].id, documentID: doc, kind: .hyperlink)
        let box = Self.rectangle(on: pages[0].id, documentID: doc, x: 300)
        _ = try await environment.commands.perform(.addMarkup(link))
        _ = try await environment.commands.perform(.addMarkup(box))
        let target = MarkupLinkTarget(pageID: pages[1].id)
        _ = try await environment.commands.perform(.setMarkupLink(id: link.id, link: target))
        #expect(await session.markup(link.id)?.link == target)
        #expect(environment.commands.undoManager.undoActionName == "Change Link")
        _ = try? await environment.commands.perform(.setMarkupLink(id: box.id, link: target))
        #expect(await session.markup(box.id)?.link == nil, "a rectangle has no destination")
        await environment.commands.undo()
        // The no-op on the rectangle registered nothing, so this undo takes back the link itself.
        #expect(await session.markup(link.id)?.link == nil)
    }

    // MARK: Storage

    @Test("Group and link ride in style_blob; an ungrouped markup writes the version-4 blob")
    func styleBlobCarriesExtras() throws {
        let page = PageID(UUID())
        var record = Self.rectangle(on: page, documentID: UUID())
        let plain = try TakeoffStyleCodec.encode(record)
        #expect(plain == (try TakeoffStyleCodec.encode(record.style)), "no extra keys when unused")
        #expect(TakeoffStyleCodec.extras(plain) == TakeoffStyleCodec.Extras())

        record.groupID = MarkupGroupID(UUID())
        record.link = MarkupLinkTarget(url: "https://example.org")
        record.style.textStyle = MarkupTextStyle(bold: true)
        let blob = try TakeoffStyleCodec.encode(record)
        // The style still decodes from the blob with the extras present (an old reader ignores them).
        #expect(TakeoffStyleCodec.decode(blob) == record.style)
        let extras = TakeoffStyleCodec.extras(blob)
        #expect(extras.groupID == record.groupID)
        #expect(extras.link == record.link)
    }

    @Test("Group, link, arranged order and text style survive a save and reopen")
    func archiveRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-r2-markup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await OpenedFixture.open(.titleBlockSheet, in: directory)
        let session = try TakeoffSession(documentID: fixture.documentID, pages: fixture.pages)
        let page = fixture.firstPage.id
        var a = Self.rectangle(on: page, documentID: fixture.documentID.rawValue, x: 10)
        a.style.textStyle = MarkupTextStyle(bold: true, italic: true, textColor: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1), boxBorder: true)
        a.style.rotationDegrees = 30
        a.style.cloudArcSize = 12
        var b = Self.rectangle(on: page, documentID: fixture.documentID.rawValue, x: 80, kind: .hyperlink)
        b.link = MarkupLinkTarget(url: "https://example.org")
        for record in [a, b] { _ = try await session.apply(.addMarkup(record)) }
        let group = MarkupGroupID(UUID())
        _ = try await session.apply(.setMarkupGroup(ids: [a.id, b.id], groupID: group))
        _ = try await session.apply(.arrangeMarkups(ids: [b.id], arrangement: .sendToBack))

        let package = try await ProjectPackage.create(
            at: directory.appendingPathComponent("R2.zpdfproj", isDirectory: true),
            displayName: "R2", originalPDF: fixture.url
        )
        try await TakeoffArchive.write(await session.takeoffState(), into: package)
        let read = try #require(try await TakeoffArchive.read(from: package))
        try await package.close()
        #expect(read.markups.map(\.id) == [b.id, a.id], "draw order is the stored order")
        let readA = try #require(read.markups.first { $0.id == a.id })
        let readB = try #require(read.markups.first { $0.id == b.id })
        #expect(readA.style == a.style)
        #expect(readA.groupID == group)
        #expect(readB.groupID == group)
        #expect(readB.link == b.link)
    }

    // MARK: Align and distribute (NL-MARKUP-12)

    private static func textBox(on page: PageID, documentID: UUID, x: Double, y: Double, width: Double) -> ZPDFContracts.MarkupRecord {
        ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(documentID), pageID: page, kind: .text,
            caption: "Note",
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: x, y: y), PDFPoint(x: x + width, y: y + 20)]),
            createdAt: now, modifiedAt: now
        )
    }

    @Test("Align Left makes four text boxes' minX equal in one undo step; Distribute Vertically spaces centres")
    func alignAndDistribute() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 1)
        let doc = environment.snapshot.documentID
        // Left edges 40, 13.7, 90, 200; the smallest is 13.7.
        let boxes = [
            Self.textBox(on: pages[0].id, documentID: doc, x: 40, y: 10, width: 50),
            Self.textBox(on: pages[0].id, documentID: doc, x: 13.7, y: 100, width: 80),
            Self.textBox(on: pages[0].id, documentID: doc, x: 90, y: 130, width: 30),
            Self.textBox(on: pages[0].id, documentID: doc, x: 200, y: 400, width: 10)
        ]
        for box in boxes { _ = try await environment.commands.perform(.addMarkup(box)) }
        let failure = await environment.layOutMarkups(boxes.map(\.id.rawValue), .left)
        #expect(failure == nil)
        for box in boxes {
            let minX = try #require(await session.markup(box.id)?.geometry?.bounds?.standardized.minX)
            #expect(abs(minX - 13.7) < 1e-9)
        }
        #expect(environment.commands.undoManager.undoActionName == "Align Left")

        // Centres y: 20, 110, 140, 410. First and last stay; step = (410 − 20) / 3 = 130, so
        // the middle two go to 150 and 280.
        _ = await environment.layOutMarkups(boxes.map(\.id.rawValue), .distributeVertically)
        var centres: [Double] = []
        for box in boxes {
            let b = try #require(await session.markup(box.id)?.geometry?.bounds?.standardized)
            centres.append((b.minY + b.maxY) / 2)
        }
        let expected: [Double] = [20, 150, 280, 410]
        for (got, want) in zip(centres, expected) { #expect(abs(got - want) < 1e-9) }

        await environment.commands.undo()
        await environment.commands.undo()
        let restored = try #require(await session.markup(boxes[0].id)?.geometry?.bounds?.standardized.minX)
        #expect(abs(restored - 40) < 1e-9, "two undo steps restore the original layout")
    }

    @Test("Make Same Width scales to the first markup's width; a sheet-spanning selection is refused")
    func sameWidthAndRefusals() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 2)
        let doc = environment.snapshot.documentID
        let a = Self.textBox(on: pages[0].id, documentID: doc, x: 0, y: 0, width: 100)
        let b = Self.textBox(on: pages[0].id, documentID: doc, x: 10, y: 50, width: 40)
        let c = Self.textBox(on: pages[1].id, documentID: doc, x: 10, y: 50, width: 40)
        for record in [a, b, c] { _ = try await environment.commands.perform(.addMarkup(record)) }
        #expect(await environment.layOutMarkups([a.id.rawValue, b.id.rawValue], .sameWidth) == nil)
        let width = try #require(await session.markup(b.id)?.geometry?.bounds?.standardized.width)
        #expect(abs(width - 100) < 1e-9)
        #expect(await environment.layOutMarkups([a.id.rawValue, c.id.rawValue], .left) != nil)
    }

    @Test("Layout planner: centre alignment, pure")
    func plannerCentres() {
        let a = MarkupID(UUID()), b = MarkupID(UUID())
        // Selection spans x 0…100; centre 50. a (0…20) moves +40; b (60…100) moves −30.
        let changes = MarkupLayoutPlanner.changes(.centreHorizontally, boxes: [
            (a, PDFRect(x: 0, y: 0, width: 20, height: 5)),
            (b, PDFRect(x: 60, y: 0, width: 40, height: 5))
        ])
        #expect(changes.map(\.dx) == [40, -30])
    }

    // MARK: Groups in the environment

    @Test("Grouping expands a one-member selection to the whole group, and arranges as one")
    func groupExpansion() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 1)
        let doc = environment.snapshot.documentID
        let records = (0..<4).map { Self.rectangle(on: pages[0].id, documentID: doc, x: Double($0) * 60) }
        for record in records { _ = try await environment.commands.perform(.addMarkup(record)) }
        #expect(await environment.groupMarkups([records[0].id.rawValue, records[1].id.rawValue]) == nil)
        #expect(environment.expandingGroups([records[1].id.rawValue]) == [records[0].id.rawValue, records[1].id.rawValue])
        #expect(environment.selectionHasGroup([records[0].id.rawValue]))
        _ = await environment.arrangeMarkups([records[0].id.rawValue], .bringToFront)
        #expect(await session.orderedMarkups.map(\.id) == [records[2].id, records[3].id, records[0].id, records[1].id])
        _ = await environment.ungroupMarkups([records[0].id.rawValue])
        #expect(!environment.selectionHasGroup([records[0].id.rawValue, records[1].id.rawValue]))
    }

    @Test("A pasted group is a new group, not a member of the copied one")
    func pastedGroupIsNew() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 1)
        let doc = environment.snapshot.documentID
        let records = (0..<2).map { Self.rectangle(on: pages[0].id, documentID: doc, x: Double($0) * 60) }
        for record in records { _ = try await environment.commands.perform(.addMarkup(record)) }
        _ = await environment.groupMarkups(records.map(\.id.rawValue))
        let original = try #require(await session.markup(records[0].id)?.groupID)
        let payload = try #require(await environment.markupClipboardPayload(for: Set(records.map(\.id.rawValue))))
        let receipt = await environment.pasteMarkups(payload, onto: [pages[0].id.rawValue], placement: .offset(dx: 10, dy: -10))
        var pastedGroups: Set<MarkupGroupID> = []
        for id in receipt.pastedIDs {
            if let group = await session.markup(MarkupID(id))?.groupID { pastedGroups.insert(group) }
        }
        #expect(pastedGroups.count == 1)
        #expect(!pastedGroups.contains(original))
    }

    // MARK: Tools (NL-MARKUP-06, 10, 17)

    @Test("Freehand simplification keeps the endpoints and drops samples within tolerance")
    func freehandSimplifies() {
        // A straight run with 0.1 pt jitter, then a corner: RDP at 0.5 keeps the ends and the corner.
        var points: [PDFPointValue] = (0...10).map { PDFPointValue(x: Double($0) * 10, y: $0 % 2 == 0 ? 0 : 0.1) }
        points.append(PDFPointValue(x: 100, y: 50))
        let simplified = AppMarkupToolPresenter.simplified(points, tolerance: 0.5)
        #expect(simplified.first == points.first)
        #expect(simplified.last == PDFPointValue(x: 100, y: 50))
        #expect(simplified.contains(PDFPointValue(x: 100, y: 0)))
        #expect(simplified.count == 3)
    }

    @Test("Pen commits a freehand stroke; Highlighter adds the multiply blend")
    func penAndHighlighter() {
        let presenter = AppMarkupToolPresenter(documentID: DocumentID(UUID()), pageID: PageID(UUID()))
        var committed: [ZPDFContracts.MarkupRecord] = []
        presenter.onCommit = { committed.append($0) }
        presenter.activate(kind: .freehand, style: .zenitInk)
        for x in stride(from: 0.0, through: 50, by: 5) { presenter.appendFreehandPoint(PDFPointValue(x: x, y: x * x / 50)) }
        presenter.commit()
        presenter.activate(kind: .freehand, style: .highlighter, variant: .highlighter)
        presenter.appendFreehandPoint(PDFPointValue(x: 0, y: 0))
        presenter.appendFreehandPoint(PDFPointValue(x: 80, y: 0))
        presenter.commit()
        #expect(committed.count == 2)
        #expect(committed[0].kind == .freehand)
        #expect(committed[0].style.blendMode == nil)
        #expect((committed[0].geometry?.points.count ?? 0) >= 3, "a curve keeps its bend")
        #expect(committed[1].style.blendMode == .multiply)
        #expect(committed[1].style.lineWidth == 12)
        #expect(abs(committed[1].style.opacity - 0.4) < 1e-12)
    }

    @Test("Clouded callout: one record, a cloud ring plus target and box, the words in caption")
    func cloudedCallout() {
        let presenter = AppMarkupToolPresenter(documentID: DocumentID(UUID()), pageID: PageID(UUID()))
        var committed: [ZPDFContracts.MarkupRecord] = []
        presenter.onCommit = { committed.append($0) }
        presenter.activate(kind: .cloud, style: .zenitInk, variant: .cloudedCallout)
        let placement = AppMarkupToolPresenter.cloudedCalloutPlacement(
            ring: PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 60), fontSize: 11
        )
        // Target is the ring's top-right corner (100, 60); the box starts 22 pt up and right.
        #expect(placement.target == PDFPointValue(x: 100, y: 60))
        #expect(placement.box.minX == 122 && placement.box.minY == 82)
        presenter.setPoints([
            PDFPointValue(x: 0, y: 0), PDFPointValue(x: 100, y: 60), placement.target,
            PDFPointValue(x: placement.box.minX, y: placement.box.minY),
            PDFPointValue(x: placement.box.maxX, y: placement.box.maxY)
        ])
        presenter.setDraftText("Revised door")
        presenter.commit()
        let record = try? #require(committed.first)
        #expect(record?.kind == .cloud)
        #expect(record?.caption == "Revised door")
        #expect(record?.geometry?.polygons.first?.outer.points.count == 4)
        #expect(record?.geometry?.points.count == 3)
        #expect(record.map(MarkupVisibleText.isCloudedCallout) == true)
        #expect(record?.style.endCap == .openArrow, "the leader has the callout's open arrow")
    }

    @Test("A note keeps its words as its note, not as drawn text; an empty note is discarded")
    func noteTool() {
        let presenter = AppMarkupToolPresenter(documentID: DocumentID(UUID()), pageID: PageID(UUID()))
        var committed: [ZPDFContracts.MarkupRecord] = []
        presenter.onCommit = { committed.append($0) }
        presenter.activate(kind: .note, style: .zenitInk)
        presenter.placePoint(PDFPointValue(x: 50, y: 50))
        #expect(!presenter.canCommit)
        presenter.setDraftText("Check this")
        presenter.commit()
        #expect(committed.first?.comment == "Check this")
        #expect(committed.first?.caption == nil)
        // A 20 pt icon, the click at its top-left: (50, 50) and (70, 30).
        #expect(committed.first?.geometry?.points == [PDFPoint(x: 50, y: 50), PDFPoint(x: 70, y: 30)])
    }

    @Test("Bulk edit writes bold, italic, text colour, box border, arc size and rotation where they fit")
    func bulkEditRoundTwoFields() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 1)
        let doc = environment.snapshot.documentID
        let text = Self.textBox(on: pages[0].id, documentID: doc, x: 0, y: 0, width: 60)
        let cloud = Self.rectangle(on: pages[0].id, documentID: doc, x: 200, kind: .cloud)
        for record in [text, cloud] { _ = try await environment.commands.perform(.addMarkup(record)) }
        var edit = MarkupStyleEdit()
        edit.bold = true
        edit.italic = true
        edit.textColor = ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1)
        edit.boxBorder = true
        edit.cloudArcSize = 100
        edit.rotationDegrees = -30
        let receipt = await environment.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [text.id.rawValue, cloud.id.rawValue], values: [:], style: edit
        ))
        #expect(receipt.failureDescription == nil)
        let storedText = try #require(await session.markup(text.id))
        let storedCloud = try #require(await session.markup(cloud.id))
        #expect(storedText.style.textStyle == MarkupTextStyle(bold: true, italic: true, textColor: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1), boxBorder: true))
        #expect(storedCloud.style.textStyle?.boxBorder == false, "a box border is a Text box's only")
        #expect(storedText.style.cloudArcSize == nil, "a text box does not scallop")
        #expect(storedCloud.style.cloudArcSize == 72, "clamped to the 72 pt ceiling")
        #expect(storedText.style.rotationDegrees == 330)
        #expect(receipt.undoActionName == "Change Appearance (2 Markups)")
    }

    // MARK: Full-style presets (NL-MARKUP-15)

    @Test("A preset captured from a red dashed 3 pt cloud with a 20 % fill places exactly that; old presets keep their colour-only look")
    func fullStylePresets() throws {
        let red = ColorRGBA(red: 0.86, green: 0.1, blue: 0.1, alpha: 1)
        let redFill = ColorRGBA(red: 0.86, green: 0.1, blue: 0.1, alpha: 0.2)
        let captured = ToolStyleSelection(stroke: red, fill: redFill, lineWidth: 3, lineStyle: .dashed)
        let preset = ToolPresetSummary(
            id: UUID(), name: "Revision", category: "Markups", panel: .myTools, markupKind: .cloud,
            colorRGBA: red, defaultSubject: "", style: captured
        )
        let placed = AppMarkupToolPresenter.markupStyle(kind: .cloud, style: preset.placementStyle)
        #expect(placed.color == RGBAColor(red: 0.86, green: 0.1, blue: 0.1, alpha: 1))
        #expect(placed.fill == RGBAColor(red: 0.86, green: 0.1, blue: 0.1, alpha: 0.2))
        #expect(placed.lineWidth == 3)
        #expect(placed.lineStyle == .dashed)

        // Through the project archive and back.
        let row = try ToolPresetArchive.record(from: preset, order: 0, projectId: "p")
        let back = try #require(ToolPresetArchive.summary(from: row))
        #expect(back.style == captured)

        // A preset written before round 2 — no style key — decodes with nil and places its
        // colour over the defaults, as it always did (old output: 1.5 pt, solid, no fill).
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any])
        object.removeValue(forKey: "style")
        let old = try JSONDecoder().decode(ToolPresetSummary.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.style == nil)
        let oldPlaced = AppMarkupToolPresenter.markupStyle(kind: .cloud, style: old.placementStyle)
        #expect(oldPlaced.lineWidth == 1.5 && oldPlaced.fill == nil && oldPlaced.lineStyle == .cloud)
    }
}
