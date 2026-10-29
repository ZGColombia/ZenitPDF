import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// A status presenter over a fixed list of warnings, for the warning tray.
@MainActor
@Observable
final class LiveTest5TrayStatus: StatusPresenting {
    var snapshot: StatusBarSnapshot = ZenitSampleProject.shared.statusBar
    var warnings: [AppWarning]
    init(_ warnings: [AppWarning]) { self.warnings = warnings }
    func setGridSnapEnabled(_ enabled: Bool) {}
    func setVectorSnapEnabled(_ enabled: Bool) {}
    func setMarkupSnapEnabled(_ enabled: Bool) {}
    func setReuseToolEnabled(_ enabled: Bool) {}
    func setActiveTool(name: String, note: String?) {}
    func dismissWarning(id: AppWarning.ID) { warnings.removeAll { $0.id == id } }
    func dismissAllWarnings() { warnings.removeAll(where: \.isDismissible) }
}

/// The three drawings of live test 5, the middle one with unsaved work (the live "• ...").
@MainActor
private func liveTest5Tabs() -> DocumentTabBarInput {
    let tabs = [
        DocumentTabSummary(id: UUID(), title: "Plan-A", fileName: "Plan-A.pdf", pageCount: 1),
        DocumentTabSummary(id: UUID(), title: "Plan-B", fileName: "Plan-B.zpdfproj", pageCount: 2, hasUnsavedChanges: true),
        DocumentTabSummary(id: UUID(), title: "Scan-C", fileName: "Scan-C.pdf", pageCount: 1)
    ]
    return DocumentTabBarInput(tabs: tabs, activeTabID: tabs[1].id, revisions: [])
}

/// A configured project window at one width over `environment`, laid out but never ordered on
/// screen.
@MainActor
private func makeLiveTest5Window(
    width: CGFloat,
    key: String,
    environment: ProjectShellEnvironment = .mock()
) -> (ProjectWindowLayoutController, ZPDFProjectWindow) {
    let layout = ProjectWindowLayoutController(
        environment: environment,
        store: ProjectWindowLayoutStore(defaults: ZPDFInMemoryDefaults(), key: key)
    )
    layout.presentDetachedLedgerWindow = { _ in }
    layout.detachedLedgerAutosaveName = ""
    layout.runCustomizationPalette = { _ in }
    let window = ZPDFProjectWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentViewController = layout
    layout.configure(window: window)
    window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: false)
    window.layoutIfNeeded()
    layout.view.layoutSubtreeIfNeeded()
    // One more turn settles anything the band's tab-row decision queued.
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    window.layoutIfNeeded()
    layout.view.layoutSubtreeIfNeeded()
    return (layout, window)
}

/// The natural width of a tab's title as the tab draws it, measured off screen.
@MainActor
private func naturalTitleWidth(_ item: DocumentTabItem) -> CGFloat {
    NSHostingView(rootView: DocumentTabView.titleText(item).fixedSize()).fittingSize.width
}

/// A rendered warning tray read back by pixel, in points from the top-left: where anything other
/// than the background is drawn (L-28). SwiftUI builds no accessibility tree for a hosting view
/// no assistive client has asked about, so the tray's captions and cards are found by their ink.
/// Raw bytes are compared with raw bytes of the same bitmap, so no colour conversion can shift
/// one side and not the other. Shared with ``L32WarningTrayPopoverSizeTests``.
@MainActor
struct TrayInk {
    let bitmap: NSBitmapImageRep
    let scale: CGFloat
    let size: CGSize
    private let background: [Int]

    init(_ bitmap: NSBitmapImageRep) throws {
        try #require(!bitmap.isPlanar && bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel >= 3)
        self.bitmap = bitmap
        size = bitmap.size
        scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        // The top-left corner lies in the tray's padding: the background.
        background = Self.pixel(bitmap, 1, 1)
    }

    private static func pixel(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
        guard let data = bitmap.bitmapData else { return [] }
        let offset = y * bitmap.bytesPerRow + x * (bitmap.bitsPerPixel / 8)
        return (0..<3).map { Int(data[offset + $0]) }
    }

    private func isInked(px x: Int, _ y: Int) -> Bool {
        zip(Self.pixel(bitmap, x, y), background).contains { abs($0 - $1) > 8 }
    }

    private func pixels(_ range: ClosedRange<CGFloat>, limit: Int) -> ClosedRange<Int> {
        max(0, Int((range.lowerBound * scale).rounded(.down)))...min(limit - 1, Int((range.upperBound * scale).rounded(.up)) - 1)
    }

    /// Whether anything is drawn in the columns `columns` over the whole height.
    func isInked(columns: ClosedRange<CGFloat>) -> Bool {
        let xs = pixels(columns, limit: bitmap.pixelsWide)
        return (0..<bitmap.pixelsHigh).contains { y in xs.contains { isInked(px: $0, y) } }
    }

    /// Whether anything is drawn in the rows `rows` across the whole width.
    func isInked(rows: ClosedRange<CGFloat>) -> Bool {
        let ys = pixels(rows, limit: bitmap.pixelsHigh)
        return ys.contains { y in (0..<bitmap.pixelsWide).contains { isInked(px: $0, y) } }
    }

    /// The vertical runs, top down, of rows where anything is drawn between `columns`.
    func rowRuns(columns: ClosedRange<CGFloat>) -> [ClosedRange<CGFloat>] {
        let xs = pixels(columns, limit: bitmap.pixelsWide)
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?
        for y in 0...bitmap.pixelsHigh {
            let inked = y < bitmap.pixelsHigh && xs.contains { isInked(px: $0, y) }
            if inked, start == nil { start = y }
            if !inked, let first = start {
                runs.append(CGFloat(first) / scale...CGFloat(y) / scale)
                start = nil
            }
        }
        return runs
    }

    /// The leftmost point drawn in the rows `rows`, across the whole width.
    func leftmostInk(rows: ClosedRange<CGFloat>) -> CGFloat? {
        let ys = pixels(rows, limit: bitmap.pixelsHigh)
        for x in 0..<bitmap.pixelsWide where ys.contains(where: { isInked(px: x, $0) }) {
            return CGFloat(x) / scale
        }
        return nil
    }

    /// Where the drawing in the rows `rows` ends on the right.
    func rightmostInk(rows: ClosedRange<CGFloat>) -> CGFloat? {
        let ys = pixels(rows, limit: bitmap.pixelsHigh)
        for x in (0..<bitmap.pixelsWide).reversed() where ys.contains(where: { isInked(px: x, $0) }) {
            return CGFloat(x + 1) / scale
        }
        return nil
    }
}

/// The warning tray over `warnings`, hosted at `width` (its own ideal width when nil) and
/// `height` (when nil, the height it needs at that width), rendered off screen — no window — and
/// read back by pixel. L-32 passes the popover's own size (``WarningTrayPopoverSizing``).
@MainActor
func renderTray(
    _ warnings: [AppWarning],
    width: CGFloat? = nil,
    height: CGFloat? = nil,
    name: String,
    prepare: (NSHostingView<AnyView>) -> Void = { _ in }
) throws -> (ink: TrayInk, host: NSHostingView<AnyView>) {
    let root = AnyView(WarningTrayView(environment: warningTrayEnvironment(warnings))
        .background(ZPDFColor.surface)
        .environment(\.colorScheme, .dark))
    let host = NSHostingView(rootView: root)
    host.appearance = NSAppearance(named: .darkAqua)
    let hostWidth = width ?? host.fittingSize.width
    let hostHeight = height ?? NSHostingController(rootView: root)
        .sizeThatFits(in: CGSize(width: hostWidth, height: .greatestFiniteMagnitude)).height
    host.frame = CGRect(x: 0, y: 0, width: hostWidth, height: hostHeight)
    host.layoutSubtreeIfNeeded()
    prepare(host)
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let directory = ProcessInfo.processInfo.environment["LV5_RENDER_DIR"],
       let data = bitmap.representation(using: .png, properties: [:]) {
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
    return (try TrayInk(bitmap), host)
}

/// Every scroll view in `view`'s subtree.
@MainActor
func scrollViews(in view: NSView) -> [NSScrollView] {
    ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
}

/// Live test 5 (2026-10-03), the shell's rows L-24, L-28 and L-29. Headless: windows are built
/// and laid out, never ordered on screen; no menu is ever tracked.
@MainActor
@Suite("Live test 5 — tab names, notices, menus hung from their chips", .shellTierSerialised)
struct LiveTest5ShellTests {

    // MARK: - L-24: readable tab names

    @Test("L-24: a tab shows its name without the extension; tooltip and spoken label keep the full name")
    func tabTitleDropsExtension() {
        let items = DocumentTabBarModel.items(from: liveTest5Tabs())
        #expect(items.map(\.tabTitle) == ["Plan-A", "Plan-B", "Scan-C"])
        #expect(items.map(\.displayTitle) == ["Plan-A.pdf", "Plan-B.zpdfproj", "Scan-C.pdf"])
        for item in items {
            #expect(item.tooltip.split(separator: "\n").first.map(String.init) == item.displayTitle)
            #expect(item.accessibilityLabel.hasPrefix(item.displayTitle + ","), "\(item.accessibilityLabel)")
        }
        // A document with no file yet shows its title as it is: a title is not a file name.
        let untitled = DocumentTabItem(
            id: UUID(), title: "Block v1.2", fileName: " ", revisionLabel: nil,
            hasUnsavedChanges: false, isActive: false, pageCount: 1, mode: .project
        )
        #expect(untitled.tabTitle == "Block v1.2")
        // Only the last extension goes; a name that is only a dot-name stays whole.
        let dotted = DocumentTabItem(
            id: UUID(), title: "", fileName: "Plan.rev2.pdf", revisionLabel: nil,
            hasUnsavedChanges: false, isActive: false, pageCount: 1, mode: .standalonePDF
        )
        #expect(dotted.tabTitle == "Plan.rev2")
        let bare = DocumentTabItem(
            id: UUID(), title: "", fileName: ".pdf", revisionLabel: nil,
            hasUnsavedChanges: false, isActive: false, pageCount: 1, mode: .standalonePDF
        )
        #expect(bare.tabTitle == ".pdf")
    }

    @Test("L-24: the readable width holds about ten characters of a tab title")
    func readableWidthHoldsTenCharacters() {
        let tenCharacterNames = ["Plan-A-rev", "Takplan 12", "A-101 Roof", "Scan-C-002"]
        let room = DocumentTabMetrics.titleRoom(tabWidth: DocumentTabMetrics.readableWidth, hasUnsavedDot: false)
        let digitWidth = naturalTitleWidth(DocumentTabItem(
            id: UUID(), title: "0", fileName: "0.pdf", revisionLabel: nil,
            hasUnsavedChanges: false, isActive: true, pageCount: 1, mode: .standalonePDF
        ))
        for active in [false, true] {
            var widths: [CGFloat] = []
            for name in tenCharacterNames {
                #expect(name.count == 10)
                let item = DocumentTabItem(
                    id: UUID(), title: name, fileName: name + ".pdf", revisionLabel: nil,
                    hasUnsavedChanges: false, isActive: active, pageCount: 1, mode: .standalonePDF
                )
                let natural = naturalTitleWidth(item)
                widths.append(natural)
                print("lv5 L-24: ten characters \"\(name)\" (active \(active)) need \(natural) pt of \(room) pt")
                // About ten: no name loses more than one character's width.
                #expect(natural <= room + digitWidth, "\(name) (active \(active)) needs \(natural) pt, a readable tab gives \(room)")
            }
            let mean = widths.reduce(0, +) / CGFloat(widths.count)
            #expect(mean <= room, "ten average characters (active \(active)) take \(mean) pt, the readable room is \(room)")
        }
        // A real step up from the 72 pt floor, which stays for many documents (LT3-03).
        #expect(DocumentTabMetrics.readableWidth > DocumentTabMetrics.minimumWidth)
        #expect(DocumentTabMetrics.minimumWidth == 72)
    }

    /// Old output (live test 5, installed build): the strip had ~319 pt of the left column,
    /// every tab was 87 pt and a title had 33 pt (21 pt beside the unsaved dot): "Pl...df",
    /// "• ...", "S...df". On the old code this test's plan gives 87 pt tabs and a 33 pt title
    /// room against "Plan-A.pdf".
    @Test("L-24: three tabs at a 1 728 pt window each show their name, without extension, untruncated")
    func threeTabsReadableAtFullWidth() throws {
        let environment = ProjectShellEnvironment.mock()
        let input = liveTest5Tabs()
        environment.tabBar.source = { input }
        let (layout, window) = makeLiveTest5Window(width: 1_728, key: "lv5.tabs.1728", environment: environment)
        defer { window.close() }
        let band = try #require(layout.topBand)
        #expect(band.tabCount == 3)
        let items = environment.tabBar.items
        let available = band.tabsView.frame.width
        let plan = DocumentTabStripPlan.make(
            tabCount: items.count,
            activeIndex: items.firstIndex(where: \.isActive),
            available: available
        )
        print("lv5 L-24: 1728 window, wrapped \(band.tabsWrapped), strip \(available) pt, tab \(plan.tabWidth) pt")
        #expect(plan.visible == [0, 1, 2], "every drawing in the strip")
        #expect(plan.overflow.isEmpty)
        #expect(plan.tabWidth >= DocumentTabMetrics.readableWidth)
        for item in items {
            let room = DocumentTabMetrics.titleRoom(tabWidth: plan.tabWidth, hasUnsavedDot: item.hasUnsavedChanges)
            let natural = naturalTitleWidth(item)
            print("lv5 L-24: \(item.tabTitle) needs \(natural) pt of \(room) pt")
            #expect(!item.tabTitle.contains("."), "\(item.tabTitle) still carries its extension")
            #expect(natural <= room, "\(item.tabTitle) is truncated: needs \(natural) pt, has \(room) pt")
        }
        // The strip never runs under the tools: in their row it ends a group gap before them.
        if !band.tabsWrapped, let firstTool = band.centreEntries.first(where: { !$0.view.isHidden })?.view {
            #expect(band.tabsView.frame.maxX <= firstTool.frame.minX - ProjectTopBandView.groupGap + 0.5)
        }
    }

    @Test("L-24: the tab column reaches over the free chrome to the tools, never under them")
    func tabColumnUsesFreeWidth() throws {
        for width in [CGFloat(1_440), 1_672, 1_728, 2_000] {
            let (layout, window) = makeLiveTest5Window(width: width, key: "lv5.column.\(Int(width))")
            defer { window.close() }
            let band = try #require(layout.topBand)
            #expect(band.tabCount == 2, "the mock's two drawings")
            let firstTool = try #require(band.centreEntries.first(where: { !$0.view.isHidden })?.view)
            print("lv5 L-24: \(width) pt window, stage \(band.stage), wrapped \(band.tabsWrapped), tabs \(band.tabsView.frame), first tool \(firstTool.frame)")
            let plan = DocumentTabStripPlan.make(tabCount: 2, activeIndex: 0, available: band.tabsView.frame.width)
            #expect(plan.tabWidth >= DocumentTabMetrics.readableWidth, "width \(width): two tabs at \(plan.tabWidth) pt")
            if width >= 1_672 {
                // The mockup's single band: the tabs share the tools' row and run up to them.
                // Old output: the strip ended at the fixed ~300 pt left column whatever the width.
                #expect(!band.tabsWrapped, "two documents at \(width) pt keep the mockup's single band")
                #expect(abs(band.tabsView.frame.maxX - (firstTool.frame.minX - ProjectTopBandView.groupGap)) <= 0.5,
                        "width \(width): tabs \(band.tabsView.frame), first tool \(firstTool.frame)")
                #expect(band.tabsView.frame.maxX > ProjectTopBandView.fullLeftColumn)
            } else {
                // At 1 440 pt the brand has given way and the tools reach the 220 pt column; two
                // readable tabs do not fit before them (old output: two 76 pt tabs, 22 pt of
                // title each), so the tabs take their own row.
                #expect(band.tabsWrapped)
            }
        }
        // The pure rule: the left column is the least the tabs get; with no tool, the right group bounds it.
        #expect(ProjectTopBandView.tabColumnRight(left: 300, centreStart: 250, rightGroupStart: 900) == 300)
        #expect(ProjectTopBandView.tabColumnRight(left: 300, centreStart: 500, rightGroupStart: 900) == 500 - ProjectTopBandView.groupGap)
        #expect(ProjectTopBandView.tabColumnRight(left: 300, centreStart: nil, rightGroupStart: 900) == 900 - ProjectTopBandView.groupGap)
    }

    @Test("L-24: tabs that would drop under the readable width take their own row instead")
    func tabsWrapBeforeTheyTurnUnreadable() {
        // A column that holds two readable tabs does not hold three.
        let two = DocumentTabStripPlan.minimumStripWidth(tabCount: 2, tabWidth: DocumentTabMetrics.readableWidth)
            + ZPDFWindowChrome.gutter
        #expect(!ProjectTopBandView.tabsNeedOwnRow(tabCount: 2, leftColumn: two))
        #expect(ProjectTopBandView.tabsNeedOwnRow(tabCount: 3, leftColumn: two))
        // Old rule: three 72 pt tabs fit the 300 pt column, so they stayed there, unreadable.
        #expect(ProjectTopBandView.tabsNeedOwnRow(tabCount: 3, leftColumn: ProjectTopBandView.fullLeftColumn))
    }

    // MARK: - L-28: notices are not warnings; captions above their group

    static let scaleOffer = AppWarning(
        id: UUID(), severity: .info, title: "The drawing says 1:10.",
        message: "Found in the title block (KV 1:10 EXEMPELPARK). Apply it, or calibrate by hand as usual.",
        source: "Scale proposal", actionTitle: "Apply 1:10", timestamp: Date(timeIntervalSince1970: 0)
    )
    static let savedReport = AppWarning(
        id: UUID(), severity: .info, title: "Markups saved into “Plan-A.pdf”",
        message: "1 annotation, one per markup. The original drawing is unchanged at the start of the file.",
        source: "Export", timestamp: Date(timeIntervalSince1970: 1)
    )
    static let staleScale = AppWarning(
        id: UUID(), severity: .warning, title: "Measured against an older scale",
        message: "Check the sheet's scale.", source: "Scale", timestamp: Date(timeIntervalSince1970: 2)
    )
    static let secondReport = AppWarning(
        id: UUID(), severity: .info, title: "Layered PDF written", message: "1 markup.",
        source: "Export", timestamp: Date(timeIntervalSince1970: 3)
    )

    /// Old output: the tray was titled "Warnings" with a count of 2 and the chip read
    /// "2 warnings" for a scale offer and a success report — neither of them a warning.
    @Test("L-28: a success report is a notice — not counted, titled or spoken as a warning")
    func noticesAreNotWarnings() {
        let notices = WarningTrayContent([Self.scaleOffer, Self.savedReport])
        #expect(notices.warningCount == 0)
        #expect(notices.noticeCount == 2)
        #expect(notices.title == "Notices")
        #expect(notices.titleCount == 2)
        #expect(notices.badgeText == "2 notices")
        #expect(notices.chipCount == 2)
        #expect(!notices.showsNoticesHeader)
        #expect(notices.accessibilityHint == "Opens the list of notices")
        #expect(notices.warningGroups.isEmpty)

        #expect(WarningTrayContent([Self.savedReport]).badgeText == "1 notice")

        let mixed = WarningTrayContent([Self.staleScale, Self.scaleOffer, Self.savedReport])
        #expect(mixed.title == "Warnings")
        #expect(mixed.titleCount == 1, "the title counts only warnings")
        #expect(mixed.badgeText == "1 warning, 2 notices")
        #expect(mixed.chipCount == 1)
        #expect(mixed.showsNoticesHeader)
        #expect(mixed.warningGroups.flatMap(\.rows).map(\.id) == [Self.staleScale.id])
        #expect(mixed.noticeGroups.flatMap(\.rows).map(\.id) == [Self.scaleOffer.id, Self.savedReport.id])

        let warningsOnly = WarningTrayContent([Self.staleScale])
        #expect(warningsOnly.badgeText == "1 warning")
        #expect(warningsOnly.accessibilityHint == "Opens the list of outstanding warnings")
    }

    @Test("L-28: rows from one source are one group under one caption, sources in first-seen order")
    func groupsBySource() {
        let content = WarningTrayContent([Self.scaleOffer, Self.savedReport, Self.secondReport])
        #expect(content.noticeGroups.map(\.source) == ["Scale proposal", "Export"])
        #expect(content.noticeGroups.map { $0.rows.map(\.id) } == [
            [Self.scaleOffer.id], [Self.savedReport.id, Self.secondReport.id]
        ])
    }

    /// Checks one rendered tray of notices from two sources, by pixel: each caption sits above
    /// its group's card — nearer that card than whatever is above it — and starts at or right of
    /// the tray's padding; nothing is drawn in the padding on either side.
    private func expectCaptionsAboveTheirCards(_ ink: TrayInk, cards expectedCards: Int, _ label: String) {
        let padding = ZPDFSpacing.l
        // Nothing overflows into the padding: an edge that cuts a caption's first letter is
        // content drawn here.
        #expect(!ink.isInked(columns: 0...(padding - 1)), "\(label): something is drawn in the left padding")
        #expect(!ink.isInked(columns: (ink.size.width - padding + 1)...ink.size.width),
                "\(label): something is drawn in the right padding")
        // Each card carries its severity bar along its leading edge, at the padding; the
        // panel header's hairline divider crosses the same column as a thin run.
        let bar = ink.rowRuns(columns: (padding + 0.5)...(padding + 2))
        let dividers = bar.filter { $0.upperBound - $0.lowerBound < 3 }
        let blocks = bar.filter { $0.upperBound - $0.lowerBound >= 3 }
        let cards = bar.filter { $0.upperBound - $0.lowerBound >= 30 }
        guard let divider = dividers.first, cards.count == expectedCards, let lastCard = cards.last else {
            Issue.record("\(label): expected a header divider and \(expectedCards) cards; bar runs \(bar)")
            return
        }
        // The captions: text between the header and the last card that is no card's.
        let captions = ink.rowRuns(columns: (padding + 2)...200).filter { run in
            run.upperBound - run.lowerBound >= 3
                && run.lowerBound > divider.upperBound
                && run.upperBound <= lastCard.upperBound
                && !blocks.contains { $0.overlaps(run) }
        }
        print("lv5 L-28: \(label) width \(ink.size.width): divider \(divider), cards \(cards), captions \(captions)")
        // Old layout: header, card, caption, card, caption — one caption in this span, under its card.
        #expect(captions.count == expectedCards, "\(label): one caption above each source's card, found \(captions)")
        for (index, caption) in captions.prefix(cards.count).enumerated() {
            let card = cards[index]
            let above = index == 0 ? divider.upperBound : cards[index - 1].upperBound
            #expect(caption.upperBound <= card.lowerBound, "\(label): caption \(caption) ends inside or under its card \(card)")
            #expect(caption.lowerBound >= above, "\(label): caption \(caption) starts above the element before it (\(above))")
            #expect(card.lowerBound - caption.upperBound < caption.lowerBound - above,
                    "\(label): caption \(caption) sits nearer the element above (\(above)) than its card \(card)")
            let leftmost = ink.leftmostInk(rows: caption)
            print("lv5 L-28: \(label) caption \(index) starts at \(leftmost.map { "\($0)" } ?? "nil") pt")
            #expect((leftmost ?? 0) >= padding, "\(label): caption \(index) starts at \(String(describing: leftmost)) pt, left of the \(padding) pt padding")
        }
    }

    /// Old output: each source caption was drawn *under* its card, inside a scroll view even
    /// for two rows; in a host narrower than the tray's rigid 380 pt the whole tray was centred
    /// and both edges were cut — "cale proposal", "xport", the live symptom (see the renders this
    /// test writes when LV5_RENDER_DIR is set).
    @Test("L-28: captions sit above their cards and inside the padding, at the tray's width and in a narrower host")
    func trayRenders() throws {
        let notices = [Self.scaleOffer, Self.savedReport]
        // At the popover's content size (L-32: what its hosting controller reads off the tray,
        // minimum included — no longer only the height at the tray's width).
        let popover = WarningTrayPopoverSizing(notices)
        let natural = try renderTray(notices, width: popover.width, height: popover.height, name: "tray-notices")
        #expect(natural.ink.size.width == WarningTrayView.width)
        // Below the last row only the padding: the popover is no taller than the content.
        #expect(!natural.ink.isInked(rows: (natural.ink.size.height - ZPDFSpacing.l + 1)...natural.ink.size.height))
        #expect(natural.ink.isInked(rows: (natural.ink.size.height - ZPDFSpacing.l - 6)...(natural.ink.size.height - ZPDFSpacing.l)),
                "the popover is taller than its content: nothing drawn just above the bottom padding")
        #expect(scrollViews(in: natural.host).isEmpty, "a short list is a plain stack")
        expectCaptionsAboveTheirCards(natural.ink, cards: 2, "natural")
        // A host that gives the tray less than it asks for — a popover's content area narrower
        // than 380 pt. The tray takes the room it is given; it is not centred over both edges.
        for width in [CGFloat(344), 300] {
            let narrow = try renderTray(notices, width: width, name: "tray-notices-\(Int(width))")
            #expect(narrow.ink.size.width == width)
            expectCaptionsAboveTheirCards(narrow.ink, cards: 2, "host \(Int(width))")
            // The rows wrap to the narrower width; the height the tray asks for there holds them,
            // down to its bottom padding.
            #expect(!narrow.ink.isInked(rows: (narrow.ink.size.height - ZPDFSpacing.l + 1)...narrow.ink.size.height),
                    "host \(Int(width)): something is drawn in the bottom padding")
        }
        // The mixed tray keeps its padding clear too.
        let mixed = try renderTray([Self.staleScale, Self.scaleOffer, Self.savedReport], name: "tray-mixed")
        #expect(scrollViews(in: mixed.host).isEmpty)
        #expect(!mixed.ink.isInked(columns: 0...(ZPDFSpacing.l - 1)))
        #expect(DesignD3Render.distinctColours(mixed.ink.bitmap) > 3)

        let many = (0..<30).map { index in
            AppWarning(id: UUID(), severity: .warning, title: "Warning \(index)", message: "Detail.",
                       source: "Source \(index % 3)", timestamp: Date(timeIntervalSince1970: Double(index)))
        }
        let long = try renderTray(many, name: "tray-long")
        #expect(scrollViews(in: long.host).count == 1, "a long list scrolls")
        #expect(long.ink.size.height <= WarningTrayView.maximumListHeight + 160, "the list stops growing at its limit")
        #expect(!long.ink.isInked(columns: 0...(ZPDFSpacing.l - 1)))
        // With a scroller that always shows (legacy style, as with scroll bars set to show
        // always), the rows give the scroller its width on the right and keep their left edge.
        let legacy = try renderTray(many, name: "tray-long-legacy") { host in
            for scrollView in scrollViews(in: host) {
                scrollView.scrollerStyle = .legacy
                scrollView.autohidesScrollers = false
                scrollView.hasVerticalScroller = true
                scrollView.tile()
            }
        }
        let firstCard = { (ink: TrayInk) in
            ink.rowRuns(columns: (ZPDFSpacing.l + 0.5)...(ZPDFSpacing.l + 2)).first { $0.upperBound - $0.lowerBound >= 30 }
        }
        let overlay = try #require(firstCard(long.ink))
        let legacyCard = try #require(firstCard(legacy.ink))
        let overlayEdges = (long.ink.leftmostInk(rows: overlay), long.ink.rightmostInk(rows: overlay))
        let legacyEdges = (legacy.ink.leftmostInk(rows: legacyCard), legacy.ink.rightmostInk(rows: legacyCard))
        print("lv5 L-28: long tray \(long.ink.size); first card spans \(overlayEdges) pt, with a legacy scroller \(legacyEdges) pt")
        #expect((legacyEdges.1 ?? .infinity) < (overlayEdges.1 ?? 0) - 8, "the legacy scroller took its width from the rows' right")
        #expect(legacyEdges.0 == overlayEdges.0, "the rows keep their left edge beside a legacy scroller")
        #expect(!legacy.ink.isInked(columns: 0...(ZPDFSpacing.l - 1)), "a legacy scroller pushed the rows into the left padding")
    }

    // MARK: - L-29: menus hang from their chip

    @Test("L-29: a menu's origin sits under the chip's left edge, in flipped and unflipped views")
    func menuOriginUnderChip() {
        final class Flipped: NSView { override var isFlipped: Bool { true } }
        let flipped = Flipped(frame: NSRect(x: 900, y: 10, width: 80, height: 60))
        #expect(ProjectTopBandView.menuOrigin(under: flipped) == NSPoint(x: 0, y: 64))
        let plain = NSView(frame: NSRect(x: 900, y: 10, width: 80, height: 60))
        #expect(ProjectTopBandView.menuOrigin(under: plain) == NSPoint(x: 0, y: -4))
        #expect(ProjectTopBandView.menuOrigin(under: plain, gap: 2) == NSPoint(x: 0, y: -2))
    }

    /// Old output: the Export chooser was popped up at `window.mouseLocationOutsideOfEventStream`
    /// in the content view — pressed through accessibility, the middle of the canvas.
    @Test("L-29: the Export chooser hangs from the Export chip, or from More when Export moved into it")
    func exportMenuHangsFromItsChip() throws {
        do {
            let (layout, window) = makeLiveTest5Window(width: 1_672, key: "lv5.export.wide")
            defer { window.close() }
            let band = try #require(layout.topBand)
            #expect(band.stage == .full)
            // Default arrangement: Export is the last chip of the rounded workspace group, one view.
            let group = try #require(band.rightEntries.first { $0.identifier == .zenitWorkspaceGroup }?.view)
            var presented: [(menu: NSMenu, origin: NSPoint, view: NSView)] = []
            band.presentMenu = { presented.append(($0, $1, $2)) }
            let menu = NSMenu(title: "Export")
            menu.addItem(withTitle: "Quantity Ledger…", action: nil, keyEquivalent: "")
            #expect(band.popUpMenu(menu, under: .zenitExport))
            let shown = try #require(presented.first)
            #expect(presented.count == 1)
            #expect(shown.menu === menu)
            #expect(shown.view === group, "the menu hangs from the workspace group that holds the Export chip")
            // Under the group (a flipped SwiftUI hosting view), its right edge at the group's right
            // edge — under Export, the group's last chip.
            #expect(group.isFlipped)
            #expect(shown.origin.y == group.bounds.height + ProjectTopBandView.menuGap)
            #expect(abs(shown.origin.x - max(0, group.bounds.maxX - menu.size.width)) < 0.5)
            let placed = try #require(band.menuPlacement(for: .zenitExport, menuWidth: 120))
            #expect(placed.origin.x == group.bounds.maxX - 120)
            #expect(band.menuPlacement(for: .zenitToolLibrary, menuWidth: 120)?.origin.x == 0, "the group's first chip starts at its left edge")
            // Hidden toolbar: no chip to hang from, nothing opened; the caller falls back.
            layout.setTopBandShown(false)
            band.layoutSubtreeIfNeeded()
            #expect(band.menuPlacement(for: .zenitExport, menuWidth: 120) == nil)
            #expect(!band.popUpMenu(menu, under: .zenitExport))
            #expect(presented.count == 1)
        }
        do {
            // Export as its own chip (customised arrangement): under that chip's left edge.
            let (layout, window) = makeLiveTest5Window(width: 1_672, key: "lv5.export.single")
            defer { window.close() }
            let band = try #require(layout.topBand)
            band.setArrangement([.zenitSelect, .zenitLength, .zenitExport, .zenitAuthor])
            band.needsLayout = true
            band.layoutSubtreeIfNeeded()
            let chip = try #require(band.rightEntries.first { $0.identifier == .zenitExport }?.view)
            #expect(!chip.isHidden)
            let placed = try #require(band.menuPlacement(for: .zenitExport, menuWidth: 120))
            #expect(placed.view === chip)
            #expect(placed.origin == NSPoint(x: 0, y: chip.bounds.height + ProjectTopBandView.menuGap))
        }
        do {
            let (layout, window) = makeLiveTest5Window(width: 1_040, key: "lv5.export.narrow")
            defer { window.close() }
            let band = try #require(layout.topBand)
            #expect(band.stage >= .rightCollapsed)
            let placed = try #require(band.menuPlacement(for: .zenitExport, menuWidth: 120))
            #expect(placed.view === band.moreView, "Export lives in More here")
        }
    }
}
