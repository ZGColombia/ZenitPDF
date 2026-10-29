import AppKit
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// One main-toolbar item as the 2026-09-23 mockup draws it: an icon over a caption.
///
/// The armed tool is a **filled accent rounded rectangle with a light glyph and caption**
/// (the mockup's Select). The fill is a shape change, the caption goes semibold, and the
/// `isSelected` trait is set, so the armed state survives greyscale, colour blindness and
/// Increase Contrast. A workspace chip whose panel is open shows an accent glyph on a faint
/// fill instead (the mockup's blue Tool Library glyph), so the one strong accent in the bar
/// stays with the armed tool. Hover and pressed states are raised fills; every state maps to
/// tokens through ``ZenitTopBarStyle/appearance(_:)``.
///
/// The chip reads the armed tool straight from the observable ``ZenitToolbarModel``, so
/// every chip repaints the moment any of them (or a menu, or a keyboard shortcut) arms a
/// tool — there is no ring to synchronise.
struct ZenitToolChip: View {

    /// Which popup palette a chip carries, if any.
    enum Palette {
        /// The Measure palette: the rarer measurement tools.
        case measure
        /// The Count palette: the Tool Library's count presets.
        case count
        /// The Shapes palette: Rectangle, Ellipse, Line, Arrow, Polyline, Polygon, Cloud.
        case shapes
    }

    let environment: ProjectShellEnvironment
    let glyph: ZPDFGlyph
    let title: String
    /// The toolbar identifier whose arming this chip mirrors; `nil` for a plain action.
    let selectionID: NSToolbarItem.Identifier?
    /// The panel command whose *open* state this chip shows; `nil` for a chip that opens
    /// nothing.
    ///
    /// Without this, Tool Library, Search and Compare looked identical open and closed, so the
    /// one obvious way back from a panel you had just opened — press the button again — did not
    /// look like a way back at all.
    var openStateCommand: ZPDFCommandID?
    /// The tooltip, evaluated on every body pass rather than baked at toolbar build time.
    ///
    /// A closure, not a `String`: the palette chips' tooltips name the tool the button will
    /// re-arm ("Click to use Length again"), and that changes whenever the palette's last-used
    /// memory does. A stored string was written once, when the toolbar was constructed, so
    /// after switching Measure to Volume the tooltip still offered Length (CR-114). Read from
    /// `body`, it re-reads the observable ``ZenitToolbarModel`` and re-renders with it.
    let helpText: @MainActor () -> String
    let action: @MainActor () -> Void
    /// Non-`nil` for a palette chip: the chevron opens the list.
    var palette: Palette?
    /// The chip's height: the tool group's full height, a little less inside the rounded
    /// workspace group so the group's outline hugs its chips the way the mockup draws it.
    var height: CGFloat = ZenitTopBarStyle.chipHeight

    /// The corner of the armed and hover fills.
    static let cornerRadius: CGFloat = ZenitTopBarStyle.chipCornerRadius

    @Environment(\.isEnabled) private var isEnabled
    /// This chip's identity in the bar's one pointer state (L-11).
    @State private var chipID = UUID()
    /// Press-and-hold on a palette chip opens its list (L-100).
    @State private var hold = ZenitPaletteHold()
    @FocusState private var isFocused: Bool

    /// The bar's pointer state, shared by every chip.
    private var pointer: ZenitChipPointerState { environment.toolbar.chipPointer }
    /// Whether the pointer is over this chip — only ever one chip at a time.
    private var isHovering: Bool { pointer.hovered == chipID }
    /// Whether this chip is held down — only ever one chip at a time.
    private var isPressed: Bool { pointer.pressed == chipID }

    /// Whether this chip is the armed tool.
    var isArmed: Bool {
        guard let selectionID else { return false }
        let current = ZenitToolbarBuilder.selectionIdentifier(
            for: environment.toolbar.activeTool,
            lastUsedMeasurement: environment.toolbar.lastUsedMeasurementKind
        )
        return current == selectionID
    }

    /// Whether this chip's panel is open.
    var isOpen: Bool {
        guard let openStateCommand else { return false }
        return environment.isPanelOpen(openStateCommand)
    }

    /// The chip's appearance right now, for the body and for tests.
    func appearance(isHovering: Bool = false, isPressed: Bool = false, isEnabled: Bool = true)
        -> ZenitTopBarStyle.ChipAppearance {
        ZenitTopBarStyle.appearance(.init(
            isArmed: isArmed,
            isOpen: isOpen,
            isHovering: isHovering,
            isPressed: isPressed,
            isEnabled: isEnabled
        ))
    }

    private var look: ZenitTopBarStyle.ChipAppearance {
        appearance(isHovering: isHovering, isPressed: isPressed, isEnabled: isEnabled)
    }

    /// Where a palette chip's menu indicator sits.
    enum PaletteIndicator: Equatable {
        /// A 6 pt chevron in the chip's lower-right corner, inside its fill (Measure, Count).
        case corner
        /// A 10 pt › disclosure in the gap after the chip, outside its fill (Shapes).
        case separate
    }

    /// The indicator style of a palette. Only the Shapes palette keeps the mockup's separate ›.
    static func indicator(for palette: Palette) -> PaletteIndicator {
        palette == .shapes ? .separate : .corner
    }

    var body: some View {
        let look = self.look
        HStack(spacing: 0) {
            chipBody(look: look)
                .background {
                    ZStack {
                        if let fill = look.fill {
                            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                                .fill(ZPDFColor.color(fill).opacity(look.fillOpacity))
                        }
                    }
                    // L-11: a change of the armed tool is never animated here, not even by the
                    // hover and press animations below when a settle lands in the same update —
                    // otherwise the chip just left fades its fill out beside the chip just armed.
                    .transaction(value: isArmed) { $0.animation = nil }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let palette, Self.indicator(for: palette) == .corner {
                        paletteMenu(palette, look: look, indicator: .corner)
                    }
                }
                .contextMenu {
                    // A right-click on any palette chip lists the palette too, so the list is
                    // reachable without aiming at the small indicator.
                    if let palette { paletteItems(palette) }
                }
                // Focus through keyboard navigation only, as a toolbar button takes it. A plain
                // `focusable()` also offers the `.edit` interaction, click-to-focus, which a tool
                // chip has no use for: its ring would be one more way to light a second chip.
                .focusable(isEnabled, interactions: .activate)
                .focused($isFocused)
                .zpdfFocusRing(isFocused, cornerRadius: Self.cornerRadius)
                .onHover { [pointer, chipID] inside in pointer.hover(chipID, inside) }

            if let palette, Self.indicator(for: palette) == .separate {
                paletteMenu(palette, look: look, indicator: .separate)
            }
        }
        // LT3-06: hover and pressed are local fills that only an exit or a release clears. When
        // a sheet, a menu or another window takes the pointer mid-press, neither arrives, and
        // the chip kept a raised fill beside the truly armed chip — two chips lit at once. Any
        // change of the armed tool, and the window losing key, settle them.
        .onChange(of: isArmed) { _, _ in settleTransientState() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            settleTransientState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            settleTransientState()
        }
        .zpdfAnimation(.micro, value: isHovering)
        .zpdfAnimation(.micro, value: isPressed)
        // L-11: the armed fill moves from one chip to the other in one frame. It used to fade over
        // `.quick` (0.16 s) on each chip, each in its own hosting view, so for the length of the
        // fade the chip just left still drew its fill beside the chip just armed: two chips lit in
        // a frame captured right after the click. One armed tool, one lit chip, at every frame.
        .zpdfAnimation(.quick, value: isOpen)
    }

    /// Clears the fills that only pointer events set (LT3-06), for the whole bar (L-11).
    private func settleTransientState() {
        pointer.settle()
    }

    /// The glyph at the spec's size. SF Symbols are set at a point size a little under the
    /// 20 pt icon box so their optical height lands on the mockup's ~18 pt glyphs; the design
    /// system's generic glyph view draws them at 0.82 of the box, which read ~15 % small
    /// (design QA pass 9).
    @ViewBuilder
    private func chipGlyph(_ look: ZenitTopBarStyle.ChipAppearance) -> some View {
        Group {
            switch glyph {
            case let .symbol(symbol):
                symbol.image
                    .font(.system(size: ZenitTopBarStyle.chipSymbolPointSize, weight: .regular))
                    .imageScale(.medium)
                    .frame(width: ZenitTopBarStyle.chipIcon, height: ZenitTopBarStyle.chipIcon)
                    .accessibilityHidden(true)
            case .measurement:
                ZPDFGlyphView(glyph, size: ZenitTopBarStyle.chipMeasurementIcon)
                    .frame(width: ZenitTopBarStyle.chipIcon, height: ZenitTopBarStyle.chipIcon)
            }
        }
        .foregroundStyle(ZPDFColor.color(look.glyph).opacity(look.foregroundOpacity))
    }

    private func chipBody(look: ZenitTopBarStyle.ChipAppearance) -> some View {
        Button {
            // A press held long enough to open the list is not also a click (L-100).
            if hold.takeFired() { return }
            action()
        } label: {
            VStack(spacing: ZenitTopBarStyle.chipLabelGap) {
                chipGlyph(look)
                Text(title)
                    .zpdfFont(look.isEmphasised ? ZPDFTypography.toolLabelActive : ZPDFTypography.toolLabel)
                    .foregroundStyle(ZPDFColor.color(look.caption).opacity(look.foregroundOpacity))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, ZenitTopBarStyle.chipHorizontalPadding)
            .frame(minWidth: ZenitTopBarStyle.chipMinWidth, minHeight: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(ZenitChipPressStyle(isPressed: Binding(
            get: { [pointer, chipID] in pointer.pressed == chipID },
            set: { [pointer, chipID, hold, palette, environment] down in
                pointer.press(chipID, down)
                // L-100: holding a palette chip down opens its list, as a toolbar button with a
                // menu does; a quick click still re-arms the last tool.
                guard let palette else { return }
                if down {
                    hold.arm(after: ZenitPaletteHold.delay) { environment.openToolbarPalette(palette) }
                } else {
                    hold.disarm()
                }
            }
        )))
        .help(helpText())
        .accessibilityLabel(title)
        .accessibilityValue(openStateValue)
        .accessibilityAddTraits(isArmed || isOpen ? [.isButton, .isSelected] : .isButton)
    }

    /// Spoken after the chip's name for a panel toggle, so the state is stated and not only
    /// drawn. Empty for a chip that toggles nothing, where "Closed" would be a lie.
    private var openStateValue: Text {
        guard let openStateCommand else { return Text(verbatim: "") }
        return environment.isPanelOpen(openStateCommand)
            ? Text(NSLocalizedString("Open", comment: "Accessibility value: the panel this button toggles is open"))
            : Text(NSLocalizedString("Closed", comment: "Accessibility value: the panel this button toggles is closed"))
    }

    /// The palette indicator: a plain click on the chip re-arms the last-used tool, the
    /// indicator opens the full list — the split behaviour the model documents.
    ///
    /// L-100 (live test 8): Shapes' › was a SwiftUI `Menu`, and AppKit sized the pop-up button
    /// behind it to its 10 pt image — measured 17 × 14 pt, vertically centred — whatever frame
    /// the label asked for. Above or below that sliver a click fell through to the band (a
    /// window drag); just inside it, it reached the chip and armed Rectangle. The › is a plain
    /// button now, whose hit area is the frame it draws — the chip's full height — and the list
    /// is the band's menu hung under the chip (``ProjectShellEnvironment/openToolbarPalette(_:)``).
    /// Measure's and Count's corner marks stay pop-ups: their image is the whole 16 pt corner
    /// (L-105), so the pop-up AppKit sizes to it is the whole target. A press held on any palette
    /// chip opens its list too, and the chip's context menu lists it as well.
    @ViewBuilder
    private func paletteMenu(
        _ palette: Palette,
        look: ZenitTopBarStyle.ChipAppearance,
        indicator: PaletteIndicator
    ) -> some View {
        // L-08: the indicator's image carries the indicator's help as its description, so
        // VoiceOver and automation read "Open the list of shapes", never the symbol's name.
        let image = Self.paletteIndicatorImage(palette, indicator: indicator)
        switch indicator {
        case .corner:
            Menu {
                paletteItems(palette)
            } label: {
                Image(nsImage: image)
                    .foregroundStyle(ZPDFColor.color(look.caption).opacity(look.foregroundOpacity * 0.8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Self.paletteHelp(palette))
            .accessibilityLabel(Self.paletteHelp(palette))
        case .separate:
            Button {
                environment.openToolbarPalette(palette)
            } label: {
                Image(nsImage: image)
                    .frame(width: ZenitTopBarStyle.separateIndicatorSize, height: ZenitTopBarStyle.separateIndicatorSize)
                    .foregroundStyle(ZPDFColor.color(ZenitTopBarStyle.chipForeground).opacity(0.75))
                    // The chip's full height, so the › is a target as tall as the chip it opens.
                    .frame(width: ZenitTopBarStyle.separateIndicatorSize + ZPDFSpacing.m)
                    .frame(minHeight: max(height, ZPDFSpacing.Control.minimumHitTarget))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(Self.paletteHelp(palette))
            .accessibilityLabel(Self.paletteHelp(palette))
        }
    }

    /// The palette indicator's glyph as a template image whose accessibility description is the
    /// indicator's help ("Open the list of shapes"), never the symbol's own name (L-08).
    static func paletteIndicatorImage(_ palette: Palette, indicator: PaletteIndicator) -> NSImage {
        let symbol: ZPDFSymbol = indicator == .corner ? .chevronDown : .disclosureClosed
        let size = indicator == .corner ? ZenitTopBarStyle.cornerIndicatorSize : ZenitTopBarStyle.separateIndicatorSize
        // The point size ZPDFGlyphView draws a symbol at inside its box.
        let glyph = symbol.nsImage(pointSize: size * 0.82) ?? NSImage(size: NSSize(width: size, height: size))
        let image: NSImage
        switch indicator {
        case .separate:
            image = glyph
        case .corner:
            // L-105: the corner target at its full size, the mark in its lower-right corner, so
            // the pop-up button sized to this image is the whole target.
            let side = ZenitTopBarStyle.cornerIndicatorHitSize
            let mark = glyph.size
            image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                glyph.draw(in: NSRect(
                    x: rect.maxX - mark.width - ZenitTopBarStyle.cornerIndicatorInset,
                    y: rect.minY + ZenitTopBarStyle.cornerIndicatorInset,
                    width: mark.width,
                    height: mark.height
                ))
                return true
            }
        }
        image.isTemplate = true
        image.accessibilityDescription = paletteHelp(palette)
        return image
    }

    @ViewBuilder
    private func paletteItems(_ palette: Palette) -> some View {
        switch palette {
        case .measure: measureItems
        case .count: countItems
        case .shapes: shapeItems
        }
    }

    /// The Measure palette, one family per run with a divider between runs, each row carrying
    /// the tool's own glyph (IM-226). The last-used tool is a checked toggle, so its state is
    /// a menu checkmark and spoken as "checked", not a tint.
    private var measureItems: some View {
        let sections = environment.toolbar.measurementPaletteSections
        return ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            ForEach(section) { kind in
                Toggle(isOn: Binding(
                    get: { kind == environment.toolbar.lastUsedMeasurementKind },
                    set: { _ in environment.toolbar.activateMeasurement(kind) }
                )) {
                    Label {
                        Text(kind.displayName)
                    } icon: {
                        Self.menuImage(for: .measurement(for: kind))
                    }
                }
            }
        }
    }

    /// A glyph as a menu-row image. Menus draw `NSImage`s, not arbitrary SwiftUI views.
    static func menuImage(for glyph: ZPDFGlyph) -> Image {
        switch glyph {
        case let .symbol(symbol):
            return symbol.nsImage(pointSize: 13).map { Image(nsImage: $0) } ?? symbol.image
        case let .measurement(kind):
            let image = ZPDFIcon.image(kind, size: 16)
            image.isTemplate = true
            return Image(nsImage: image)
        }
    }

    @ViewBuilder
    private var shapeItems: some View {
        ForEach(environment.toolbar.shapePalette) { kind in
            Button {
                environment.toolbar.activateShape(kind)
            } label: {
                if kind == environment.toolbar.lastUsedShapeKind {
                    Label(kind.displayName, systemImage: "checkmark")
                } else {
                    Text(kind.displayName)
                }
            }
        }
        // r2-markup: the clouded callout beside the shapes, then the annotation tools.
        Divider()
        ForEach(environment.toolbar.variantPalette) { variant in
            Button(variant.displayName) { environment.toolbar.activateShapeVariant(variant) }
        }
        ForEach(environment.toolbar.annotationPalette) { kind in
            Button(kind == .freehand ? ZenitToolbarModel.penTitle : kind.displayName) {
                environment.toolbar.activateShape(kind)
            }
        }
    }

    @ViewBuilder
    private var countItems: some View {
        // Exactly the toolbar model's palette, which ``ZenitToolbarBuilder`` binds live to the
        // Tool Library: one source, so a preset this menu offers is always one
        // ``ZenitToolbarModel/activateCountPreset(id:)`` can arm (IM-138).
        let presets = environment.toolbar.countPalette
        if presets.isEmpty {
            // IM-227: the empty state points at the next step instead of ending at a disabled
            // line — the plain Count tool works without a preset, and the Tool Library is where
            // one is made.
            Text(NSLocalizedString(
                "No count tools saved yet",
                comment: "Count palette menu shown when the Tool Library has no count presets"
            ))
            Divider()
            Button(NSLocalizedString(
                "Use Plain Count",
                comment: "Count palette menu: arm the Count tool without a saved preset"
            )) {
                environment.toolbar.activateMeasurement(.count)
            }
            Button(NSLocalizedString(
                "Open Tool Library…",
                comment: "Count palette menu: open the Tool Library to create a count tool"
            )) {
                environment.perform(.toolLibrary)
            }
        } else {
            ForEach(presets) { preset in
                Button {
                    environment.toolbar.activateCountPreset(id: preset.id)
                } label: {
                    if preset.id == environment.toolbar.lastUsedCountPresetID {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
        }
    }

    static func paletteHelp(_ palette: Palette) -> String {
        switch palette {
        case .measure:
            return NSLocalizedString(
                "Open the list of measurement tools",
                comment: "Toolbar palette chevron help"
            )
        case .count:
            return NSLocalizedString(
                "Open the list of count tools",
                comment: "Toolbar palette chevron help"
            )
        case .shapes:
            return NSLocalizedString(
                "Open the list of shapes",
                comment: "Toolbar palette chevron help"
            )
        }
    }
}

/// A plain button style that reports its pressed state to the chip, so the chip's rounded
/// fill — which also spans the palette chevron — can show the press.
private struct ZenitChipPressStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}

/// Press-and-hold for a palette chip (L-100): armed on the press, it opens the list once the
/// press has lasted ``delay``, and the click that ends that press is swallowed.
@MainActor
final class ZenitPaletteHold {

    /// How long a press lasts before it opens the list rather than re-arming the tool.
    static let delay: TimeInterval = 0.45

    private var timer: Timer?
    /// Whether the press now ending opened the list.
    private(set) var fired = false

    /// A press began: open the list if it is still down after `delay`.
    func arm(after delay: TimeInterval, open: @escaping @MainActor () -> Void) {
        timer?.invalidate()
        fired = false
        // A run-loop timer in the common modes, so it also fires while a mouse-tracking loop
        // holds the run loop.
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.timer != nil else { return }
                self.timer = nil
                self.fired = true
                open()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The press ended before the list opened.
    func disarm() {
        timer?.invalidate()
        timer = nil
    }

    /// Whether the press now ending opened the list; reading it clears it.
    func takeFired() -> Bool {
        defer { fired = false }
        return fired
    }
}
