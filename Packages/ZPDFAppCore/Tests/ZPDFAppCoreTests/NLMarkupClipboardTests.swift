import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// NL-MARKUP-05 / NL-UX-03: copy, paste, paste in place, paste to pages and
/// duplicate of markups, and the bulk-edit rules for markup styles (line ends, font, alignment,
/// fields a kind cannot hold). Expected values are derived by hand in each comment.
@MainActor
struct NLMarkupClipboardTests {

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func environment(pages count: Int) async throws -> (AppCoreEnvironment, TakeoffSession, [ZPDFContracts.PageDescriptor]) {
        let documentID = DocumentID(UUID())
        let pages = (0..<count).map { index in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: documentID,
                index: index,
                label: "A-\(index + 1)",
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1_000, height: 1_000))
            )
        }
        let session = try TakeoffSession(documentID: documentID, pages: pages, units: .metric)
        let environment = try await AppCoreEnvironment.make(session: session, documentID: documentID)
        return (environment, session, pages)
    }

    private static func cloud(on page: PageID, documentID: UUID) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID()),
            documentID: DocumentID(documentID),
            pageID: page,
            kind: .cloud,
            geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(
                points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 200, y: 100), PDFPoint(x: 200, y: 200), PDFPoint(x: 100, y: 200)],
                isClosed: true
            ))]),
            createdAt: now,
            modifiedAt: now
        )
    }

    private static func length(on page: PageID, documentID: UUID) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID()),
            documentID: DocumentID(documentID),
            pageID: page,
            kind: .measurement,
            tool: .polylength,
            subject: "Wall",
            geometry: MeasurementGeometry(pageID: page, points: [PDFPoint(x: 10, y: 10), PDFPoint(x: 110, y: 10)]),
            parameters: .default,
            createdAt: now,
            modifiedAt: now
        )
    }

    @Test("Copy a cloud, Paste: a new MarkupID offset by 10 pt, one undo step named Paste Markup")
    func pasteOffsetsWithNewIdentity() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 1)
        let original = Self.cloud(on: pages[0].id, documentID: environment.snapshot.documentID)
        _ = try await environment.commands.perform(.addMarkup(original))
        let payload = try #require(await environment.markupClipboardPayload(for: [original.id.rawValue]))
        // Round-trips through the pasteboard encoding.
        let decoded = try #require(payload.encoded().flatMap(MarkupClipboardPayload.decoded(from:)))
        #expect(decoded == payload)

        let receipt = await environment.pasteMarkups(decoded, onto: [pages[0].id.rawValue], placement: .offset(dx: 10, dy: -10))
        #expect(receipt.failureDescription == nil)
        #expect(receipt.actionName == "Paste Markup")
        let pastedID = try #require(receipt.pastedIDs.first)
        #expect(pastedID != original.id.rawValue)
        let pasted = try #require(await session.markup(MarkupID(pastedID)))
        // (100, 100) moved by (+10, −10) is (110, 90).
        #expect(pasted.geometry?.polygons.first?.outer.points.first == PDFPoint(x: 110, y: 90))
        #expect(await session.orderedMarkups.count == 2)
        #expect(environment.canvas.selectedMarkupIDs == [pastedID], "the paste is selected")

        // One undo takes the whole paste back.
        await environment.commands.undo()
        #expect(await session.orderedMarkups.count == 1)
    }

    @Test("Paste in Place on another sheet keeps page coordinates; Paste to Pages is one step over every page")
    func pasteInPlaceAndToPages() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 4)
        let original = Self.cloud(on: pages[0].id, documentID: environment.snapshot.documentID)
        _ = try await environment.commands.perform(.addMarkup(original))
        let payload = try #require(await environment.markupClipboardPayload(for: [original.id.rawValue]))

        let inPlace = await environment.pasteMarkups(payload, onto: [pages[1].id.rawValue], placement: .inPlace)
        let movedID = try #require(inPlace.pastedIDs.first)
        let moved = try #require(await session.markup(MarkupID(movedID)))
        #expect(moved.pageID == pages[1].id)
        #expect(moved.geometry?.polygons.first?.outer.points == original.geometry?.polygons.first?.outer.points)

        // Three pages, one markup each: three new markups, one undo step.
        let before = await session.orderedMarkups.count
        let toPages = await environment.pasteMarkups(
            payload, onto: pages[1...3].map(\.id.rawValue), placement: .inPlace, actionName: "Paste to 3 Pages"
        )
        #expect(toPages.pastedIDs.count == 3)
        #expect(Set(toPages.pastedIDs).count == 3)
        #expect(await session.orderedMarkups.count == before + 3)
        await environment.commands.undo()
        #expect(await session.orderedMarkups.count == before)
    }

    @Test("A length pasted onto a sheet with another scale is recomputed from that scale and counted")
    func pasteRecalculatesUnderTheTargetScale() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 2)
        // Sheet 1: 100 pt = 10 m. Sheet 2: 100 pt = 1 m.
        try await environment.commands.calibrate(
            page: pages[0].id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 10, knownLengthUnit: .metre
        )
        try await environment.commands.calibrate(
            page: pages[1].id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        let wall = Self.length(on: pages[0].id, documentID: environment.snapshot.documentID)
        _ = try await environment.commands.perform(.addMarkup(wall))
        let measured = try #require(await session.markup(wall.id))
        // 100 pt at 10 m per 100 pt is 10 m.
        #expect(measured.measurement?.values[.planLength]?.value == 10)

        let payload = try #require(await environment.markupClipboardPayload(for: [wall.id.rawValue]))
        let receipt = await environment.pasteMarkups(payload, onto: [pages[1].id.rawValue], placement: .inPlace)
        #expect(receipt.recalculatedCount == 1)
        let pastedFirst = try #require(receipt.pastedIDs.first)
        let pasted = try #require(await session.markup(MarkupID(pastedFirst)))
        // The same 100 pt at 1 m per 100 pt is 1 m — not the copied 10 m.
        #expect(pasted.measurement?.values[.planLength]?.value == 1)
        #expect(pasted.scaleID != measured.scaleID)

        // Same page: nothing recalculated.
        let same = await environment.pasteMarkups(payload, onto: [pages[0].id.rawValue], placement: .offset(dx: 10, dy: -10))
        #expect(same.recalculatedCount == 0)
    }

    @Test("Cut removes as one step; a cutout travels with its parent under new identities")
    func cutAndCutoutLinks() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 1)
        let cloud = Self.cloud(on: pages[0].id, documentID: environment.snapshot.documentID)
        _ = try await environment.commands.perform(.addMarkup(cloud))
        let (payload, failure) = await environment.cutMarkups([cloud.id.rawValue])
        #expect(failure == nil)
        #expect(payload?.records.count == 1)
        #expect(await session.orderedMarkups.isEmpty)
        await environment.commands.undo()
        #expect(await session.orderedMarkups.count == 1)

        // Pure: parent and child are re-linked under fresh IDs.
        var parent = Self.cloud(on: pages[0].id, documentID: environment.snapshot.documentID)
        var child = Self.cloud(on: pages[0].id, documentID: environment.snapshot.documentID)
        child.parentMarkupID = parent.id
        parent.cutoutMarkupIDs = [child.id]
        let records = MarkupClipboard.copiedRecords(selected: [parent.id], from: [parent.id: parent, child.id: child])
        #expect(records.map(\.id) == [child.id, parent.id], "the cutout comes first, and with its parent")
        let prepared = MarkupClipboard.prepared(
            MarkupClipboardPayload(sourceDocumentID: UUID(), sourcePageID: pages[0].id.rawValue, records: records),
            targetPageID: pages[0].id.rawValue, targetDocumentID: UUID(), dx: 0, dy: 0,
            now: Self.now, author: "A", newID: { UUID() }
        )
        let newChild = prepared[0], newParent = prepared[1]
        #expect(newChild.id != child.id && newParent.id != parent.id)
        #expect(newChild.parentMarkupID == newParent.id)
        #expect(newParent.cutoutMarkupIDs == [newChild.id])
    }

    @Test("Line ends, font and alignment go through one bulk edit; fields a kind cannot hold are skipped")
    func styleFieldsFitTheKind() async throws {
        let (environment, session, pages) = try await Self.environment(pages: 1)
        let documentID = environment.snapshot.documentID
        var line = Self.cloud(on: pages[0].id, documentID: documentID)
        line.kind = .line
        line.geometry = MeasurementGeometry(pageID: pages[0].id, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 50, y: 0)])
        let rectangle = { () -> MarkupRecord in var r = Self.cloud(on: pages[0].id, documentID: documentID); r.kind = .rectangle; return r }()
        _ = try await environment.commands.perform(.addMarkup(line))
        _ = try await environment.commands.perform(.addMarkup(rectangle))

        let receipt = await environment.applyBulkEdit(LedgerBulkEditRequest(
            markupIDs: [line.id.rawValue, rectangle.id.rawValue],
            style: MarkupStyleEdit(
                lineStyle: .cloud,
                fill: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 0.2),
                startCap: .circle, endCap: .closedArrow, fontName: "Georgia"
            )
        ))
        #expect(receipt.failureDescription == nil)
        let storedLine = try #require(await session.markup(line.id))
        let storedRectangle = try #require(await session.markup(rectangle.id))
        #expect(storedLine.style.startCap == .circle && storedLine.style.endCap == .closedArrow)
        #expect(storedLine.style.lineStyle == .solid, "Cloud draws nothing on a line, so it is not written")
        #expect(storedLine.style.fill == nil, "a line has no interior")
        #expect(storedLine.style.fontName == "Helvetica", "a line draws no words")
        #expect(storedRectangle.style.lineStyle == .cloud)
        #expect(storedRectangle.style.fill != nil)
        #expect(storedRectangle.style.endCap == .none, "a rectangle has no ends")

        // Undo names.
        #expect(AppCoreEnvironment.undoActionName(
            for: LedgerBulkEditRequest(markupIDs: [UUID()], style: MarkupStyleEdit(endCap: .circle)), markupCount: 1
        ) == "Change Line Ends")
        #expect(AppCoreEnvironment.undoActionName(
            for: LedgerBulkEditRequest(markupIDs: [UUID()], style: MarkupStyleEdit(color: ColorRGBA(red: 1, green: 0, blue: 0)), actionName: "Paste Style"),
            markupCount: 1
        ) == "Paste Style")
    }

    @Test("A tool style carries line style, opacity, ends and alignment into the markup it draws")
    func toolStyleReachesTheRecord() {
        var tool = ToolStyleSelection.zenitInk
        tool.lineStyle = .dashed
        tool.opacity = 0.5
        tool.endCap = .circle
        tool.textAlignment = .center
        let line = AppMarkupToolPresenter.markupStyle(kind: .line, style: tool)
        #expect(line.lineStyle == .dashed && line.opacity == 0.5 && line.endCap == .circle)
        #expect(line.fill == nil)
        let text = AppMarkupToolPresenter.markupStyle(kind: .text, style: tool)
        #expect(text.textAlignment == .center && text.endCap == .none)
        // Cloud chosen as a line style for a tool that cannot draw it keeps the kind's default.
        tool.lineStyle = .cloud
        #expect(AppMarkupToolPresenter.markupStyle(kind: .arrow, style: tool).lineStyle == .solid)
        #expect(AppMarkupToolPresenter.markupStyle(kind: .rectangle, style: tool).lineStyle == .cloud)
        // An old tool style (no new keys) decodes with today's defaults.
        let old = #"{"stroke":{"red":1,"green":0,"blue":0,"alpha":1},"lineWidth":3,"fontName":"Helvetica","fontSize":11}"#
        let decoded = try? JSONDecoder().decode(ToolStyleSelection.self, from: Data(old.utf8))
        #expect(decoded?.lineWidth == 3 && decoded?.opacity == 1 && decoded?.lineStyle == nil && decoded?.endCap == nil)
    }
}
