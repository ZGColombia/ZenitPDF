import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Pure display decisions for the status bar, split out so the honest-empty-state rules are
/// testable without rendering a view.
///
/// With no document loaded the bar says "No document" — it never
/// asserts `1 of 0` and never claims Vector Snap is unavailable, because with no document
/// the snap state is unknown, not unavailable.
enum StatusBarDisplay {

    /// Whether a document is loaded. Everything else in the bar hangs on this.
    /// The warnings chip's text. Compact, it is the bare count beside the severity icon —
    /// "⚠ 3" — never the icon alone: a count-less chip is a colour-only status (design QA,
    /// pass 9). The full sentence stays in the tooltip and the spoken label.
    static func warningChipTitle(count: Int, badgeText: String, compact: Bool) -> String {
        compact ? String(count) : badgeText
    }

    static func hasDocument(_ snapshot: StatusBarSnapshot) -> Bool {
        snapshot.pageCount > 0
    }

    /// The Page segment's text: the page indicator, or the honest empty state.
    static func pageText(_ snapshot: StatusBarSnapshot) -> String {
        guard hasDocument(snapshot) else {
            return NSLocalizedString("No document", comment: "Status bar with nothing open")
        }
        return snapshot.pageIndicatorText
    }

    /// Where a sheet reference typed into the page field should go, as a zero-based index, or
    /// `nil` when the text names no page (S-048).
    ///
    /// **Sheet number, then label, then position** — the app's one rule for a typed sheet
    /// reference; the presenters navigate by index and identity only (T-033). A named sheet
    /// answers to its sheet number compared the way the core compares
    /// them (``PageDescriptor/normalisedSheetNumber(_:)``: "a102" reaches "A-102"); a number two
    /// sheets share goes nowhere rather than to the first of them. Otherwise the PDF label and the
    /// position decide, as in ``pageDestination(forTyped:labels:)``.
    static func pageDestination(forTyped text: String, pages: [PageDescriptor]) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = PageDescriptor.normalisedSheetNumber(trimmed)
        if !wanted.isEmpty {
            let named = pages.indices.filter {
                pages[$0].sheetNumber.map(PageDescriptor.normalisedSheetNumber) == wanted
            }
            if named.count == 1 { return named[0] }
            if named.count > 1 { return nil }
        }
        return pageDestination(forTyped: trimmed, labels: pages.map(\.label))
    }

    /// Where a page number typed into the status bar's field should go by label or position, as
    /// a zero-based index, or `nil` when the text names no page.
    ///
    /// **Label first, position second.** A sheet printed `A-101` is page 3 of the set; typing
    /// `A-101` must reach it, and so must typing `3`. Label lookup goes first because the number
    /// printed in the corner of the drawing is the one an estimator says out loud — and on a set
    /// whose sheets are labelled `1…23` the two rules agree anyway.
    ///
    /// The ambiguous case is a set whose labels are numbers that are *not* the positions —
    /// sheets labelled `101, 102, 103`. There, typing `101` goes to the sheet printed `101`, not
    /// to position 101, which does not exist. That is the reading a person means.
    static func pageDestination(forTyped text: String, labels: [String]) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let match = labels.firstIndex(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return match
        }
        // `1...labels.count` traps when the document has no pages — `Range requires lowerBound
        // <= upperBound` — so the count is checked before the range is formed rather than by it.
        guard !labels.isEmpty,
              let position = Int(trimmed),
              position >= 1, position <= labels.count
        else { return nil }
        return position - 1
    }

    /// The Coord segment's text. An em dash when the pointer is off the page — an empty
    /// segment would read as a rendering bug.
    static func coordinateText(_ snapshot: StatusBarSnapshot) -> String {
        snapshot.cursorDisplayText.isEmpty ? "—" : snapshot.cursorDisplayText
    }

    /// The Tool segment's text, which is the armed **mode** when a mode is what decides the
    /// next click.
    ///
    /// Apply and Place deliberately disarm both drawing families, so the tool name the core
    /// last wrote is the name of a tool the canvas is no longer in: the segment read `"Select"`
    /// while a stamp was armed. Naming the mode and the preset — `"Place · Door Count"` — makes
    /// the segment true again, and it is derived from the Tool Library presenter rather than
    /// pushed into the snapshot so it cannot lag behind the panel by a refresh.
    ///
    /// In Draw the tool name is already correct and nothing is substituted: the armed preset
    /// arms a real tool, and the toolbar, the cursor and this segment all name it already.
    static func toolText(_ snapshot: StatusBarSnapshot, armed: ArmedToolState?) -> String {
        guard let armed else { return snapshot.toolIndicatorText }
        let note = snapshot.activeToolNote.flatMap { $0.isEmpty ? nil : $0 } ?? armed.mode.shortHelp
        return snapshot.toolIndicatorText(namedBy: armed.indicatorText, note: note)
    }

    /// The spoken form of the Tool segment.
    static func toolAccessibilityText(_ snapshot: StatusBarSnapshot, armed: ArmedToolState?) -> String {
        armed?.accessibilityDescription ?? snapshot.toolIndicatorText
    }

    /// One source's text inside the Snap segment: an active
    /// source is listed by its bare name — `Snap: Vector, Markup` — which is the text form
    /// that satisfies the no-colour-only rule. A source that is off (or has nothing to
    /// snap to) keeps its name plus the word "off", so its state is still words, and the
    /// name is still there to click.
    static func snapSourceText(name: String, isActive: Bool) -> String {
        guard !isActive else { return name }
        let format = NSLocalizedString(
            "%@ off",
            comment: "Status bar snap source that is not active: source name, the word off"
        )
        return String(format: format, name)
    }

    /// A snap source's short name for the listing — `Snap: Grid, Vector, Markup` — as the
    /// mockup draws the segment (IM-221). The full name ("Vector Snap") stays the spoken label;
    /// repeating "Snap" after the segment's own "Snap:" label only cost width.
    static func snapShortName(_ kind: ZPDFSnapKind) -> String {
        switch kind {
        case .grid: return NSLocalizedString("Grid", comment: "Status bar snap source, short name after 'Snap:'")
        case .vector: return NSLocalizedString("Vector", comment: "Status bar snap source, short name after 'Snap:'")
        case .markup: return NSLocalizedString("Markup", comment: "Status bar snap source, short name after 'Snap:'")
        }
    }

    /// A snap toggle's tooltip: its full name and what it snaps to, or why it cannot (IM-221).
    static func snapHelp(_ kind: ZPDFSnapKind, isAvailable: Bool) -> String {
        guard isAvailable else {
            return NSLocalizedString(
                "This page has no vector geometry to snap to.",
                comment: "Why Vector Snap is unavailable"
            )
        }
        let format = NSLocalizedString(
            "%1$@: %2$@",
            comment: "Snap toggle tooltip: the source's full name, then what it snaps to"
        )
        return String(format: format, kind.title, kind.icon.helpText)
    }

    /// What a snap toggle draws as its pressed state (BH-819).
    ///
    /// The stored preference alone is not it: on a page with no vector geometry the label says
    /// "Vector off" and VoiceOver says off, so the button must not draw pressed either.
    static func snapToggleIsOn(isOn: Bool, isAvailable: Bool) -> Bool {
        isOn && isAvailable
    }

    /// A control title with its shortcut in brackets, the way every toolbar tooltip prints it
    /// (IM-222): `Fit Width (⌘0)`.
    static func titleWithShortcut(_ title: String, binding: ZPDFKeyBinding?) -> String {
        binding.map { "\(title) (\($0.displayString))" } ?? title
    }

    /// A zoom preset's label, formatted by the locale — `25%` in English, `25 %` in Swedish —
    /// rather than a hard-coded `"25 %"` (IM-222).
    static func zoomPresetTitle(percent: Double, locale: Locale = .current) -> String {
        (percent / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// The zoom percentage a typed text asks for, clamped to the supported 5 %–6400 %, or `nil`
    /// when the text is not a usable percentage (IM-022).
    ///
    /// Read through ``ZPDFDecimalParser``, the one number grammar every Zenit field uses: `nan`
    /// and `inf` are refused, `150,5` is 150.5 %. One case is refused on top of the grammar: a
    /// single separator followed by exactly three digits (`1,000`, `1.000`). As a percentage
    /// that is either a thousand or one with three decimals, and the old reader took it as one
    /// — then clamped it to 5 % — which zoomed the page to a speck when a person had asked for
    /// a thousand. An ambiguous zoom is refused and the field reverts.
    static func zoomPercent(fromTyped text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("%") { trimmed.removeLast() }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAmbiguousGrouping(trimmed) { return nil }
        guard let percent = ZPDFDecimalParser.double(trimmed), percent > 0 else { return nil }
        return min(6_400, max(5, percent))
    }

    /// `1,000` / `12.500`: one to three digits, one separator, exactly three digits.
    private static func isAmbiguousGrouping(_ text: String) -> Bool {
        let separators = text.filter { $0 == "," || $0 == "." }
        guard separators.count == 1, let mark = separators.first,
              let split = text.firstIndex(of: mark) else { return false }
        let whole = text[..<split]
        let fraction = text[text.index(after: split)...]
        return (1...3).contains(whole.count) && fraction.count == 3
            && whole.allSatisfy(\.isASCIIDigitCharacter) && fraction.allSatisfy(\.isASCIIDigitCharacter)
    }

    /// Navigates to the page a typed text names and tells the shell the page moved (BH-299).
    ///
    /// The arrows go through ``ProjectShellEnvironment/perform(_:)``, which calls
    /// ``ProjectShellEnvironment/pageDidChange()``; the field called `goToPage(index:)` straight
    /// on the presenter, so the Scale Regions panel kept the previous sheet's regions — and its
    /// half-drawn boundary — after a typed jump.
    ///
    /// - Returns: `true` when the text named a page.
    @MainActor
    @discardableResult
    static func commitTypedPage(_ text: String, environment: ProjectShellEnvironment) -> Bool {
        // A named sheet answers to its sheet number (NL-DOCS-05), compared as the core compares
        // them (S-048); then the PDF label, then the position.
        guard let index = pageDestination(forTyped: text, pages: environment.document.pages) else {
            return false
        }
        environment.goToPage(index: index)
        return true
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}

/// The canvas status strip: the slim readout row along the bottom edge of the canvas column.
///
/// Until the 2026-09-23 mockup this was a status bar across the whole bottom of the window. The
/// mockup has none — its bottom edge is the Quantity Ledger bar — so the bar became a strip
/// under the page, where the pointer coordinate and the snap toggles sit next to the drawing
/// they describe. Nothing it showed was dropped: page navigation and zoom moved to the canvas
/// bar above the page (`CanvasPageControl`, `CanvasZoomControl`) and every other readout and
/// toggle is still here. The strip's own page and zoom controls, reachable only when no canvas
/// bar carried them — never in the product — were deleted (R-086).
///
/// Segment order is fixed:
/// `Page │ Scale │ Unit │ Snap │ Coord │ Zoom`. The snap toggles are named text controls
/// inside the Snap segment, coordinates use monospaced digits, and with no document loaded
/// the bar shows only "No document". Every readout is text, every toggle
/// is a real control with a keyboard path and a spoken state, and no state anywhere in this
/// bar is carried by colour alone.
public struct StatusBarView: View {

    private let environment: ProjectShellEnvironment

    /// Creates the status strip.
    public init(environment: ProjectShellEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        // R-079: the rows read the snapshot as the strip shows it, and are skipped when that is
        // unchanged. The strip used to read the whole snapshot and rebuild all five arrangements
        // on every publish — and the canvas publishes on every scroll and zoom frame
        // (`reportVisibleRect`), for a zoom the strip does not even show.
        StatusStripRows(environment: environment, snapshot: Self.shownSnapshot(environment.status.snapshot))
            .equatable()
            .padding(.horizontal, ZPDFSpacing.m)
            .frame(maxWidth: .infinity, minHeight: ProjectWindowLayoutController.statusBarHeight)
            // The chrome ground, not a raised bar: the strip is quiet furniture under the page,
            // and the hairline above it is the only edge it needs.
            .background(ZPDFColor.color(ZPDFWindowChrome.groundToken))
            .overlay(alignment: .top) { ZPDFHairlineDivider(axis: .horizontal) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(NSLocalizedString(
                "Canvas status",
                comment: "Accessibility label for the status strip under the page canvas"
            )))
    }

    /// The snapshot as the strip shows it: the zoom, the page's label, position and size and
    /// the raw pointer point — the canvas bar's, or nobody's — blanked, and the page count kept
    /// only as "a document is open". Two snapshots that differ only there draw the same strip.
    static func shownSnapshot(_ snapshot: StatusBarSnapshot) -> StatusBarSnapshot {
        var shown = snapshot
        shown.zoomDisplayString = ""
        shown.pageLabel = ""
        shown.pageIndex = 0
        shown.pageCount = StatusBarDisplay.hasDocument(snapshot) ? 1 : 0
        shown.pageDimensionsText = ""
        shown.cursorPagePoint = nil
        return shown
    }

    /// One arrangement of the strip at its natural width.
    func stripRow(_ variant: CanvasStripVariant, snapshot: StatusBarSnapshot, hasDocument: Bool) -> some View {
        StatusStripRows(environment: environment, snapshot: snapshot)
            .stripRow(variant, snapshot: snapshot, hasDocument: hasDocument)
    }
}

/// The strip's rows: every arrangement, the first that fits drawn. Equatable over what they
/// draw, so ``StatusBarView`` re-runs them only when the shown snapshot changed (R-079). What
/// they read from the presenters directly — the warnings, the armed mode — they observe as
/// before.
struct StatusStripRows: View, Equatable {

    let environment: ProjectShellEnvironment
    /// The snapshot as ``StatusBarView/shownSnapshot(_:)`` gives it.
    let snapshot: StatusBarSnapshot

    @State private var isShowingWarnings = false

    nonisolated static func == (lhs: StatusStripRows, rhs: StatusStripRows) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.environment === rhs.environment
    }

    private var status: any StatusPresenting { environment.status }

    var body: some View {
        let hasDocument = StatusBarDisplay.hasDocument(snapshot)
        // The first arrangement that fits, never a truncated one. Each variant is drawn at its
        // natural width, so no toggle shrinks to "Grid…" and the warnings chip never loses its
        // count (design QA, pass 9: at a 1086 pt column it clipped to an icon and a colour). The
        // Coord readout gives way first, then the right group goes compact — the count always stays.
        return ViewThatFits(in: .horizontal) {
            ForEach(CanvasStripVariant.allCases, id: \.self) { variant in
                stripRow(variant, snapshot: snapshot, hasDocument: hasDocument)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One arrangement of the strip at its natural width.
    func stripRow(_ variant: CanvasStripVariant, snapshot: StatusBarSnapshot, hasDocument: Bool) -> some View {
        HStack(spacing: ZPDFSpacing.m) {
            leftGroup(snapshot: snapshot, hasDocument: hasDocument, coord: variant.coord, showsUnit: variant.showsUnit)
                .fixedSize()
            Spacer(minLength: ZPDFSpacing.m)
            rightGroup(snapshot: snapshot, hasDocument: hasDocument, compact: variant.compactRight)
                .fixedSize()
        }
    }

    /// Tool, Scale, Unit, Snap and Coord. With no document, only the honest "No document": nothing
    /// here may claim a scale or a snap availability it cannot know.
    @ViewBuilder
    private func leftGroup(
        snapshot: StatusBarSnapshot,
        hasDocument: Bool,
        coord: CanvasStripVariant.Coord,
        showsUnit: Bool
    ) -> some View {
        HStack(spacing: ZPDFSpacing.m) {
            if !hasDocument {
                // The honest empty state that the page control used to carry.
                Text(StatusBarDisplay.pageText(snapshot))
                    .zpdfText(.caption, .textSecondary)
            }
            if hasDocument {
                // Tool — the armed tool, named. The first rule every tool shares: arming a tool
                // must be visible and true — the toolbar shows which tool is active, the status
                // bar names it, and the cursor changes. The mockup predates the rule; the rule
                // outranks it. When the tool is known to be incomplete
                // the segment says so in the same breath, so an honest "not implemented" is
                // never hidden behind a lit chip. …and when a *mode* is armed it is the mode
                // that decides the click, so that is what the segment names.
                readout(
                    label: NSLocalizedString("Tool", comment: "Status bar readout label"),
                    value: StatusBarDisplay.toolText(
                        snapshot,
                        armed: environment.toolLibrary.armedModeState
                    ),
                    spokenValue: StatusBarDisplay.toolAccessibilityText(
                        snapshot,
                        armed: environment.toolLibrary.armedModeState
                    )
                )
                ZPDFHairlineDivider(axis: .vertical)
                scaleSegment(snapshot)
                if showsUnit {
                    ZPDFHairlineDivider(axis: .vertical)
                    unitSegment(snapshot)
                }
                ZPDFHairlineDivider(axis: .vertical)
                // Snap — active sources listed by name, every name a clickable toggle.
                // Spaced pills, not a comma-separated list: each toggle carries its own
                // selected fill, so the gap reads as the separator.
                HStack(spacing: ZPDFSpacing.xs) {
                    Text(NSLocalizedString("Snap", comment: "Status bar readout label"))
                        .zpdfText(.caption, .textSecondary)
                        .accessibilityHidden(true)
                    snapToggle(kind: .grid, isOn: snapshot.gridSnapEnabled, isAvailable: true)
                    snapToggle(
                        kind: .vector,
                        isOn: snapshot.vectorSnapEnabled,
                        isAvailable: snapshot.geometryIndexStatus.allowsVectorSnap
                    )
                    snapToggle(kind: .markup, isOn: snapshot.markupSnapEnabled, isAvailable: true)
                }
                if coord != .hidden {
                    ZPDFHairlineDivider(axis: .vertical)
                    // Coord, monospaced, throttled by the presenter. The label is the first
                    // thing to go when the column narrows: the parenthesised pair explains itself.
                    readout(
                        label: NSLocalizedString("Coord", comment: "Status bar readout label"),
                        value: StatusBarDisplay.coordinateText(snapshot),
                        showsLabel: coord == .labelled
                    )
                }
            }
        }
    }

    /// The reuse-tool toggle, the geometry-index readout, and the warning tray.
    @ViewBuilder
    private func rightGroup(snapshot: StatusBarSnapshot, hasDocument: Bool, compact: Bool) -> some View {
        HStack(spacing: ZPDFSpacing.m) {
            if hasDocument {
                reuseToolToggle(isOn: snapshot.reuseToolEnabled, compact: compact)
                ZPDFHairlineDivider(axis: .vertical)
                geometryIndexReadout(snapshot.geometryIndexStatus, compact: compact)
            }
            warningAffordance(compact: compact)
        }
    }


    // MARK: - Pieces

    /// The Scale readout, as a button that opens the scale sheet when the app wires one
    /// (LT3-08). Still reads "Scale 1:50" / "Scale No scale"; the button adds a way to change it.
    @ViewBuilder
    func scaleSegment(_ snapshot: StatusBarSnapshot) -> some View {
        let label = NSLocalizedString("Scale", comment: "Status bar readout label")
        if let open = environment.onScaleSegmentPressed, let apply = environment.onApplyScaleRatio {
            // NL-UX-19 (r2-markup): the read-out is a menu — the common drawing ratios for this
            // page, the scale sheet, calibration and Scale Regions, each an existing command.
            Menu {
                ForEach(ProjectShellEnvironment.scaleRatioChoices, id: \.self) { denominator in
                    Button(ProjectShellEnvironment.ratioTitle(denominator)) { apply(denominator) }
                }
                Divider()
                Button(NSLocalizedString("Set Scale…", comment: "Status strip scale menu: the page scale sheet"), action: open)
                Button(NSLocalizedString("Calibrate…", comment: "Status strip scale menu: calibrate from two points")) {
                    environment.perform(.calibrateScale)
                }
                Button(NSLocalizedString("Scale Regions…", comment: "Status strip scale menu: the Scale Regions panel")) {
                    environment.perform(.scaleRegions)
                }
            } label: {
                // L-07: one Text, never the HStack readout — see ``menuTitle(label:value:)``.
                Self.menuTitle(label: label, value: snapshot.scaleIndicatorText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(NSLocalizedString(
                "Set the scale for this page: a drawing ratio such as 1:50, or calibrate from two points.",
                comment: "Tooltip of the status strip's Scale segment"
            ))
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(snapshot.scaleIndicatorText))
        } else if let open = environment.onScaleSegmentPressed {
            Button(action: open) {
                readout(label: label, value: snapshot.scaleIndicatorText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString(
                "Set the scale for this page: a drawing ratio such as 1:50, or calibrate from two points.",
                comment: "Tooltip of the status strip's Scale segment"
            ))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(snapshot.scaleIndicatorText))
            .accessibilityHint(Text(NSLocalizedString(
                "Opens the scale sheet for this page.",
                comment: "Accessibility hint of the status strip's Scale segment"
            )))
            .accessibilityAddTraits(.isButton)
        } else {
            readout(label: label, value: snapshot.scaleIndicatorText)
        }
    }

    /// The Unit read-out, a menu of output units when the app wired the setter (NL-UX-19): it
    /// looked like a control and was plain text.
    @ViewBuilder
    func unitSegment(_ snapshot: StatusBarSnapshot) -> some View {
        let label = NSLocalizedString("Unit", comment: "Status bar readout label")
        if let setUnits = environment.onSetOutputUnits {
            Menu {
                ForEach(StatusUnitChoice.menuChoices, id: \.self) { choice in
                    if choice == .divider {
                        Divider()
                    } else {
                        Button(choice.title) { setUnits(choice) }
                    }
                }
            } label: {
                Self.menuTitle(label: label, value: snapshot.outputUnitSymbol)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(NSLocalizedString(
                "Choose the units quantities are shown in.",
                comment: "Tooltip of the status strip's Unit segment"
            ))
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(snapshot.outputUnitSymbol))
        } else {
            readout(label: label, value: snapshot.outputUnitSymbol)
        }
    }

    /// A read-out as the title of a menu segment: the label and the value as **one** `Text`, each
    /// run in its own type role and colour.
    ///
    /// L-07: on macOS a borderless `Menu` draws its label as a pop-up button, which keeps the
    /// first `Text` of a composite label and drops the rest. With the HStack read-out as the
    /// label, the Scale and Unit segments read "Scale" and "Unit" with no values — the moment the
    /// menu hooks were wired and the strip redrew. A concatenated `Text` is a single title, and
    /// the pop-up button keeps all of it, runs and fonts included.
    static func menuTitle(label: String, value: String) -> Text {
        Text(label)
            .font(ZPDFTypography.font(.caption))
            .tracking(ZPDFTypography.caption.tracking)
            .foregroundStyle(ZPDFColor.color(.textSecondary))
        + Text(verbatim: " ")
        + Text(value)
            .font(ZPDFTypography.font(.monoNumeric))
            .tracking(ZPDFTypography.monoNumeric.tracking)
            .foregroundStyle(ZPDFColor.color(.textPrimary))
    }

    private func readout(label: String, value: String, spokenValue: String? = nil, showsLabel: Bool = true) -> some View {
        HStack(spacing: ZPDFSpacing.xs) {
            if showsLabel {
                Text(label)
                    .zpdfText(.caption, .textSecondary)
                    .accessibilityHidden(true)
            }
            Text(value)
                // Tabular figures: a coordinate readout that jitters as digits change is
                // unreadable while the pointer is moving.
                .zpdfText(.monoNumeric, .textPrimary)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(spokenValue ?? value))
    }

    private func snapToggle(
        kind: ZPDFSnapKind,
        isOn: Bool,
        isAvailable: Bool
    ) -> some View {
        let state: ZPDFSnapState = isAvailable ? (isOn ? .armed : .off) : .off
        let isActive = isAvailable && isOn
        let environment = self.environment
        let binding = Binding(
            get: { StatusBarDisplay.snapToggleIsOn(isOn: isOn, isAvailable: isAvailable) },
            set: { enabled in
                switch kind {
                case .grid: environment.status.setGridSnapEnabled(enabled)
                case .vector: environment.status.setVectorSnapEnabled(enabled)
                case .markup: environment.status.setMarkupSnapEnabled(enabled)
                }
            }
        )
        return Toggle(isOn: binding) {
            // The listing is the state: an active source shows its bare name, an off
            // source shows "name off" — words either way, never a tint alone.
            Text(StatusBarDisplay.snapSourceText(
                name: StatusBarDisplay.snapShortName(kind),
                isActive: isActive
            ))
                .zpdfText(.caption, isActive ? .textPrimary : .textSecondary)
                .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
        }
        .toggleStyle(CanvasStripToggleStyle())
        .disabled(!isAvailable)
        .help(StatusBarDisplay.snapHelp(kind, isAvailable: isAvailable))
        .accessibilityLabel(Text(kind.title))
        .accessibilityValue(Text(state.spokenName))
    }

    private func reuseToolToggle(isOn: Bool, compact: Bool) -> some View {
        let title = NSLocalizedString("Reuse tool", comment: "Status bar toggle")
        let stateText = isOn
            ? NSLocalizedString("On", comment: "Reuse tool state")
            : NSLocalizedString("Off", comment: "Reuse tool state")
        let environment = self.environment
        let binding = Binding(
            get: { isOn },
            set: { environment.status.setReuseToolEnabled($0) }
        )
        return Toggle(isOn: binding) {
            HStack(spacing: ZPDFSpacing.xs) {
                ZPDFGlyphView(.symbol(.duplicate), size: ZPDFSpacing.Control.iconSmall)
                if !compact {
                    Text(title).zpdfText(.caption, .textPrimary)
                }
                // Compact keeps the state in words: the icon names the toggle, "On" says how
                // it stands; the title stays in the tooltip and the spoken label.
                Text(stateText).zpdfText(.caption, .textSecondary)
            }
            .padding(.horizontal, ZPDFSpacing.xs)
            .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
        }
        .toggleStyle(CanvasStripToggleStyle())
        .help(String(
            format: NSLocalizedString(
                "%@ — keep the active tool armed after a markup is finished.",
                comment: "Reuse tool help; the argument is the toggle's title"
            ),
            title
        ))
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(stateText))
    }

    private func geometryIndexReadout(_ indexStatus: GeometryIndexStatus, compact: Bool) -> some View {
        let title = NSLocalizedString("Geometry index", comment: "Status bar readout label")
        // Compact drops the title, never the state: the pill still says what the index is doing.
        return ZPDFStatusPill(
            severity: indexStatus.allowsVectorSnap ? .success : .neutral,
            title: compact ? indexStatus.displayName : title,
            value: compact ? nil : indexStatus.displayName,
            usesMonospacedValue: false
        )
        .help("\(title): \(indexStatus.displayName)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(NSLocalizedString(
            "Geometry index",
            comment: "Accessibility label for the geometry index readout"
        )))
        .accessibilityValue(Text(indexStatus.displayName))
    }

    @ViewBuilder
    private func warningAffordance(compact: Bool) -> some View {
        let warnings = status.warnings
        if warnings.isEmpty {
            EmptyView()
        } else {
            let severity = status.highestSeverity ?? .info
            // L-28: notices (an informational report such as "Markups saved into …") are
            // counted and named as notices, never as warnings.
            let content = WarningTrayContent(warnings)
            let fullText = content.badgeText
            Button {
                isShowingWarnings.toggle()
            } label: {
                ZPDFStatusPill(
                    severity: Self.severity(for: severity),
                    title: StatusBarDisplay.warningChipTitle(
                        count: content.chipCount,
                        badgeText: fullText,
                        compact: compact
                    ),
                    usesMonospacedValue: false
                )
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: ZPDFSpacing.Control.minimumHitTarget)
            .help(fullText)
            .accessibilityLabel(Text(fullText))
            .accessibilityHint(Text(content.accessibilityHint))
            .popover(isPresented: $isShowingWarnings, arrowEdge: .top) {
                WarningTrayView(environment: environment)
            }
        }
    }

    private static func severity(for severity: AppWarningSeverity) -> ZPDFSeverity {
        switch severity {
        case .info: return .info
        case .warning: return .warning
        case .danger: return .danger
        }
    }
}

/// What the warning tray holds, arranged (L-28).
///
/// Live test 5 (2026-10-03): the success report "Markups saved into Plan-A.pdf" was counted and
/// listed under WARNINGS, and each row's source ("Scale proposal", "Export") sat *under* its card
/// as if it captioned the next one — and was clipped at the popover's left edge. Now:
///
/// - **Warnings** (`.warning`, `.danger`) and **notices** (`.info`: no action required, such as a
///   finished export or a scale offer) are separate. The tray is titled after what it holds —
///   "Warnings" while there is one, "Notices" when there are only notices — and notices under a
///   warnings list get a "Notices" header of their own. The status bar chip counts and names
///   them the same way ("1 notice", "2 warnings, 1 notice").
/// - Rows from one source are one group, captioned **above** its cards, in the order the sources
///   first appear (the presenter's order: most serious first).
struct WarningTrayContent: Equatable {

    /// The rows from one source, under one caption.
    struct Group: Equatable {
        /// The caption: the rows' source. Empty for rows that name none, which get no caption.
        let source: String
        let rows: [AppWarning]
    }

    /// The warnings, grouped by source.
    let warningGroups: [Group]
    /// The notices, grouped by source.
    let noticeGroups: [Group]
    let warningCount: Int
    let noticeCount: Int

    init(_ all: [AppWarning]) {
        let warnings = all.filter { !Self.isNotice($0) }
        let notices = all.filter(Self.isNotice)
        warningGroups = Self.groups(warnings)
        noticeGroups = Self.groups(notices)
        warningCount = warnings.count
        noticeCount = notices.count
    }

    /// A notice is informational: it needs no action and is not a warning.
    static func isNotice(_ warning: AppWarning) -> Bool {
        warning.severity == .info
    }

    /// `rows` grouped by source, each group where its source first appears.
    static func groups(_ rows: [AppWarning]) -> [Group] {
        var order: [String] = []
        var bySource: [String: [AppWarning]] = [:]
        for row in rows {
            if bySource[row.source] == nil { order.append(row.source) }
            bySource[row.source, default: []].append(row)
        }
        return order.map { Group(source: $0, rows: bySource[$0] ?? []) }
    }

    /// The tray's title: "Warnings" while it holds a warning, "Notices" when it holds only notices.
    var title: String {
        warningCount > 0
            ? NSLocalizedString("Warnings", comment: "Warning tray title")
            : Self.noticesTitle
    }

    /// The count beside the title: what the title names.
    var titleCount: Int { warningCount > 0 ? warningCount : noticeCount }

    /// Whether the notices need a header of their own, under the warnings.
    var showsNoticesHeader: Bool { warningCount > 0 && noticeCount > 0 }

    static var noticesTitle: String {
        NSLocalizedString("Notices", comment: "Warning tray: title or section header for informational notices")
    }

    /// The bare count on the compact status bar chip, beside the most serious severity's icon:
    /// the warnings while there are any, otherwise the notices.
    var chipCount: Int { warningCount > 0 ? warningCount : noticeCount }

    /// The chip's text, tooltip and spoken label: "2 warnings", "1 notice", "2 warnings, 1 notice".
    var badgeText: String {
        // BH-786's plural rule, for both nouns.
        let warnings = LocalizedPlural.string(
            "%lld warnings",
            count: warningCount,
            one: NSLocalizedString("%lld warning", comment: "Status bar badge: one outstanding warning"),
            other: NSLocalizedString("%lld warnings", comment: "Status bar badge showing how many warnings are outstanding")
        )
        let notices = LocalizedPlural.string(
            "%lld notices",
            count: noticeCount,
            one: NSLocalizedString("%lld notice", comment: "Status bar badge: one informational notice"),
            other: NSLocalizedString("%lld notices", comment: "Status bar badge: how many informational notices there are")
        )
        switch (warningCount > 0, noticeCount > 0) {
        case (true, true):
            return String(
                format: NSLocalizedString("%1$@, %2$@", comment: "Status bar badge: the warning count, then the notice count"),
                warnings, notices
            )
        case (false, true):
            return notices
        default:
            return warnings
        }
    }

    /// What pressing the chip does, spoken.
    var accessibilityHint: String {
        switch (warningCount > 0, noticeCount > 0) {
        case (true, true):
            return NSLocalizedString("Opens the list of warnings and notices", comment: "Accessibility hint for the status bar warning badge with notices too")
        case (false, true):
            return NSLocalizedString("Opens the list of notices", comment: "Accessibility hint for the status bar badge holding only notices")
        default:
            return NSLocalizedString("Opens the list of outstanding warnings", comment: "Accessibility hint for the status bar warning badge")
        }
    }
}

/// The list of outstanding warnings and notices, shown from the status bar badge.
///
/// IM-134: the list scrolls once it outgrows the popover, each row names where the warning came
/// from, and a warning that points at a markup or a page carries a **Show** button that takes
/// the canvas there — "which markup has the stale scale?" is answered by a click. L-28: warnings
/// and notices apart, each source's rows under one caption above them (``WarningTrayContent``).
struct WarningTrayView: View {

    let environment: ProjectShellEnvironment

    /// The tallest the list grows before it scrolls.
    static let maximumListHeight: CGFloat = 420
    /// The tray's width.
    static let width: CGFloat = 380

    private var status: any StatusPresenting { environment.status }

    var body: some View {
        let content = WarningTrayContent(status.warnings)
        VStack(alignment: .leading, spacing: ZPDFSpacing.s) {
            ZPDFPanelHeader(title: content.title, count: content.titleCount)
            // As tall as its rows up to the limit (L-32, ``TrayListHeightLayout``): a plain
            // stack while the list fits, a scroll view only past the limit.
            TrayListHeightLayout(cap: Self.maximumListHeight) {
                ViewThatFits(in: .vertical) {
                    list(content)
                    ScrollView(.vertical) {
                        list(content)
                    }
                }
            }
            if status.warnings.contains(where: \.isDismissible) {
                Button(NSLocalizedString("Dismiss all", comment: "Warning tray action")) {
                    status.dismissAllWarnings()
                }
                .zpdfFont(.control)
            }
        }
        .padding(ZPDFSpacing.l)
        // L-28: the tray asks for its width but takes the room its host gives it. It used to
        // insist on exactly 380 pt, and a host narrower than that centred it over both of its
        // edges: the leftmost text, the source captions, lost its first letter, the way live
        // test 5 showed it ("cale proposal", "xport"; LiveTest5ShellTests.trayRenders
        // reproduces that at 344 pt).
        .frame(idealWidth: Self.width, maxWidth: Self.width)
    }

    private func list(_ content: WarningTrayContent) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            ForEach(Array(content.warningGroups.enumerated()), id: \.offset) { _, group in
                self.group(group)
            }
            if content.showsNoticesHeader {
                ZPDFPanelHeader(title: WarningTrayContent.noticesTitle, count: content.noticeCount)
                    .padding(.top, ZPDFSpacing.s)
            }
            ForEach(Array(content.noticeGroups.enumerated()), id: \.offset) { _, group in
                self.group(group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One source's rows under their caption.
    private func group(_ group: WarningTrayContent.Group) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            if !group.source.isEmpty {
                // Above its cards, inset to the cards' text so no edge can take its first letter.
                Text(group.source)
                    .zpdfText(.caption, .textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, ZPDFSpacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(Text(String(
                        format: NSLocalizedString(
                            "Source: %@",
                            comment: "Accessibility label for where a warning came from"
                        ),
                        group.source
                    )))
            }
            ForEach(group.rows) { warning in
                row(warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ warning: AppWarning) -> some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.xs) {
            ZPDFInlineWarning(
                severity: severity(for: warning.severity),
                // Composed with exactly one terminator per sentence: a title that
                // carries its own full stop ("The drawing says 1:50.") used to render
                // as "1:50.." here (LT-3, 2026-08-29).
                message: warning.trayMessage,
                actionTitle: warning.actionTitle,
                // Routed to the application tier, which owns what the action does. The
                // closure here was `{}` until 2026-08-29 — a dead control on the warnings
                // surface itself.
                action: warning.actionTitle == nil
                    ? nil
                    : { environment.onWarningAction?(warning) },
                onDismiss: warning.isDismissible ? { status.dismissWarning(id: warning.id) } : nil
            )
            .accessibilityLabel(Text(warning.accessibilityLabel))
            if Self.canShow(warning) {
                Button(NSLocalizedString("Show", comment: "Warning tray: go to the markup or page a warning is about")) {
                    Self.show(warning, environment: environment)
                }
                .zpdfFont(.control)
                .help(NSLocalizedString(
                    "Go to the markup or page this warning is about",
                    comment: "Warning tray Show button help"
                ))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether a warning points at something the canvas can go to.
    static func canShow(_ warning: AppWarning) -> Bool {
        warning.relatedMarkupID != nil || warning.relatedPageID != nil
    }

    /// Takes the canvas to what a warning is about: its page first, then its markup, zoomed and
    /// selected. The page turn goes through ``ProjectShellEnvironment/pageDidChange()`` like
    /// every other, so the page-scoped panels follow.
    @MainActor
    static func show(_ warning: AppWarning, environment: ProjectShellEnvironment) {
        guard canShow(warning) else { return }
        environment.turningPage {
            if let pageID = warning.relatedPageID {
                environment.document.goToPage(id: pageID)
            }
            if let markupID = warning.relatedMarkupID {
                environment.canvas.zoomTo(markupID: markupID)
            }
        }
    }

    private func severity(for severity: AppWarningSeverity) -> ZPDFSeverity {
        switch severity {
        case .info: return .info
        case .warning: return .warning
        case .danger: return .danger
        }
    }
}

/// The warning tray's list area (L-32): exactly as tall as its rows, up to `cap`. Shorter only
/// when its host offers less, never taller, and its height never depends on how tall a size
/// it is asked about.
///
/// The list used to be capped with `.frame(maxHeight:)` under `.fixedSize(vertical: true)`.
/// That answers the ideal-size question right. A popover's hosting controller also asks for the
/// *minimum* size, with a zero proposal, and turns the answer into a minimum height for the
/// popover. The tray takes the width its host gives it (L-28), so at a zero proposal it wrapped
/// every row at its narrowest width (112 pt). The fixed vertical size then reported the list at
/// its 420 pt cap. One notice, a 180 pt tray, came back with a 502 pt minimum height. The
/// popover grew to that: empty space above the header and the popover lying over its own button.
///
/// Here a zero height proposal gets zero back, so the minimum is the header and the button. An
/// unspecified or unbounded proposal gets the rows' height, capped, so the ideal and the maximum
/// agree.
struct TrayListHeightLayout: Layout {

    /// The tallest the list area grows; past it the list scrolls.
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let list = subviews.first else { return .zero }
        let rows = list.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: rows.width, height: Self.height(rows: rows.height, cap: cap, offered: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }

    /// The list area's height: the rows', capped, and no more than the host offers.
    static func height(rows: CGFloat, cap: CGFloat, offered: CGFloat?) -> CGFloat {
        max(0, min(rows, cap, offered ?? .infinity))
    }
}

#if DEBUG
struct StatusBar_Previews: PreviewProvider {
    static var previews: some View {
        StatusBarView(environment: .mock())
            .frame(width: 1_100, height: 26)
    }
}
#endif

/// The canvas status strip's arrangements, roomiest first. `StatusBarView` shows the first one
/// that fits the column at its natural width.
enum CanvasStripVariant: Int, CaseIterable, Hashable {
    /// Everything, labelled.
    case full
    /// The Coord label goes; the coordinate pair stays.
    case unlabelledCoord
    /// The coordinate readout goes.
    case noCoord
    /// The right group goes compact: icon + state, the warning count kept.
    case compactRight
    /// The Unit readout goes too (the scale already carries it).
    case tightest

    /// How the coordinate readout is drawn.
    enum Coord { case labelled, unlabelled, hidden }

    var coord: Coord {
        switch self {
        case .full: return .labelled
        case .unlabelledCoord: return .unlabelled
        case .noCoord, .compactRight, .tightest: return .hidden
        }
    }

    var compactRight: Bool { self == .compactRight || self == .tightest }

    var showsUnit: Bool { self != .tightest }
}

/// The strip's toggles: a quiet pill whose on-state is the chrome's selected fill — the same
/// fill as a selected segment or the ledger bar's Per Sheet — rather than the saturated accent
/// of a system button toggle. The state is also in the words ("Grid off", "On").
struct CanvasStripToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        CanvasStripToggleBody(configuration: configuration)
    }
}

private struct CanvasStripToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .padding(.horizontal, ZPDFSpacing.s)
                .background(
                    RoundedRectangle(cornerRadius: ZPDFRadius.control, style: .continuous)
                        .fill(fill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }

    private var fill: Color {
        if configuration.isOn { return ZPDFColor.color(.selectedFill) }
        if isHovering && isEnabled { return ZPDFColor.color(.stateHover) }
        return .clear
    }
}
