import AppKit
import Foundation
import ZPDFUIPresentation

/// What a project window held when it was last closed (NL-DOCS-14): its drawings in tab order,
/// the front one, and where each was looking. Reopened at the next launch, so a morning starts
/// where the evening stopped — thirty drawings in order, each at its sheet and zoom.
public struct WindowSession: Codable, Equatable, Sendable {
    public struct Viewport: Codable, Equatable, Sendable {
        /// The sheet's place in its drawing's set.
        public var position: Int
        public var zoom: Double
    }
    /// A second window on one of the session's drawings (C-07, NL-UX-20): which drawing, and
    /// where that window was looking.
    public struct SecondWindow: Codable, Equatable, Sendable {
        public var path: String
        public var viewport: Viewport
    }
    public var paths: [String]
    public var activeIndex: Int
    public var viewports: [String: Viewport]
    /// The drawings' second windows, in the order they were opened. `nil` in a session written
    /// before second windows were recorded, which still reads.
    public var secondWindows: [SecondWindow]?

    public init(paths: [String], activeIndex: Int, viewports: [String: Viewport] = [:], secondWindows: [SecondWindow]? = nil) {
        self.paths = paths
        self.activeIndex = activeIndex
        self.viewports = viewports
        self.secondWindows = secondWindows
    }
}

/// Where the session lives: the injected layout store, never `UserDefaults.standard` directly.
public enum WindowSessionStore {
    static let key = "zenit.windowSession"

    public static func save(_ session: WindowSession?, defaults: any ZPDFDefaultsStoring) {
        defaults.setPersistedData(session.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }

    public static func load(defaults: any ZPDFDefaultsStoring) -> WindowSession? {
        guard let data = defaults.persistedData(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WindowSession.self, from: data)
    }
}

extension ProjectWindowController {

    /// Windows whose close review is running: their session is the one recorded when the
    /// close began, not the shrinking list the review leaves behind.
    private static var frozenSessions: Set<ObjectIdentifier> = []

    /// Viewports to apply when a restored drawing's canvas is installed, by path.
    static var pendingSessionViewports: [String: WindowSession.Viewport] = [:]
    /// Second windows to open, each at its viewport, once a restored drawing is on screen, by path
    /// (C-07).
    static var pendingSecondWindows: [String: [WindowSession.Viewport]] = [:]
    /// The drawing to bring to the front once it has opened.
    static var pendingActivePath: String?
    /// The sheet to turn to once a drawing opened from a folder search hit is on screen, by path
    /// (NL-DOCS-15).
    static var pendingPagesOnOpen: [String: Int] = [:]

    /// The window's session now: file-backed drawings only, in tab order.
    func currentSession() -> WindowSession? {
        let saved = documents.filter { $0.fileURL != nil }
        guard !saved.isEmpty else { return nil }
        var viewports: [String: WindowSession.Viewport] = [:]
        for document in saved {
            guard let path = document.fileURL?.path, let core = windowCore(for: document) else { continue }
            let position = core.document.pages.firstIndex { $0.id == core.document.currentPageID } ?? 0
            viewports[path] = WindowSession.Viewport(position: position, zoom: core.canvas.viewport.zoom)
        }
        let active = activeDocument.flatMap { front in saved.firstIndex { $0 === front } } ?? 0
        // Each drawing's second windows, where each was looking (C-07): reopened with the drawing.
        var seconds: [WindowSession.SecondWindow] = []
        for document in saved {
            guard let path = document.fileURL?.path else { continue }
            for view in document.windowViews where view.controller != nil {
                let position = view.core.document.pages.firstIndex { $0.id == view.core.document.currentPageID } ?? 0
                seconds.append(WindowSession.SecondWindow(
                    path: path, viewport: WindowSession.Viewport(position: position, zoom: view.core.canvas.viewport.zoom)
                ))
            }
        }
        return WindowSession(
            paths: saved.compactMap { $0.fileURL?.path }, activeIndex: active, viewports: viewports,
            secondWindows: seconds.isEmpty ? nil : seconds
        )
    }

    /// Records the session unless a whole-window close is under way.
    ///
    /// Runs on every tab-state refresh, and that is every edit, undo, redo and autosave, so it
    /// does nothing when the session is the one already stored: the dirty dot moving is not a
    /// change to which drawings are open or where each is looking. It used to take one
    /// security-scoped bookmark and rewrite the whole bookmark store per open drawing on every
    /// one of those (R-021).
    func recordSession(defaults: any ZPDFDefaultsStoring = ZenitProcessDefaults.layout) {
        // The session is the first window's: a second window on one of its drawings (NL-UX-20)
        // would record that drawing alone over it. The first window records its drawings'
        // second windows (C-07).
        guard !isSecondWindow else { return }
        guard !isSessionFrozen, let session = currentSession() else { return }
        guard WindowSessionStore.load(defaults: defaults) != session else { return }
        DroppedFileBookmarks.rememberMissing(session.paths.map { URL(fileURLWithPath: $0) }, defaults: ZenitProcessDefaults.bookmarks)
        WindowSessionStore.save(session, defaults: defaults)
    }

    /// Whether a whole-window close or a quit is holding this window's recorded session.
    var isSessionFrozen: Bool { Self.frozenSessions.contains(ObjectIdentifier(self)) }

    /// A whole-window close (or quit) starts: record the full session once, then hold it.
    func freezeSessionForClose(defaults: any ZPDFDefaultsStoring = ZenitProcessDefaults.layout) {
        recordSession(defaults: defaults)
        Self.frozenSessions.insert(ObjectIdentifier(self))
    }

    /// The close or quit that froze the session was cancelled: the window lives on, so its
    /// session follows it again, starting with what it holds now. Without this a Cancel in
    /// the close review left the session frozen until the next drawing arrived, and every
    /// tab closed, moved or switched in between was never recorded (R-022).
    func thawSession(defaults: any ZPDFDefaultsStoring = ZenitProcessDefaults.layout) {
        Self.frozenSessions.remove(ObjectIdentifier(self))
        recordSession(defaults: defaults)
    }

    /// A quit that ``prepareForTermination()`` froze this window for was cancelled.
    public func terminationCancelled() {
        thawSession()
    }

    /// The window has closed: its freeze goes with it, so a later window that happens to be
    /// allocated at the same address does not start out frozen.
    func releaseSessionFreeze() {
        Self.frozenSessions.remove(ObjectIdentifier(self))
    }

    /// Applies a restored drawing's viewport once its canvas exists.
    func applyPendingSessionViewport(for document: ZenitPDFProjectDocument) {
        // A drawing arriving means any close that froze the session was not the end of it.
        Self.frozenSessions.remove(ObjectIdentifier(self))
        guard let path = document.fileURL?.path else { return }
        if path == Self.pendingActivePath {
            Self.pendingActivePath = nil
            activateTab(id: document.documentIdentity)
        }
        if let pageIndex = Self.pendingPagesOnOpen.removeValue(forKey: path) {
            Self.turn(document, toPageIndex: pageIndex)
        }
        if let viewport = Self.pendingSessionViewports.removeValue(forKey: path), let core = document.core {
            let pages = core.document.pages
            if pages.indices.contains(viewport.position) { document.shell?.goToPage(id: pages[viewport.position].id) }
            core.canvas.setZoom(viewport.zoom)
        }
        // The drawing's second windows come back with it, each at its own sheet and zoom (C-07).
        if let seconds = Self.pendingSecondWindows.removeValue(forKey: path), !isSecondWindow {
            Task { @MainActor [weak self, weak document] in
                for viewport in seconds {
                    guard let self, let document,
                          let window = await self.openNewWindow(for: document),
                          let core = window.windowCore(for: document) else { return }
                    let pages = core.document.pages
                    if pages.indices.contains(viewport.position) {
                        window.windowShell(for: document)?.goToPage(id: pages[viewport.position].id)
                    }
                    core.canvas.setZoom(viewport.zoom)
                }
            }
        }
    }

    /// Turns an open drawing to the sheet at `pageIndex` in its own file (a folder search hit).
    static func turn(_ document: ZenitPDFProjectDocument, toPageIndex pageIndex: Int) {
        guard let core = document.core, let drawing = document.drawing,
              let page = drawing.pages.first(where: { $0.index == pageIndex }),
              core.document.pages.contains(where: { $0.id == page.id.rawValue }) else { return }
        document.shell?.goToPage(id: page.id.rawValue)
    }

    /// Whether the person wants windows back at launch, read the way macOS decides it for every
    /// application: System Settings ▸ Desktop & Dock ▸ "Close windows when quitting an application"
    /// is stored as `NSQuitAlwaysKeepsWindows` in the global domain — `true` only when the box is
    /// *off* — and an application may be opted out with `ApplePersistence = false`. Absent means
    /// the macOS default, which closes windows, so nothing is reopened (r2-layers
    /// follow-up). `preference` is injected; tests never read the user's settings.
    static func systemKeepsWindowsOnQuit(preference: (String) -> Any? = { UserDefaults.standard.object(forKey: $0) }) -> Bool {
        if let persistence = preference("ApplePersistence") as? Bool, !persistence { return false }
        return (preference("NSQuitAlwaysKeepsWindows") as? Bool) ?? false
    }

    /// Launch's door: reopens the last session only when the system setting keeps windows on quit.
    @discardableResult
    static func restoreLastSessionIfAllowed(
        defaults: any ZPDFDefaultsStoring = ZenitProcessDefaults.layout,
        preference: (String) -> Any? = { UserDefaults.standard.object(forKey: $0) }
    ) -> [URL] {
        guard systemKeepsWindowsOnQuit(preference: preference) else { return [] }
        return restoreLastSession(defaults: defaults)
    }

    /// Where a session's drawing is now, when it still exists — decided under its bookmark's
    /// security scope, which is ended again here.
    ///
    /// The access used to be started here and kept: the document controller then found the file
    /// readable, took no access of its own, and so handed the opened document nothing to end when
    /// it closed (R-037). Now the controller resolves the bookmark itself and gives the document
    /// its release. `begin` and `end` are injectable, so a test can count them.
    static func restorableURL(
        forPath path: String,
        begin: (String) -> URL? = { DroppedFileBookmarks.beginAccess(forPath: $0, defaults: ZenitProcessDefaults.bookmarks) },
        end: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        guard let scoped = begin(path) else {
            return exists(path) ? URL(fileURLWithPath: path) : nil
        }
        defer { end(scoped) }
        return exists(scoped.path) ? scoped : nil
    }

    /// Reopens the last session's drawings in order, through the same opener drops use, and
    /// remembers the viewports to apply as each opens. Files that are gone are skipped.
    /// Answers the files opened.
    @discardableResult
    static func restoreLastSession(defaults: any ZPDFDefaultsStoring = ZenitProcessDefaults.layout) -> [URL] {
        guard let session = WindowSessionStore.load(defaults: defaults), !session.paths.isEmpty else { return [] }
        var urls: [URL] = []
        for path in session.paths {
            guard let url = restorableURL(forPath: path) else { continue }
            urls.append(url)
            if let viewport = session.viewports[path] { pendingSessionViewports[url.path] = viewport }
            let seconds = (session.secondWindows ?? []).filter { $0.path == path }.map(\.viewport)
            if !seconds.isEmpty { pendingSecondWindows[url.path] = seconds }
        }
        // Tabs open in their order; the front one is brought forward once it has opened.
        if session.paths.indices.contains(session.activeIndex) {
            let front = session.paths[session.activeIndex]
            pendingActivePath = urls.first { $0.path == front || URL(fileURLWithPath: front).lastPathComponent == $0.lastPathComponent }?.path
        }
        guard !urls.isEmpty else { return [] }
        dropOpener(urls)
        return urls
    }
}
