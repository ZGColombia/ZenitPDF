import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// NL-DOCS-14: the window's drawings, in order, with the front one and each viewport, recorded
/// and reopened; a Split Canvas pane on a window of its own and back. Headless: the opener and
/// the pane window's presenter are injected; nothing is ordered front.
@MainActor
@Suite("Documents — session and pane windows", .appTierSerialised)
struct NextLevelDocumentsSessionTests {

    private final class Store: ZPDFDefaultsStoring {
        var values: [String: Data] = [:]
        func persistedData(forKey key: String) -> Data? { values[key] }
        func setPersistedData(_ data: Data?, forKey key: String) { values[key] = data }
    }

    @Test("A session round-trips; restore reopens the drawings in order and skips the missing one")
    func restoreOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nl-docs-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = (1...30).map { String(format: "Sheet %02d.pdf", $0) }
        for name in names { try Data("%PDF-1.4".utf8).write(to: directory.appendingPathComponent(name)) }
        var paths = names.map { directory.appendingPathComponent($0).path }
        paths.insert(directory.appendingPathComponent("Gone.pdf").path, at: 5)
        let store = Store()
        let session = WindowSession(
            paths: paths, activeIndex: 12,
            viewports: [paths[12]: WindowSession.Viewport(position: 3, zoom: 1.5)]
        )
        WindowSessionStore.save(session, defaults: store)
        #expect(WindowSessionStore.load(defaults: store) == session)

        var opened: [URL] = []
        let previous = ProjectWindowController.dropOpener
        ProjectWindowController.dropOpener = { opened.append(contentsOf: $0) }
        defer {
            ProjectWindowController.dropOpener = previous
            ProjectWindowController.pendingSessionViewports = [:]
            ProjectWindowController.pendingActivePath = nil
        }
        let restored = ProjectWindowController.restoreLastSession(defaults: store)
        #expect(restored.count == 30, "the missing file is skipped")
        #expect(opened.map(\.lastPathComponent) == names, "all thirty, in their tab order")
        #expect(ProjectWindowController.pendingActivePath?.hasSuffix("Sheet 12.pdf") == true, "the front tab comes forward")
        #expect(ProjectWindowController.pendingSessionViewports.values.first == WindowSession.Viewport(position: 3, zoom: 1.5))
    }

    @Test("Launch restore honours 'Close windows when quitting an application' through an injected preference")
    func restoreHonoursTheSystemSetting() throws {
        // r2-layers follow-up (2026-09-26). Old: every launch reopened the last
        // window's drawings, whatever the macOS setting said.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nl-docs-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Plan.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        let store = Store()
        WindowSessionStore.save(WindowSession(paths: [file.path], activeIndex: 0), defaults: store)

        var opened: [URL] = []
        let previous = ProjectWindowController.dropOpener
        ProjectWindowController.dropOpener = { opened.append(contentsOf: $0) }
        defer {
            ProjectWindowController.dropOpener = previous
            ProjectWindowController.pendingSessionViewports = [:]
            ProjectWindowController.pendingActivePath = nil
        }
        // The macOS default — the key absent — closes windows: nothing reopens.
        #expect(ProjectWindowController.restoreLastSessionIfAllowed(defaults: store, preference: { _ in nil }).isEmpty)
        // The box ticked: NSQuitAlwaysKeepsWindows = false.
        #expect(ProjectWindowController.restoreLastSessionIfAllowed(
            defaults: store, preference: { $0 == "NSQuitAlwaysKeepsWindows" ? false : nil }).isEmpty)
        #expect(opened.isEmpty)
        // The application opted out of persistence wins even over a kept-windows setting.
        #expect(ProjectWindowController.restoreLastSessionIfAllowed(defaults: store, preference: { key in
            key == "ApplePersistence" ? false : (key == "NSQuitAlwaysKeepsWindows" ? true : nil)
        }).isEmpty)
        #expect(opened.isEmpty)
        // The box unticked: NSQuitAlwaysKeepsWindows = true — the window comes back.
        let restored = ProjectWindowController.restoreLastSessionIfAllowed(
            defaults: store, preference: { $0 == "NSQuitAlwaysKeepsWindows" ? true : nil })
        #expect(restored.map(\.lastPathComponent) == ["Plan.pdf"])
        #expect(opened.map(\.lastPathComponent) == ["Plan.pdf"])
    }

    @Test("The open window records its drawings and each viewport")
    func recordsCurrentWindow() async throws {
        let harness = try await Fix2Harness.make("Session.pdf", pageCount: 3, calibrate: false)
        defer { harness.tearDown() }
        // The harness reads the file without an NSDocument URL; a real open has one.
        harness.document.fileURL = harness.directory.appendingPathComponent("Session.pdf")
        harness.shell.goToPage(id: harness.core.document.pages[2].id)
        harness.core.canvas.setZoom(2)
        let session = try #require(harness.controller.currentSession())
        #expect(session.paths.count == 1)
        #expect(session.viewports.values.first == WindowSession.Viewport(position: 2, zoom: 2))
        let store = Store()
        harness.controller.recordSession(defaults: store)
        #expect(WindowSessionStore.load(defaults: store)?.paths == session.paths)
    }

    @Test("A pane moves to its own window, the split shows it is there, closing brings it back")
    func paneWindow() async throws {
        let harness = try await Fix2Harness.make("Pane.pdf", pageCount: 2, calibrate: false)
        defer { harness.tearDown() }
        var presented: [NSWindow] = []
        let previous = ProjectWindowController.paneWindowPresenter
        ProjectWindowController.paneWindowPresenter = { presented.append($0) }
        defer { ProjectWindowController.paneWindowPresenter = previous }
        let split = harness.shell.splitCanvas
        #expect(split.onDetachPane != nil, "the window wires Move to Window")
        split.setLayout(.twoColumns)
        split.setContent(documentID: harness.document.documentIdentity, documentTitle: "Pane",
                         page: harness.core.document.pages[0], in: .first)
        let window = try #require(harness.controller.detachSplitPane(.first, shell: harness.shell))
        #expect(presented == [window])
        #expect(split.detachedPaneIDs == [.first])
        #expect(!window.isVisible, "nothing on screen")
        window.close()
        #expect(split.detachedPaneIDs.isEmpty, "closing the window brings the pane back")
        #expect(harness.controller.paneWindow(.first) == nil)
    }
}
