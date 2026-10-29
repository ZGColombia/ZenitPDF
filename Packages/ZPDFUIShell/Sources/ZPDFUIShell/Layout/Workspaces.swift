import Foundation
import Observation
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// A named window arrangement: which panes are open and how big, which Navigator page and
/// bottom tab are showing, which Inspector sections are expanded (NL-UX-10, "Workspaces").
///
/// A person keeps one for takeoff (Tool Library and ledger up), one for review (Inspector and
/// History), one for comparing — and switches with ⌃1–⌃4 instead of dragging dividers.
public struct ZenitWorkspace: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// The pane arrangement. Tool memory (last-used measurement, count preset, style) is not
    /// part of a workspace: switching the layout never changes the armed tool.
    public var layout: ProjectWindowLayoutState
    /// Workspaces that follow the task: the canvas mode that switches the
    /// window to this workspace on entry (and back on exit), or `nil`. Optional in the stored
    /// JSON, so workspaces saved before it existed still read.
    public var followsMode: DismissibleCanvasMode?

    public init(id: UUID = UUID(), name: String, layout: ProjectWindowLayoutState, followsMode: DismissibleCanvasMode? = nil) {
        self.id = id
        self.name = name
        self.layout = layout
        self.followsMode = followsMode
    }
}

/// Where workspaces are kept: one JSON array in defaults, beside the window layout.
@MainActor
public final class ZenitWorkspaceStore {

    public static let defaultsKey = "Zenit.Workspaces"
    private let defaults: any ZPDFDefaultsStoring
    private let key: String

    public init(defaults: any ZPDFDefaultsStoring = UserDefaults.standard, key: String = ZenitWorkspaceStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public var workspaces: [ZenitWorkspace] {
        get {
            guard let data = defaults.persistedData(forKey: key),
                  let decoded = try? JSONDecoder().decode([ZenitWorkspace].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            defaults.setPersistedData(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }
}

/// The Workspaces list and its operations, apart from any menu (NL-UX-10).
@MainActor
@Observable
public final class WorkspacesModel {

    /// How many workspaces get a ⌃-number shortcut.
    public static let shortcutSlots = 4

    public private(set) var workspaces: [ZenitWorkspace]
    @ObservationIgnored private let store: ZenitWorkspaceStore

    public init(store: ZenitWorkspaceStore) {
        self.store = store
        self.workspaces = store.workspaces
    }

    /// Saves a layout under a name. A name already used is replaced in place (keeping its
    /// slot and shortcut); a new name is appended. Blank names are refused.
    @discardableResult
    public func save(name: String, layout: ProjectWindowLayoutState) -> ZenitWorkspace? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var stored = layout.normalized()
        // Tool memory stays with the window, not the workspace.
        stored.lastUsedMeasurementKind = nil
        stored.lastUsedCountPresetID = nil
        stored.lastUsedShapeKind = nil
        stored.toolStyle = nil
        if let index = workspaces.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            workspaces[index].layout = stored  // keeps its followsMode
            workspaces[index].name = trimmed
            persist()
            return workspaces[index]
        }
        let workspace = ZenitWorkspace(name: trimmed, layout: stored)
        workspaces.append(workspace)
        persist()
        return workspace
    }

    /// The workspace in a zero-based slot, or `nil`.
    public func workspace(inSlot index: Int) -> ZenitWorkspace? {
        workspaces.indices.contains(index) ? workspaces[index] : nil
    }

    /// Removes one workspace; the ones after it move up a slot.
    public func delete(id: UUID) {
        workspaces.removeAll { $0.id == id }
        persist()
    }

    /// Renames one workspace. Refused (returns `false`) for a blank name or one already used.
    @discardableResult
    public func rename(id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !workspaces.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }),
              let index = workspaces.firstIndex(where: { $0.id == id })
        else { return false }
        workspaces[index].name = trimmed
        persist()
        return true
    }

    /// Makes one workspace the one a canvas mode switches to (only one per mode), or clears it.
    public func setFollowsMode(_ mode: DismissibleCanvasMode?, for id: UUID) {
        for index in workspaces.indices {
            if workspaces[index].id == id {
                workspaces[index].followsMode = mode
            } else if let mode, workspaces[index].followsMode == mode {
                workspaces[index].followsMode = nil
            }
        }
        persist()
    }

    /// The workspace a canvas mode switches to, if any.
    public func workspace(following mode: DismissibleCanvasMode) -> ZenitWorkspace? {
        workspaces.first { $0.followsMode == mode }
    }

    /// A suggested name for the next workspace: "Workspace 3".
    public var suggestedName: String {
        var number = workspaces.count + 1
        while workspaces.contains(where: { $0.name == Self.defaultName(number) }) { number += 1 }
        return Self.defaultName(number)
    }

    static func defaultName(_ number: Int) -> String {
        String(format: NSLocalizedString("Workspace %ld", comment: "Default name of a saved workspace"), number)
    }

    private func persist() {
        store.workspaces = workspaces
    }
}

public extension ProjectShellEnvironment {

    /// The window's arrangement now, as a workspace would store it.
    func currentWorkspaceLayout() -> ProjectWindowLayoutState? {
        layoutController?.workspaceLayoutSnapshot()
    }

    /// Re-arranges the window to a workspace. Returns whether a window was there to arrange.
    @discardableResult
    func applyWorkspace(_ workspace: ZenitWorkspace) -> Bool {
        guard let layoutController else { return false }
        layoutController.applyWorkspaceLayout(workspace.layout)
        return true
    }
}

/// Switches a window to the workspace a canvas mode names when the mode starts, and back to
/// the arrangement it had when the mode ends (compare → overlay layout, split → its own). Nothing happens for a mode no workspace follows.
@MainActor
public final class WorkspaceModeFollower {

    private weak var environment: ProjectShellEnvironment?
    private let model: WorkspacesModel
    private var lastMode: DismissibleCanvasMode?
    /// The arrangement to go back to when the followed mode ends.
    public private(set) var returnLayout: ProjectWindowLayoutState?
    private var generation = 0

    public init(environment: ProjectShellEnvironment, model: WorkspacesModel) {
        self.environment = environment
        self.model = model
        self.lastMode = environment.canvasModes.activeMode
        observe()
    }

    /// Reacts to one mode change. Public so a test can drive it without observation timing.
    public func modeDidChange(to mode: DismissibleCanvasMode?) {
        guard let environment, mode != lastMode else { return }
        defer { lastMode = mode }
        if let mode, let workspace = model.workspace(following: mode) {
            if returnLayout == nil { returnLayout = environment.currentWorkspaceLayout() }
            environment.applyWorkspace(workspace)
        } else if mode == nil, let back = returnLayout {
            returnLayout = nil
            environment.applyWorkspace(ZenitWorkspace(name: "", layout: back))
        }
    }

    private func observe() {
        generation &+= 1
        let token = generation
        guard let environment else { return }
        withObservationTracking {
            _ = environment.canvasModes.activeMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, token == self.generation, let environment = self.environment else { return }
                self.modeDidChange(to: environment.canvasModes.activeMode)
                self.observe()
            }
        }
    }
}
