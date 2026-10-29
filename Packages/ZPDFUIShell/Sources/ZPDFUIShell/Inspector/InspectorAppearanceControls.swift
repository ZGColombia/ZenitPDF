import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The Inspector's appearance controls.
///
/// Three rules they all share, and each one is a defect avoided:
///
///   * **Mixed is a state, not a value.** A selection whose members disagree shows an em dash and
///     no number. Showing the first markup's width would invite the reader to "confirm" a value
///     they never chose and quietly flatten eleven others.
///   * **Nothing is written until the reader commits.** Dragging a stepper writes once per step,
///     and typing writes on Return or on leaving the field — never on every keystroke, which
///     would fill the undo stack with a letter at a time.
///   * **Disabled says why.** A locked markup refuses style edits in the engine, so the control is
///     off and its help text names the reason rather than leaving a dead control on screen.
///
/// They are values with a callback rather than bindings into the selection, because the selection
/// is derived state: it is rebuilt from the canvas on every snapshot, and a two-way binding into
/// something rebuilt underneath you writes stale values back.

/// What a colour swatch needs from its window: who presents the palette, the colour panel,
/// and the recent colours. Read off the shell environment so the probe and the tests can
/// inject all three.
@MainActor
struct InspectorColourServices {
    let presenter: any ZPDFPopoverPresenting
    let panel: ZPDFColourPanelController
    let recents: ZPDFRecentColours
    let company: ZPDFCompanyColours
    let sampler: any ZPDFColourSampling
    let projectColours: (@MainActor () -> [ColorRGBA])?

    init(environment: ProjectShellEnvironment) {
        presenter = environment.colourPalettePresenter
        panel = environment.colourPanel
        recents = environment.recentColours
        company = environment.companyColours
        sampler = environment.colourSampler
        projectColours = environment.projectColours
    }
}

/// A colour swatch (NL-MARKUP-01, the fix for LT3-01).
///
/// **A real button.** The swatch used to be a painted square over a system `ColorPicker` drawn
/// at 2 % opacity, on the assumption that the nearly transparent well still took the click. In
/// the shipped app — stamped with the macOS 14 SDK — SwiftUI drops a hosted AppKit control that
/// faint from hit-testing, so the click fell through and the colour panel never opened. Package
/// tests run inside `xctest`, which is stamped with the current SDK and hit-tests the modern
/// way, so they never saw it. Now the swatch is a plain SwiftUI `Button` at full opacity that
/// opens ``ZPDFColourPalette`` in a popover: the markup inks, the recent colours, "No Fill"
/// where it applies, and "More Colours…", which drives `NSColorPanel` through
/// ``ZPDFColourPanelController``'s explicit target and action. `zpdf-hit-probe` clicks both
/// Inspector swatches in a binary stamped like the app.
///
/// The value rules the well had survive unchanged: a pick equal to the current colour writes
/// nothing, a mixed selection's placeholder is never written (CR-99), a deliberate pick on a
/// mixed selection is (BH-053), and a continuous colour-panel drag lands as one undo step
/// (BH-284).
struct InspectorColourControl: View {

    let value: ColorRGBA?
    let isMixed: Bool
    let isEnabled: Bool
    /// Whether the hex code sits beside the swatch. The Markup tab's swatch rows leave it out,
    /// as the mockup does; the code is still spoken as the swatch's value.
    var showsHex: Bool = true
    /// What VoiceOver calls the swatch: "Markup colour", "Border colour", "Fill colour". Also
    /// the palette's heading.
    var accessibilityTitle: String = NSLocalizedString("Markup colour", comment: "Accessibility label for the colour well")
    /// A stable name for the swatch's marker view ("border", "fill"), which the off-screen
    /// hit-target probe finds it by.
    var role: String = "colour"
    /// The palette's "no colour" choice — the fill row's "No Fill" — or `nil` to offer none.
    var noneChoice: (title: String, action: () -> Void)?
    let services: InspectorColourServices
    let onChange: (ColorRGBA) -> Void

    /// The marker view under the swatch, which the popover points at.
    @State private var anchor = ZPDFAnchorBox()
    /// This control's identity towards the shared colour panel, and the value it shows now.
    @State private var live = InspectorColourLive()
    /// Folds a continuous colour-panel drag into one write (BH-284).
    @State private var coalescer = InspectorEditCoalescer<ColorRGBA>()

    /// The identifier of a swatch's marker view.
    static func markerIdentifier(role: String) -> String { "zpdf.inspector.swatch.\(role)" }

    var body: some View {
        HStack(spacing: ZPDFSpacing.s) {
            Button(action: openPalette) {
                swatch.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: InspectorMetrics.swatch, height: InspectorMetrics.swatch)
            .zpdfMarker(Self.markerIdentifier(role: role), anchor: anchor)
            .disabled(!isEnabled)
            .accessibilityLabel(Text(accessibilityTitle))
            .accessibilityValue(Text(hexText))
            .accessibilityHint(Text(NSLocalizedString(
                "Opens the colour palette.", comment: "Accessibility hint of an Inspector colour swatch"
            )))
            if showsHex {
                Text(hexText)
                    .zpdfText(.monoNumeric.withSize(11), .textSecondary)
            } else if isMixed {
                // Without the code beside it the swatch alone cannot say "these disagree".
                Text(InspectorAppearanceText.mixed)
                    .zpdfText(.monoNumeric.withSize(11), .textSecondary)
            }
        }
        .help(InspectorAppearanceText.helpText(isEnabled: isEnabled))
        .onAppear { live.current = isMixed ? nil : value }
        .onChange(of: value) { _, new in live.current = isMixed ? nil : new }
        .onChange(of: isMixed) { _, mixed in live.current = mixed ? nil : value }
        .onDisappear {
            coalescer.flush()
            services.panel.detach(owner: live)
            if live.ownsPopover { services.presenter.dismiss() }
            live.ownsPopover = false
        }
    }

    // MARK: Palette

    /// Opens the palette in a popover pointing at the swatch.
    private func openPalette() {
        guard isEnabled, let anchorView = anchor.view else { return }
        let services = services
        let content = ZPDFColourPalette.Content(
            title: accessibilityTitle,
            current: isMixed ? nil : value,
            recents: services.recents.colours,
            noneTitle: noneChoice?.title,
            company: services.company.colours,
            project: services.projectColours?() ?? []
        )
        let none = noneChoice?.action
        let live = live
        let close = {
            live.ownsPopover = false
            services.presenter.dismiss()
        }
        let palette = ZPDFColourPalette(
            content: content,
            onPick: { picked in
                close()
                applyPick(picked)
            },
            onNone: none.map { action in
                {
                    close()
                    action()
                }
            },
            onMore: {
                close()
                openColourPanel()
            },
            onSample: {
                // NL-MARKUP-14: the eyedropper; its colour lands like a palette pick.
                close()
                services.sampler.sample { picked in
                    guard let picked else { return }
                    applyPick(picked)
                }
            },
            onAddToCompany: isMixed || value == nil ? nil : { [value] in
                close()
                if let value { services.company.add(value) }
            },
            // U-042: a company colour could be added but never taken out again. The palette
            // offers this on every company swatch's context menu, and in place of Add when the
            // current colour is already a company colour.
            onRemoveFromCompany: { stored in
                close()
                services.company.remove(stored)
            }
        )
        let controller = NSHostingController(rootView: palette)
        controller.sizingOptions = [.preferredContentSize]
        live.ownsPopover = true
        services.presenter.present(controller, anchoredTo: anchorView)
    }

    /// A palette pick: written at once, as one undoable change, and remembered as recent.
    private func applyPick(_ picked: ColorRGBA) {
        guard let colour = Self.pickedColour(picked, current: live.current) else { return }
        let onChange = onChange
        let recents = services.recents
        coalescer.submit(colour) { applied in
            onChange(applied)
            recents.record(applied)
        }
        coalescer.flush()
    }

    /// "More Colours…": the system colour panel, reporting to this control until it goes away.
    private func openColourPanel() {
        let live = live
        let coalescer = coalescer
        let onChange = onChange
        let recents = services.recents
        services.panel.attach(owner: live, initial: live.current) { picked in
            guard let colour = Self.pickedColour(picked, current: live.current) else { return }
            // NSColorPanel is continuous: a drag across the wheel delivers dozens of values.
            // Only the one the reader settles on is written, as one undo step (BH-284).
            coalescer.submit(colour) { applied in
                onChange(applied)
                recents.record(applied)
            }
        }
    }

    // MARK: Drawing

    /// The mockup's swatch: a rounded square of the markup's colour with a hairline edge, or
    /// an empty square with a diagonal when the selection disagrees.
    private var swatch: some View {
        let shape = RoundedRectangle(cornerRadius: ZPDFRadius.label, style: .continuous)
        return ZStack {
            if isMixed || value == nil {
                shape.fill(ZPDFColor.color(InspectorChrome.field))
                Path { path in
                    path.move(to: CGPoint(x: InspectorMetrics.swatch - 4, y: 4))
                    path.addLine(to: CGPoint(x: 4, y: InspectorMetrics.swatch - 4))
                }
                .stroke(ZPDFColor.color(.textTertiary), lineWidth: ZPDFStroke.regular)
            } else if let value, value.alpha < 0.995 {
                // A translucent colour (a fill at 20 %) reads as the colour it is only with
                // the opaque hue beside it: the upper-left half shows the hue, the lower-right
                // half what the page gets.
                shape.fill(value.swiftUIColor)
                shape.fill(ColorRGBA(red: value.red, green: value.green, blue: value.blue, alpha: 1).swiftUIColor)
                    .mask {
                        Path { path in
                            path.move(to: .zero)
                            path.addLine(to: CGPoint(x: InspectorMetrics.swatch, y: 0))
                            path.addLine(to: CGPoint(x: 0, y: InspectorMetrics.swatch))
                            path.closeSubpath()
                        }
                    }
            } else if let value {
                shape.fill(value.swiftUIColor)
            }
            shape.strokeBorder(ZPDFColor.color(InspectorChrome.fieldEdge), lineWidth: ZPDFStroke.regular)
        }
        .frame(width: InspectorMetrics.swatch, height: InspectorMetrics.swatch)
        // Disabled dimming of a drawing inside a SwiftUI button — not a hosted control, and
        // the button is disabled whenever this is below 1.
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityHidden(true)
    }

    private var hexText: String {
        isMixed ? InspectorAppearanceText.mixed : (value?.hexString ?? InspectorAppearanceText.none)
    }

    // MARK: Value rules

    /// The colour to apply for a picked value, or `nil` when nothing should be written.
    ///
    /// **The mixed placeholder is never written.** With members that disagree, `current` is
    /// `nil`, and a fully transparent colour is the placeholder, not a pick. The old guard was
    /// `picked != value` — comparing an opaque `ColorRGBA` against `nil`, which always passes —
    /// so expanding Appearance on a mixed selection applied `.clear` to every selected markup
    /// in one bulk edit: transparent black, eleven markups, one undo step (CR-99).
    ///
    /// **A deliberate pick on a mixed selection is written** (BH-053): giving a disagreeing
    /// selection one colour is the reason the control is on a multi-selection at all.
    ///
    /// **The colour already in force is not an edit**, compared by hue: the palette offers
    /// opaque inks, and the fill row's value carries the fill's own alpha, which the row keeps.
    static func pickedColour(_ picked: ColorRGBA, current: ColorRGBA?) -> ColorRGBA? {
        guard let current else { return picked.alpha > 0 ? picked : nil }
        return ZPDFColourMath.sameHue(picked, current) ? nil : picked
    }
}

/// A colour swatch's identity towards the shared colour panel, and the value it shows now —
/// a reference, so the panel's closure reads the current value rather than the one captured
/// when the panel opened.
@MainActor
final class InspectorColourLive {
    var current: ColorRGBA?
    var ownsPopover = false
}

/// A number with a stepper: line width, opacity, text size.
struct InspectorNumberControl: View {

    let value: Double?
    let isMixed: Bool
    let isEnabled: Bool
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    let accessibilityLabel: String
    let onChange: (Double) -> Void

    @State private var text: String = ""
    /// What the field last put on screen from a value, or last committed — the CR-173 rule:
    /// a blur over untouched text is not an edit (BH-285, BH-800).
    @State private var committedText: String = ""
    /// The values the stepper (or the field) asked for that the asynchronous bulk edit has not
    /// brought back into ``value`` yet (BH-802, V-043). The last one is the next click's base.
    @State private var inFlight = InspectorStepsInFlight<Double>()
    @FocusState private var isEditing: Bool
    /// The stepper shows while the pointer is on the control or the field is being edited,
    /// so the row reads "20%" at rest as the mockup draws it. Its slot stays in the layout, so
    /// nothing shifts when it appears.
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
          HStack(spacing: Self.suffixSpacing(for: suffix)) {
            TextField("", text: $text, prompt: Text(InspectorAppearanceText.mixed))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .zpdfText(.monoNumeric, .textPrimary)
                .frame(width: 46)
                .focused($isEditing)
                .disabled(!isEnabled)
                .onSubmit(commitTyped)
                .onAppear { resync(to: value) }
                .onChange(of: value) { _, new in
                    // The asks up to the value that landed are done; later ones are still in
                    // flight and stay the base. A value nobody asked for (an undo, another
                    // selection) drops them all (V-043).
                    inFlight.snapshotMoved(to: new, matches: Self.sameAsk(step: step))
                    // An undo lands while the field still has focus: when nobody has typed
                    // since the last commit, the field follows it, so the next blur does not
                    // re-apply the undone value (BH-800).
                    if Self.shouldResync(isEditing: isEditing, text: text, committedText: committedText) {
                        resync(to: inFlight.last ?? new)
                    }
                }
                .onChange(of: isEditing) { _, editing in if !editing { commitTyped() } }
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityValue(Text(spokenValue))
                // VoiceOver steps the value from the field itself (VO-↑ / VO-↓), so the
                // stepper being absent at rest never takes the adjustment away.
                .accessibilityAdjustableAction { direction in
                    guard isEnabled else { return }
                    switch direction {
                    case .increment: nudge(by: step)
                    case .decrement: nudge(by: -step)
                    @unknown default: break
                    }
                }
            Text(suffix)
                .zpdfText(.caption, .textSecondary)
                .fixedSize()
                .accessibilityHidden(true)
          }
            // LT3-01's sibling: the stepper used to sit in the layout at opacity 0 until hovered.
            // A hosted AppKit control that transparent is outside SwiftUI's hit-testing in a
            // binary stamped with the macOS 14 SDK — invisible *and* unreachable, and the opacity
            // lint now refuses it. The stepper is therefore present only while it is shown, in a
            // fixed slot so nothing shifts, and fully opaque whenever it exists.
            ZStack {
                if Self.showsStepper(isHovering: isHovering, isEditing: isEditing) {
                    Stepper(
                        "",
                        onIncrement: isEnabled ? { nudge(by: step) } : nil,
                        onDecrement: isEnabled ? { nudge(by: -step) } : nil
                    )
                    .labelsHidden()
                    .controlSize(.mini)
                    .transition(.identity)
                    // IM-211: the stepper is its own element with its own name and the value it
                    // moves, not a second copy of the field's label with nothing to read.
                    .accessibilityLabel(Text(String(
                        format: NSLocalizedString(
                            "Adjust %@", comment: "Accessibility label of an inspector stepper; the property it adjusts"
                        ),
                        accessibilityLabel
                    )))
                    .accessibilityValue(Text(spokenValue))
                }
            }
            .frame(width: Self.stepperSlot.width, height: Self.stepperSlot.height)
        }
        .onHover { isHovering = $0 }
        .help(InspectorAppearanceText.helpText(isEnabled: isEnabled))
    }

    /// "20%" hugs its sign; "2 pt" keeps a space before a word unit.
    static func suffixSpacing(for suffix: String) -> CGFloat {
        suffix == "%" ? 1 : ZPDFSpacing.xs
    }

    /// Whether the stepper exists: while hovered or while the field has focus.
    static func showsStepper(isHovering: Bool, isEditing: Bool) -> Bool {
        isHovering || isEditing
    }

    /// The stepper's slot, reserved whether or not the stepper is there: a mini `NSStepper`
    /// with a point of air.
    static let stepperSlot = CGSize(width: 11, height: 16)

    /// The value as VoiceOver reads it: the number with its unit, or "Mixed value".
    private var spokenValue: String {
        Self.spokenValue(text: text, suffix: suffix)
    }

    static func spokenValue(text: String, suffix: String) -> String {
        guard !text.isEmpty else {
            return NSLocalizedString("Mixed value", comment: "Accessibility label for a mixed multi-selection value")
        }
        return suffix.isEmpty ? text : "\(text) \(suffix)"
    }

    /// Whether a new value from the selection replaces the field's text (BH-800).
    static func shouldResync(isEditing: Bool, text: String, committedText: String) -> Bool {
        !isEditing || text == committedText
    }

    private func resync(to value: Double?) {
        text = Self.format(value)
        committedText = text
    }

    /// Rounds to two decimals and drops a trailing `.0`, so a 2 pt line reads `2` and not `2.00`.
    ///
    /// Every path to `Int(_:)` is guarded, because `Int(_:)` **traps** — it does not return
    /// `nil` — on infinity, on NaN and on any magnitude outside `Int`. `inf == inf.rounded()`
    /// is `true`, so a line width that arrived as infinity took the whole-number branch and
    /// crashed the Inspector instead of printing something (CR-118). A value that cannot be
    /// shown as a number is shown as nothing, which is what the field's mixed prompt already
    /// covers.
    static func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        // Multiplying by 100 can itself overflow to infinity near the top of `Double`, so the
        // question is asked again of the result rather than only of the input.
        let rounded = (value * 100).rounded() / 100
        guard rounded.isFinite else { return "" }
        // 2^53 is the largest integer `Double` represents exactly; past it the whole-number
        // test means nothing anyway, and the fractional form is the honest rendering.
        let exactIntegerLimit = 9_007_199_254_740_992.0
        guard rounded == rounded.rounded(), rounded.magnitude <= exactIntegerLimit else {
            return String(format: "%.2f", rounded)
        }
        return String(Int(rounded))
    }

    /// Parses the typed number and applies it, clamped. Text that is not a number reverts.
    private func commitTyped() {
        switch Self.commitDecision(text: text, committedText: committedText, value: value, range: range) {
        case .none:
            return
        case .revert:
            resync(to: inFlight.last ?? value)
        case let .write(clamped):
            text = Self.format(clamped)
            committedText = text
            // A typed value is an ask like a click: the next click steps from it (V-043).
            inFlight.asked(clamped)
            onChange(clamped)
        }
    }

    /// What committing the field's text does.
    enum CommitDecision: Equatable {
        /// Nothing: the text is what the field itself put there, or it equals the value.
        case none
        /// The text is not a finite number: put the value back.
        case revert
        /// Write this (clamped) value.
        case write(Double)
    }

    /// The commit rule, value-only so it is testable without a view tree.
    ///
    /// * Untouched text is not an edit. The field shows ``format(_:)``'s two-decimal rounding,
    ///   so re-parsing it on a blur wrote 1.33 over a stored 1.333, and 0.25 over a 0.1
    ///   hairline — an undo step and audit rows for an edit nobody made (BH-285).
    /// * The text is read by the one shared grammar, `ZPDFDecimalParser` (IM-022), which
    ///   refuses `nan` and `inf`. `Double("nan")` accepted them and `max(lo, .nan)` then wrote
    ///   the range floor to every selected markup (BH-801).
    static func commitDecision(
        text: String,
        committedText: String,
        value: Double?,
        range: ClosedRange<Double>
    ) -> CommitDecision {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed != committedText.trimmingCharacters(in: .whitespaces) else { return .none }
        guard let typed = ZPDFDecimalParser.double(trimmed) else { return .revert }
        let clamped = min(range.upperBound, max(range.lowerBound, typed))
        guard clamped != value else { return .none }
        return .write(clamped)
    }

    /// The stepper. From a mixed selection it starts at the bottom of the range rather than
    /// guessing at a value nobody chose.
    private func nudge(by delta: Double) {
        guard let next = Self.click(delta: delta, value: value, range: range, inFlight: &inFlight) else { return }
        text = Self.format(next)
        committedText = text
        onChange(next)
    }

    /// One stepper click: the value it asks for (recorded as in flight), or `nil` at a bound. The
    /// view's click and the tests run this same rule (V-043).
    static func click(
        delta: Double,
        value: Double?,
        range: ClosedRange<Double>,
        inFlight: inout InspectorStepsInFlight<Double>
    ) -> Double? {
        guard let next = nudged(value: value, pending: inFlight.last, delta: delta, range: range) else { return nil }
        inFlight.asked(next)
        return next
    }

    /// Whether a value that landed is a given ask. A quarter step of slack: a fill opacity comes
    /// back through an 8-bit alpha and a percentage product (35 % -> 0.35 -> 34.9…), which must
    /// still read as the ask it is, while two asks are always at least a step apart.
    static func sameAsk(step: Double) -> (Double, Double) -> Bool {
        let tolerance = abs(step) / 4
        return { abs($0 - $1) <= tolerance }
    }

    /// The value one stepper click asks for, or `nil` at a bound.
    ///
    /// The base is the value the stepper last asked for while the asynchronous bulk edit is
    /// still in flight. Using the stale prop made an auto-repeating stepper ask for
    /// 2 + 0.25 over and over and stall on 2.25 (BH-802).
    static func nudged(value: Double?, pending: Double?, delta: Double, range: ClosedRange<Double>) -> Double? {
        let current = pending ?? value
        let base = current ?? range.lowerBound
        let next = min(range.upperBound, max(range.lowerBound, base + delta))
        // A mixed selection (no current value) is always given the value; otherwise a click
        // at a bound asks for nothing.
        guard let current else { return next }
        return next == current ? nil : next
    }
}

/// Solid, dashed, dotted, dash-dot, cloud.
struct InspectorLineStyleControl: View {

    let value: MarkupLineStyle?
    let isMixed: Bool
    let isEnabled: Bool
    /// Drawn as the mockup's full-width boxed popup with a chevron, rather than a bare title.
    var isBoxed: Bool = false
    /// Whether Cloud is offered: only where every selected markup draws it (nl-markup,
    /// NL-MARKUP-16). A value already Cloud stays listed so the checkmark has a row.
    var offersCloud: Bool = true
    let onChange: (MarkupLineStyle) -> Void

    private var offered: [MarkupLineStyle] {
        MarkupLineStyle.allCases.filter { $0 != .cloud || offersCloud || value == .cloud }
    }

    private var title: String {
        isMixed ? InspectorAppearanceText.mixed : (value?.displayName ?? InspectorAppearanceText.none)
    }

    var body: some View {
        if isBoxed {
            InspectorPopup(title: title, isEnabled: isEnabled) { items }
                .accessibilityLabel(Text(NSLocalizedString(
                    "Line style", comment: "Accessibility label for the line style menu"
                )))
                .accessibilityValue(Text(title))
                .help(InspectorAppearanceText.helpText(isEnabled: isEnabled))
        } else {
            bare
        }
    }

    @ViewBuilder
    private var items: some View {
        ForEach(offered) { style in
            Button {
                guard style != value else { return }
                onChange(style)
            } label: {
                if style == value {
                    Label(style.displayName, systemImage: "checkmark")
                } else {
                    Text(style.displayName)
                }
            }
        }
    }

    private var bare: some View {
        Menu {
            items
        } label: {
            Text(title).zpdfText(.control, .textPrimary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!isEnabled)
        .accessibilityValue(Text(title))
        .accessibilityLabel(Text(NSLocalizedString(
            "Line style", comment: "Accessibility label for the line style menu"
        )))
        .help(InspectorAppearanceText.helpText(isEnabled: isEnabled))
    }
}

/// The strings the three controls share, so "mixed" is one em dash everywhere.
enum InspectorAppearanceText {

    static let mixed = "—"
    static let none = "—"

    /// IM-023: the disabled help used to send the reader to "Unlock it under Status", where
    /// the Locked row is a read-out with no control. It now states the reason and nothing it
    /// cannot back up.
    static func helpText(isEnabled: Bool) -> String {
        isEnabled
            ? NSLocalizedString(
                "Applies to every selected markup, as one undoable change.",
                comment: "Inspector appearance control help"
            )
            : NSLocalizedString(
                "The selection includes a locked markup, and a locked markup cannot be restyled.",
                comment: "Inspector appearance control help when the selection is locked"
            )
    }
}

/// Folds a burst of values into one write: the last value submitted, applied once the burst
/// has been quiet for ``delay``, or immediately on ``flush()``.
///
/// The colour well uses it because `NSColorPanel` is continuous — a single drag across the
/// wheel delivered one bulk edit, one undo step and one audit row per markup for every tick
/// (BH-284).
@MainActor
final class InspectorEditCoalescer<Value: Sendable> {

    let delay: Duration
    private var pending: (value: Value, apply: (Value) -> Void)?
    private var task: Task<Void, Never>?

    init(delay: Duration = .milliseconds(350)) {
        self.delay = delay
    }

    /// Replaces any pending value and restarts the quiet period.
    func submit(_ value: Value, apply: @escaping (Value) -> Void) {
        pending = (value, apply)
        task?.cancel()
        let delay = delay
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Applies the pending value now, if there is one.
    func flush() {
        task?.cancel()
        task = nil
        guard let pending else { return }
        self.pending = nil
        pending.apply(pending.value)
    }
}
