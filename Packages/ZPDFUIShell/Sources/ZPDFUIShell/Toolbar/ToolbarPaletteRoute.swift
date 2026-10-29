import AppKit

extension ProjectShellEnvironment {

    /// Opens a palette chip's list — Measure, Count or Shapes — hung under its chip in the top
    /// band (L-100). The chip's indicator and a press held on the chip both come here.
    ///
    /// The list is the band's `NSMenu`, built fresh from the toolbar model by the same
    /// ``ZenitToolbarBuilder/paletteMenuItems(_:)`` the More menu's palette submenus use, so the
    /// three ways to reach a palette list one set of rows.
    func openToolbarPalette(_ palette: ZenitToolChip.Palette) {
        layoutController?.topBand?.popUpPalette(palette)
        // The menu tracked the release itself: no chip is held down or hovered any more.
        toolbar.chipPointer.settle()
    }
}

extension ProjectTopBandView {

    /// The band item a palette chip stands for.
    static func identifier(for palette: ZenitToolChip.Palette) -> NSToolbarItem.Identifier {
        switch palette {
        case .measure: return .zenitMeasure
        case .count: return .zenitCount
        case .shapes: return .zenitShapes
        }
    }

    /// Opens `palette`'s list under its chip, or under the More chip when the chip has moved
    /// into it. Returns `false`, and opens nothing, when the band shows neither.
    @discardableResult
    func popUpPalette(_ palette: ZenitToolChip.Palette) -> Bool {
        let menu = NSMenu(title: palette.menuTitle)
        menu.autoenablesItems = false
        for item in paletteBuilder.paletteMenuItems(palette) { menu.addItem(item) }
        return popUpMenu(menu, under: Self.identifier(for: palette))
    }
}

extension ZenitToolChip.Palette {
    /// The list's title, for the menu's accessibility.
    var menuTitle: String {
        switch self {
        case .measure: return NSLocalizedString("Measure", comment: "Toolbar item")
        case .count: return NSLocalizedString("Count", comment: "Toolbar item")
        case .shapes: return NSLocalizedString("Shapes", comment: "Toolbar item")
        }
    }
}
