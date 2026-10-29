import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// NL-DOCS-07 (arranging the set from the Navigator) and NL-DOCS-03 (the honest drop).
@MainActor
@Suite("Next level documents — arranging the set", .shellTierSerialised)
struct NextLevelDocumentsArrangeTests {

    private func pages(_ count: Int) -> [PageDescriptor] {
        let box = PDFRectValue(x: 0, y: 0, width: 100, height: 100)
        return (0..<count).map {
            PageDescriptor(id: UUID(), index: $0, label: "\($0 + 1)", mediaBox: box, cropBox: box, rotation: .degrees0)
        }
    }

    /// W-050: the same six cases on the one arrange entry point, `target(moving:in:)`, over a
    /// contiguous block (the removed `targetPosition(first:count:total:)` took its first place,
    /// size and set size).
    @Test("Move targets: top, up, down, bottom — and nothing for a move that changes nothing")
    func targets() {
        let ids = (0..<5).map { _ in UUID() }
        #expect(NavigatorArrangeAction.moveToTop.target(moving: [ids[3]], in: ids) == 0)
        #expect(NavigatorArrangeAction.moveUp.target(moving: [ids[3]], in: ids) == 2)
        #expect(NavigatorArrangeAction.moveDown.target(moving: [ids[3]], in: ids) == 4)
        #expect(NavigatorArrangeAction.moveToBottom.target(moving: [ids[1], ids[2]], in: ids) == 3)
        #expect(NavigatorArrangeAction.moveUp.target(moving: [ids[0]], in: ids) == nil)
        #expect(NavigatorArrangeAction.moveToBottom.target(moving: [ids[3], ids[4]], in: ids) == nil)
    }

    @Test("A move acts on the selection when the card is part of it, in set order")
    func blockAndReorder() {
        let set = pages(5)
        let ids = set.map(\.id)
        #expect(NavigatorArrangeAction.block(for: ids[3], selection: [ids[3], ids[1]], pages: set) == [ids[1], ids[3]])
        #expect(NavigatorArrangeAction.block(for: ids[2], selection: [ids[3], ids[1]], pages: set) == [ids[2]])
        // [0 1 2 3 4], move {1, 3} to the top → [1 3 0 2 4].
        #expect(NavigatorArrangeAction.reordered(ids, moving: [ids[1], ids[3]], to: 0)
            == [ids[1], ids[3], ids[0], ids[2], ids[4]])
    }

    @Test("A card dropped on another lands before it; the payload is private to page cards")
    func dragTarget() {
        let set = pages(5)
        let ids = set.map(\.id)
        // Card 4 dropped on card 1 → first position 1.
        #expect(NavigatorPageDrag.target(dropOn: 1, block: [ids[4]], pages: set) == 1)
        // Card 0 dropped on card 3 → it lands before 3, which is position 2 without card 0.
        #expect(NavigatorPageDrag.target(dropOn: 3, block: [ids[0]], pages: set) == 2)
        #expect(NavigatorPageDrag.pageID(in: NavigatorPageDrag.payload(for: ids[2])) == ids[2])
        #expect(NavigatorPageDrag.pageID(in: "hello") == nil)
    }

    @Test("The card's first line is its place in the set, not its PDF index")
    func cardShowsPosition() {
        let page = pages(8)[7]
        #expect(NavigatorPageCard.title(for: page) == "8")
        #expect(NavigatorPageCard.title(for: page, position: 0) == "1", "moved to the top of the set")
        #expect(NavigatorPageCard.accessibilityLabel(for: page, pageCount: 8, position: 0).hasPrefix("Page 1 of 8"))
    }

    /// Before: a drop on a card drew an insertion line and promised a page insertion that
    /// never happened.
    @Test("The drop says what it does: a project adds the drawing, a Quick PDF opens it separately")
    func honestDropHint() {
        #expect(NavigatorDropPolicy.dropHint(addsToProject: false) == "Opens as a separate drawing")
        #expect(NavigatorDropPolicy.dropHint(addsToProject: true) == "Adds the drawing to this project")
        #expect(!ProjectShellEnvironment.mock().navigatorDropAddsToProject, "off until the app says it is a project")
    }

    @Test("The sheet-name editor starts from the sheet's own name, else from a named label; empty clears")
    func sheetNameEditorSeed() {
        let box = PDFRectValue(x: 0, y: 0, width: 100, height: 100)
        let plain = PageDescriptor(id: UUID(), index: 0, label: "A-101", mediaBox: box, cropBox: box, rotation: .degrees0)
        #expect(NavigatorSheetNameEditor.seed(for: plain) == ("A-101", ""))
        let numbered = PageDescriptor(id: UUID(), index: 0, label: "3", mediaBox: box, cropBox: box, rotation: .degrees0)
        #expect(NavigatorSheetNameEditor.seed(for: numbered) == ("", ""))
        let named = plain.withSheetIdentity(number: "A-101", title: "FLOOR PLAN")
        #expect(named.sheetTitle == "A-101 · FLOOR PLAN")
        #expect(NavigatorSheetNameEditor.seed(for: named) == ("A-101", "FLOOR PLAN"))
        #expect(NavigatorSheetNameEditor.committed(number: "  ", title: " Roof ") == (nil, "Roof"))
        // A later outline read does not replace a sheet's own name.
        #expect(named.withSheetTitle("Something else").sheetTitle == "A-101 · FLOOR PLAN")
        #expect(NavigatorPageCard.subtitle(for: named, usesMetric: true) == "A-101 · FLOOR PLAN")
    }

    // MARK: NL-DOCS-06 — sheet index

    @Test("The index groups sheets by discipline in set order and shows sheet names")
    func indexGroups() {
        let box = PDFRectValue(x: 0, y: 0, width: 100, height: 100)
        let pages = [
            PageDescriptor(id: UUID(), index: 0, label: "A-101", mediaBox: box, cropBox: box, rotation: .degrees0)
                .withSheetIdentity(number: "A-101", title: "SITE PLAN"),
            PageDescriptor(id: UUID(), index: 1, label: "S-201", mediaBox: box, cropBox: box, rotation: .degrees0),
            PageDescriptor(id: UUID(), index: 2, label: "A-102", mediaBox: box, cropBox: box, rotation: .degrees0),
            PageDescriptor(id: UUID(), index: 3, label: "4", mediaBox: box, cropBox: box, rotation: .degrees0)
        ]
        let groups = NavigatorSheetIndex.groups(pages: pages)
        #expect(groups.map(\.id) == ["A", "S", ""])
        #expect(groups[0].rows.map(\.number) == ["A-101", "A-102"])
        #expect(groups[0].rows[0].title == "SITE PLAN")
        #expect(groups[2].rows.map(\.number) == ["4"], "an unnamed page is listed by its position")
        #expect(NavigatorSheetIndex.groups(pages: pages, query: "site").flatMap(\.rows).map(\.number) == ["A-101"])
    }

    @Test("Typing A5 selects A-501 in a 400-sheet set well inside 100 ms")
    func typeToSelect() {
        let box = PDFRectValue(x: 0, y: 0, width: 100, height: 100)
        var pages: [PageDescriptor] = []
        for (d, letter) in ["A", "S", "M", "E"].enumerated() {
            for n in 0..<100 {
                pages.append(PageDescriptor(
                    id: UUID(), index: pages.count, label: "\(letter)-\((d == 0 ? 500 : 100 * (d + 1)) + n + 1)",
                    mediaBox: box, cropBox: box, rotation: .degrees0
                ))
            }
        }
        let target = pages.first { $0.label == "A-501" }
        #expect(target != nil)
        let started = Date()
        let hit = NavigatorSheetIndex.firstMatch(pages: pages, query: "A5")
        let elapsed = Date().timeIntervalSince(started)
        // The A sheets run A-501…A-600; S-201…, M-301…, E-401… never start "A5".
        #expect(hit == target?.id)
        #expect(elapsed < 0.1, "took \(elapsed) s")
        #expect(NavigatorSheetIndex.firstMatch(pages: pages, query: "  ") == nil)
    }

    /// LT3-04: "A1 · 841 × 594 mm" wrapped onto two lines inside the card (lineLimit 2).
    @Test("The sheet-size line stays on one line; a sheet name may take two")
    func sizeLineIsOneLine() {
        let box = PDFRectValue(x: 0, y: 0, width: 2384, height: 1684)
        let unnamed = PageDescriptor(id: UUID(), index: 0, label: "1", mediaBox: box, cropBox: box, rotation: .degrees0)
        #expect(NavigatorPageCard.subtitleLineLimit(for: unnamed) == 1)
        #expect(NavigatorPageCard.subtitleLineLimit(for: unnamed.withSheetIdentity(number: "A-101", title: "FLOOR PLAN")) == 2)
    }
}
