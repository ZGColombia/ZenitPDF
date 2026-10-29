import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// Design round d2 (2026-09-23 main-window mockup): the top bar's brand block, tool group,
/// rounded workspace group and author badge.
///
/// No window is ever created (a test may never put a window on screen): items are built through the toolbar delegate
/// exactly as AppKit builds them, and views are rendered off screen only when
/// `ZENIT_D2_RENDER_DIR` names a directory.
@Suite("Design d2 — top bar", .shellTierSerialised)
@MainActor
struct DesignD2TopBarTests {

    private func built(
        _ identifier: NSToolbarItem.Identifier,
        environment: ProjectShellEnvironment = .mock()
    ) throws -> (ZenitToolbarBuilder, NSToolbarItem) {
        let builder = ZenitToolbarBuilder(environment: environment)
        let toolbar = builder.makeToolbar()
        let item = try #require(builder.toolbar(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true))
        return (builder, item)
    }

    private func run(_ item: NSMenuItem) throws {
        let action = try #require(item.action)
        let target = try #require(item.target as? NSObject)
        target.perform(action, with: item)
    }

    // MARK: - Order and structure

    @Test("The tool group follows the mockup exactly, with one separator between Measure and Text")
    func toolGroupOrder() {
        let tools = ZenitToolbarBuilder.defaultItemIdentifiers.filter {
            ZenitToolbarBuilder.selectableItemIdentifiers.contains($0) || $0 == .zenitToolSeparator
        }
        #expect(tools == [
            .zenitSelect, .zenitZoom, .zenitPan, .zenitCalibrate, .zenitLength, .zenitArea, .zenitMeasure,
            .zenitToolSeparator,
            .zenitText, .zenitCallout, .zenitShapes, .zenitCount, .zenitCutout
        ])
        #expect(ZenitToolbarBuilder.defaultItemIdentifiers.filter { $0 == .zenitToolSeparator }.count == 1)
        #expect(!ZenitToolbarBuilder.selectableItemIdentifiers.contains(.zenitToolSeparator))
        #expect(!ZenitToolbarBuilder.selectableItemIdentifiers.contains(.zenitWorkspaceGroup))
        #expect(!ZenitToolbarBuilder.selectableItemIdentifiers.contains(.zenitAuthor))
    }

    @Test("Every mockup tool maps to a real command: the tool chips arm the tool their caption names")
    func everyToolArmsItsTool() throws {
        let expectations: [(NSToolbarItem.Identifier, ZenitToolIdentifier)] = [
            (.zenitSelect, .select), (.zenitZoom, .zoom), (.zenitPan, .pan),
            (.zenitCalibrate, .calibrate), (.zenitLength, .length), (.zenitArea, .area),
            (.zenitMeasure, .measure), (.zenitText, .text), (.zenitCallout, .callout),
            (.zenitShapes, .shapes), (.zenitCount, .count), (.zenitCutout, .cutout)
        ]
        for (identifier, tool) in expectations {
            let environment = ProjectShellEnvironment.mock()
            // Start from a tool other than the one under test so arming is observable.
            environment.toolbar.selectTool(tool == .pan ? .select : .pan)
            // The builder is the overflow row's (weak) target: keep it alive for the run.
            let (builder, item) = try built(identifier, environment: environment)
            #expect(item.label == tool.displayName, "\(identifier.rawValue) caption")
            let menuForm = try #require(item.menuFormRepresentation)
            try withExtendedLifetime(builder) { try run(menuForm) }
            #expect(environment.toolbar.activeTool == tool, "\(identifier.rawValue) armed \(environment.toolbar.activeTool)")
        }
    }

    @Test("The separator is decorative: hidden from VoiceOver, a separator when overflowed, on the bar")
    func separatorIsDecorative() throws {
        let (_, item) = try built(.zenitToolSeparator)
        let view = try #require(item.view)
        #expect(!view.isAccessibilityElement())
        #expect(item.menuFormRepresentation?.isSeparatorItem == true)
        #expect(item.isBordered == false)
        #expect(!item.paletteLabel.isEmpty)
    }

    @Test("The workspace group holds Tool Library, Search, Compare, Export; overflowed it keeps all four")
    func workspaceGroupOverflow() throws {
        let environment = ProjectShellEnvironment.mock()
        var forwarded: [ZPDFCommandID] = []
        environment.externalCommandHandler = { forwarded.append($0) }
        let (builder, item) = try built(.zenitWorkspaceGroup, environment: environment)
        defer { withExtendedLifetime(builder) {} }
        #expect(item.view != nil)
        #expect(item.isBordered == false)
        #expect(!item.label.isEmpty)
        #expect(item.view?.accessibilityLabel()?.isEmpty == false)

        let submenu = try #require(item.menuFormRepresentation?.submenu)
        #expect(submenu.items.map(\.title) == ["Tool Library", "Search", "Compare", "Export"].map {
            NSLocalizedString($0, comment: "Toolbar item")
        })
        #expect(submenu.items.map(\.tag) == [ZPDFCommandID.toolLibrary, .find, .revisionCompare, .export].map {
            ZPDFCommandID.allCases.firstIndex(of: $0)!
        })
        // Export is forwarded to the app tier; running the overflow row must reach it.
        try run(try #require(submenu.items.last))
        #expect(forwarded.contains(.export))
    }

    @Test("Workspace chips show their panel's open state; Export, which opens no panel, never does")
    func workspaceChipsOpenState() throws {
        let environment = ProjectShellEnvironment.mock()
        let builder = ZenitToolbarBuilder(environment: environment)
        let library = try #require(builder.workspaceChip(.zenitToolLibrary))
        let search = try #require(builder.workspaceChip(.zenitSearch))
        let compare = try #require(builder.workspaceChip(.zenitCompare))
        let export = try #require(builder.workspaceChip(.zenitExport))
        #expect(library.openStateCommand == .toolLibrary)
        #expect(search.openStateCommand == .find)
        #expect(compare.openStateCommand == .revisionCompare)
        #expect(export.openStateCommand == nil)
        for chip in [library, search, compare, export] {
            #expect(chip.selectionID == nil, "\(chip.title) must never read as the armed tool")
            #expect(!chip.helpText().isEmpty)
        }
        #expect(builder.workspaceChip(.zenitSelect) == nil)
    }

    // MARK: - Chip appearance (tokens, states)

    @Test("The armed tool chip uses the accent fill with text-on-accent glyph and caption")
    func armedChipUsesAccentFill() {
        let environment = ProjectShellEnvironment.mock()
        environment.toolbar.selectTool(.select)
        let chip = ZenitToolChip(
            environment: environment,
            glyph: ZenitToolIdentifier.select.glyph,
            title: ZenitToolIdentifier.select.displayName,
            selectionID: .zenitSelect,
            helpText: { "" },
            action: {}
        )
        #expect(chip.isArmed)
        let look = chip.appearance()
        #expect(look.fill == .accent)
        #expect(look.fillOpacity == 1)
        #expect(look.glyph == .textOnAccent)
        #expect(look.caption == .textOnAccent)
        #expect(look.isEmphasised)

        // Another chip reads as not armed, with no fill at rest.
        let pan = ZenitToolChip(
            environment: environment,
            glyph: ZenitToolIdentifier.pan.glyph,
            title: ZenitToolIdentifier.pan.displayName,
            selectionID: .zenitPan,
            helpText: { "" },
            action: {}
        )
        #expect(!pan.isArmed)
        #expect(pan.appearance().fill == nil)
        #expect(!pan.appearance().isEmphasised)

        // Arming Pan moves the fill: the chips read the model, nothing is synchronised by hand.
        environment.toolbar.selectTool(.pan)
        #expect(pan.appearance().fill == .accent)
        #expect(chip.appearance().fill == nil)
    }

    @Test("Hover, pressed, open and disabled states each map to their own design-system token")
    func stateTable() {
        typealias S = ZenitTopBarStyle
        #expect(S.appearance(.init()).fill == nil)
        #expect(S.appearance(.init(isHovering: true)).fill == .stateHover)
        #expect(S.appearance(.init(isHovering: true, isPressed: true)).fill == .statePressed)
        let open = S.appearance(.init(isOpen: true))
        #expect(open.fill == .selectedFill)
        #expect(open.glyph == .accentBlue)
        #expect(open.caption == .accentBlue, "glyph and label draw in accentBlue while open")
        #expect(open.isEmphasised, "an open panel is a shape change too, not only a colour")
        let armedPressed = S.appearance(.init(isArmed: true, isPressed: true))
        #expect(armedPressed.fill == .accent)
        #expect(armedPressed.fillOpacity < 1)
        // Armed wins over open: the one strong accent stays with the armed tool.
        #expect(S.appearance(.init(isArmed: true, isOpen: true)).fill == .accent)
        let disabled = S.appearance(.init(isArmed: true, isHovering: true, isEnabled: false))
        #expect(disabled.fill == nil)
        #expect(disabled.foregroundOpacity < 1)
    }

    @Test("The top bar reads the d1 chrome metrics")
    func chromeMetrics() {
        #expect(ZenitTopBarStyle.chipHeight == ZPDFSpacing.Chrome.toolButtonHeight)
        #expect(ZenitTopBarStyle.chipMinWidth == ZPDFSpacing.Chrome.toolButtonWidth)
        #expect(ZenitTopBarStyle.chipIcon == ZPDFSpacing.Chrome.toolIcon)
        #expect(ZenitTopBarStyle.badgeDiameter == ZPDFSpacing.Chrome.avatarLarge)
        #expect(ZenitToolChip.cornerRadius == ZPDFRadius.card)
        #expect(ZenitTopBarStyle.chipMinWidth >= ZPDFSpacing.Control.minimumHitTarget)
    }

    @Test("No raw colour literal in the toolbar sources: every colour is a design-system token")
    func noRawColourLiterals() throws {
        let toolbarDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZPDFUIShell/Toolbar")
        let files = try FileManager.default.contentsOfDirectory(at: toolbarDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count >= 7, "the scan found \(files.count) files")
        let forbidden = try NSRegularExpression(pattern: [
            #"Color\s*\(\s*(red|hue|white|\.sRGB|\.displayP3)"#,
            #"NSColor\s*\(\s*(red|calibrated|srgb|deviceRed|white|displayP3)"#,
            #"#colorLiteral"#,
            #"Color\.(white|black|blue|red|green|gray|grey|orange|yellow|cyan|purple|pink)\b"#,
            #"NSColor\.(white|black|blue|red|green|gray|orange|yellow|cyan|system[A-Z]\w*)\b"#,
            #"ZPDFRGBA\s*\("#
        ].joined(separator: "|"))
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            let hits = forbidden.matches(in: source, range: range).compactMap { Range($0.range, in: source).map { String(source[$0]) } }
            #expect(hits.isEmpty, "\(file.lastPathComponent) spells colours: \(hits)")
        }
    }

    // MARK: - Brand

    @Test("The brand block leads, is identity rather than a control, and speaks its tagline")
    func brandBlock() throws {
        let (_, item) = try built(.zenitBrand)
        #expect(item.view != nil)
        #expect(item.isBordered == false)
        #expect(item.label.isEmpty, "the brand draws itself; AppKit adds no caption")
        #expect(!item.paletteLabel.isEmpty)
        #expect(item.menuFormRepresentation?.isEnabled == false, "overflowed, the brand is not a dead button")
        #expect(item.visibilityPriority == .low, "the tools outrank the wordmark on a narrow window")
        // VoiceOver reads the product name only; the tagline is decoration and is an
        // English brand line, not a catalogue string.
        #expect(ZenitToolbarBrand.accessibilityText == NSLocalizedString("Zenit PDF", comment: ""))
        #expect(!ZenitToolbarBrand.accessibilityText.contains(ZenitToolbarBrand.tagline))
        #expect(ZenitToolbarBrand.tagline == "Built for what's next")
        #expect(item.view?.accessibilityLabel() == ZenitToolbarBrand.accessibilityText)
    }

    @Test("The peak mark is a closed shape inside its frame, with the ridge and the valley cut out")
    func peakMarkGeometry() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 22)
        let path = ZenitPeakMark.path(in: rect)
        #expect(!path.isEmpty)
        #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(path.boundingRect))
        // Solid: the left flank. Cut: the valley at the foot and the ridge band.
        #expect(path.contains(CGPoint(x: 6, y: 20)))
        #expect(!path.contains(CGPoint(x: 15.5, y: 20)), "the valley notch is filled")
        #expect(!path.contains(CGPoint(x: 30, y: 12)), "the ridge band is filled")
        // The slim second ridge on the right survives.
        #expect(path.contains(CGPoint(x: 38.6, y: 21)))
    }

    // MARK: - Author badge

    @Test("Initials come from the first and last word of the real name, never from source")
    func initials() {
        #expect(ZenitToolbarModel.initials(for: "Sample Author") == "SA")
        #expect(ZenitToolbarModel.initials(for: "sample middle author") == "SA")
        #expect(ZenitToolbarModel.initials(for: "Single") == "S")
        #expect(ZenitToolbarModel.initials(for: "  ") == "")
        #expect(ZenitToolbarModel.initials(for: "Test-Exempel Person") == "TP")
        #expect(ZenitToolbarModel.initials(for: "Ört Ärt") == "ÖÄ")
        #expect(ZenitToolbarModel.initials(for: "(Team) Studio") == "S", "punctuation-led words are skipped")
    }

    @Test("The badge shows the installed author identity and follows a rename")
    func badgeFollowsTheAuthorIdentity() throws {
        let environment = ProjectShellEnvironment.mock()
        // Without an installed provider the badge shows the machine's own answer, the same
        // fallback AuthorIdentity uses.
        #expect(environment.toolbar.authorName == ZenitToolbarModel.machineAuthorName)

        var stored = "Sample Author"
        environment.toolbar.authorNameProvider = { stored }
        #expect(environment.toolbar.authorName == "Sample Author")
        #expect(environment.toolbar.authorInitials == "SA")

        let (builder, item) = try built(.zenitAuthor, environment: environment)
        #expect(item.isBordered == false)
        #expect(item.view?.accessibilityLabel()?.contains("Sample Author") == true)
        #expect(item.toolTip?.contains("Sample Author") == true)
        #expect(item.toolTip?.contains("Settings") == true, "the tooltip says where the name is changed")
        #expect(item.toolTip?.contains("(") == false, "the tooltip uses no parentheses")
        #expect(item.menuFormRepresentation?.action != nil, "overflowed, the row still opens Settings")
        #expect(!ZenitAuthorBadge.accessibilityHint.isEmpty)

        stored = "Other Person"
        environment.toolbar.refreshAuthorName()
        #expect(environment.toolbar.authorInitials == "OP")
        #expect(builder.liveHelpText(for: .zenitAuthor)?.contains("Other Person") == true)
        #expect(ZenitAuthorBadge.accessibilityText(name: environment.toolbar.authorName).contains("Other Person"))
    }

    @Test("The badge opens Settings through the application menu's own ⌘, item")
    func badgeOpensSettings() throws {
        final class Target: NSObject {
            var runs = 0
            @objc func showSettings(_ sender: Any?) { runs += 1 }
        }
        let target = Target()
        let main = NSMenu(title: "Main")
        let appItem = main.addItem(withTitle: "App", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "App")
        appMenu.autoenablesItems = false
        appMenu.addItem(withTitle: "About", action: nil, keyEquivalent: "")
        let settings = appMenu.addItem(
            withTitle: "Settings…", action: #selector(Target.showSettings(_:)), keyEquivalent: ","
        )
        settings.target = target
        appItem.submenu = appMenu

        let toolbar = ZenitToolbarModel()
        #expect(toolbar.openAuthorSettings(in: main))
        #expect(target.runs == 1)
        // No Settings item (a menu without ⌘,): nothing is run and the call says so.
        #expect(!toolbar.openAuthorSettings(in: NSMenu(title: "Empty")))
        #expect(target.runs == 1)
    }

    // MARK: - Palette indicators and glyph size (design QA pass 9)

    @Test("Measure and Count carry a corner indicator inside the chip; only Shapes keeps the separate ›")
    func paletteIndicators() {
        #expect(ZenitToolChip.indicator(for: .measure) == .corner)
        #expect(ZenitToolChip.indicator(for: .count) == .corner)
        #expect(ZenitToolChip.indicator(for: .shapes) == .separate)
        #expect(ZenitTopBarStyle.cornerIndicatorSize == 6, "a 6 pt chevron")
        #expect(ZenitTopBarStyle.separateIndicatorSize == 10, "the › disclosure is 10 pt")
        // The corner hit area stays in the corner: it cannot reach the chip's centre line.
        #expect(ZenitTopBarStyle.cornerIndicatorHitSize + ZenitTopBarStyle.cornerIndicatorInset
            < ZenitTopBarStyle.chipMinWidth / 2)
    }

    @Test("The Zoom tool draws the plain magnifier, not the zoom-in (plus) magnifier")
    func zoomToolGlyph() {
        guard case let .symbol(symbol) = ZenitToolIdentifier.zoom.glyph else {
            Issue.record("Zoom is not a symbol glyph")
            return
        }
        #expect(symbol == .zoomTool)
        #expect(symbol != .zoomIn)
    }

    @Test("Tool glyphs are sized to the spec's 20 pt icon, not the generic 0.82 scale")
    func glyphSize() {
        #expect(ZenitTopBarStyle.chipIcon == 20)
        // The generic glyph view sets symbols at 0.82 × box = 16.4 pt, which measured ~15 % small.
        #expect(ZenitTopBarStyle.chipSymbolPointSize >= 0.82 * ZenitTopBarStyle.chipIcon * 1.15)
        #expect(ZenitTopBarStyle.chipSymbolPointSize <= ZenitTopBarStyle.chipIcon)
        #expect(ZenitTopBarStyle.chipMeasurementIcon > ZenitTopBarStyle.chipIcon)
    }

    // MARK: - Off-screen render (opt-in, no window)

    @Test("Renders the top bar pieces off screen when ZENIT_D2_RENDER_DIR is set")
    func offscreenRender() throws {
        guard let dir = ProcessInfo.processInfo.environment["ZENIT_D2_RENDER_DIR"] else { return }
        let environment = ProjectShellEnvironment.mock()
        environment.toolbar.authorNameProvider = { "Sample Author" }
        let builder = ZenitToolbarBuilder(environment: environment)
        let toolbar = builder.makeToolbar()
        for scheme in [NSAppearance.Name.darkAqua, .aqua] {
            let views: [NSView] = ZenitToolbarBuilder.defaultItemIdentifiers.compactMap {
                builder.toolbar(toolbar, itemForItemIdentifier: $0, willBeInsertedIntoToolbar: true)?.view
            }
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            stack.appearance = NSAppearance(named: scheme)
            stack.wantsLayer = true
            stack.layer?.backgroundColor = ZPDFColor.nsColor(.background).resolved(for: scheme)
            stack.layoutSubtreeIfNeeded()
            stack.setFrameSize(stack.fittingSize)
            stack.layoutSubtreeIfNeeded()
            let rep = try #require(stack.bitmapImageRepForCachingDisplay(in: stack.bounds))
            stack.cacheDisplay(in: stack.bounds, to: rep)
            let name = scheme == .darkAqua ? "d2-topbar-dark.png" : "d2-topbar-light.png"
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}

private extension NSColor {
    /// The colour as a CGColor under a given appearance, for an off-screen layer.
    func resolved(for appearance: NSAppearance.Name) -> CGColor {
        var result = cgColor
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            result = cgColor
        }
        return result
    }
}
