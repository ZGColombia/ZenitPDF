import AppKit
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFUIPresentation
import ZPDFUIShell

/// The nl-markup window-level hooks, in one place so the big window controller carries a
/// single call (`wireNextLevelMarkup`).
extension ProjectWindowController {

    func wireNextLevelMarkup(shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) {
        // NL-MARKUP-04: every window's markup tools read one per-kind style table, kept in the
        // process defaults (the standard defaults in the shipping app, memory in a test).
        shell.toolbar.styleDefaults = MarkupStyleDefaultsHost.shared
        // The markup presenter is armed by the canvas from the toolbar's selection, and the
        // canvas used to hear of a change only through its observation chain, which starts
        // when its view first appears. A tool chosen before that — or in a window that is never
        // shown, as in every app-tier test — lit the chip and armed nothing. The canvas now
        // hears the change directly as well; applying twice is a no-op (`appliedSelection`).
        let previous = shell.toolbar.onSelectionChange
        shell.toolbar.onSelectionChange = { [weak self, weak document] selection in
            previous?(selection)
            guard let self, let document else { return }
            // The page view's routing flags with it, so the very next press is routed by the
            // tool just chosen (L-36b).
            self.canvasController(for: document)?.applyArmedTool()
        }
        wireMarkupRound2(shell: shell, document: document)
        wireMarkupLayers(shell: shell, document: document)   // ADR-0032 (r2-layers)
    }

    /// r2-markup: the Inspector's Link, Group and Ungroup, and the palette's project colours.
    func wireMarkupRound2(shell: ProjectShellEnvironment, document: ZenitPDFProjectDocument) {
        shell.inspectorEditing.onEditLink = { [weak self, weak document] markupID in
            guard let core = document?.core else { return }
            core.canvas.select(markupIDs: [markupID], additive: false)
            MarkupRound2Actions.editLink(core, window: self?.window)
        }
        shell.inspectorEditing.onGroup = { [weak document] markupIDs in
            guard let core = document?.core else { return }
            core.canvas.select(markupIDs: markupIDs, additive: false)
            MarkupRound2Actions.group(core)
        }
        shell.inspectorEditing.onUngroup = { [weak document] markupIDs in
            guard let core = document?.core else { return }
            core.canvas.select(markupIDs: markupIDs, additive: false)
            MarkupRound2Actions.ungroup(core)
        }
        // NL-UX-15: image files dropped on a project's sheet become image markups; ⌥ keeps the
        // old meaning (open the image as a scanned sheet).
        // The canvas is registered after the window's wiring runs, so these are installed one
        // main-actor turn later, once it exists.
        Task { @MainActor [weak self, weak document] in
            guard let self, let document, let canvas = self.canvasController(for: document) else { return }
            canvas.enablePresetDrops()
            canvas.contentDropBehavior = { [weak document] urls, optionHeld in
                Self.imageDropBehavior(urls: urls, optionHeld: optionHeld, document: document)
            }
        }
        wireToolLibraryDock(shell: shell, document: document)
        // NL-UX-19: the status strip's Scale menu sets a drawing ratio as one undo step.
        shell.onApplyScaleRatio = { [weak document] denominator in
            guard let core = document?.core else { return }
            Self.applyScaleRatio(denominator, core: core)
        }
        shell.projectColours = { [weak document] in
            ZPDFColourPalette.projectColours(from: document?.core?.snapshot.markups.map(\.colorRGBA) ?? [])
        }
    }
}

/// The one per-kind tool style table of the process (NL-MARKUP-04).
@MainActor
enum MarkupStyleDefaultsHost {
    static let shared = MarkupStyleDefaults(store: ZenitProcessDefaults.layout)
}

extension ProjectWindowController {

    /// Whether a drop of `urls` places images (NL-UX-15): every file an image, a project with a
    /// drawing to place them on, and no ⌥. `nil` leaves the drop to its usual behaviour.
    static func imageDropBehavior(urls: [URL], optionHeld: Bool, document: ZenitPDFProjectDocument?) -> CanvasDropBehavior? {
        guard !optionHeld, !urls.isEmpty, let document, document.projectPackage != nil, document.drawing != nil,
              urls.allSatisfy({ MarkupRound2Actions.imageTypes.contains($0.pathExtension.lowercased()) })
        else { return nil }
        return .placeImages
    }

    /// Places each dropped image at the drop point, the next ones 20 pt down and right.
    func placeDroppedImages(_ urls: [URL], document: ZenitPDFProjectDocument) -> Bool {
        let origin = canvasController(for: document)?.lastDropPagePoint
        Task { @MainActor in
            for (index, url) in urls.enumerated() {
                let point = origin.map { PDFPointValue(x: $0.x + Double(index) * 20, y: $0.y - Double(index) * 20) }
                if let failure = await MarkupRound2Actions.insertImage(from: url, at: point, document: document) {
                    document.core?.status.setActiveToolNote(failure)
                }
            }
        }
        return true
    }

    /// Sets the page on screen to 1:`denominator` through the preset-scale command (NL-UX-19).
    static func applyScaleRatio(_ denominator: Int, core: AppCoreEnvironment) {
        let page = PageID(core.canvas.viewport.pageID)
        Task { @MainActor in
            do {
                _ = try await core.commands.setPresetScale(page: page, ratioDenominator: Decimal(denominator))
            } catch {
                core.status.setActiveToolNote(String(describing: error))
            }
        }
    }
}
