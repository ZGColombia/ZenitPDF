import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// NL-UX-12: a 1.5 s toast over the canvas names what an undo or redo did, announced to
/// VoiceOver, never taking a click.
@MainActor
@Suite("Undo toast", .shellTierSerialised)
struct UndoToastTests {

    @Test("The toast reads Undid / Redid and the step's name; an unnamed step shows nothing")
    func text() {
        #expect(UndoToastModel.text(undid: "Change Colour (12 Markups)", isRedo: false) == "Undid Change Colour (12 Markups)")
        #expect(UndoToastModel.text(undid: "Delete Markup", isRedo: true) == "Redid Delete Markup")
        #expect(UndoToastModel.text(undid: "  ", isRedo: false) == nil)
    }

    @Test("A message is announced, shown, and gone after its duration; a newer one is not cut short")
    func lifetime() async throws {
        let model = UndoToastModel()
        var announced: [String] = []
        model.announce = { announced.append($0) }
        model.duration = .milliseconds(60)
        model.show("Undid Move Markup")
        #expect(model.message == "Undid Move Markup")
        #expect(announced == ["Undid Move Markup"])
        try await Task.sleep(for: .milliseconds(40))
        model.show("Redid Move Markup")
        try await Task.sleep(for: .milliseconds(35))
        #expect(model.message == "Redid Move Markup", "the first message's timer did not clear the second")
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.message == nil)
    }

    @Test("The toast floats over the canvas and never takes a click")
    func hostedOverTheCanvas() throws {
        let environment = ProjectShellEnvironment.mock()
        let layout = ProjectWindowLayoutController(
            environment: environment,
            store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: "test.toast.layout")
        )
        _ = layout.view
        let host = try #require(layout.undoToastHost)
        #expect(host.superview != nil)
        #expect(host.hitTest(NSPoint(x: 1, y: 1)) == nil)
    }
}
