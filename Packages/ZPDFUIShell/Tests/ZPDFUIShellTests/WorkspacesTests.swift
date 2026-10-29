import AppKit
import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZPDFUIShell

/// NL-UX-10, named Workspaces. Acceptance: saving stores pane visibility and sizes,
/// the Navigator page and the rest of the window arrangement; recall restores it; workspaces
/// persist across launches. (The ⌃1–⌃4 menu rows are asserted at the app tier.)
@MainActor
@Suite("Workspaces", .shellTierSerialised)
struct WorkspacesTests {

    private func makeWindow() -> (ProjectWindowLayoutController, NSWindow, ProjectShellEnvironment) {
        let environment = ProjectShellEnvironment.mock()
        let layout = ProjectWindowLayoutController(
            environment: environment,
            store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: "test.workspace.layout")
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 900),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = layout
        window.setFrame(NSRect(x: 0, y: 0, width: 1_400, height: 900), display: false)
        window.layoutIfNeeded()
        layout.view.layoutSubtreeIfNeeded()
        return (layout, window, environment)
    }

    @Test("Save, rearrange, recall: the window goes back to the saved arrangement")
    func saveAndRecall() throws {
        let (layout, window, environment) = makeWindow()
        defer { window.close() }
        let model = WorkspacesModel(store: ZenitWorkspaceStore(defaults: ZPDFInMemoryDefaults()))

        // "Review": Inspector up, Navigator on Search, Navigator hidden.
        layout.revealNavigatorSection(.search)
        layout.setNavigatorVisible(false)
        let reviewLayout = try #require(environment.currentWorkspaceLayout())
        let review = try #require(model.save(name: "Review", layout: reviewLayout))
        #expect(review.layout.isNavigatorCollapsed)
        #expect(review.layout.navigatorSection == .search)

        // Change everything.
        layout.setNavigatorVisible(true)
        layout.revealNavigatorSection(.pages)
        #expect(layout.isVisible(.navigator))

        #expect(environment.applyWorkspace(review))
        #expect(!layout.isVisible(.navigator), "the Navigator is hidden again")
        #expect(layout.panelState.navigatorSection == .search)
    }

    @Test("A workspace never changes the armed tool's memory")
    func toolMemoryIsNotPartOfAWorkspace() throws {
        let (layout, window, environment) = makeWindow()
        defer { window.close() }
        let model = WorkspacesModel(store: ZenitWorkspaceStore(defaults: ZPDFInMemoryDefaults()))
        environment.toolbar.activateMeasurement(.volume)
        let current = try #require(environment.currentWorkspaceLayout())
        let saved = try #require(model.save(name: "Takeoff", layout: current))
        #expect(saved.layout.lastUsedMeasurementKind == nil)
        environment.toolbar.activateMeasurement(.wallArea)
        layout.captureLayoutState()
        environment.applyWorkspace(saved)
        #expect(layout.layoutState.lastUsedMeasurementKind == .wallArea)
    }

    @Test("Workspaces persist; a name already used is replaced in place; blank names are refused")
    func persistence() {
        let defaults = ZPDFInMemoryDefaults()
        let model = WorkspacesModel(store: ZenitWorkspaceStore(defaults: defaults))
        let first = model.save(name: "Takeoff", layout: .default)
        _ = model.save(name: "Review", layout: .default)
        #expect(model.save(name: "   ", layout: .default) == nil)
        var wider = ProjectWindowLayoutState.default
        wider.inspectorWidth = 400
        let replaced = model.save(name: "takeoff", layout: wider)
        #expect(replaced?.id == first?.id)
        #expect(model.workspaces.count == 2)

        let reopened = WorkspacesModel(store: ZenitWorkspaceStore(defaults: defaults))
        #expect(reopened.workspaces.map(\.name) == ["takeoff", "Review"])
        #expect(reopened.workspace(inSlot: 0)?.layout.inspectorWidth == 400)
        #expect(reopened.workspace(inSlot: 5) == nil)
        #expect(reopened.suggestedName == "Workspace 3")
    }

    @Test("Rename refuses a clash; delete moves the later ones up a slot")
    func renameAndDelete() throws {
        let model = WorkspacesModel(store: ZenitWorkspaceStore(defaults: ZPDFInMemoryDefaults()))
        let a = try #require(model.save(name: "A", layout: .default))
        let b = try #require(model.save(name: "B", layout: .default))
        #expect(!model.rename(id: b.id, to: "a"))
        #expect(model.rename(id: b.id, to: "Compare"))
        model.delete(id: a.id)
        #expect(model.workspace(inSlot: 0)?.name == "Compare")
    }

    /// A workspace follows a canvas mode — entering switches, leaving restores.
    @Test("A workspace that follows a mode is applied on entry and the old arrangement restored on exit")
    func workspaceFollowsTheTask() throws {
        let (layout, window, environment) = makeWindow()
        defer { window.close() }
        let model = WorkspacesModel(store: ZenitWorkspaceStore(defaults: ZPDFInMemoryDefaults()))
        layout.setNavigatorVisible(false)
        let compareLayout = try #require(environment.currentWorkspaceLayout())
        let compare = try #require(model.save(name: "Compare", layout: compareLayout))
        model.setFollowsMode(.splitCanvas, for: compare.id)
        #expect(model.workspace(following: .splitCanvas)?.id == compare.id)
        layout.setNavigatorVisible(true)

        let follower = WorkspaceModeFollower(environment: environment, model: model)
        follower.modeDidChange(to: .splitCanvas)
        #expect(!layout.isVisible(.navigator), "entering Split Canvas switched to Compare")
        follower.modeDidChange(to: nil)
        #expect(layout.isVisible(.navigator), "leaving restored the arrangement from before")
        #expect(follower.returnLayout == nil)

        // A mode no workspace follows changes nothing.
        follower.modeDidChange(to: .revisionOverlay)
        #expect(layout.isVisible(.navigator))
        // One workspace per mode.
        let other = try #require(model.save(name: "Other", layout: compareLayout))
        model.setFollowsMode(.splitCanvas, for: other.id)
        #expect(model.workspace(following: .splitCanvas)?.id == other.id)
        #expect(model.workspaces.first { $0.id == compare.id }?.followsMode == nil)
    }
}
