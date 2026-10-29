import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

public extension NSToolbarItem.Identifier {

    /// The brand block (peak mark, `ZenitPDF` wordmark, tagline), left of the tool group.
    static let zenitBrand = NSToolbarItem.Identifier("zenit.toolbar.brand")
    /// The hairline between the drawing tools and the markup tools (2026-09-23 mockup).
    static let zenitToolSeparator = NSToolbarItem.Identifier("zenit.toolbar.toolSeparator")
    /// The rounded workspace group: Tool Library, Search, Compare and Export in one outline
    /// (2026-09-23 mockup). The four also exist as single items for customization.
    static let zenitWorkspaceGroup = NSToolbarItem.Identifier("zenit.toolbar.workspaceGroup")
    /// The author badge: the initials of the name new markups are signed with.
    static let zenitAuthor = NSToolbarItem.Identifier("zenit.toolbar.author")
    /// Pointer tool.
    static let zenitSelect = NSToolbarItem.Identifier("zenit.toolbar.select")
    /// Hand tool.
    static let zenitPan = NSToolbarItem.Identifier("zenit.toolbar.pan")
    /// Zoom tool: drag a marquee to zoom into it.
    static let zenitZoom = NSToolbarItem.Identifier("zenit.toolbar.zoom")
    /// Scale calibration tool. First class — never behind a chevron.
    static let zenitCalibrate = NSToolbarItem.Identifier("zenit.toolbar.calibrate")
    /// Length measurement tool. First class — never behind a chevron.
    static let zenitLength = NSToolbarItem.Identifier("zenit.toolbar.length")
    /// Polygon area measurement tool. First class — never behind a chevron.
    static let zenitArea = NSToolbarItem.Identifier("zenit.toolbar.area")
    /// Text markup tool.
    static let zenitText = NSToolbarItem.Identifier("zenit.toolbar.text")
    /// Callout markup tool.
    static let zenitCallout = NSToolbarItem.Identifier("zenit.toolbar.callout")
    /// Shape markup tool.
    static let zenitShapes = NSToolbarItem.Identifier("zenit.toolbar.shapes")
    /// Measurement palette.
    static let zenitMeasure = NSToolbarItem.Identifier("zenit.toolbar.measure")
    /// Count palette.
    static let zenitCount = NSToolbarItem.Identifier("zenit.toolbar.count")
    /// Cutout tool.
    static let zenitCutout = NSToolbarItem.Identifier("zenit.toolbar.cutout")
    /// Tool Library panel.
    static let zenitToolLibrary = NSToolbarItem.Identifier("zenit.toolbar.toolLibrary")
    /// Search panel.
    static let zenitSearch = NSToolbarItem.Identifier("zenit.toolbar.search")
    /// Revision Compare.
    static let zenitCompare = NSToolbarItem.Identifier("zenit.toolbar.compare")
    /// Export.
    static let zenitExport = NSToolbarItem.Identifier("zenit.toolbar.export")
    /// The contextual measurement controls row.
    static let zenitMeasurementControls = NSToolbarItem.Identifier("zenit.toolbar.measurementControls")
}

/// Builds and owns the project window's `NSToolbar` — the top bar of the 2026-09-23
/// main-window mockup.
///
/// Left, the brand block. Centre, the tool group: `Select · Zoom · Pan · Calibrate · Length ·
/// Area · Measure`, a hairline, then `Text · Callout · Shapes · Count · Cutout`. Right, the
/// rounded workspace group (`Tool Library · Search · Compare · Export`) and the author badge.
/// One rule holds inside that order: `Calibrate`, `Length` and `Area` are
/// always-visible first-class items right after `Pan`.
///
/// Every tool is a ``ZenitToolChip`` — icon over caption, the armed tool a filled accent
/// rounded rect with light glyph and caption — so the labels are part of the item itself, not
/// an `NSToolbar` display mode. Measure, Shapes and Count are popup palettes with last-used
/// memory: a plain click re-arms whatever was last used, the chevron opens the full list.
@MainActor
public final class ZenitToolbarBuilder: NSObject, NSToolbarDelegate, NSMenuDelegate {

    /// The toolbar identifier, also the customization autosave key.
    public static let toolbarIdentifier = NSToolbar.Identifier(ZPDFShellAutosaveName.toolbar)

    private let environment: ProjectShellEnvironment
    private weak var toolbar: NSToolbar?

    /// The live tooltip of every chip item that has one, by identifier.
    ///
    /// `NSToolbarItem.toolTip` is a stored string AppKit reads when it decides to show a
    /// tooltip, so a palette chip whose tooltip names its last-used tool needs the string
    /// rewritten when that memory changes. ``refreshLiveHelp()`` does that; the SwiftUI chip
    /// inside the item evaluates its own `.help` live and needs no help from here (CR-114).
    private var liveHelp: [NSToolbarItem.Identifier: @MainActor () -> String] = [:]

    /// Creates the builder.
    ///
    /// Binds the toolbar model's Count palette to the Tool Library, live (BH-054). The builder
    /// owns this window's toolbar, and the Count chip's menu, its button and
    /// ``ZenitToolbarModel/activateCountPreset(id:)`` must all read one list: a palette frozen
    /// at shell init listed a newly created preset in the menu and then armed plain Count
    /// when it was picked.
    public init(environment: ProjectShellEnvironment) {
        self.environment = environment
        super.init()
        environment.toolbar.bindCountPalette { [weak environment] in
            environment?.toolLibrary.presets ?? []
        }
    }

    /// The items shown by default, in order. This is the documented default set.
    ///
    /// The brand block stays pinned left, the drawing group (`Select … Zoom`) is
    /// **horizontally centred** between two flexible spaces, and the workspace group
    /// (`Tool Library · Search · Compare · Export`) stays pinned right. `Calibrate`, `Length`
    /// and `Area` sit right after `Pan`; `Zoom` closes the drawing group — the mockup predates
    /// the marquee-zoom tool, and dropping it would remove marquee zoom from the toolbar. The contextual
    /// measurement controls stay out of the default set (they read as a second toolbar)
    /// and remain available from the customization palette. When the window is too narrow
    /// to centre everything, the standard overflow chevron engages — items never silently
    /// vanish. Restoring toolbar defaults restores exactly this arrangement.
    ///
    /// The 2026-09-23 mockup, which replaces the earlier mockups where they disagree, fixes the
    /// order inside the group: `Select · Zoom · Pan · Calibrate · Length · Area · Measure`, a
    /// hairline separator, `Text · Callout · Shapes · Count · Cutout`. Zoom moved up next to
    /// Select and Measure closes the measuring run; the first-class rule is untouched (Calibrate,
    /// Length and Area still follow Pan directly). The workspace group is one rounded item and
    /// the author badge closes the bar.
    public static let defaultItemIdentifiers: [NSToolbarItem.Identifier] = [
        .zenitBrand,
        .flexibleSpace,
        .zenitSelect, .zenitZoom, .zenitPan,
        .zenitCalibrate, .zenitLength, .zenitArea, .zenitMeasure,
        .zenitToolSeparator,
        .zenitText, .zenitCallout, .zenitShapes, .zenitCount, .zenitCutout,
        .flexibleSpace,
        .zenitWorkspaceGroup, .zenitAuthor
    ]

    /// Every item a user can add in the customization sheet.
    public static let allowedItemIdentifiers: [NSToolbarItem.Identifier] = [
        .zenitBrand,
        .zenitSelect, .zenitPan, .zenitZoom,
        .zenitCalibrate, .zenitLength, .zenitArea,
        .zenitText, .zenitCallout, .zenitShapes,
        .zenitMeasure, .zenitCount, .zenitCutout,
        .zenitMeasurementControls,
        .zenitToolSeparator,
        .zenitWorkspaceGroup,
        .zenitToolLibrary, .zenitSearch, .zenitCompare, .zenitExport,
        .zenitAuthor,
        .space, .flexibleSpace, .toggleSidebar, .toggleInspector
    ]

    /// The items that can read as the armed tool.
    ///
    /// The chips draw the armed state themselves (the filled cyan rect), so this set is
    /// no longer handed to AppKit's selection ring — it is the vocabulary of
    /// ``selectionIdentifier(for:lastUsedMeasurement:)`` and of the tests that pin it.
    public static let selectableItemIdentifiers: [NSToolbarItem.Identifier] = [
        .zenitSelect, .zenitPan, .zenitZoom, .zenitCalibrate, .zenitLength, .zenitArea,
        .zenitText, .zenitCallout, .zenitShapes,
        .zenitMeasure, .zenitCount, .zenitCutout
    ]

    /// Builds the toolbar.
    ///
    /// User customization is on and autosaved; the customization
    /// sheet is reachable from View > Customize Toolbar (the `.customizeToolbar` command)
    /// and from a Control-click on the toolbar, which AppKit provides once
    /// `allowsUserCustomization` is set. Labels are always visible — every chip draws its
    /// icon *and* its 10 pt caption itself, as the mockup draws them — so the
    /// toolbar's own display mode stays `.iconOnly` to keep AppKit from doubling the
    /// captions under the chips.
    public func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        // The person's arrangement is autosaved in the assembled application only; a test process
        // must not write `NSToolbar Configuration …` into its runner's real defaults.
        toolbar.autosavesConfiguration = ZPDFShellAutosaveName.appKitAutosavesEnabled
        toolbar.showsBaselineSeparator = true
        self.toolbar = toolbar
        return toolbar
    }

    /// Re-evaluates every item's tooltip against the toolbar model as it is now.
    ///
    /// Called from ``ProjectWindowLayoutController`` whenever the toolbar reports a
    /// persistable change — which is exactly when a palette's last-used memory moves. The
    /// hosted SwiftUI chip re-reads its own `.help` on the next body pass, so this only has to
    /// carry the AppKit side: the item's `toolTip`, which the overflow menu and the
    /// customization sheet also read (CR-114).
    public func refreshLiveHelp() {
        guard let toolbar else { return }
        for item in toolbar.items {
            guard let text = liveHelpText(for: item.itemIdentifier) else { continue }
            item.toolTip = text
        }
    }

    /// The tooltip an item would show right now. For tests, and for ``refreshLiveHelp()``.
    public func liveHelpText(for identifier: NSToolbarItem.Identifier) -> String? {
        liveHelp[identifier]?()
    }

    /// The toolbar item that reads as armed for a tool.
    ///
    /// `Length` and `Area` have their own first-class items, so when the Measure family is
    /// armed with one of those kinds the fill lands on that item rather than on the palette.
    static func selectionIdentifier(
        for tool: ZenitToolIdentifier,
        lastUsedMeasurement: MeasurementKind
    ) -> NSToolbarItem.Identifier {
        switch tool {
        case .select: return .zenitSelect
        case .pan: return .zenitPan
        case .zoom: return .zenitZoom
        case .calibrate: return .zenitCalibrate
        case .length: return .zenitLength
        case .area: return .zenitArea
        case .text: return .zenitText
        case .callout: return .zenitCallout
        case .shapes: return .zenitShapes
        case .measure:
            // `.length` and `.area` are their own identifiers now, so this only fires for
            // a stale caller that still spells them as the Measure family.
            switch lastUsedMeasurement {
            case .length: return .zenitLength
            case .area: return .zenitArea
            default: return .zenitMeasure
            }
        case .count: return .zenitCount
        case .cutout: return .zenitCutout
        }
    }

    // MARK: - NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItemIdentifiers
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.allowedItemIdentifiers
    }

    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The chips draw the armed state; AppKit's grey selection ring on top of the
        // cyan fill would be two competing indicators for one state.
        []
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .zenitBrand:
            return brandItem()
        case .zenitToolSeparator:
            return separatorItem()
        case .zenitWorkspaceGroup:
            return workspaceGroupItem()
        case .zenitAuthor:
            return authorItem()
        case .zenitSelect:
            return toolItem(itemIdentifier, tool: .select, command: .selectTool)
        case .zenitPan:
            return toolItem(itemIdentifier, tool: .pan, command: .panTool)
        case .zenitZoom:
            return toolItem(itemIdentifier, tool: .zoom, command: .zoomTool)
        case .zenitCalibrate:
            return toolItem(itemIdentifier, tool: .calibrate, command: .calibrateScale)
        case .zenitLength:
            return chipItem(
                itemIdentifier,
                glyph: .measurement(.length),
                title: NSLocalizedString("Length", comment: "Toolbar item"),
                command: .measureLength,
                selectionID: itemIdentifier
            )
        case .zenitArea:
            return chipItem(
                itemIdentifier,
                glyph: .measurement(.area),
                title: NSLocalizedString("Area", comment: "Toolbar item"),
                command: .measureArea,
                selectionID: itemIdentifier
            )
        case .zenitText:
            return toolItem(itemIdentifier, tool: .text, command: .textTool)
        case .zenitCallout:
            return toolItem(itemIdentifier, tool: .callout, command: .calloutTool)
        case .zenitShapes:
            return shapesPaletteItem()
        case .zenitCutout:
            return toolItem(itemIdentifier, tool: .cutout, command: .cutoutTool)
        case .zenitMeasure:
            return measurePaletteItem()
        case .zenitCount:
            return countPaletteItem()
        case .zenitToolLibrary:
            return chipItem(
                itemIdentifier,
                glyph: .symbol(.toolLibrary),
                title: NSLocalizedString("Tool Library", comment: "Toolbar item"),
                command: .toolLibrary,
                showsOpenState: true
            )
        case .zenitSearch:
            return chipItem(
                itemIdentifier,
                glyph: .symbol(.search),
                title: NSLocalizedString("Search", comment: "Toolbar item"),
                command: .find,
                showsOpenState: true
            )
        case .zenitCompare:
            return chipItem(
                itemIdentifier,
                glyph: .symbol(.revisionCompare),
                title: NSLocalizedString("Compare", comment: "Toolbar item"),
                command: .revisionCompare,
                showsOpenState: true
            )
        case .zenitExport:
            // nl-ux: the chip opens the chooser of every export; `.export` alone is the ledger.
            let environment = self.environment
            return chipItem(
                itemIdentifier,
                glyph: .symbol(.export),
                title: NSLocalizedString("Export", comment: "Toolbar item"),
                command: .export,
                action: { environment.presentExportChooser() },
                help: { Self.exportChipHelp }
            )
        case .zenitMeasurementControls:
            return measurementControlsItem()
        default:
            return nil
        }
    }

    // MARK: - Item construction

    /// The brand block of the 2026-09-23 mockup: peak mark, `ZenitPDF`, tagline. Identity,
    /// not a control: it is excluded from the selectable set and takes no action.
    private func brandItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .zenitBrand)
        let hosting = NSHostingView(rootView: ZenitToolbarBrand())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        item.view = hosting
        let title = NSLocalizedString("Zenit PDF", comment: "Toolbar brand block, customization palette label")
        item.label = ""
        item.paletteLabel = title
        item.toolTip = nil
        item.isBordered = false
        // The brand gives way first when the window is too narrow for everything: the tools
        // are the bar's purpose, the wordmark is not.
        item.visibilityPriority = .low
        // Overflowed, it is a plain disabled row naming the product rather than a blank one.
        let menuForm = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuForm.isEnabled = false
        item.menuFormRepresentation = menuForm
        item.view?.setAccessibilityLabel(ZenitToolbarBrand.accessibilityText)
        return item
    }

    /// The hairline between the measuring tools and the markup tools. Decorative: hidden from
    /// VoiceOver, and a plain separator in the overflow menu.
    private func separatorItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .zenitToolSeparator)
        let separator = ZenitToolSeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        item.view = separator
        let title = NSLocalizedString("Separator", comment: "Toolbar customization palette label for the tool group separator")
        item.label = title
        item.paletteLabel = title
        item.isBordered = false
        item.autovalidates = false
        item.menuFormRepresentation = .separator()
        return item
    }

    /// The commands of the rounded workspace group, in mockup order.
    static let workspaceCommands: [(identifier: NSToolbarItem.Identifier, command: ZPDFCommandID)] = [
        (.zenitToolLibrary, .toolLibrary),
        (.zenitSearch, .find),
        (.zenitCompare, .revisionCompare),
        (.zenitExport, .export)
    ]

    /// The rounded workspace group: the same four chips the single items build, in one
    /// outline. Tooltips, open states and actions are the single items' own.
    private func workspaceGroupItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .zenitWorkspaceGroup)
        let chips = Self.workspaceCommands.compactMap { entry in
            workspaceChip(entry.identifier, height: ZenitTopBarStyle.chipHeight - 2 * ZenitTopBarStyle.groupInset)
        }
        let hosting = NSHostingView(rootView: ZenitWorkspaceGroup(chips: chips))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        item.view = hosting
        let title = ZenitWorkspaceGroup.accessibilityText
        item.label = title
        item.paletteLabel = NSLocalizedString(
            "Tool Library, Search, Compare, Export",
            comment: "Toolbar customization palette label for the workspace group"
        )
        item.isBordered = false
        item.autovalidates = false
        item.visibilityPriority = .high
        // A named group for VoiceOver; its four chips stay individually reachable inside it.
        hosting.setAccessibilityRole(.group)
        hosting.setAccessibilityLabel(title)

        // Overflowed, the group is a submenu of its four commands.
        let menuForm = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for entry in Self.workspaceCommands {
            let row = NSMenuItem(
                title: Self.workspaceTitle(entry.identifier),
                action: #selector(runMenuFormItem(_:)),
                keyEquivalent: ""
            )
            row.target = self
            row.tag = Self.tagValue(for: entry.command)
            submenu.addItem(row)
        }
        menuForm.submenu = submenu
        item.menuFormRepresentation = menuForm
        return item
    }

    /// The Export chip's tooltip: it names what the chip opens, since the caption alone does
    /// not say which of the exports it is (nl-ux).
    static var exportChipHelp: String {
        NSLocalizedString(
            "Export the Quantity Ledger or the drawing",
            comment: "Tooltip of the toolbar Export chip, which opens the list of exports"
        )
    }

    /// The caption of a workspace chip.
    static func workspaceTitle(_ identifier: NSToolbarItem.Identifier) -> String {
        switch identifier {
        case .zenitToolLibrary: return NSLocalizedString("Tool Library", comment: "Toolbar item")
        case .zenitSearch: return NSLocalizedString("Search", comment: "Toolbar item")
        case .zenitCompare: return NSLocalizedString("Compare", comment: "Toolbar item")
        default: return NSLocalizedString("Export", comment: "Toolbar item")
        }
    }

    /// One workspace chip, built exactly as its single toolbar item builds it.
    func workspaceChip(_ identifier: NSToolbarItem.Identifier, height: CGFloat = ZenitTopBarStyle.chipHeight) -> ZenitToolChip? {
        guard let command = Self.workspaceCommands.first(where: { $0.identifier == identifier })?.command else {
            return nil
        }
        let glyph: ZPDFGlyph
        switch identifier {
        case .zenitToolLibrary: glyph = .symbol(.toolLibrary)
        case .zenitSearch: glyph = .symbol(.search)
        case .zenitCompare: glyph = .symbol(.revisionCompare)
        default: glyph = .symbol(.export)
        }
        let title = Self.workspaceTitle(identifier)
        let environment = self.environment
        return ZenitToolChip(
            environment: environment,
            glyph: glyph,
            title: title,
            selectionID: nil,
            // Export opens a flow, not a panel that stays open, so it shows no open state.
            openStateCommand: command == .export ? nil : command,
            helpText: { [weak self] in
                let help = command == .export ? Self.exportChipHelp : title
                return self?.helpTag(help, command: command) ?? help
            },
            // Through the toolbar's command route, like every chip: it is where the lit Search
            // chip toggles Search closed again (R-073) — `perform(.find)` only ever reveals.
            action: command == .export
                ? { environment.presentExportChooser() }
                : { environment.toolbar.run(command) },
            palette: nil,
            height: height
        )
    }

    /// The author badge: the author's initials; a click opens Settings to change the name.
    private func authorItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .zenitAuthor)
        // Identity and a way to Settings: the badge is a button.
        let toolbar = environment.toolbar
        let hosting = NSHostingView(rootView: ZenitAuthorBadge(toolbar: toolbar))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        item.view = hosting
        let title = NSLocalizedString("Author", comment: "Toolbar item: the author badge")
        item.label = title
        item.paletteLabel = title
        item.isBordered = false
        item.autovalidates = false
        item.visibilityPriority = .high
        liveHelp[.zenitAuthor] = { ZenitAuthorBadge.helpText(name: toolbar.authorName) }
        item.toolTip = ZenitAuthorBadge.helpText(name: toolbar.authorName)
        item.view?.setAccessibilityLabel(ZenitAuthorBadge.accessibilityText(name: toolbar.authorName))
        // Overflowed, a row naming the author that opens Settings, as the badge does.
        let menuForm = NSMenuItem(
            title: ZenitAuthorBadge.accessibilityText(name: toolbar.authorName),
            action: #selector(runPaletteMenuItem(_:)),
            keyEquivalent: ""
        )
        menuForm.target = self
        menuForm.representedObject = PaletteAction { toolbar.openAuthorSettings() }
        item.menuFormRepresentation = menuForm
        return item
    }

    private func shortcut(for command: ZPDFCommandID) -> ZPDFKeyBinding? {
        environment.commands.command(command)?.binding
    }

    /// The tooltip: the help text, the shortcut in brackets, and — on a second line — the usage
    /// hint the command table already carries (IM-139). "Hold the Space bar to pan" and
    /// "Option-click to zoom out" were written down for VoiceOver and shown to nobody else.
    private func helpTag(_ help: String, command: ZPDFCommandID) -> String {
        let tagged = shortcut(for: command).map { "\(help) (\($0.displayString))" } ?? help
        guard let hint = environment.commands.command(command)?.accessibilityHint,
              !hint.trimmingCharacters(in: .whitespaces).isEmpty
        else { return tagged }
        return "\(tagged)\n\(hint)"
    }

    /// A chip item for a shell tool: arming state mirrored from the toolbar model.
    private func toolItem(
        _ identifier: NSToolbarItem.Identifier,
        tool: ZenitToolIdentifier,
        command: ZPDFCommandID
    ) -> NSToolbarItem {
        chipItem(
            identifier,
            glyph: tool.glyph,
            title: tool.displayName,
            command: command,
            selectionID: identifier
        )
    }

    /// A chip item running one command; `selectionID` non-`nil` when the chip can read as
    /// the armed tool, `palette` non-`nil` when it carries a popup list.
    private func chipItem(
        _ identifier: NSToolbarItem.Identifier,
        glyph: ZPDFGlyph,
        title: String,
        command: ZPDFCommandID,
        selectionID: NSToolbarItem.Identifier? = nil,
        showsOpenState: Bool = false,
        palette: ZenitToolChip.Palette? = nil,
        action: (@MainActor () -> Void)? = nil,
        help: (@MainActor () -> String)? = nil
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let environment = self.environment
        let tooltip: @MainActor () -> String = { [weak self] in
            guard let self else { return title }
            return self.helpTag(help?() ?? title, command: command)
        }
        liveHelp[identifier] = tooltip
        let chip = ZenitToolChip(
            environment: environment,
            glyph: glyph,
            title: title,
            selectionID: selectionID,
            openStateCommand: showsOpenState ? command : nil,
            helpText: tooltip,
            // R-073: a chip press is a toolbar press — `toolbar.run` → `onCommand`, which toggles
            // Search and performs everything else. It called `perform(_:)` directly, so the lit
            // Search chip never closed Search.
            action: action ?? { environment.toolbar.run(command) },
            palette: palette
        )
        let hosting = NSHostingView(rootView: chip)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        item.view = hosting

        // The group's container is the toolbar itself. On macOS 26, AppKit puts a shared
        // Liquid Glass slab behind adjacent view items — a dark bubble around the group. `isBordered = false` opts the chip out of that
        // material, so hover states and the filled-cyan active chip sit directly on the
        // bar; on macOS 14/15 the property is inert for view items.
        item.isBordered = false

        // The label feeds the overflow menu and the customization sheet; the chip draws
        // the visible caption itself (the toolbar's display mode is icon-only).
        item.label = title
        item.paletteLabel = title
        item.toolTip = tooltip()
        item.autovalidates = false
        item.view?.setAccessibilityLabel(title)

        // The overflow menu needs an explicit menu form for a view-based item.
        let menuForm = NSMenuItem(title: title, action: #selector(runMenuFormItem(_:)), keyEquivalent: "")
        menuForm.target = self
        menuForm.tag = Self.tagValue(for: command)
        if let palette {
            // IM-140: an overflowed palette chip keeps its list. Without a submenu the overflow
            // row could only run the chip's command, and the palette's other tools were
            // unreachable on a narrow window.
            let submenu = PaletteMenu(title: title, palette: palette)
            submenu.delegate = self
            refill(submenu)
            menuForm.submenu = submenu
        }
        item.menuFormRepresentation = menuForm
        return item
    }

    private func measurePaletteItem() -> NSToolbarItem {
        let environment = self.environment
        let title = NSLocalizedString("Measure", comment: "Toolbar item")
        let helpFormat = NSLocalizedString(
            "Measure. Click to use %@ again, or open the list for another tool.",
            comment: "Toolbar tooltip for the measurement palette, with the last-used tool name"
        )
        return chipItem(
            .zenitMeasure,
            glyph: .symbol(.measure),
            title: title,
            // BH-300: `.measureTool` is the command that re-arms the palette's last used tool.
            // `.measureLength` put ⌘L in this tooltip and made the overflow row arm Length.
            command: .measureTool,
            selectionID: .zenitMeasure,
            palette: .measure,
            action: { environment.toolbar.activateLastUsedMeasurement() },
            help: { String(format: helpFormat, environment.toolbar.measureButtonTitle) }
        )
    }

    /// The Shapes palette: a plain click re-arms the last
    /// shape drawn, the chevron opens Rectangle · Ellipse · Line · Arrow · Polyline ·
    /// Polygon · Cloud. It used to be a plain chip with no chevron and no list, which is
    /// half of why "Shapes does nothing" was true.
    private func shapesPaletteItem() -> NSToolbarItem {
        let environment = self.environment
        let title = NSLocalizedString("Shapes", comment: "Toolbar item")
        let helpFormat = NSLocalizedString(
            "Shapes. Click to draw another %@, or open the list for another shape.",
            comment: "Toolbar tooltip for the shapes palette, with the last-used shape name"
        )
        return chipItem(
            .zenitShapes,
            glyph: ZenitToolIdentifier.shapes.glyph,
            title: title,
            command: .shapesTool,
            selectionID: .zenitShapes,
            palette: .shapes,
            action: { environment.toolbar.activateLastUsedShape() },
            help: { String(format: helpFormat, environment.toolbar.shapeButtonTitle) }
        )
    }

    private func countPaletteItem() -> NSToolbarItem {
        let environment = self.environment
        let title = NSLocalizedString("Count", comment: "Toolbar item")
        let helpFormat = NSLocalizedString(
            "Count. Click to use %@ again, or open the list for another count tool.",
            comment: "Toolbar tooltip for the count palette, with the last-used preset name"
        )
        return chipItem(
            .zenitCount,
            glyph: .measurement(.count),
            title: title,
            command: .measureCount,
            selectionID: .zenitCount,
            palette: .count,
            action: { environment.toolbar.activateLastUsedCount() },
            help: { String(format: helpFormat, environment.toolbar.countButtonTitle) }
        )
    }

    private func measurementControlsItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .zenitMeasurementControls)
        let hosting = NSHostingView(
            rootView: MeasurementControlsRow(environment: environment)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Modern toolbars measure view items from constraints rather than min/max sizes.
        NSLayoutConstraint.activate([
            hosting.heightAnchor.constraint(equalToConstant: ZPDFSpacing.Control.toolbarHeight),
            hosting.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            hosting.widthAnchor.constraint(lessThanOrEqualToConstant: 720)
        ])
        item.view = hosting
        item.visibilityPriority = .low
        // Same bar-integration rule as the chips: no glass slab behind the row.
        item.isBordered = false
        let title = NSLocalizedString("Measurement controls", comment: "Toolbar item")
        item.label = title
        item.paletteLabel = title
        item.toolTip = title
        item.autovalidates = false
        item.view?.setAccessibilityLabel(title)
        return item
    }

    // MARK: - Actions

    /// Commands are carried on the menu item's tag so one selector can serve every
    /// overflow-menu form.
    private static func tagValue(for command: ZPDFCommandID) -> Int {
        ZPDFCommandID.allCases.firstIndex(of: command) ?? -1
    }

    private static func command(forTag tag: Int) -> ZPDFCommandID? {
        guard tag >= 0, tag < ZPDFCommandID.allCases.count else { return nil }
        return ZPDFCommandID.allCases[tag]
    }

    @objc
    private func runMenuFormItem(_ sender: NSMenuItem) {
        guard let command = Self.command(forTag: sender.tag) else { return }
        // The overflowed Export row does what the chip does (nl-ux).
        if command == .export {
            environment.presentExportChooser()
        } else {
            // The overflowed chip does what the chip does (R-073).
            environment.toolbar.run(command)
        }
    }

    // MARK: - Overflow palettes (IM-140)

    /// An overflow submenu that knows which palette it lists, so it can be rebuilt against the
    /// toolbar model every time it opens.
    final class PaletteMenu: NSMenu {
        let palette: ZenitToolChip.Palette

        init(title: String, palette: ZenitToolChip.Palette) {
            self.palette = palette
            super.init(title: title)
        }

        required init(coder: NSCoder) {
            // Never decoded in practice; a decoded one lists the Measure palette.
            self.palette = .measure
            super.init(coder: coder)
        }
    }

    /// The action a palette row runs, carried on the row itself.
    private final class PaletteAction: NSObject {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard let menu = menu as? PaletteMenu else { return }
        refill(menu)
    }

    /// Rebuilds one overflow palette from the toolbar model as it is now.
    func refill(_ menu: PaletteMenu) {
        menu.removeAllItems()
        for item in paletteMenuItems(menu.palette) { menu.addItem(item) }
    }

    /// The rows an overflowed palette chip lists: the same entries as the chip's chevron, with
    /// the last-used one checked.
    func paletteMenuItems(_ palette: ZenitToolChip.Palette) -> [NSMenuItem] {
        let toolbar = environment.toolbar
        let environment = self.environment
        switch palette {
        case .measure:
            var items: [NSMenuItem] = []
            for (index, section) in toolbar.measurementPaletteSections.enumerated() {
                if index > 0 { items.append(.separator()) }
                for kind in section {
                    let item = paletteRow(kind.displayName, isChecked: kind == toolbar.lastUsedMeasurementKind) {
                        environment.toolbar.activateMeasurement(kind)
                    }
                    let image = ZPDFIcon.image(kind: kind)
                    item.image = image
                    items.append(item)
                }
            }
            return items
        case .shapes:
            let shapes = toolbar.shapePalette.map { kind in
                paletteRow(kind.displayName, isChecked: kind == toolbar.lastUsedShapeKind) {
                    environment.toolbar.activateShape(kind)
                }
            }
            // r2-markup: the variants and the annotation tools, below a divider.
            let variants = toolbar.variantPalette.map { variant in
                paletteRow(variant.displayName, isChecked: false) {
                    environment.toolbar.activateShapeVariant(variant)
                }
            }
            let annotations = toolbar.annotationPalette.map { kind in
                paletteRow(kind == .freehand ? ZenitToolbarModel.penTitle : kind.displayName, isChecked: false) {
                    environment.toolbar.activateShape(kind)
                }
            }
            return shapes + [.separator()] + variants + annotations
        case .count:
            let presets = toolbar.countPalette
            guard !presets.isEmpty else {
                let empty = NSMenuItem(
                    title: NSLocalizedString(
                        "No count tools saved yet",
                        comment: "Count palette menu shown when the Tool Library has no count presets"
                    ),
                    action: nil,
                    keyEquivalent: ""
                )
                empty.isEnabled = false
                return [
                    empty,
                    .separator(),
                    paletteRow(NSLocalizedString(
                        "Use Plain Count",
                        comment: "Count palette menu: arm the Count tool without a saved preset"
                    ), isChecked: false) { environment.toolbar.activateMeasurement(.count) },
                    paletteRow(NSLocalizedString(
                        "Open Tool Library…",
                        comment: "Count palette menu: open the Tool Library to create a count tool"
                    ), isChecked: false) { environment.perform(.toolLibrary) }
                ]
            }
            return presets.map { preset in
                paletteRow(preset.name, isChecked: preset.id == toolbar.lastUsedCountPresetID) {
                    environment.toolbar.activateCountPreset(id: preset.id)
                }
            }
        }
    }

    private func paletteRow(
        _ title: String,
        isChecked: Bool,
        run: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runPaletteMenuItem(_:)), keyEquivalent: "")
        item.target = self
        item.state = isChecked ? .on : .off
        item.representedObject = PaletteAction(run)
        return item
    }

    @objc
    private func runPaletteMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? PaletteAction)?.run()
    }
}

private extension ZPDFIcon {
    /// A measurement tool's glyph as a template menu image.
    @MainActor
    static func image(kind: MeasurementKind) -> NSImage? {
        guard case let .measurement(icon) = ZPDFGlyph.measurement(for: kind) else { return nil }
        let image = ZPDFIcon.image(icon, size: 16)
        image.isTemplate = true
        return image
    }
}
