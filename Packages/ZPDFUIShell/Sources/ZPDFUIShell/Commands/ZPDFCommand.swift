import Foundation
import ZPDFDesignSystem

/// Stable identity for every command the project window can install.
///
/// The app target maps these to real actions. The shell only declares them, so the menu bar,
/// the toolbar and the keyboard layer can all be built from one table.
public enum ZPDFCommandID: String, Codable, Hashable, Sendable, CaseIterable {

    // File
    case openDocument = "zenit.file.open"
    case save = "zenit.file.save"
    case saveAs = "zenit.file.saveAs"
    case print = "zenit.file.print"
    case export = "zenit.file.export"
    case closeTab = "zenit.file.closeTab"

    // Edit
    case undo = "zenit.edit.undo"
    case redo = "zenit.edit.redo"
    case selectAll = "zenit.edit.selectAll"
    case deleteSelection = "zenit.edit.deleteSelection"

    // View
    case zoomIn = "zenit.view.zoomIn"
    case zoomOut = "zenit.view.zoomOut"
    case fitWidth = "zenit.view.fitWidth"
    case actualSize = "zenit.view.actualSize"
    case fitPage = "zenit.view.fitPage"
    case zoomToSelection = "zenit.view.zoomToSelection"

    // Page navigation. A 23-sheet drawing set that can only be paged through by clicking a
    // thumbnail is a document you cannot read; there was no keyboard route to the next sheet
    // at all until 2026-08-26.
    case nextPage = "zenit.view.nextPage"
    case previousPage = "zenit.view.previousPage"
    case firstPage = "zenit.view.firstPage"
    case lastPage = "zenit.view.lastPage"
    case customizeToolbar = "zenit.view.customizeToolbar"

    // Panes — the four closable surfaces of the project window.
    // They live in the **View** menu, which is where macOS puts pane visibility and where
    // people look for them; the Panels menu keeps the panels that are not window edges.
    case toggleNavigator = "zenit.panel.navigator"
    case toggleInspector = "zenit.panel.inspector"
    case toggleQuantityLedger = "zenit.panel.quantityLedger"
    /// Shows the bottom pane on its History tab, and hides it again.
    case toggleHistory = "zenit.panel.history"

    /// Draws the coverage map over the drawing — the opt-in overlay that tints measured
    /// regions so unmeasured ones stand out. A toggle in the View menu, off by default.
    case toggleCoverageMap = "zenit.view.coverageMap"

    // Panels
    case collapseQuantityLedger = "zenit.panel.quantityLedger.collapse"
    case detachQuantityLedger = "zenit.panel.quantityLedger.detach"
    case toolLibrary = "zenit.panel.toolLibrary"
    case find = "zenit.panel.find"
    /// Opens the Scale Regions panel over the drawing.
    case scaleRegions = "zenit.panel.scaleRegions"
    /// Opens the Navigator on its Project Zones page.
    case projectZones = "zenit.panel.projectZones"

    // Tools
    case selectTool = "zenit.tool.select"
    case panTool = "zenit.tool.pan"
    case zoomTool = "zenit.tool.zoom"
    case textTool = "zenit.tool.text"
    case calloutTool = "zenit.tool.callout"
    case shapesTool = "zenit.tool.shapes"
    case measureTool = "zenit.tool.measure"
    case cutoutTool = "zenit.tool.cutout"
    case revisionCompare = "zenit.tool.revisionCompare"
    /// Enters Revision Overlay, a canvas view mode.
    case revisionOverlay = "zenit.tool.revisionOverlay"
    /// Enters Split Canvas, a canvas view mode.
    case splitCanvas = "zenit.tool.splitCanvas"
    /// Leaves whichever canvas view mode is active.
    case closeCanvasMode = "zenit.tool.closeCanvasMode"

    // Measure
    case calibrateScale = "zenit.measure.calibrate"
    case measureLength = "zenit.measure.length"
    case measurePolylength = "zenit.measure.polylength"
    case measureArea = "zenit.measure.area"
    case measureCount = "zenit.measure.count"
    case finishGeometry = "zenit.measure.finish"
    case cancelTool = "zenit.measure.cancel"
    case removeLastVertex = "zenit.measure.removeLastVertex"
    case cycleSnapCandidate = "zenit.measure.cycleSnap"
}

/// Which menu a command belongs in, and in what order the menus appear.
public enum ZPDFCommandGroup: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    case file
    case edit
    case view
    case panels
    case tools
    case measure

    public var id: String { rawValue }

    /// Position of the menu in the menu bar, after the application menu.
    public var menuOrder: Int {
        switch self {
        case .file: return 0
        case .edit: return 1
        case .view: return 2
        case .panels: return 3
        case .tools: return 4
        case .measure: return 5
        }
    }

    /// The menu title.
    public var displayName: String {
        switch self {
        case .file: return NSLocalizedString("File", comment: "Menu bar title")
        case .edit: return NSLocalizedString("Edit", comment: "Menu bar title")
        case .view: return NSLocalizedString("View", comment: "Menu bar title")
        case .panels: return NSLocalizedString("Panels", comment: "Menu bar title")
        case .tools: return NSLocalizedString("Tools", comment: "Menu bar title")
        case .measure: return NSLocalizedString("Measure", comment: "Menu bar title")
        }
    }
}

/// When a shortcut is live.
///
/// Exactly one context is active at the moment a key is pressed, and the narrowest active
/// context wins. That is what lets `⌘A` mean *Select All* in a list and *Area* on the canvas,
/// or Delete remove a vertex while a polygon is open and a markup when it is not, without
/// either pair being an accident.
public enum ZPDFCommandContext: String, Codable, Hashable, Sendable, CaseIterable {

    /// Live wherever the window is key.
    case application
    /// Live while the canvas is first responder and no text is being edited.
    case canvas
    /// Live while a geometry is being drawn on the canvas. Narrower than ``canvas``.
    case canvasDrawing
    /// Live while a text editor has focus.
    case textEditing

    /// The broader contexts this one shadows, nearest first.
    public var ancestors: [ZPDFCommandContext] {
        switch self {
        case .application: return []
        case .canvas: return [.application]
        case .canvasDrawing: return [.canvas, .application]
        case .textEditing: return [.application]
        }
    }

    /// A localized description used in the shortcut sheet and by VoiceOver.
    public var displayName: String {
        switch self {
        case .application:
            return NSLocalizedString("Anywhere in the window", comment: "Shortcut context")
        case .canvas:
            return NSLocalizedString("While the canvas has focus", comment: "Shortcut context")
        case .canvasDrawing:
            return NSLocalizedString("While drawing a measurement", comment: "Shortcut context")
        case .textEditing:
            return NSLocalizedString("While editing text", comment: "Shortcut context")
        }
    }
}

/// One installable command: what it is called, where it lives, what it is bound to.
///
/// The shell never performs a command. It hands this table to the app target, which builds
/// the menu bar and routes the responder chain.
public struct ZPDFCommand: Identifiable, Hashable, Sendable {

    /// Stable identity.
    public let id: ZPDFCommandID
    /// The menu item title.
    public let title: String
    /// Which menu the command lives in.
    public let group: ZPDFCommandGroup
    /// The shortcut, or `nil` when the command is menu- and toolbar-only.
    public let binding: ZPDFKeyBinding?
    /// When the shortcut is live.
    public let context: ZPDFCommandContext
    /// Set when the command deliberately shadows a broader binding on the same chord.
    /// Every such shadow has to be declared, which is what the conflict audit checks.
    public let shadowsBroaderBinding: Bool
    /// The icon a toolbar item or menu item can draw.
    public let glyph: ZPDFGlyph?
    /// Extra spoken context for VoiceOver, beyond the title and the shortcut.
    public let accessibilityHint: String?
    /// Whether the command destroys work, so the app can style it and confirm it.
    public let isDestructive: Bool

    /// Creates a command declaration.
    public init(
        id: ZPDFCommandID,
        title: String,
        group: ZPDFCommandGroup,
        binding: ZPDFKeyBinding? = nil,
        context: ZPDFCommandContext = .application,
        shadowsBroaderBinding: Bool = false,
        glyph: ZPDFGlyph? = nil,
        accessibilityHint: String? = nil,
        isDestructive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.binding = binding
        self.context = context
        self.shadowsBroaderBinding = shadowsBroaderBinding
        self.glyph = glyph
        self.accessibilityHint = accessibilityHint
        self.isDestructive = isDestructive
    }

    /// The full spoken form: title, shortcut, and when the shortcut applies.
    public var accessibilityLabel: String {
        guard let binding else { return title }
        let format = NSLocalizedString(
            "%1$@, shortcut %2$@, %3$@",
            comment: "Accessibility label for a command: title, spoken shortcut, context"
        )
        return String(format: format, title, binding.spokenString, context.displayName)
    }
}
