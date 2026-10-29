import Observation
import SwiftUI
import ZPDFDesignSystem
import ZPDFUIPresentation

// MARK: - Controls, as values

/// One control in the canvas top bar, in the order the bar draws them.
///
/// The order is the 2026-09-23 main-window mockup's, left to right: page navigation, zoom, the
/// sidebar toggle and fit, undo and redo, then the document search field and its options at the
/// far end. Every control maps to a real command or a real presenter call — the bar carries no
/// control that does nothing.
public enum CanvasTopBarControl: String, CaseIterable, Sendable, Hashable {
    case previousPage
    case pageField
    case nextPage
    case zoomOut
    case zoomField
    case zoomIn
    case toggleNavigator
    case fitPage
    case undo
    case redo
    case searchField
    case searchOptions

    /// The visual groups the bar separates with a hairline, in order.
    public static let groups: [[CanvasTopBarControl]] = [
        [.previousPage, .pageField, .nextPage],
        [.zoomOut, .zoomField, .zoomIn],
        [.toggleNavigator, .fitPage],
        [.undo, .redo],
        [.searchField, .searchOptions]
    ]

    /// The command a press runs, or `nil` for the fields and the options menu, which act on the
    /// presenters directly.
    public var command: ZPDFCommandID? {
        switch self {
        case .previousPage: return .previousPage
        case .nextPage: return .nextPage
        case .zoomOut: return .zoomOut
        case .zoomIn: return .zoomIn
        case .toggleNavigator: return .toggleNavigator
        case .fitPage: return .fitPage
        case .undo: return .undo
        case .redo: return .redo
        case .pageField, .zoomField, .searchField, .searchOptions: return nil
        }
    }

    /// The glyph drawn for the control, or `nil` for the two text fields.
    public var symbol: ZPDFSymbol? {
        switch self {
        case .previousPage: return .chevronLeading
        case .nextPage: return .chevronTrailing
        case .zoomOut: return .remove
        case .zoomIn: return .add
        case .toggleNavigator: return .navigator
        case .fitPage: return .viewfinder
        case .undo: return .undo
        case .redo: return .redo
        case .searchField: return .search
        case .searchOptions: return .sliders
        case .pageField, .zoomField: return nil
        }
    }

    /// The control's name: its accessibility label and the first part of its hover help.
    public var title: String {
        switch self {
        case .previousPage:
            return NSLocalizedString("Previous Page", comment: "Canvas bar: go to the previous page")
        case .pageField:
            return NSLocalizedString("Page number", comment: "Canvas bar: accessibility label of the editable page field")
        case .nextPage:
            return NSLocalizedString("Next Page", comment: "Canvas bar: go to the next page")
        case .zoomOut:
            return NSLocalizedString("Zoom Out", comment: "Canvas bar: zoom out one step")
        case .zoomField:
            return NSLocalizedString("Zoom percentage", comment: "Canvas bar: accessibility label of the editable zoom field")
        case .zoomIn:
            return NSLocalizedString("Zoom In", comment: "Canvas bar: zoom in one step")
        case .toggleNavigator:
            return NSLocalizedString("Navigator", comment: "Canvas bar: show or hide the Navigator sidebar")
        case .fitPage:
            return NSLocalizedString("Fit Page", comment: "Canvas bar: fit the whole page in the window")
        case .undo:
            return NSLocalizedString("Undo", comment: "Canvas bar: undo the last change")
        case .redo:
            return NSLocalizedString("Redo", comment: "Canvas bar: redo the last undone change")
        case .searchField:
            return NSLocalizedString("Search in document", comment: "Canvas bar: accessibility label of the document search field")
        case .searchOptions:
            return NSLocalizedString("Search Options", comment: "Canvas bar: menu of search sources, case, whole words and regex")
        }
    }
}

/// How much of the bar a canvas column of a given width can carry. The bar tries each in order
/// and draws the first that fits.
public enum CanvasTopBarDensity: CaseIterable, Sendable, Hashable {
    /// Everything the mockup shows.
    case full
    /// Without the search field and its options.
    case withoutSearch
    /// Without search, undo and redo.
    case withoutHistory
    /// Page navigation and zoom only.
    case navigationOnly

    /// Whether a control is drawn at this density.
    public func shows(_ control: CanvasTopBarControl) -> Bool {
        switch control {
        case .previousPage, .pageField, .nextPage, .zoomOut, .zoomField, .zoomIn:
            return true
        case .toggleNavigator, .fitPage:
            return self != .navigationOnly
        case .undo, .redo:
            return self == .full || self == .withoutSearch
        case .searchField, .searchOptions:
            return self == .full
        }
    }
}

// MARK: - Undo availability

/// Whether Undo and Redo have anything to act on, and what.
///
/// The shell cannot see the document's undo manager — undo is serviced by the app tier — so the
/// app writes this whenever its undo stack changes. `nil` means *unknown*: the buttons stay
/// enabled rather than claiming there is nothing to undo, and the menu command's own validation
/// still decides what happens. A known `false` dims the button, exactly as the Edit menu dims its
/// item.
@MainActor
@Observable
public final class CanvasUndoState {

    /// Whether there is a change to undo, or `nil` when the app has not said.
    public var canUndo: Bool?
    /// Whether there is an undone change to redo, or `nil` when the app has not said.
    public var canRedo: Bool?
    /// The undo manager's action name for the next undo, such as `"Move Markup"`, or empty.
    public var undoActionName: String = ""
    /// The undo manager's action name for the next redo, or empty.
    public var redoActionName: String = ""

    /// Creates an undo state that knows nothing yet.
    public init() {}

    /// Whether the Undo button is pressable.
    public var isUndoEnabled: Bool { canUndo ?? true }
    /// Whether the Redo button is pressable.
    public var isRedoEnabled: Bool { canRedo ?? true }

    /// The Undo button's help: `Undo Move Markup (⌘Z)` when the action is named.
    public func undoHelp(binding: ZPDFKeyBinding?) -> String {
        CanvasTopBarDisplay.titleWithShortcut(
            CanvasTopBarDisplay.actionTitle(CanvasTopBarControl.undo.title, actionName: undoActionName),
            binding: binding
        )
    }

    /// The Redo button's help: `Redo Move Markup (⇧⌘Z)` when the action is named.
    public func redoHelp(binding: ZPDFKeyBinding?) -> String {
        CanvasTopBarDisplay.titleWithShortcut(
            CanvasTopBarDisplay.actionTitle(CanvasTopBarControl.redo.title, actionName: redoActionName),
            binding: binding
        )
    }
}

// MARK: - Display decisions

/// Pure display decisions for the canvas top bar, split out so they are testable without
/// rendering a view.
enum CanvasTopBarDisplay {

    /// What a Return in the search field should do.
    enum SearchSubmit: Equatable {
        /// Nothing: the field is empty.
        case none
        /// Run the query and show the results in the Navigator's Search page.
        case run
        /// The same query already has results: reveal the next one, the way Return steps through
        /// hits in every macOS find field.
        case advance
    }

    /// The field's Return, decided from what was last run.
    static func searchSubmit(query: String, lastRunQuery: String?, hitCount: Int) -> SearchSubmit {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        if let lastRunQuery, lastRunQuery == trimmed, hitCount > 0 { return .advance }
        return .run
    }

    /// The text after the page field: `/ 6`, or `· 3 / 23` when the printed sheet label in the
    /// field is not the page's position.
    static func pageTrailingText(pageLabel: String, pageIndex: Int, pageCount: Int) -> String {
        if pageLabel != String(pageIndex + 1) {
            let format = NSLocalizedString(
                "· %1$d / %2$d",
                comment: "Canvas bar page control: position and page count, after a printed sheet label"
            )
            return String(format: format, pageIndex + 1, pageCount)
        }
        let format = NSLocalizedString("/ %d", comment: "Canvas bar page control: page count after the page field")
        return String(format: format, pageCount)
    }

    /// The spoken page position, `Page 3 of 23`, or `Page A-101, 3 of 23`.
    static func pageAccessibilityValue(pageLabel: String, pageIndex: Int, pageCount: Int) -> String {
        if pageLabel != String(pageIndex + 1) {
            let format = NSLocalizedString(
                "Page %1$@, %2$d of %3$d",
                comment: "Canvas bar page field, spoken: printed sheet label, position, page count"
            )
            return String(format: format, pageLabel, pageIndex + 1, pageCount)
        }
        let format = NSLocalizedString(
            "Page %1$d of %2$d",
            comment: "Canvas bar page field, spoken: position and page count"
        )
        return String(format: format, pageIndex + 1, pageCount)
    }

    /// `Undo Move Markup`, or plain `Undo` when the action has no name.
    static func actionTitle(_ base: String, actionName: String) -> String {
        let name = actionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return base }
        return "\(base) \(name)"
    }

    /// A control title with its shortcut in brackets, the way every toolbar tooltip prints it.
    static func titleWithShortcut(_ title: String, binding: ZPDFKeyBinding?) -> String {
        StatusBarDisplay.titleWithShortcut(title, binding: binding)
    }

    /// The compact hit position shown inside the search field: `3/12`, or `12` before any hit
    /// is revealed. `nil` when there is nothing to show.
    static func searchPositionText(position: Int?, count: Int) -> String? {
        guard count > 0 else { return nil }
        guard let position else { return String(count) }
        let format = NSLocalizedString("%1$lld/%2$lld", comment: "Canvas bar search field: revealed hit / total hits")
        return String(format: format, Int64(position), Int64(count))
    }

    /// The Navigator toggle's spoken state.
    static func navigatorValue(isVisible: Bool) -> String {
        isVisible
            ? NSLocalizedString("Open", comment: "Accessibility value: the Navigator is open")
            : NSLocalizedString("Closed", comment: "Accessibility value: the Navigator is closed")
    }

    /// The Navigator toggle's help, naming what a click will do.
    static func navigatorHelp(isVisible: Bool, binding: ZPDFKeyBinding?) -> String {
        let title = isVisible
            ? NSLocalizedString("Hide the Navigator", comment: "Canvas bar sidebar toggle help, Navigator open")
            : NSLocalizedString("Show the Navigator", comment: "Canvas bar sidebar toggle help, Navigator closed")
        return titleWithShortcut(title, binding: binding)
    }
}

// MARK: - Actions

/// What the bar's controls do, against the shell environment. Split from the view so tests can
/// drive the same paths the buttons take.
@MainActor
enum CanvasTopBarActions {

    /// Runs a button's command through the shell, so page turns refresh the page-scoped panels
    /// exactly as the menu and the keyboard do.
    static func press(_ control: CanvasTopBarControl, environment: ProjectShellEnvironment) {
        guard let command = control.command else { return }
        environment.perform(command)
    }

    /// Applies a typed zoom. Text that is not a usable percentage changes nothing.
    ///
    /// - Returns: `true` when the text was applied.
    @discardableResult
    static func commitZoom(_ text: String, environment: ProjectShellEnvironment) -> Bool {
        guard let percent = StatusBarDisplay.zoomPercent(fromTyped: text) else { return false }
        environment.canvas.setZoom(percent / 100)
        return true
    }

    /// Applies a typed page: label first, position second, and a page turn the page-scoped
    /// panels hear of.
    @discardableResult
    static func commitPage(_ text: String, environment: ProjectShellEnvironment) -> Bool {
        StatusBarDisplay.commitTypedPage(text, environment: environment)
    }

    /// The search field's Return.
    ///
    /// A new query runs and opens the Navigator on its Search page so the results are visible
    /// — without taking the caret out of this field. The same query again reveals the next hit.
    ///
    /// - Returns: the query that was run, for the next Return to compare against, or the
    ///   previous one when nothing new ran.
    @discardableResult
    static func submitSearch(
        query: String,
        lastRunQuery: String?,
        environment: ProjectShellEnvironment
    ) -> String? {
        let search = environment.search
        switch CanvasTopBarDisplay.searchSubmit(
            query: query,
            lastRunQuery: lastRunQuery,
            hitCount: search.hits.count
        ) {
        case .none:
            return lastRunQuery
        case .advance:
            environment.advanceSearch(by: 1)
            return lastRunQuery
        case .run:
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if search.query != trimmed { search.query = trimmed }
            search.runSearch()
            environment.layoutController?.revealNavigatorSection(.search)
            return trimmed
        }
    }
}

// MARK: - The bar

/// The bar across the top of the canvas: page navigation, zoom, the Navigator toggle and fit,
/// undo and redo, and the document search field with its options.
///
/// Matches the 2026-09-23 main-window mockup. Everything it shows is read from the presenters —
/// the page label and count, the zoom, the search query and its hits — and everything it does
/// goes through ``ProjectShellEnvironment/perform(_:)`` or the search presenter, the same routes
/// the menu bar and the keyboard take. With no document open the page and zoom controls
/// disappear and the bar says so, rather than showing `1 / 0`.
public struct CanvasTopBar: View {

    private let environment: ProjectShellEnvironment
    private let undoState: CanvasUndoState?

    /// The bar's height in points: the design system's canvas bar height, from the mockup's band
    /// between the panel tops and the page.
    public static let height: CGFloat = ZPDFSpacing.Chrome.canvasBarHeight

    /// Creates the bar.
    ///
    /// - Parameters:
    ///   - environment: the shell the controls act on.
    ///   - undoState: Undo and Redo availability, written by the app tier. `nil` leaves both
    ///     buttons enabled and the Edit menu's validation in charge.
    public init(environment: ProjectShellEnvironment, undoState: CanvasUndoState? = nil) {
        self.environment = environment
        self.undoState = undoState
    }

    public var body: some View {
        // R-079: the rows are handed only what the bar shows — the page and the zoom — and are
        // skipped when that is unchanged. The bar used to read the whole snapshot and rebuild
        // all four arrangements on every publish: every scroll frame, every command refresh,
        // every snap toggle and tool note, none of which it draws.
        CanvasTopBarRows(
            environment: environment,
            undoState: undoState,
            snapshot: Self.shownSnapshot(environment.status.snapshot)
        )
        .equatable()
        .padding(.horizontal, ZPDFSpacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No ground of its own: the canvas column paints the chrome, and the bar draws only the
        // mockup's rounded control groups on it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(NSLocalizedString(
            "Canvas controls",
            comment: "Accessibility label for the bar above the canvas"
        )))
    }

    /// The snapshot as the bar shows it: the page's label, position and count and the zoom.
    /// Everything else takes the snapshot's defaults, so a publish that moved only the strip's
    /// readouts leaves the bar alone. A field the bar starts to show must be carried here.
    static func shownSnapshot(_ snapshot: StatusBarSnapshot) -> StatusBarSnapshot {
        StatusBarSnapshot(
            pageLabel: snapshot.pageLabel,
            pageIndex: snapshot.pageIndex,
            pageCount: snapshot.pageCount,
            pageDimensionsText: "",
            activeScaleDisplay: "",
            outputUnitSymbol: "",
            zoomDisplayString: snapshot.zoomDisplayString
        )
    }
}

/// The canvas bar's rows: every density, the first that fits drawn. Equatable over what they
/// draw, so ``CanvasTopBar`` re-runs them only when the page or the zoom changed (R-079). The
/// Navigator toggle, undo and redo and the search field observe their own state as before.
struct CanvasTopBarRows: View, Equatable {

    let environment: ProjectShellEnvironment
    let undoState: CanvasUndoState?
    /// The snapshot as ``CanvasTopBar/shownSnapshot(_:)`` gives it.
    let snapshot: StatusBarSnapshot

    nonisolated static func == (lhs: CanvasTopBarRows, rhs: CanvasTopBarRows) -> Bool {
        lhs.snapshot == rhs.snapshot && lhs.environment === rhs.environment && lhs.undoState === rhs.undoState
    }

    var body: some View {
        let hasDocument = StatusBarDisplay.hasDocument(snapshot)
        // A narrow canvas column sheds groups from the right rather than clipping or holding the
        // column open: the search field first (Search stays one click away in the Navigator and
        // on ⌘F), then undo and redo (Edit menu, ⌘Z), then the Navigator toggle and fit. Page
        // navigation and zoom are the last to go, because they are the bar's reason to exist.
        ViewThatFits(in: .horizontal) {
            ForEach(CanvasTopBarDensity.allCases, id: \.self) { density in
                row(density: density, snapshot: snapshot, hasDocument: hasDocument)
            }
        }
    }

    private func row(density: CanvasTopBarDensity, snapshot: StatusBarSnapshot, hasDocument: Bool) -> some View {
        HStack(spacing: ZPDFSpacing.s) {
            if hasDocument {
                CanvasPageControl(environment: environment, snapshot: snapshot)
                CanvasBarSeparator()
                CanvasZoomControl(environment: environment, displayString: snapshot.zoomDisplayString)
                if density.shows(.fitPage) {
                    CanvasBarSeparator()
                    HStack(spacing: CanvasBarMetrics.viewPairSpacing) {
                        navigatorToggle
                        iconButton(.fitPage)
                    }
                }
                if density.shows(.undo) {
                    CanvasBarSeparator()
                    HStack(spacing: CanvasBarMetrics.historyPairSpacing) {
                        undoButton
                        redoButton
                    }
                }
            } else {
                Text(StatusBarDisplay.pageText(snapshot))
                    .zpdfText(.control, CanvasBarPalette.secondaryText)
                    .padding(.leading, ZPDFSpacing.s)
                navigatorToggle
            }
            Spacer(minLength: ZPDFSpacing.l)
            if hasDocument, density.shows(.searchField) {
                CanvasSearchField(environment: environment)
                CanvasSearchOptionsMenu(environment: environment)
            }
        }
    }

    private func binding(_ command: ZPDFCommandID) -> ZPDFKeyBinding? {
        environment.commands.command(command)?.binding
    }

    private func iconButton(_ control: CanvasTopBarControl, isEnabled: Bool = true, help: String? = nil) -> some View {
        CanvasBarIconButton(
            control: control,
            help: help ?? CanvasTopBarDisplay.titleWithShortcut(
                control.title,
                binding: control.command.flatMap(binding)
            ),
            spokenShortcut: control.command.flatMap(binding)?.spokenString
        ) {
            CanvasTopBarActions.press(control, environment: environment)
        }
        .disabled(!isEnabled)
    }

    private var navigatorToggle: some View {
        let isVisible = environment.isSurfaceVisible(.navigator)
        return iconButton(
            .toggleNavigator,
            help: CanvasTopBarDisplay.navigatorHelp(isVisible: isVisible, binding: binding(.toggleNavigator))
        )
        .accessibilityValue(Text(CanvasTopBarDisplay.navigatorValue(isVisible: isVisible)))
    }

    private var undoButton: some View {
        iconButton(
            .undo,
            isEnabled: undoState?.isUndoEnabled ?? true,
            help: undoState?.undoHelp(binding: binding(.undo))
        )
    }

    private var redoButton: some View {
        iconButton(
            .redo,
            isEnabled: undoState?.isRedoEnabled ?? true,
            help: undoState?.redoHelp(binding: binding(.redo))
        )
    }
}

// MARK: - Palette

/// Every colour the canvas bar draws, as design-system tokens. One place to read, so the bar
/// cannot drift from the chrome and a test can pin that nothing here is a raw colour.
enum CanvasBarPalette {
    /// The inset well of the page and zoom fields. The controls around them sit flat on the
    /// bar's ground; only the fields are wells, as the mockup draws them.
    static let field: ZPDFColorToken = .elevated
    // The search field is the design system's `ZPDFSearchField`, painted from its own paint
    // table — inset ground, borderStrong edge, accentBlue while focused (W-047).
    /// A glyph at rest.
    static let glyph: ZPDFColorToken = .textPrimary
    /// A disabled glyph (the mockup's greyed Redo).
    static let glyphDisabled: ZPDFColorToken = .textTertiary
    /// Secondary text: `/ 6`.
    static let secondaryText: ZPDFColorToken = .textSecondary
    /// The hairline between control groups.
    static let separator: ZPDFColorToken = .border

    /// Every token above, for the token-use test.
    static let all: [ZPDFColorToken] = [
        field, glyph, glyphDisabled, secondaryText, separator
    ]
}

/// Bar geometry, from the mockup's measured pitch.
enum CanvasBarMetrics {
    /// A control row's height inside the bar.
    static let controlHeight: CGFloat = ZPDFSpacing.Chrome.barControlHeight
    /// A page or zoom field's height.
    static let fieldHeight: CGFloat = 28
    /// The glyph frame: `ZPDFGlyphView` draws the symbol at 0.82 of it, so 18 lands on the
    /// mockup's ~15 px glyphs (16 pt glyphs by eye).
    static let glyph: CGFloat = 18
    /// The gap between the two view buttons (sidebar 667 → fit 716 in the mockup, 28 pt hits).
    static let viewPairSpacing: CGFloat = 20
    /// The gap between Undo and Redo (778 → 817).
    static let historyPairSpacing: CGFloat = 10
    /// The vertical divider between groups: 1 px × 22 pt.
    static let separatorHeight: CGFloat = 22
}

/// A control group sitting flat on the bar: its height and nothing else. No capsule — the
/// mockup separates groups with hairlines, not fills.
struct CanvasBarGroupBackground: ViewModifier {

    /// The group's height inside the bar.
    static let height: CGFloat = CanvasBarMetrics.controlHeight

    func body(content: Content) -> some View {
        content.frame(height: Self.height)
    }
}

// MARK: - Pieces

/// The quiet vertical hairline between control groups.
struct CanvasBarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(ZPDFColor.color(CanvasBarPalette.separator))
            .frame(width: ZPDFStroke.regular, height: CanvasBarMetrics.separatorHeight)
            .padding(.horizontal, ZPDFSpacing.xs)
            .accessibilityHidden(true)
    }
}

/// A glyph-only button: quiet at rest, a soft fill on hover, a firmer one while pressed, the
/// Zenit focus ring under the keyboard, and dimmed — not hidden — when disabled, so the bar
/// never reflows.
struct CanvasBarIconButton: View {

    let control: CanvasTopBarControl
    let help: String
    let spokenShortcut: String?
    let action: () -> Void

    /// The square hit area, in points.
    static let side: CGFloat = 28

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            if let symbol = control.symbol {
                ZPDFGlyphView(.symbol(symbol), size: CanvasBarMetrics.glyph)
            }
        }
        .buttonStyle(CanvasBarButtonStyle(isHovering: isHovering))
        .focusable(isEnabled)
        .focused($isFocused)
        .zpdfFocusRing(isFocused, cornerRadius: ZPDFRadius.control)
        .onHover { isHovering = $0 }
        .zpdfAnimation(.micro, value: isHovering)
        .help(help)
        .accessibilityLabel(Text(control.title))
        .accessibilityHint(Text(spokenShortcut ?? ""))
    }
}

/// The canvas bar's button look: the glyph on a rounded square whose fill follows hover and
/// press.
struct CanvasBarButtonStyle: ButtonStyle {

    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, isHovering: isHovering)
    }

    /// The overlay a button draws for its state: none at rest or disabled, the hover wash under
    /// the pointer, the pressed wash while held.
    static func overlay(isEnabled: Bool, isHovering: Bool, isPressed: Bool) -> ZPDFColorToken? {
        ZPDFInteractionState.resolve(isHovering: isHovering, isPressed: isPressed, isEnabled: isEnabled).overlay
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let isHovering: Bool

        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let overlay = CanvasBarButtonStyle.overlay(
                isEnabled: isEnabled,
                isHovering: isHovering,
                isPressed: configuration.isPressed
            )
            configuration.label
                .foregroundStyle(ZPDFColor.color(isEnabled ? CanvasBarPalette.glyph : CanvasBarPalette.glyphDisabled))
                .frame(width: CanvasBarIconButton.side, height: CanvasBarIconButton.side)
                .background {
                    if let overlay {
                        RoundedRectangle(cornerRadius: ZPDFRadius.control, style: .continuous)
                            .fill(ZPDFColor.color(overlay))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: ZPDFRadius.control, style: .continuous))
        }
    }
}

/// The inset well a page or zoom field sits in.
struct CanvasBarFieldWell: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: ZPDFRadius.control, style: .continuous)
                .fill(ZPDFColor.color(CanvasBarPalette.field))
        }
    }
}

/// `‹  [ 1 ]  / 6  ›` — the page arrows either side of a field you can type a page into.
///
/// The arrows disable at the ends rather than wrapping, the field takes a printed sheet label
/// first and a position second, and text that names no page reverts. These are the page
/// control's rules (2026-08-26), carried over from the status bar unchanged.
struct CanvasPageControl: View {

    let environment: ProjectShellEnvironment
    let snapshot: StatusBarSnapshot

    @State private var text: String = ""
    @FocusState private var isEditing: Bool

    private var fieldText: String { snapshot.pageLabel }

    var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            arrow(.previousPage, isEnabled: environment.document.canGoToPreviousPage)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .zpdfText(.monoNumeric, .textPrimary)
                .frame(minWidth: 40, idealWidth: 48, maxWidth: 72)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, ZPDFSpacing.s)
                .frame(height: CanvasBarMetrics.fieldHeight)
                .modifier(CanvasBarFieldWell())
                .zpdfFocusRing(isEditing, cornerRadius: ZPDFRadius.control)
                .focused($isEditing)
                .onSubmit { commit() }
                .onAppear { text = fieldText }
                .onChange(of: fieldText) { _, newValue in
                    if !isEditing { text = newValue }
                }
                .onChange(of: isEditing) { _, editing in
                    // Leaving without Return reverts: a half-typed page number left on screen
                    // would claim the canvas is somewhere it is not.
                    if !editing { text = fieldText }
                }
                .help(NSLocalizedString(
                    "Type a page number or a sheet label and press Return",
                    comment: "Canvas bar page field help"
                ))
                .accessibilityLabel(Text(CanvasTopBarControl.pageField.title))
                .accessibilityValue(Text(CanvasTopBarDisplay.pageAccessibilityValue(
                    pageLabel: snapshot.pageLabel,
                    pageIndex: snapshot.pageIndex,
                    pageCount: snapshot.pageCount
                )))
            Text(CanvasTopBarDisplay.pageTrailingText(
                pageLabel: snapshot.pageLabel,
                pageIndex: snapshot.pageIndex,
                pageCount: snapshot.pageCount
            ))
            .zpdfText(.monoNumeric, CanvasBarPalette.secondaryText)
            .fixedSize()
            .padding(.trailing, ZPDFSpacing.xs)
            .accessibilityHidden(true)
            arrow(.nextPage, isEnabled: environment.document.canGoToNextPage)
        }
        .modifier(CanvasBarGroupBackground())
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private func arrow(_ control: CanvasTopBarControl, isEnabled: Bool) -> some View {
        let binding = control.command.flatMap { environment.commands.command($0)?.binding }
        return CanvasBarIconButton(
            control: control,
            help: CanvasTopBarDisplay.titleWithShortcut(control.title, binding: binding),
            spokenShortcut: binding?.spokenString
        ) {
            CanvasTopBarActions.press(control, environment: environment)
        }
        .disabled(!isEnabled)
    }

    private func commit() {
        CanvasTopBarActions.commitPage(text, environment: environment)
        // Whatever happened, the field shows where the canvas actually is.
        text = fieldText
        isEditing = false
    }
}

/// `−  100%  +` — zoom steps either side of a field you can type a percentage into. The field's
/// context menu carries the presets and the three fits.
struct CanvasZoomControl: View {

    let environment: ProjectShellEnvironment
    let displayString: String

    @State private var text: String = ""
    @FocusState private var isEditing: Bool

    static let presetPercentages: [Double] = [25, 50, 100, 200, 400]

    var body: some View {
        HStack(spacing: ZPDFSpacing.xs) {
            step(.zoomOut)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .zpdfText(.monoNumeric, .textPrimary)
                .frame(width: 56, height: CanvasBarMetrics.fieldHeight)
                .modifier(CanvasBarFieldWell())
                .focused($isEditing)
                .zpdfFocusRing(isEditing, cornerRadius: ZPDFRadius.control)
                .onSubmit { commit() }
                .onAppear { text = displayString }
                .onChange(of: displayString) { _, newValue in
                    if !isEditing { text = newValue }
                }
                .onChange(of: isEditing) { _, editing in
                    if !editing { text = displayString }
                }
                .contextMenu { presets }
                .help(NSLocalizedString(
                    "Type a zoom percentage and press Return. Control-click for presets.",
                    comment: "Canvas bar zoom field help"
                ))
                .accessibilityLabel(Text(CanvasTopBarControl.zoomField.title))
                .accessibilityValue(Text(displayString))
            step(.zoomIn)
        }
        .modifier(CanvasBarGroupBackground())
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var presets: some View {
        ForEach(Self.presetPercentages, id: \.self) { percent in
            Button(StatusBarDisplay.zoomPresetTitle(percent: percent)) {
                environment.canvas.setZoom(percent / 100)
            }
        }
        Divider()
        // Shortcuts printed in the title rather than registered again: the menu bar owns them.
        fitButton(NSLocalizedString("Fit Width", comment: "Zoom preset"), command: .fitWidth)
        fitButton(NSLocalizedString("Actual Size", comment: "Zoom preset"), command: .actualSize)
        fitButton(NSLocalizedString("Fit Page", comment: "Zoom preset"), command: .fitPage)
    }

    private func fitButton(_ title: String, command: ZPDFCommandID) -> some View {
        Button(CanvasTopBarDisplay.titleWithShortcut(
            title,
            binding: environment.commands.command(command)?.binding
        )) {
            environment.perform(command)
        }
    }

    private func step(_ control: CanvasTopBarControl) -> some View {
        let binding = control.command.flatMap { environment.commands.command($0)?.binding }
        return CanvasBarIconButton(
            control: control,
            help: CanvasTopBarDisplay.titleWithShortcut(control.title, binding: binding),
            spokenShortcut: binding?.spokenString
        ) {
            CanvasTopBarActions.press(control, environment: environment)
        }
    }

    private func commit() {
        if !CanvasTopBarActions.commitZoom(text, environment: environment) {
            text = displayString
            return
        }
        isEditing = false
    }
}

/// The rounded "Search in document" field.
///
/// Bound to the same search presenter as the Navigator's Search page, so the two fields never
/// disagree. Return runs the query and opens the results in the Navigator; Return again steps to
/// the next hit. While there are results the field shows where you are (`3/12`), and a clear
/// button — or Escape — clears the search.
///
/// W-047: the design system's ``ZPDFSearchField`` at the canvas bar's widths, no longer a
/// hand-built copy of it. The copy had drifted: Escape only dropped focus, and it had no hover
/// paint or focus ring.
struct CanvasSearchField: View {

    let environment: ProjectShellEnvironment

    @State private var lastRunQuery: String?

    private var search: any SearchPresenting { environment.search }

    /// The field's width, from the mockup (215 px at 1672 px wide).
    static let width: CGFloat = 216
    /// The narrowest the field goes before the bar drops it.
    static let minimumWidth: CGFloat = 150

    /// The placeholder, as the mockup words it.
    static var placeholder: String {
        NSLocalizedString("Search in document", comment: "Canvas bar search field placeholder")
    }

    var body: some View {
        ZPDFSearchField(
            text: Binding(get: { search.query }, set: { search.query = $0 }),
            placeholder: Self.placeholder,
            accessibilityLabel: CanvasTopBarControl.searchField.title,
            accessibilityValue: search.resultSummary,
            accessoryText: CanvasTopBarDisplay.searchPositionText(
                position: search.activeHitPosition,
                count: search.hits.count
            ),
            onClear: {
                search.clear()
                lastRunQuery = nil
            },
            onSubmit: {
                lastRunQuery = CanvasTopBarActions.submitSearch(
                    query: search.query,
                    lastRunQuery: lastRunQuery,
                    environment: environment
                )
            }
        )
        .frame(minWidth: Self.minimumWidth, idealWidth: Self.width, maxWidth: Self.width)
    }
}

/// The sliders button at the bar's far end: which bodies of text the search looks in, Match
/// Case, Whole Words and — once a second drawing is open — whether it
/// reaches every open drawing. The presenter's own scope, so the Navigator's Search page shows
/// the same choices.
struct CanvasSearchOptionsMenu: View {

    let environment: ProjectShellEnvironment

    private var search: any SearchPresenting { environment.search }

    var body: some View {
        Menu {
            // Offering one drawing versus the same one drawing would be a control that does
            // nothing, so the reach appears with the second open drawing.
            SearchOptionsMenuContent(search: search, offersAllDrawings: environment.document.tabs.count > 1)
        } label: {
            ZPDFGlyphView(.symbol(.sliders), size: CanvasBarMetrics.glyph)
                .foregroundStyle(ZPDFColor.color(CanvasBarPalette.glyph))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: CanvasBarIconButton.side, height: CanvasBarIconButton.side)
        .help(CanvasTopBarControl.searchOptions.title)
        .accessibilityLabel(Text(CanvasTopBarControl.searchOptions.title))
        .accessibilityValue(Text(search.scope.summary))
    }
}

#if DEBUG
struct CanvasTopBar_Previews: PreviewProvider {
    static var previews: some View {
        CanvasTopBar(environment: ProjectShellEnvironment.mock())
            .frame(width: 1075)
    }
}
#endif
