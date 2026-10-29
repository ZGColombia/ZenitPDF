import AppKit
import ZPDFAppCore
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIShell

/// The canvas context menu (nl-markup, NL-MARKUP-02, NL-UX-02).
///
/// Right-click on a markup used to select it and show nothing: the canvas called `super` on a
/// view that had no menu, and a comment promised a menu "from the shell" that did not exist.
/// Every professional reaches for this menu first. It is built on each right-click from the
/// same doors the menu bar and the Inspector use — the bulk-edit bus for style (one undo step,
/// named for what changed, refused whole over a locked markup), the application command table
/// for Copy Style, Lock, Hide and Select Same, the shell command table for Zoom to Selection
/// and Delete — so it validates like the menu bar and adds no second path.
///
/// `handleSecondaryClick` still runs first, so no menu ever appears while a measurement or a
/// multi-point markup is being drawn.
extension PDFCanvasViewController {

    /// Selects for a right-click: the markup under the pointer, unless it is already part of
    /// the selection (the Mac convention — a right-click inside a multi-selection acts on all
    /// of it); empty drawing clears the selection.
    func selectForContextMenu(at point: PDFPointValue) {
        if activeTextEntry != nil { commitTextEntry() }
        if let hit = hitTest(point) {
            if !core.canvas.selectedMarkupIDs.contains(hit) {
                core.canvas.select(markupIDs: [hit], additive: false)
            }
        } else {
            core.canvas.clearSelection()
        }
    }

    /// The menu for a right-click at `point` (page space, `nil` off the page).
    func markupContextMenu(at point: PDFPointValue?) -> NSMenu? {
        let selected = core.canvas.selectedMarkupIDs
        let markups = core.snapshot.markups.filter { selected.contains($0.id) }
        let menu = NSMenu(title: NSLocalizedString("Markup", comment: "Canvas context menu title"))
        menu.autoenablesItems = false
        if markups.isEmpty {
            buildCanvasMenu(menu, at: point)
        } else {
            buildMarkupMenu(menu, markups: markups, at: point)
        }
        return menu
    }

    // MARK: Empty canvas

    private func buildCanvasMenu(_ menu: NSMenu, at point: PDFPointValue?) {
        let hasClipboard = pasteboardMarkups != nil
        menu.addItem(ContextMenuItem(
            title: NSLocalizedString("Paste Here", comment: "Canvas context menu: paste the copied markups at the pointer"),
            enabled: hasClipboard && point != nil
        ) { [weak self] in
            guard let self, let point else { return }
            Task { @MainActor in _ = await self.pasteMarkups(at: point) }
        })
        menu.addItem(ContextMenuItem(
            title: NSLocalizedString("Paste in Place", comment: "Canvas context menu: paste the copied markups at their own position"),
            enabled: hasClipboard
        ) { [weak self] in
            guard let self else { return }
            Task { @MainActor in _ = await self.pasteMarkups(placement: .inPlace) }
        })
        menu.addItem(.separator())
        menu.addItem(ContextMenuItem(
            title: NSLocalizedString("Select All on Page", comment: "Canvas context menu"),
            enabled: !core.canvas.visibleMarkups.isEmpty
        ) { [weak self] in self?.selectAll(nil) })
        menu.addItem(shellItem(.calibrateScale))
        menu.addItem(.separator())
        menu.addItem(shellItem(.fitPage))
        menu.addItem(shellItem(.fitWidth))
        menu.addItem(shellItem(.actualSize))
    }

    // MARK: Markups

    private func buildMarkupMenu(_ menu: NSMenu, markups: [MarkupSummary], at point: PDFPointValue?) {
        let ids = Set(markups.map(\.id))
        let locked = markups.contains(where: \.locked)

        // Clipboard.
        menu.addItem(ContextMenuItem(title: NSLocalizedString("Cut", comment: "Canvas context menu"), key: "x", enabled: !locked) { [weak self] in
            guard let self else { return }
            Task { @MainActor in _ = await self.cutSelectedMarkups() }
        })
        menu.addItem(ContextMenuItem(title: NSLocalizedString("Copy", comment: "Canvas context menu"), key: "c") { [weak self] in
            guard let self else { return }
            Task { @MainActor in _ = await self.copySelectedMarkups() }
        })
        menu.addItem(ContextMenuItem(
            title: NSLocalizedString("Paste", comment: "Canvas context menu"), key: "v", enabled: pasteboardMarkups != nil
        ) { [weak self] in
            guard let self else { return }
            Task { @MainActor in _ = await self.pasteMarkups(placement: nil) }
        })
        menu.addItem(ContextMenuItem(title: NSLocalizedString("Duplicate", comment: "Canvas context menu"), key: "d") { [weak self] in
            guard let self else { return }
            Task { @MainActor in _ = await self.duplicateSelectedMarkups() }
        })
        menu.addItem(.separator())

        // Appearance, through the bulk-edit bus.
        menu.addItem(colourSubmenu(markups: markups, enabled: !locked))
        if markups.allSatisfy(MarkupContextMenuRules.acceptsFill) {
            menu.addItem(fillSubmenu(markups: markups, enabled: !locked))
        }
        menu.addItem(lineWidthSubmenu(markups: markups, enabled: !locked))
        menu.addItem(lineStyleSubmenu(markups: markups, enabled: !locked))
        if markups.allSatisfy({ InspectorPanel.holdsLineEnds($0.kind) }) {
            menu.addItem(lineEndSubmenu(start: true, markups: markups, enabled: !locked))
            menu.addItem(lineEndSubmenu(start: false, markups: markups, enabled: !locked))
        }
        menu.addItem(.separator())
        menu.addItem(appItem(.copyStyle))
        menu.addItem(appItem(.pasteStyle))
        if markups.count == 1, let markup = markups.first, ZenitToolMode.isDrawable(markup.kind) {
            menu.addItem(ContextMenuItem(title: InspectorPanel.setAsDefaultTitle(for: markup.kind)) { [weak self] in
                self?.markupDocument?.shell?.toolbar.setAsDefault(markup)
            })
        }
        // r2-markup: edit in place, link, rotation, group, arrange, align (ADR-0029).
        menu.addItem(.separator())
        if markups.count == 1, let markup = markups.first,
           let record = sceneRecords.first(where: { $0.id.rawValue == markup.id }),
           Self.inPlaceEntry(for: record) != nil {
            menu.addItem(ContextMenuItem(
                title: NSLocalizedString("Edit Text", comment: "Canvas context menu: edit a text box's words in place"),
                enabled: !locked
            ) { [weak self] in
                _ = self?.beginInPlaceTextEdit(markupID: record.id.rawValue)
            })
        }
        if markups.count == 1, markups.first?.kind == .hyperlink {
            menu.addItem(appItem(.editMarkupLink))
        }
        if markups.allSatisfy(InspectorPanel.holdsRotation) {
            menu.addItem(rotateSubmenu(markups: markups, enabled: !locked))
        }
        menu.addItem(appItem(.groupMarkups))
        if core.selectionHasGroup(ids) { menu.addItem(appItem(.ungroupMarkups)) }
        let arrange = NSMenu()
        for command in [ZenitAppCommand.bringToFront, .bringForward, .sendBackward, .sendToBack] {
            arrange.addItem(appItem(command))
        }
        menu.addItem(Self.parent(NSLocalizedString("Arrange", comment: "Canvas context menu: draw-order submenu"), arrange, enabled: true))
        if markups.count >= 2 {
            let align = NSMenu()
            for (index, command) in [ZenitAppCommand.alignLeft, .alignCentres, .alignRight, .alignTop, .alignMiddles, .alignBottom,
                                     .distributeHorizontally, .distributeVertically, .makeSameWidth, .makeSameHeight].enumerated() {
                if index == 6 || index == 8 { align.addItem(.separator()) }
                align.addItem(appItem(command))
            }
            menu.addItem(Self.parent(NSLocalizedString("Align", comment: "Canvas context menu: align submenu"), align, enabled: !locked))
        }
        // Split, merge, curve and vertex edits on measurements (Canvas/PDFCanvasViewController+GeometryMenu.swift).
        addGeometryEditItems(to: menu, markups: markups, at: point)
        menu.addItem(.separator())
        menu.addItem(statusSubmenu(ids: ids, markups: markups, enabled: !locked))
        // ADR-0032 (r2-layers): Markup/Layers/PDFCanvasViewController+MarkupLayers.swift.
        menu.addItem(moveToLayerSubmenu(ids: ids, markups: markups, enabled: !locked))
        menu.addItem(appItem(.toggleLockSelection))
        menu.addItem(appItem(.hideSelection))
        menu.addItem(.separator())
        menu.addItem(appItem(.selectSameSubject))
        menu.addItem(appItem(.selectSameKind))
        menu.addItem(shellItem(.zoomToSelection))
        menu.addItem(ContextMenuItem(title: NSLocalizedString("Show in Inspector", comment: "Canvas context menu")) { [weak self] in
            guard let shell = self?.markupDocument?.shell else { return }
            if !shell.isSurfaceVisible(.inspector) { shell.perform(.toggleInspector) }
        })
        menu.addItem(.separator())
        menu.addItem(ContextMenuItem(title: NSLocalizedString("Delete", comment: "Canvas context menu"), enabled: !locked) { [weak self] in
            // Delete here is the markup: removing one vertex is the menu's own Remove Vertex row (T-001).
            self?.focusedVertex = nil
            self?.delete(nil)
        })
    }

    // MARK: Submenus

    /// Rotate ▸ 90° left, 90° right, 180°, and back to 0° (NL-MARKUP-18), one undo step each.
    private func rotateSubmenu(markups: [MarkupSummary], enabled: Bool) -> NSMenuItem {
        let submenu = NSMenu()
        let steps: [(String, Double)] = [
            (NSLocalizedString("Rotate 90° Left", comment: "Canvas context menu: rotate counter-clockwise"), 90),
            (NSLocalizedString("Rotate 90° Right", comment: "Canvas context menu: rotate clockwise"), -90),
            (NSLocalizedString("Rotate 180°", comment: "Canvas context menu"), 180)
        ]
        for (title, delta) in steps {
            submenu.addItem(ContextMenuItem(title: title) { [weak self] in
                guard let self else { return }
                let ids = markups.map(\.id)
                Task { @MainActor in await self.rotateMarkups(ids, by: delta) }
            })
        }
        submenu.addItem(.separator())
        submenu.addItem(ContextMenuItem(
            title: NSLocalizedString("Reset Rotation", comment: "Canvas context menu: back to 0°"),
            enabled: markups.contains { ($0.rotationDegrees ?? 0) != 0 }
        ) { [weak self] in
            var edit = MarkupStyleEdit()
            edit.rotationDegrees = 0
            self?.applyContextStyle(edit, to: markups)
        })
        return Self.parent(NSLocalizedString("Rotate", comment: "Canvas context menu: rotation submenu"), submenu, enabled: enabled)
    }

    private func colourSubmenu(markups: [MarkupSummary], enabled: Bool) -> NSMenuItem {
        let current = InspectorSelectionSummary.commonValue(markups.map(\.colorRGBA))
        let submenu = NSMenu()
        for ink in ZPDFMarkupInk.allCases {
            let item = ContextMenuItem(title: ink.displayName) { [weak self] in
                self?.applyContextStyle(MarkupStyleEdit(color: ink.color), to: markups)
            }
            item.image = Self.swatch(ink.color)
            item.state = current.map { ZPDFColourMath.sameHue($0, ink.color) } == true ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(ContextMenuItem(
            title: NSLocalizedString("More Colours…", comment: "Canvas context menu: open the Inspector's colour controls")
        ) { [weak self] in
            guard let shell = self?.markupDocument?.shell else { return }
            if !shell.isSurfaceVisible(.inspector) { shell.perform(.toggleInspector) }
        })
        return Self.parent(NSLocalizedString("Colour", comment: "Canvas context menu submenu: stroke colour"), submenu, enabled: enabled)
    }

    private func fillSubmenu(markups: [MarkupSummary], enabled: Bool) -> NSMenuItem {
        let submenu = NSMenu()
        for ink in ZPDFMarkupInk.allCases {
            var fill = ink.color
            fill.alpha = markups.first?.fillRGBA?.alpha ?? MarkupFillDefaults.derivedAreaFillAlpha
            let item = ContextMenuItem(title: ink.displayName) { [weak self] in
                self?.applyContextStyle(MarkupStyleEdit(fill: fill), to: markups)
            }
            item.image = Self.swatch(ink.color)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(ContextMenuItem(title: NSLocalizedString("No Fill", comment: "Colour palette: removes the markup's fill")) { [weak self] in
            self?.applyContextStyle(MarkupStyleEdit(removesFill: true), to: markups)
        })
        return Self.parent(NSLocalizedString("Fill", comment: "Canvas context menu submenu: fill colour"), submenu, enabled: enabled)
    }

    private func lineWidthSubmenu(markups: [MarkupSummary], enabled: Bool) -> NSMenuItem {
        let current = InspectorSelectionSummary.commonValue(markups.map(\.lineWidth))
        let submenu = NSMenu()
        for width in MarkupContextMenuRules.lineWidths {
            let item = ContextMenuItem(title: MarkupContextMenuRules.widthTitle(width)) { [weak self] in
                self?.applyContextStyle(MarkupStyleEdit(lineWidth: width), to: markups)
            }
            item.state = current == width ? .on : .off
            submenu.addItem(item)
        }
        return Self.parent(NSLocalizedString("Line Width", comment: "Canvas context menu submenu"), submenu, enabled: enabled)
    }

    private func lineStyleSubmenu(markups: [MarkupSummary], enabled: Bool) -> NSMenuItem {
        let current = InspectorSelectionSummary.commonValue(markups.map(\.lineStyle))
        let offersCloud = markups.allSatisfy { InspectorPanel.drawsCloudStyle($0.kind) }
        let submenu = NSMenu()
        for style in MarkupLineStyle.allCases where style != .cloud || offersCloud {
            let item = ContextMenuItem(title: style.displayName) { [weak self] in
                self?.applyContextStyle(MarkupStyleEdit(lineStyle: style), to: markups)
            }
            item.state = current == style ? .on : .off
            submenu.addItem(item)
        }
        return Self.parent(NSLocalizedString("Line Style", comment: "Canvas context menu submenu"), submenu, enabled: enabled)
    }

    private func lineEndSubmenu(start: Bool, markups: [MarkupSummary], enabled: Bool) -> NSMenuItem {
        let current = InspectorSelectionSummary.commonValue(markups.map { (start ? $0.startCap : $0.endCap) ?? .none })
        let submenu = NSMenu()
        for cap in MarkupLineCap.offered {
            let item = ContextMenuItem(title: cap.displayName) { [weak self] in
                self?.applyContextStyle(start ? MarkupStyleEdit(startCap: cap) : MarkupStyleEdit(endCap: cap), to: markups)
            }
            item.state = current == cap ? .on : .off
            submenu.addItem(item)
        }
        return Self.parent(
            start
                ? NSLocalizedString("Line Start", comment: "Canvas context menu submenu: decoration at the start of a line")
                : NSLocalizedString("Line End", comment: "Canvas context menu submenu: decoration at the end of a line"),
            submenu,
            enabled: enabled
        )
    }

    private func statusSubmenu(ids: Set<UUID>, markups: [MarkupSummary], enabled: Bool) -> NSMenuItem {
        let current = InspectorSelectionSummary.commonValue(markups.map(\.status))
        let submenu = NSMenu()
        for status in MarkupStatus.allCases {
            let item = ContextMenuItem(title: status.displayName) { [weak self] in
                guard let self else { return }
                let core = self.core
                Task { @MainActor in
                    let receipt = await core.applyBulkEdit(LedgerBulkEditRequest(
                        markupIDs: ids,
                        values: [.status: .text(status.rawValue)]
                    ))
                    if let failure = receipt.failureDescription {
                        ZenitPDFProjectDocument.reportRefusedEdit(MarkupClipboardRefusal(message: failure), core: core)
                    }
                }
            }
            item.state = current == status ? .on : .off
            submenu.addItem(item)
        }
        return Self.parent(NSLocalizedString("Status", comment: "Canvas context menu submenu: review status"), submenu, enabled: enabled)
    }

    // MARK: Doors

    /// One style change to the selection through the bulk-edit bus, remembered as the tools'
    /// style exactly as an Inspector edit is.
    func applyContextStyle(_ edit: MarkupStyleEdit, to markups: [MarkupSummary]) {
        let core = self.core
        if markups.contains(where: { ZenitToolMode.isDrawable($0.kind) }) {
            markupDocument?.shell?.toolbar.rememberStyle(edit, kinds: Set(markups.map(\.kind)))
        }
        Task { @MainActor in
            let receipt = await core.applyBulkEdit(LedgerBulkEditRequest(markupIDs: Set(markups.map(\.id)), style: edit))
            if let failure = receipt.failureDescription {
                ZenitPDFProjectDocument.reportRefusedEdit(MarkupClipboardRefusal(message: failure), core: core)
            }
        }
    }

    /// A row for an application command: its title, shortcut and enablement from the table.
    func appItem(_ command: ZenitAppCommand) -> NSMenuItem {
        let spec = ZenitAppCommandTable.spec(for: command)
        let item = ContextMenuItem(title: spec.title, key: spec.keyEquivalent?.key ?? "", modifiers: spec.keyEquivalent?.modifiers) { [weak self] in
            guard let self, let controller = self.markupWindowController else { return }
            ZenitAppCommandTable.perform(command, controller: controller, document: self.markupDocument)
        }
        if let controller = markupWindowController {
            item.isEnabled = ZenitAppCommandTable.validate(command, item: item, state: ZenitAppCommandWindowState(controller: controller))
        } else {
            item.isEnabled = false
        }
        return item
    }

    /// A row for a shell command: its title from the shell's table, run through the canvas's
    /// shell door.
    private func shellItem(_ id: ZPDFCommandID) -> NSMenuItem {
        let title = markupDocument?.shell?.commands.command(id)?.title ?? id.rawValue
        return ContextMenuItem(title: title) { [weak self] in self?.onShellCommand?(id) }
    }

    private static func parent(_ title: String, _ submenu: NSMenu, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        submenu.title = title
        item.isEnabled = enabled
        return item
    }

    /// A small round swatch of a palette ink, for a menu row. The row's title names the colour,
    /// so it is never colour-only.
    static func swatch(_ color: ColorRGBA) -> NSImage {
        let side: CGFloat = 12
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let ink = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
            ink.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.accessibilityDescription = nil
        return image
    }
}

/// The rules the context menu reads, pure so they are testable.
enum MarkupContextMenuRules {

    /// The widths the Line Width submenu offers, in points.
    static let lineWidths: [Double] = [0.5, 1, 1.5, 2, 3, 4, 6, 9]

    /// "1.5 pt".
    static func widthTitle(_ width: Double) -> String {
        let number = width.rounded() == width ? String(Int(width)) : String(width)
        return String(format: NSLocalizedString("%@ pt", comment: "A line width in points, e.g. 1.5 pt"), number)
    }

    /// Whether the markup has an interior a fill colours — the Inspector's rule.
    static func acceptsFill(_ markup: MarkupSummary) -> Bool {
        if let tool = markup.measurementKind {
            switch tool {
            case .area, .rectangleArea, .ellipseArea, .trueSlopedArea, .volume, .perimeter: return true
            default: return false
            }
        }
        return [.rectangle, .ellipse, .polygon, .cloud, .callout, .stamp].contains(markup.kind)
    }
}

/// A menu row that runs a closure. The row is its own target, and the menu keeps the row.
@MainActor
final class ContextMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(
        title: String,
        key: String = "",
        modifiers: NSEvent.ModifierFlags? = nil,
        enabled: Bool = true,
        handler: @escaping @MainActor () -> Void
    ) {
        self.handler = handler
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: key)
        if let modifiers { keyEquivalentModifierMask = modifiers }
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not coded") }

    @objc private func fire(_ sender: Any?) { handler() }
}
