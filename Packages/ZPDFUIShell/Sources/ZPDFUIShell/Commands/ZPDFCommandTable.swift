import Foundation
import ZPDFDesignSystem

/// A shortcut declared twice in a way that cannot be resolved at key-press time.
public struct ZPDFShortcutConflict: Hashable, Sendable, CustomStringConvertible {

    /// The printed chord, for example `"⇧⌘L"`.
    public let shortcut: String
    /// The context both commands claim.
    public let context: ZPDFCommandContext
    /// Every command claiming the chord in that context.
    public let commandIDs: [ZPDFCommandID]

    /// Creates a conflict record.
    public init(shortcut: String, context: ZPDFCommandContext, commandIDs: [ZPDFCommandID]) {
        self.shortcut = shortcut
        self.context = context
        self.commandIDs = commandIDs
    }

    public var description: String {
        "\(shortcut) in \(context.rawValue) claimed by \(commandIDs.map(\.rawValue).joined(separator: ", "))"
    }
}

/// The whole menu and keyboard command table for a project window.
///
/// Section 21.8 of the plan fixes the base shortcuts. This type is that table as data: the app
/// target walks it to build `NSMenu`s and to register key handling, and the tests walk it to
/// prove no two commands fight over the same chord.
public struct ZPDFCommandTable: Hashable, Sendable {

    /// Every declared command, in menu order.
    public let commands: [ZPDFCommand]

    /// Creates a table from an explicit command list.
    public init(commands: [ZPDFCommand]) {
        self.commands = commands
    }

    /// Looks a command up by identity.
    public func command(_ id: ZPDFCommandID) -> ZPDFCommand? {
        commands.first { $0.id == id }
    }

    /// Commands in one menu, in declaration order.
    public func commands(in group: ZPDFCommandGroup) -> [ZPDFCommand] {
        commands.filter { $0.group == group }
    }

    /// Commands grouped into menus, menus in menu-bar order.
    public var menus: [(group: ZPDFCommandGroup, commands: [ZPDFCommand])] {
        ZPDFCommandGroup.allCases
            .sorted { $0.menuOrder < $1.menuOrder }
            .compactMap { group in
                let items = commands(in: group)
                return items.isEmpty ? nil : (group, items)
            }
    }

    /// Every command that carries a shortcut.
    public var boundCommands: [ZPDFCommand] {
        commands.filter { $0.binding != nil }
    }

    /// Chords claimed more than once inside the same context.
    ///
    /// A chord claimed in two *different* contexts is not a conflict — it is an override, and
    /// the narrower command must declare `shadowsBroaderBinding`. Those are reported by
    /// ``undeclaredShadows()`` instead.
    public func conflicts() -> [ZPDFShortcutConflict] {
        var buckets: [String: [ZPDFCommand]] = [:]
        for command in boundCommands {
            guard let binding = command.binding else { continue }
            buckets["\(command.context.rawValue)|\(binding.chord)", default: []].append(command)
        }
        return buckets.values
            .filter { $0.count > 1 }
            .map { group in
                ZPDFShortcutConflict(
                    shortcut: group[0].binding?.displayString ?? "",
                    context: group[0].context,
                    commandIDs: group.map(\.id).sorted { $0.rawValue < $1.rawValue }
                )
            }
            .sorted { $0.shortcut < $1.shortcut }
    }

    /// Commands that reuse a chord already claimed by a broader context without saying so.
    ///
    /// `⌘A` meaning *Area* on the canvas is legitimate, but it has to be written down, because
    /// it changes what `⌘A` does in the one place users expect *Select All*.
    public func undeclaredShadows() -> [ZPDFCommandID] {
        var chordsByContext: [ZPDFCommandContext: Set<String>] = [:]
        for command in boundCommands {
            guard let chord = command.binding?.chord else { continue }
            chordsByContext[command.context, default: []].insert(chord)
        }
        return boundCommands
            .filter { !$0.shadowsBroaderBinding }
            .filter { command in
                guard let chord = command.binding?.chord else { return false }
                return command.context.ancestors.contains { ancestor in
                    chordsByContext[ancestor]?.contains(chord) == true
                }
            }
            .map(\.id)
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// The chords macOS itself owns at the application level: the one list the takeover audit
    /// is derived from.
    ///
    /// Zenit is allowed to shadow one of these in a narrower context, but never to take one
    /// over at `.application` scope, which is what ``systemShortcutTakeovers()`` checks.
    static let systemReservedBindings: [ZPDFKeyBinding] = [
        ZPDFKeyBinding.character("n", [.command]),      // New
        ZPDFKeyBinding.character("w", [.command]),      // Close
        ZPDFKeyBinding.character("q", [.command]),      // Quit
        ZPDFKeyBinding.character("m", [.command]),      // Minimise
        ZPDFKeyBinding.character("h", [.command]),      // Hide
        ZPDFKeyBinding.character("x", [.command]),      // Cut
        ZPDFKeyBinding.character("c", [.command]),      // Copy
        ZPDFKeyBinding.character("v", [.command]),      // Paste
        ZPDFKeyBinding.character(",", [.command]),      // Settings
        ZPDFKeyBinding.character("?", [.command, .shift]) // Help
    ]

    /// The chord a takeover audit compares, with Shift folded away for a key that is a shifted
    /// glyph rather than a letter or digit (BH-799).
    ///
    /// A menu key equivalent for `?` may be written with or without the Shift bit — the glyph
    /// already implies it, and AppKit's own menus leave it out — so `⌘?` and `⇧⌘?` are the same
    /// keystroke. The reserved Help entry was stored as `⇧⌘?` and compared by exact string, so a
    /// command declared `.character("?", [.command])` slipped past the audit.
    static func takeoverAuditChord(_ binding: ZPDFKeyBinding) -> String {
        var modifiers = binding.modifiers
        let isShiftedGlyph = binding.key.count == 1
            && binding.key.unicodeScalars.allSatisfy { scalar in
                CharacterSet.punctuationCharacters.contains(scalar)
                    || CharacterSet.symbols.contains(scalar)
            }
        if isShiftedGlyph { modifiers.remove(.shift) }
        return "\(modifiers.rawValue):\(binding.key.lowercased())"
    }

    /// ``systemReservedBindings`` as the takeover audit compares them.
    static let systemReservedAuditChords: Set<String> = Set(systemReservedBindings.map(takeoverAuditChord))

    /// Application-scope commands that take over a chord macOS reserves.
    public func systemShortcutTakeovers() -> [ZPDFCommandID] {
        boundCommands
            .filter { $0.context == .application }
            .filter { command in
                guard let binding = command.binding else { return false }
                guard Self.systemReservedAuditChords.contains(Self.takeoverAuditChord(binding)) else {
                    return false
                }
                // Zenit's own Close Tab and Select All intentionally sit on the standard
                // chords because they *are* the standard commands, scoped to a project window.
                return ![.closeTab, .selectAll].contains(command.id)
            }
            .map(\.id)
            .sorted { $0.rawValue < $1.rawValue }
    }
}

public extension ZPDFCommandTable {

    /// The command table the project window installs: the keyboard map.
    static let standard = ZPDFCommandTable(commands: fileCommands + editCommands + viewCommands
        + panelCommands + toolCommands + measureCommands)

    private static var fileCommands: [ZPDFCommand] {
        [
            ZPDFCommand(
                id: .openDocument,
                title: NSLocalizedString("Open…", comment: "File menu command"),
                group: .file,
                binding: .character("o", [.command]),
                glyph: .symbol(.open)
            ),
            ZPDFCommand(
                id: .save,
                title: NSLocalizedString("Save", comment: "File menu command"),
                group: .file,
                binding: .character("s", [.command]),
                glyph: .symbol(.save)
            ),
            ZPDFCommand(
                id: .saveAs,
                title: NSLocalizedString("Save As…", comment: "File menu command"),
                group: .file,
                binding: .character("s", [.command, .shift]),
                glyph: .symbol(.save)
            ),
            ZPDFCommand(
                id: .print,
                title: NSLocalizedString("Print…", comment: "File menu command"),
                group: .file,
                binding: .character("p", [.command]),
                glyph: .symbol(.print)
            ),
            ZPDFCommand(
                id: .export,
                title: NSLocalizedString("Export…", comment: "File menu command"),
                group: .file,
                binding: .character("e", [.command, .shift]),
                glyph: .symbol(.export)
            ),
            ZPDFCommand(
                id: .closeTab,
                title: NSLocalizedString("Close Document", comment: "File menu command"),
                group: .file,
                binding: .character("w", [.command]),
                accessibilityHint: NSLocalizedString(
                    "Closes the front document and asks before discarding unsaved work",
                    comment: "Accessibility hint for Close Document"
                )
            )
        ]
    }

    private static var editCommands: [ZPDFCommand] {
        [
            ZPDFCommand(
                id: .undo,
                title: NSLocalizedString("Undo", comment: "Edit menu command"),
                group: .edit,
                binding: .character("z", [.command]),
                glyph: .symbol(.undo)
            ),
            ZPDFCommand(
                id: .redo,
                title: NSLocalizedString("Redo", comment: "Edit menu command"),
                group: .edit,
                binding: .character("z", [.command, .shift]),
                glyph: .symbol(.redo)
            ),
            ZPDFCommand(
                id: .selectAll,
                title: NSLocalizedString("Select All", comment: "Edit menu command"),
                group: .edit,
                binding: .character("a", [.command])
            ),
            ZPDFCommand(
                id: .deleteSelection,
                title: NSLocalizedString("Delete Selection", comment: "Edit menu command"),
                group: .edit,
                binding: .delete(),
                context: .canvas,
                glyph: .symbol(.delete),
                isDestructive: true
            )
        ]
    }

    private static var viewCommands: [ZPDFCommand] {
        [
            ZPDFCommand(
                id: .zoomIn,
                title: NSLocalizedString("Zoom In", comment: "View menu command"),
                group: .view,
                binding: .character("+", [.command]),
                glyph: .symbol(.zoomIn)
            ),
            ZPDFCommand(
                id: .zoomOut,
                title: NSLocalizedString("Zoom Out", comment: "View menu command"),
                group: .view,
                binding: .character("-", [.command]),
                glyph: .symbol(.zoomOut)
            ),
            ZPDFCommand(
                id: .fitWidth,
                title: NSLocalizedString("Fit Width", comment: "View menu command"),
                group: .view,
                binding: .character("0", [.command]),
                glyph: .symbol(.fitWidth)
            ),
            ZPDFCommand(
                id: .actualSize,
                title: NSLocalizedString("Actual Size", comment: "View menu command"),
                group: .view,
                binding: .character("1", [.command]),
                glyph: .symbol(.actualSize)
            ),
            ZPDFCommand(
                id: .fitPage,
                title: NSLocalizedString("Fit Page", comment: "View menu command"),
                group: .view,
                binding: .character("2", [.command]),
                glyph: .symbol(.fitPage)
            ),
            ZPDFCommand(
                id: .zoomToSelection,
                title: NSLocalizedString("Zoom to Selection", comment: "View menu command"),
                group: .view,
                binding: .character("*", [.command]),
                glyph: .symbol(.zoomIn),
                accessibilityHint: NSLocalizedString(
                    "Fits the selected markups in the viewport with padding",
                    comment: "Accessibility hint for Zoom to Selection"
                )
            ),
            // Page navigation. `⌘↑` / `⌘↓` are the platform's, and the modifier matters for a
            // reason beyond convention: a binding without Command never becomes a menu key
            // equivalent here, so a plain `⌥↑` would be invisible in the menu. The canvas also
            // accepts Page Up / Page Down / Home / End, and scrolling past a page edge turns
            // the page — three routes, because a person reaching for the next sheet should not
            // have to guess which one this application chose.
            ZPDFCommand(
                id: .previousPage,
                title: NSLocalizedString("Previous Page", comment: "View menu command"),
                group: .view,
                binding: .arrowUp([.command]),
                glyph: .symbol(.chevronUp),
                accessibilityHint: NSLocalizedString(
                    "Shows the page before this one. Does nothing on the first page.",
                    comment: "Accessibility hint for Previous Page"
                )
            ),
            ZPDFCommand(
                id: .nextPage,
                title: NSLocalizedString("Next Page", comment: "View menu command"),
                group: .view,
                binding: .arrowDown([.command]),
                glyph: .symbol(.chevronDown),
                accessibilityHint: NSLocalizedString(
                    "Shows the page after this one. Does nothing on the last page.",
                    comment: "Accessibility hint for Next Page"
                )
            ),
            ZPDFCommand(
                id: .firstPage,
                title: NSLocalizedString("First Page", comment: "View menu command"),
                group: .view,
                binding: .arrowUp([.command, .option]),
                glyph: .symbol(.pages)
            ),
            ZPDFCommand(
                id: .lastPage,
                title: NSLocalizedString("Last Page", comment: "View menu command"),
                group: .view,
                binding: .arrowDown([.command, .option]),
                glyph: .symbol(.pages)
            ),
            ZPDFCommand(
                id: .toggleNavigator,
                title: ZPDFClosableSurface.navigator.showTitle,
                group: .view,
                binding: .character("n", [.command, .option]),
                glyph: .symbol(.navigator),
                accessibilityHint: NSLocalizedString(
                    "Shows and hides the left sidebar; the title says which it will do",
                    comment: "Accessibility hint for the Navigator pane toggle"
                )
            ),
            ZPDFCommand(
                id: .toggleInspector,
                title: ZPDFClosableSurface.inspector.showTitle,
                group: .view,
                binding: .character("i", [.command, .option]),
                glyph: .symbol(.inspector),
                accessibilityHint: NSLocalizedString(
                    "Shows and hides the right sidebar; the title says which it will do",
                    comment: "Accessibility hint for the Inspector pane toggle"
                )
            ),
            ZPDFCommand(
                id: .toggleQuantityLedger,
                title: ZPDFClosableSurface.quantityLedger.showTitle,
                group: .view,
                binding: .character("l", [.command, .option]),
                glyph: .symbol(.quantityLedger),
                accessibilityHint: NSLocalizedString(
                    "Shows and hides the bottom pane on its Quantities tab",
                    comment: "Accessibility hint for the Quantity Ledger pane toggle"
                )
            ),
            ZPDFCommand(
                id: .toggleHistory,
                title: ZPDFClosableSurface.history.showTitle,
                group: .view,
                binding: .character("y", [.command, .option]),
                glyph: .symbol(.quantityLedger),
                accessibilityHint: NSLocalizedString(
                    "Shows and hides the bottom pane on its History tab, the project audit trail",
                    comment: "Accessibility hint for the History pane toggle"
                )
            ),
            ZPDFCommand(
                id: .toggleCoverageMap,
                title: NSLocalizedString("Coverage Map", comment: "View menu command"),
                group: .view,
                accessibilityHint: NSLocalizedString(
                    "Shows and hides the overlay that tints measured regions so unmeasured ones stand out",
                    comment: "Accessibility hint for the Coverage Map toggle"
                )
            ),
            ZPDFCommand(
                id: .customizeToolbar,
                title: NSLocalizedString("Customize Toolbar…", comment: "View menu command"),
                group: .view,
                accessibilityHint: NSLocalizedString(
                    "Opens the sheet for rearranging the toolbar items",
                    comment: "Accessibility hint for Customize Toolbar"
                )
            )
        ]
    }

    private static var panelCommands: [ZPDFCommand] {
        [
            ZPDFCommand(
                id: .collapseQuantityLedger,
                title: NSLocalizedString("Collapse Quantity Ledger", comment: "Panels menu command"),
                group: .panels,
                glyph: .symbol(.quantityLedger),
                accessibilityHint: NSLocalizedString(
                    "Collapses the docked Quantity Ledger to its header bar and restores it",
                    comment: "Accessibility hint for collapsing the ledger to its header bar"
                )
            ),
            ZPDFCommand(
                id: .detachQuantityLedger,
                title: NSLocalizedString("Detach Quantity Ledger", comment: "Panels menu command"),
                group: .panels,
                binding: .character("l", [.command, .option, .shift]),
                glyph: .symbol(.quantityLedger),
                accessibilityHint: NSLocalizedString(
                    "Moves the Quantity Ledger into its own window and back",
                    comment: "Accessibility hint for detaching the ledger"
                )
            ),
            ZPDFCommand(
                id: .toolLibrary,
                title: NSLocalizedString("Show Tool Library", comment: "Panels menu command"),
                group: .panels,
                binding: .character("t", [.command, .option]),
                glyph: .symbol(.toolLibrary)
            ),
            ZPDFCommand(
                id: .find,
                title: NSLocalizedString("Search", comment: "Panels menu command"),
                group: .panels,
                binding: .character("f", [.command]),
                glyph: .symbol(.search)
            ),
            ZPDFCommand(
                id: .scaleRegions,
                title: NSLocalizedString("Show Scale Regions", comment: "Panels menu command"),
                group: .panels,
                binding: .character("r", [.command, .option]),
                glyph: .symbol(.scaleRegions),
                accessibilityHint: NSLocalizedString(
                    "Opens the panel for the parts of a page that measure at their own scale",
                    comment: "Accessibility hint for Show Scale Regions"
                )
            ),
            ZPDFCommand(
                id: .projectZones,
                title: NSLocalizedString("Show Project Zones", comment: "Panels menu command"),
                group: .panels,
                binding: .character("4", [.command, .option]),
                glyph: .symbol(.projectZones),
                accessibilityHint: NSLocalizedString(
                    "Opens the Navigator on the page where zones are created and named",
                    comment: "Accessibility hint for Show Project Zones"
                )
            )
        ]
    }

    /// The tools.
    ///
    /// IM-116: each toolbar tool has a single-key shortcut on the canvas — the first letter of
    /// its name where that is free, otherwise a letter from the name or the shape it draws
    /// (`R` for Shapes, whose default is the rectangle; `X` for Cutout; `⇧C` for Calibrate,
    /// beside Callout's `C`). Digits stay with the number-key tool slots. The letters are
    /// canvas-scoped and served by ``CanvasToolShortcut`` through the window's key monitor;
    /// the audits below prove they collide with nothing.
    private static var toolCommands: [ZPDFCommand] {
        [
            ZPDFCommand(
                id: .selectTool,
                title: NSLocalizedString("Select", comment: "Tools menu command"),
                group: .tools,
                binding: .character("s", []),
                context: .canvas,
                glyph: .symbol(.select)
            ),
            ZPDFCommand(
                id: .panTool,
                title: NSLocalizedString("Pan", comment: "Tools menu command"),
                group: .tools,
                binding: .character("p", []),
                context: .canvas,
                glyph: .symbol(.pan),
                accessibilityHint: NSLocalizedString(
                    "Hold the Space bar to pan without leaving the current tool",
                    comment: "Accessibility hint for the Pan tool"
                )
            ),
            ZPDFCommand(
                id: .zoomTool,
                title: NSLocalizedString("Zoom", comment: "Tools menu command"),
                group: .tools,
                binding: .character("z", []),
                context: .canvas,
                glyph: .symbol(.zoomIn),
                accessibilityHint: NSLocalizedString(
                    "Drag a rectangle to zoom into it; hold Option and click to zoom out",
                    comment: "Accessibility hint for the Zoom tool"
                )
            ),
            ZPDFCommand(
                id: .textTool,
                title: NSLocalizedString("Text", comment: "Tools menu command"),
                group: .tools,
                binding: .character("t", []),
                context: .canvas,
                glyph: .symbol(.text)
            ),
            ZPDFCommand(
                id: .calloutTool,
                title: NSLocalizedString("Callout", comment: "Tools menu command"),
                group: .tools,
                binding: .character("c", []),
                context: .canvas,
                glyph: .symbol(.callout)
            ),
            ZPDFCommand(
                id: .shapesTool,
                title: NSLocalizedString("Shapes", comment: "Tools menu command"),
                group: .tools,
                binding: .character("r", []),
                context: .canvas,
                glyph: .symbol(.shapes)
            ),
            ZPDFCommand(
                id: .measureTool,
                title: NSLocalizedString("Measure", comment: "Tools menu command"),
                group: .tools,
                binding: .character("m", []),
                context: .canvas,
                glyph: .symbol(.measure)
            ),
            ZPDFCommand(
                id: .cutoutTool,
                title: NSLocalizedString("Cutout", comment: "Tools menu command"),
                group: .tools,
                binding: .character("x", []),
                context: .canvas,
                glyph: .measurement(.cutout)
            ),
            ZPDFCommand(
                id: .revisionCompare,
                title: NSLocalizedString("Revision Compare", comment: "Tools menu command"),
                group: .tools,
                glyph: .symbol(.revisionCompare)
            ),
            ZPDFCommand(
                id: .revisionOverlay,
                title: NSLocalizedString("Revision Overlay", comment: "Tools menu command"),
                group: .tools,
                glyph: .symbol(.revisionOverlay),
                accessibilityHint: NSLocalizedString(
                    "Stacks two revisions over each other; Escape returns to the drawing",
                    comment: "Accessibility hint for Revision Overlay"
                )
            ),
            ZPDFCommand(
                id: .splitCanvas,
                title: NSLocalizedString("Split Canvas", comment: "Tools menu command"),
                group: .tools,
                glyph: .symbol(.splitCanvas),
                accessibilityHint: NSLocalizedString(
                    "Shows up to four canvases at once; Escape returns to the drawing",
                    comment: "Accessibility hint for Split Canvas"
                )
            ),
            ZPDFCommand(
                id: .closeCanvasMode,
                title: NSLocalizedString("Close Canvas View Mode", comment: "Tools menu command"),
                group: .tools,
                accessibilityHint: NSLocalizedString(
                    "Leaves Split Canvas, Revision Overlay or Revision Compare and returns the drawing",
                    comment: "Accessibility hint for leaving a canvas view mode"
                )
            )
        ]
    }

    private static var measureCommands: [ZPDFCommand] {
        [
            ZPDFCommand(
                id: .calibrateScale,
                title: NSLocalizedString("Calibrate", comment: "Measure menu command"),
                group: .measure,
                binding: .character("c", [.shift]),
                context: .canvas,
                glyph: .measurement(.calibrate),
                accessibilityHint: NSLocalizedString(
                    "Sets the drawing scale from a known dimension",
                    comment: "Accessibility hint for the Calibrate command"
                )
            ),
            ZPDFCommand(
                id: .measureLength,
                title: NSLocalizedString("Length", comment: "Measure menu command"),
                group: .measure,
                binding: .character("l", [.command]),
                glyph: .measurement(.length)
            ),
            ZPDFCommand(
                id: .measurePolylength,
                title: NSLocalizedString("Polylength", comment: "Measure menu command"),
                group: .measure,
                binding: .character("l", [.command, .shift]),
                glyph: .measurement(.polylength)
            ),
            ZPDFCommand(
                id: .measureArea,
                title: NSLocalizedString("Area", comment: "Measure menu command"),
                group: .measure,
                // Decided 2026-09-23: ⌘A is Select All everywhere, the Mac
                // standard. It used to be Area on the canvas, which AppKit never honoured
                // consistently — the menu bar's Select All took ⌘A first whenever the page had
                // markups, so the same key selected everything on one page and armed Area on
                // the next. Area keeps a single-key shortcut, served like the other tool letters.
                binding: .character("a", []),
                context: .canvas,
                glyph: .measurement(.area),
                accessibilityHint: NSLocalizedString(
                    "Available while the canvas has focus and no text is being edited",
                    comment: "Accessibility hint for the Area shortcut"
                )
            ),
            ZPDFCommand(
                id: .measureCount,
                title: NSLocalizedString("Count", comment: "Measure menu command"),
                group: .measure,
                binding: .character("k", [.command]),
                glyph: .measurement(.count)
            ),
            ZPDFCommand(
                id: .finishGeometry,
                title: NSLocalizedString("Finish Geometry", comment: "Measure menu command"),
                group: .measure,
                binding: .return(),
                context: .canvasDrawing,
                accessibilityHint: NSLocalizedString(
                    "Closes the measurement being drawn",
                    comment: "Accessibility hint for finishing a measurement"
                )
            ),
            ZPDFCommand(
                id: .cancelTool,
                title: NSLocalizedString("Cancel Tool", comment: "Measure menu command"),
                group: .measure,
                binding: .escape(),
                context: .canvas,
                accessibilityHint: NSLocalizedString(
                    "Discards the measurement being drawn and returns to Select",
                    comment: "Accessibility hint for cancelling a measurement"
                )
            ),
            ZPDFCommand(
                id: .removeLastVertex,
                title: NSLocalizedString("Remove Last Point", comment: "Measure menu command"),
                group: .measure,
                binding: .delete(),
                context: .canvasDrawing,
                // Deliberate: while a geometry is open, Delete walks the vertices back.
                // The moment the geometry is closed, Delete goes back to deleting the
                // selected markups.
                shadowsBroaderBinding: true,
                accessibilityHint: NSLocalizedString(
                    "Removes the most recently placed point",
                    comment: "Accessibility hint for removing the last vertex"
                )
            ),
            ZPDFCommand(
                id: .cycleSnapCandidate,
                title: NSLocalizedString("Cycle Snap Candidate", comment: "Measure menu command"),
                group: .measure,
                binding: .tab(),
                context: .canvasDrawing,
                accessibilityHint: NSLocalizedString(
                    "Steps through the snap candidates under the pointer",
                    comment: "Accessibility hint for cycling snap candidates"
                )
            )
        ]
    }
}
