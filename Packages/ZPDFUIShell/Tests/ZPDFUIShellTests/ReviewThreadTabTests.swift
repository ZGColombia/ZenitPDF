import AppKit
import SwiftUI
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// NL-COLLAB-02 and NL-COLLAB-18 in the shell: the Comments tab's thread and reply field, and
/// the Markup tab's Text row for a text box.
@MainActor
@Suite(.shellTierSerialised)
struct ReviewThreadTabTests {

    private static func markup(kind: MarkupKind = .cloud, comment: String = "", drawnText: String? = nil) -> MarkupSummary {
        var summary = MarkupSummary(
            id: UUID(), kind: kind, subject: "Review", label: "", comment: comment,
            pageLabel: "A-101", pageID: UUID(), pageIndex: 0, author: "Ada",
            colorRGBA: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
            created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
            boundsInPageSpace: PDFRectValue(x: 0, y: 0, width: 10, height: 10)
        )
        summary.drawnText = drawnText
        return summary
    }

    @Test("Status lines read as words with who, from and to — never colour alone")
    func statusLineWords() {
        #expect(ReviewThreadText.statusLine(author: "Bo", from: .open, to: .accepted, reverted: false)
            == "Bo set status Open → Accepted")
        #expect(ReviewThreadText.statusLine(author: "Bo", from: .accepted, to: .open, reverted: true)
            == "Bo reverted a status change: Accepted → Open")
        #expect(ReviewThreadText.statusLine(author: "", from: nil, to: .cancelled, reverted: false)
            == "Author not recorded set status No Status → Cancelled")
    }

    @Test("A reply through the presenter lands in the thread; withdrawing keeps it, marked")
    func replyAndWithdraw() throws {
        let presenter = MockReviewThreadPresenter(author: "Bo")
        let target = Self.markup(comment: "Check the slab edge")
        let id = try #require(presenter.addReply("  Confirmed on site.  ", to: target.id))
        #expect(presenter.addReply("   ", to: target.id) == nil, "a blank reply is not sent")
        var thread = presenter.thread(for: target)
        #expect(thread.items.map(\.text) == ["Confirmed on site."])
        #expect(thread.replyCount == 1)
        presenter.retractReply(id)
        thread = presenter.thread(for: target)
        #expect(thread.items.first?.isRetracted == true)
        #expect(thread.replyCount == 0)
    }

    @Test("The Comments tab renders the thread and reply field off screen, light and dark")
    func rendersThread() async throws {
        let environment = ProjectShellEnvironment.mock()
        let presenter = MockReviewThreadPresenter(author: "Bo")
        environment.review = presenter
        let target = try #require(environment.canvas.visibleMarkups.first)
        presenter.seededItems[target.id] = [
            ReviewThreadItem(id: "n", kind: .note, author: "Ada", date: Date(timeIntervalSince1970: 100), text: "Check"),
            ReviewThreadItem(id: "s", kind: .statusChange(from: .open, to: .accepted, reverted: false),
                             author: "Bo", date: Date(timeIntervalSince1970: 200), text: "")
        ]
        presenter.addReply("Done", to: target.id)
        environment.canvas.select(markupIDs: [target.id], additive: false)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = NSHostingView(rootView: InspectorPanel(
                environment: environment, panelState: ShellPanelState(), initialTab: .comments
            ))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 780)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            #expect(rep.pixelsWide > 0)
        }
    }

    @Test("A text box shows a Text row apart from Notes; a cloud does not; editing sends one edit")
    func drawnTextRow() {
        let box = Self.markup(kind: .text, comment: "Reviewer note", drawnText: "EXISTING WALL")
        let cloud = Self.markup(kind: .cloud, comment: "Check")
        #expect(InspectorPanel.drawnTextState(InspectorSelectionSummary(markups: [box])) == .some("EXISTING WALL"))
        #expect(InspectorPanel.drawnTextState(InspectorSelectionSummary(markups: [cloud])) == nil)
        #expect(InspectorPanel.drawnTextState(InspectorSelectionSummary(markups: [box, cloud])) == nil)
        let other = Self.markup(kind: .callout, drawnText: "NEW")
        #expect(InspectorPanel.drawnTextState(InspectorSelectionSummary(markups: [box, other])) == .some(nil), "mixed")

        let environment = ProjectShellEnvironment.mock()
        var sent: [(Set<UUID>, String)] = []
        environment.inspectorEditing.onEditText = { ids, text in sent.append((ids, text)) }
        let panel = InspectorPanel(environment: environment, panelState: ShellPanelState())
        panel.applyDrawnText("EXISTING WALL", to: InspectorSelectionSummary(markups: [box]))
        #expect(sent.isEmpty, "unchanged text writes nothing")
        panel.applyDrawnText("DEMOLISH", to: InspectorSelectionSummary(markups: [box]))
        #expect(sent.count == 1)
        #expect(sent.first?.0 == [box.id])
        #expect(sent.first?.1 == "DEMOLISH")
    }
}
