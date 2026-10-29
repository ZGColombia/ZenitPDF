import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Design round d4: the Navigator restyled after the 2026-09-23 main-window mockup — the filled
/// tab strip, the file header with its ⋯ menu, and the page cards (thumbnail left, number and a
/// second line right, ⋯ menu, the page on screen framed in the accent).
///
/// Everything here is pinned as values (the paint of each state, the menu items and the command
/// each one runs, the card's words), plus one off-screen render that proves the column draws
/// without a window. No test puts anything on screen.
@MainActor
@Suite("Design d4 — Navigator", .shellTierSerialised)
struct DesignD4NavigatorTests {

    // MARK: - Fixtures

    private func page(
        index: Int,
        label: String,
        width: Double = 2592,
        height: Double = 1728,
        sheetTitle: String? = nil
    ) -> PageDescriptor {
        let box = PDFRectValue(origin: PDFPointValue(x: 0, y: 0), size: PDFSizeValue(width: width, height: height))
        return PageDescriptor(
            id: UUID(), index: index, label: label, mediaBox: box, cropBox: box,
            rotation: .degrees0, sheetTitle: sheetTitle
        )
    }

    @Test("An outline-titled page shows its sheet title on the card's second line")
    func outlineTitledCard() {
        let titled = page(index: 0, label: "1", sheetTitle: PageDescriptor.resolvedSheetTitle(
            outlineTitle: "A1.01 - Floor Plan", label: "1"
        ))
        #expect(NavigatorPageCard.title(for: titled) == "1")
        #expect(NavigatorPageCard.subtitle(for: titled, usesMetric: false) == "A1.01 - Floor Plan")
        #expect(NavigatorPageCard.accessibilityLabel(for: titled, pageCount: 6) == "Page 1 of 6, A1.01 - Floor Plan")
        // A named label the document also defines wins over the outline title.
        let both = page(index: 0, label: "A-101", sheetTitle: PageDescriptor.resolvedSheetTitle(
            outlineTitle: "Floor Plan", label: "A-101"
        ))
        #expect(NavigatorPageCard.subtitle(for: both, usesMetric: false) == "A-101")
    }

    @Test("A page without a sheet title falls back to its own label, then to the sheet size")
    func untitledCardFallsBack() {
        let noOutline = page(index: 1, label: "3", sheetTitle: PageDescriptor.resolvedSheetTitle(outlineTitle: nil, label: "3"))
        #expect(noOutline.sheetTitle == nil)
        #expect(NavigatorPageCard.subtitle(for: noOutline, usesMetric: false) == "ARCH D · 36 × 24 in")
        #expect(NavigatorPageCard.accessibilityLabel(for: noOutline, pageCount: 6) == "Page 2 of 6")
        // Blank titles count as absent; a descriptor built before titles existed keeps its label.
        #expect(NavigatorPageCard.subtitle(for: page(index: 0, label: "A-101", sheetTitle: "  "), usesMetric: false) == "A-101")
        #expect(NavigatorPageCard.subtitle(for: page(index: 0, label: "A-101"), usesMetric: false) == "A-101")
    }

    // MARK: - Tab strip

    /// Polish round (d9 QA): the strip is the mockup's four segments at
    /// ~13 pt, whatever is open. This test used to expect Drawings as a fifth, leading segment
    /// with two drawings open; five segments forced the labels down to ~10 pt, so Open Drawings
    /// moved into the file header's ⋯ menu. It stays a section the Navigator shows
    /// (`offeredSections`), just not a segment.
    @Test("The strip is always the mockup's four segments at 13 pt; Open Drawings is reached from the file menu")
    func tabOrder() {
        #expect(NavigatorSidebar.segments.map(\.switcherTitle) == ["Pages", "Layers", "Zones", "Search"])
        #expect(!NavigatorSidebar.segments.contains(.drawings))
        #expect(NavigatorStyle.segmentLabelSize == 13)
        // Still a section the Navigator can show once there is a second drawing to list.
        #expect(NavigatorSidebar.offeredSections(forOpenDrawings: 2).contains(.drawings))
        #expect(NavigatorFileAction.offered(openDrawings: 2).first == .showOpenDrawings)
        #expect(NavigatorDrawingsHeader.backTitle == "Back to Pages")
    }

    @Test("The file header keeps the whole name in its tooltip and lists the other drawings to switch to")
    func fileHeaderTooltipAndSwitching() {
        #expect(NavigatorFileHeader.tooltip(title: "Sample Block — Office Fit-Out", fileName: "SB-Office.pdf")
                == "Sample Block — Office Fit-Out — SB-Office.pdf")
        #expect(NavigatorFileHeader.tooltip(title: "A1.01.pdf", fileName: "A1.01.pdf") == "A1.01.pdf")
        #expect(NavigatorFileHeader.tooltip(title: "A1.01", fileName: nil) == "A1.01")
        let environment = ProjectShellEnvironment.mock()
        let others = NavigatorFileHeader.otherDrawings(in: environment.document)
        #expect(others.count == environment.document.tabs.count - 1)
        #expect(!others.contains { $0.id == environment.document.activeTabID })
    }

    @Test("The selected tab is filled, underlined in the accent and semibold; the others are flat")
    func selectedTabPaint() {
        let selected = NavigatorSwitcher.tabAppearance(isSelected: true, isHovered: false)
        #expect(selected.base == .selectedFill, "the mockup's filled Pages tab")
        #expect(selected.underline == .accentBlue, "the mockup's underline is the accent on chrome")
        #expect(selected.text == .textPrimary)
        #expect(selected.isEmphasised)

        let idle = NavigatorSwitcher.tabAppearance(isSelected: false, isHovered: false)
        #expect(idle.base == nil && idle.tint == nil && idle.underline == nil)
        #expect(idle.text == .textSecondary)
        #expect(!idle.isEmphasised)

        // Hover answers the pointer without looking selected: no underline, no raised ground.
        let hovered = NavigatorSwitcher.tabAppearance(isSelected: false, isHovered: true)
        #expect(hovered.tint == .stateHover)
        #expect(hovered.underline == nil && hovered.base == nil)
        #expect(hovered.text == .textPrimary)
    }

    // MARK: - Page card words

    @Test("A card's first line is the page's position; the second is the document's own label")
    func cardWordsWithOwnLabel() {
        let named = page(index: 0, label: "A-101")
        #expect(NavigatorPageCard.title(for: named) == "1")
        #expect(NavigatorPageCard.subtitle(for: named, usesMetric: false) == "A-101")
        #expect(NavigatorPageCard.hasOwnLabel(named))
    }

    @Test("Without an own label the second line is the sheet size, named when it is a standard sheet")
    func cardWordsWithSheetSize() {
        // ARCH D landscape, 36 × 24 in.
        let archD = page(index: 2, label: "3")
        #expect(NavigatorPageCard.title(for: archD) == "3")
        #expect(!NavigatorPageCard.hasOwnLabel(archD), "an all-digit label is the numeric fallback")
        #expect(NavigatorPageCard.subtitle(for: archD, usesMetric: false) == "ARCH D · 36 × 24 in")
        #expect(NavigatorPageCard.subtitle(for: archD, usesMetric: true) == "ARCH D · 914 × 610 mm")

        // A1 portrait within CAD rounding, and a size with no standard name.
        #expect(NavigatorPageCard.standardSheetName(PDFSizeValue(width: 1684, height: 2384)) == "A1")
        let odd = PDFSizeValue(width: 1000, height: 500)
        #expect(NavigatorPageCard.standardSheetName(odd) == nil)
        #expect(NavigatorPageCard.sheetSizeText(odd, usesMetric: true) == "353 × 176 mm")
    }

    @Test("The sheet keeps its proportions inside the card's thumbnail box")
    func sheetFit() {
        let box = NavigatorStyle.thumbnailSize
        let landscape = NavigatorPageThumbnail.sheetSize(for: page(index: 0, label: "1"))
        #expect(landscape.width == box.width)
        #expect(landscape.height <= box.height)
        let portrait = NavigatorPageThumbnail.sheetSize(for: page(index: 0, label: "1", width: 612, height: 792))
        #expect(portrait.height == box.height)
        #expect(portrait.width < box.width)
        // A pathological strip is clamped, never drawn as a line.
        let strip = NavigatorPageThumbnail.sheetSize(for: page(index: 0, label: "1", width: 10_000, height: 100))
        #expect(strip.height >= box.width / 2.2 - 1)
    }

    // MARK: - Page card paint

    @Test("The page on screen is raised and framed in a 2 pt accent border, as in the mockup")
    func currentCardPaint() {
        let current = NavigatorPageCard.appearance(isCurrent: true, isSelected: false, isHovered: false)
        #expect(current.base == .elevated, "raised: the selected page card's surface")
        #expect(current.border == .accentBlue, "state lines use accentBlue: accent as a line fails 3:1 on surface")
        #expect(current.borderWidth == 2)
        // The hairline under a card: `NavigatorPagesList.showsSeparator(after:highlighted:)`,
        // asserted in `separators` — the card paint's own copy was deleted (R-092).
        // Current wins over merely selected.
        #expect(NavigatorPageCard.appearance(isCurrent: true, isSelected: true, isHovered: true) == current)
    }

    @Test("Current, selected and plain cards differ by border weight, not colour alone")
    func cardStatesSurviveGreyscale() {
        let current = NavigatorPageCard.appearance(isCurrent: true, isSelected: false, isHovered: false)
        let selected = NavigatorPageCard.appearance(isCurrent: false, isSelected: true, isHovered: false)
        let plain = NavigatorPageCard.appearance(isCurrent: false, isSelected: false, isHovered: false)
        #expect(current.borderWidth > selected.borderWidth)
        #expect(selected.borderWidth > plain.borderWidth)
        #expect(plain.border == nil && plain.base == nil && plain.tint == nil)
        // VoiceOver hears the same three states in words.
        #expect(NavigatorPageThumbnail.stateText(isCurrent: true, isSelected: false) == "Showing")
        #expect(NavigatorPageThumbnail.stateText(isCurrent: false, isSelected: true) == "Selected")
    }

    @Test("Hover is a faint wash on a plain card and nothing more")
    func hoverPaint() {
        let hovered = NavigatorPageCard.appearance(isCurrent: false, isSelected: false, isHovered: true)
        #expect(hovered.tint == .stateHover, "the design system's hover overlay")
        #expect(hovered.base == nil)
        #expect(hovered.border == nil, "hover must not look like selection")
    }

    @Test("Card hairlines run only between two flat cards, never into a framed one")
    func separators() {
        // Cards 0 and 1 flat, 2 current, 3 flat.
        let highlighted = [false, false, true, false]
        #expect(NavigatorPagesList.showsSeparator(after: 0, highlighted: highlighted))
        #expect(!NavigatorPagesList.showsSeparator(after: 1, highlighted: highlighted))
        #expect(!NavigatorPagesList.showsSeparator(after: 2, highlighted: highlighted))
        #expect(!NavigatorPagesList.showsSeparator(after: 3, highlighted: highlighted), "no rule under the last card")
        #expect(!NavigatorPagesList.showsSeparator(after: 0, highlighted: []))
    }

    // MARK: - Page card ⋯ menu

    @Test("The page menu offers real commands only, and names what it does to this page")
    func pageMenuTitles() {
        #expect(NavigatorPageAction.allCases == [.show, .toggleSelection, .fitPage, .fitWidth, .calibrate, .scaleRegions])
        #expect(NavigatorPageAction.title(for: .toggleSelection, isSelected: false) == "Add to Selection")
        #expect(NavigatorPageAction.title(for: .toggleSelection, isSelected: true) == "Remove from Selection")
        for action in NavigatorPageAction.allCases {
            #expect(!NavigatorPageAction.title(for: action, isSelected: false).isEmpty)
        }
        #expect(NavigatorPageAction.menuLabel(for: page(index: 2, label: "3")) == "Page 3 options")
        // S-057 (iteration 2): the hint names the page as the label does — its place — then the
        // sheet's own label. It said "P1", the text of a badge the card no longer draws.
        #expect(NavigatorPageAction.menuHint(for: page(index: 0, label: "1")) == "Actions for page 1")
        #expect(NavigatorPageAction.menuHint(for: page(index: 0, label: "A-101")) == "Actions for page 1, A-101")
        // The card itself: number and count, then the sheet's own name when there is one.
        #expect(NavigatorPageCard.accessibilityLabel(for: page(index: 0, label: "A-101"), pageCount: 3) == "Page 1 of 3, A-101")
        #expect(NavigatorPageCard.accessibilityLabel(for: page(index: 1, label: "2"), pageCount: 3) == "Page 2 of 3")
    }

    @Test("Every page-menu item turns to its page, then runs the command it names")
    func pageMenuPerforms() throws {
        let environment = ProjectShellEnvironment.mock()
        var forwarded: [ZPDFCommandID] = []
        environment.externalCommandHandler = { forwarded.append($0) }
        let pages = environment.document.pages
        try #require(pages.count >= 2)
        let target = pages[1]

        NavigatorPageAction.show.perform(pageID: target.id, in: environment)
        #expect(environment.document.currentPageID == target.id)

        environment.selectPage(id: pages[0].id, mode: .replace)
        NavigatorPageAction.fitPage.perform(pageID: target.id, in: environment)
        #expect(environment.document.currentPageID == target.id)

        environment.selectPage(id: pages[0].id, mode: .replace)
        NavigatorPageAction.calibrate.perform(pageID: target.id, in: environment)
        #expect(environment.document.currentPageID == target.id)
        #expect(forwarded.contains(.calibrateScale), "Calibrate reaches the app tier's calibration flow")

        NavigatorPageAction.toggleSelection.perform(pageID: pages[0].id, in: environment)
        #expect(environment.document.selectedPageIDs.contains(pages[0].id))
    }

    // MARK: - File header

    @Test("The file header names the active drawing and hides with no drawing open")
    func fileHeaderTitle() {
        let environment = ProjectShellEnvironment.mock()
        let active = environment.document.tabs.first { $0.id == environment.document.activeTabID }
        #expect(NavigatorFileHeader.title(for: environment.document) == active?.title)
        #expect(NavigatorFileAction.menuLabel == "Document Options")
        #expect(NavigatorFileAction.menuHint(for: "A1.01.pdf") == "Actions for A1.01.pdf")
    }

    @Test("The file menu runs the File commands; Open Drawings appears only with two drawings open")
    func fileMenu() {
        #expect(NavigatorFileAction.offered(openDrawings: 1) == [.save, .saveAs, .export, .print, .close])
        #expect(NavigatorFileAction.offered(openDrawings: 3) == [.showOpenDrawings, .save, .saveAs, .export, .print, .close])
        #expect(NavigatorFileAction.save.command == .save)
        #expect(NavigatorFileAction.saveAs.command == .saveAs)
        #expect(NavigatorFileAction.export.command == .export)
        #expect(NavigatorFileAction.print.command == .print)
        #expect(NavigatorFileAction.close.command == .closeTab)
        #expect(NavigatorFileAction.showOpenDrawings.command == nil)

        let environment = ProjectShellEnvironment.mock()
        var forwarded: [ZPDFCommandID] = []
        environment.externalCommandHandler = { forwarded.append($0) }
        let panelState = ShellPanelState()
        NavigatorFileAction.save.perform(in: environment, panelState: panelState)
        NavigatorFileAction.export.perform(in: environment, panelState: panelState)
        #expect(forwarded == [.save, .export])
        NavigatorFileAction.showOpenDrawings.perform(in: environment, panelState: panelState)
        #expect(panelState.navigatorSection == .drawings)
    }

    // MARK: - Tokens

    @Test("The Navigator paints with design-system tokens, each with a dark and a light value")
    func tokensHaveBothAppearances() {
        // `accent` is the one fill the mockup keeps identical in both appearances (d1: the same
        // blue reads on light chrome), so it is checked for presence, not for a light variant.
        let tokens: [ZPDFColorToken] = [
            NavigatorStyle.chromeFill, NavigatorStyle.panelFill, NavigatorStyle.raisedFill,
            NavigatorStyle.selectedTabFill, NavigatorStyle.hairline, NavigatorStyle.indicator
        ]
        for token in tokens {
            let set = ZPDFColor.set(for: token)
            #expect(set.light != set.dark, "\(token) must differ between light and dark")
        }
        // The panel stands off the chrome in both appearances.
        #expect(ZPDFColor.rgba(NavigatorStyle.panelFill, .dark) != ZPDFColor.rgba(NavigatorStyle.chromeFill, .dark))
        #expect(ZPDFColor.rgba(NavigatorStyle.panelFill, .light) != ZPDFColor.rgba(NavigatorStyle.chromeFill, .light))
    }

    @Test("No Navigator source file carries a raw colour literal")
    func noRawColourLiterals() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()           // ZPDFUIShellTests
            .deletingLastPathComponent()           // Tests
            .deletingLastPathComponent()           // ZPDFUIShell
            .appendingPathComponent("Sources/ZPDFUIShell/Navigator")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        try #require(!files.isEmpty)
        let forbidden = ["Color(red", "Color(.sRGB", "Color.white", "Color.black", "Color.blue", "Color.gray",
                         "NSColor(red", "NSColor(srgbRed", "NSColor(calibratedRed", "Color(hex"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for literal in forbidden {
                #expect(!text.contains(literal), "\(file.lastPathComponent) contains \(literal)")
            }
        }
    }

    // MARK: - Off-screen render

    @Test("The restyled Navigator draws off screen in dark and light, on every tab, without a window")
    func rendersOffScreen() throws {
        let environment = ProjectShellEnvironment.mock()
        let output = ProcessInfo.processInfo.environment["ZENIT_DESIGN_QA_OUT"]
        for section in NavigatorSection.allCases {
            for name in ["DarkAqua", "Aqua"] {
                let appearance = try #require(NSAppearance(named: NSAppearance.Name(name)))
                let panelState = ShellPanelState()
                panelState.navigatorSection = section
                let host = NSHostingView(rootView: NavigatorSidebar(environment: environment, panelState: panelState)
                    .frame(width: 272, height: 760)
                    .environment(\.colorScheme, name == "Aqua" ? .light : .dark))
                host.appearance = appearance
                host.frame = NSRect(x: 0, y: 0, width: 272, height: 760)
                host.layoutSubtreeIfNeeded()
                #expect(host.window == nil, "the render must never touch a window")
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                // Dynamic token colours resolve against the drawing appearance, which a view
                // outside a window only has while it is made current.
                appearance.performAsCurrentDrawingAppearance {
                    host.cacheDisplay(in: host.bounds, to: rep)
                }
                #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
                // Pixels for a human reviewer, only when asked for (the d9 harness's switch).
                if let output, let png = rep.representation(using: .png, properties: [:]) {
                    let url = URL(fileURLWithPath: output, isDirectory: true)
                        .appendingPathComponent("d4-navigator-\(section.rawValue)-\(name == "Aqua" ? "light" : "dark").png")
                    try png.write(to: url)
                }
            }
        }
    }

    @Test("An open-drawing card counts its pages in words")
    func drawingCardPageCount() {
        #expect(NavigatorDrawingsList.pageCountText(1) == "1 page")
        #expect(NavigatorDrawingsList.pageCountText(6) == "6 pages")
    }

    @Test("Tabs share the strip in proportion to their labels and scale together when it is tight")
    func tabStripWidths() {
        // Room to spare: each tab gets its label plus an equal share of the rest.
        let roomy = NavigatorTabStripLayout.widths(ideal: [50, 40, 40, 44], available: 240, spacing: 2)
        #expect(abs(roomy.reduce(0, +) - (240 - 6)) < 0.001)
        #expect(roomy[0] - roomy[1] == 10, "the difference between labels is kept, the extra is shared")
        // Too tight for five labels: everything scales by one factor, nothing is dropped.
        let tight = NavigatorTabStripLayout.widths(ideal: [66, 50, 52, 50, 56], available: 220, spacing: 2)
        #expect(tight.count == 5)
        #expect(abs(tight.reduce(0, +) - (220 - 8)) < 0.001)
        #expect(tight[0] > tight[1], "the longest label keeps the widest tab")
        #expect(NavigatorTabStripLayout.widths(ideal: [], available: 100, spacing: 2).isEmpty)
    }
}
