import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// NL-AUTO-08 through the window: nine rooms proposed with names read from their labels, the
/// door between two of them closed not merged; accepting seven lands seven named areas in one undo.
@MainActor
@Suite(.appTierSerialised)
struct RoomDetectionWiringTests {

    /// Walls as 6 pt filled rectangles at an offset of (100, 100); rooms 100 × 80 pt; a 30 pt door
    /// between the bottom-left room and its neighbour; a label inside every room.
    static func plan() -> String {
        var parts = ["0 g"]
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { parts.append("\(100 + x) \(100 + y) \(w) \(h) re f") }
        for y in [0.0, 86, 172, 258] { rect(0, y, 324, 6) }
        for x in [0.0, 212, 318] { rect(x, 0, 6, 264) }
        rect(106, 0, 6, 30)
        rect(106, 60, 6, 204)
        var number = 1
        for y in [218.0, 132, 46] {
            for x in [30.0, 136, 242] {
                parts.append("BT /F1 8 Tf \(100 + x) \(100 + y) Td (Rum \(number)) Tj ET")
                number += 1
            }
        }
        return parts.joined(separator: "\n")
    }

    @Test("Nine rooms proposed and named; seven accepted land as seven named areas, one undo")
    func detectsAndLands() async throws {
        let document = try AppTestSupport.makeDocument(opening: try AutomationFixtures.writeSinglePage(named: "Plan.pdf", content: Self.plan()))
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let core = try #require(document.core)
        let controller = ProjectWindowController(document: document)
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        // 50 pt = 1 m: a room is 2 m × 1.6 m = 3.2 m².
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 50, y: 0),
            knownLength: 1, knownLengthUnit: .metre
        )
        let previous = ProjectWindowController.roomReviewPresenter
        defer { ProjectWindowController.roomReviewPresenter = previous }
        var captured: RoomDetectionReviewModel?
        ProjectWindowController.roomReviewPresenter = { model, _ in
            captured = model
            return {}
        }
        controller.detectRooms(for: document)
        #expect(await AppTestSupport.wait(upTo: 20) { captured != nil }, "\(core.status.snapshot.activeToolNote ?? "")")
        let model = try #require(captured)
        #expect(model.rows.count == 9, "\(model.rows.map(\.name))")
        #expect(Set(model.rows.map(\.name)) == Set((1...9).map { "Rum \($0)" }))
        #expect(model.rows.allSatisfy { $0.areaText == "3.20 m²" }, "\(model.rows.map(\.areaText))")
        #expect(model.rows.filter { $0.notes.contains("closes 1 opening(s)") }.count == 2)

        for row in model.rows where row.name == "Rum 4" || row.name == "Rum 5" { model.setIncluded(false, id: row.id) }
        model.accept()
        var areas: [MarkupRecord] = []
        for _ in 0..<150 {
            areas = await core.session.orderedMarkups.filter { $0.tool == .area }
            if areas.count == 7 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(areas.count == 7)
        #expect(!areas.contains { $0.subject == "Rum 4" || $0.subject == "Rum 5" })
        let values = areas.compactMap { $0.measurement?[.planArea].map { NSDecimalNumber(decimal: $0.value).doubleValue } }
        #expect(values.count == 7 && values.allSatisfy { abs($0 - 3.2) < 1e-6 }, "\(values)")

        document.undoManager?.undo()
        var after = areas
        for _ in 0..<150 {
            after = await core.session.orderedMarkups.filter { $0.tool == .area }
            if after.isEmpty { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(after.isEmpty)
    }
}
