import AppKit
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Whether the ledger draws as a flat list or as a grouped outline.
public enum LedgerTableMode: String, Hashable, Sendable, CaseIterable, Identifiable {

    /// Every row at one level, in `NSTableView`.
    case flat
    /// Rows nested under group headings, in `NSOutlineView`.
    case grouped

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized name for the mode control.
    public var displayName: String {
        switch self {
        case .flat: return NSLocalizedString("Flat", comment: "Quantity Ledger table mode")
        case .grouped: return NSLocalizedString("Grouped", comment: "Quantity Ledger table mode")
        }
    }
}

/// What the table is showing at one visual row.
public enum LedgerVisualRow: Hashable, Sendable {

    /// A data row at a display position in ``LedgerGroupPlan/order``.
    case row(displayPosition: Int)
    /// A group heading.
    case group(path: String)
    /// Nothing, for an index the table no longer has.
    case none
}

/// Callbacks the ledger table sends to whatever owns it.
///
/// Every method has a default no-op implementation, so a host adopts only the parts it
/// needs and the protocol can grow without breaking conformers.
@MainActor
public protocol LedgerTableControllerDelegate: AnyObject {

    /// The row selection changed from inside the table.
    func ledgerTable(_ controller: LedgerTableController, didChangeSelection rowIDs: Set<UUID>)
    /// A row was activated with Return or a double click, which jumps to its markup.
    func ledgerTable(_ controller: LedgerTableController, didActivate rowID: UUID)
    /// The user changed column order, width, visibility or pinning.
    func ledgerTable(_ controller: LedgerTableController, didChangeColumns columns: [LedgerColumn])
    /// The user clicked a column header to sort.
    func ledgerTable(_ controller: LedgerTableController, didRequestSort columnID: LedgerColumnID, ascending: Bool)
    /// A group heading was expanded or collapsed.
    func ledgerTable(_ controller: LedgerTableController, didSetExpanded expanded: Bool, groupPath: String)
    /// The header asked for a sort with every level it now carries, outermost first.
    ///
    /// The table keeps the previous levels when a new header is clicked, so this is the
    /// multi-column request "Page, then Subject" (IM-099). The default forwards the first
    /// level to ``ledgerTable(_:didRequestSort:ascending:)``, so a host that only knows
    /// single-column sorting keeps working unchanged.
    func ledgerTable(_ controller: LedgerTableController, didRequestSort descriptors: [LedgerSortDescriptor])
}

public extension LedgerTableControllerDelegate {
    func ledgerTable(_ controller: LedgerTableController, didChangeSelection rowIDs: Set<UUID>) {}
    func ledgerTable(_ controller: LedgerTableController, didActivate rowID: UUID) {}
    func ledgerTable(_ controller: LedgerTableController, didChangeColumns columns: [LedgerColumn]) {}
    func ledgerTable(_ controller: LedgerTableController, didRequestSort columnID: LedgerColumnID, ascending: Bool) {}
    func ledgerTable(_ controller: LedgerTableController, didSetExpanded expanded: Bool, groupPath: String) {}
    func ledgerTable(_ controller: LedgerTableController, didRequestSort descriptors: [LedgerSortDescriptor]) {
        guard let first = descriptors.first else { return }
        ledgerTable(controller, didRequestSort: first.column, ascending: first.ascending)
    }
}

/// The Quantity Ledger table.
///
/// `NSOutlineView` draws the grouped ledger and `NSTableView` draws the flat one. Both are
/// fed by index from a ``LedgerRowProviding`` source: the controller never builds an array
/// of view models, and the only rows it touches per frame are the ones inside the scroll
/// window. That is what keeps a 100 000 row project responsive, and it is what
/// `LedgerBenchmarkTests` measures.
///
/// Pinned columns are drawn by a second, non-scrolling table laid over the leading edge of
/// the scroll view. The main table still owns every column, so keyboard order, sorting and
/// VoiceOver see one table, not two.
@MainActor
public final class LedgerTableController: NSViewController {

    // MARK: Configuration

    /// Where rows come from.
    ///
    /// Replacing the source re-derives the columns from it: columns the new source still
    /// has keep their width, order, visibility, pinning and alignment; columns it adds
    /// appear in their default place; columns it lacks are dropped. The old source's column
    /// set used to survive the swap, so a new column never showed and a vanished one drew
    /// blank cells (BH-738).
    public var rowSource: any LedgerRowProviding {
        didSet {
            watchPlanSource()
            // Re-reads the new source's columns (``adoptSourceColumns()``) before the plan.
            rebuildPlan()
        }
    }

    /// The source's columns as the table last adopted them, in the default arrangement.
    ///
    /// Every ``rebuildPlan()`` compares the source against this, so a column the source added,
    /// renamed, retyped, showed, hid, moved or dropped since — the Column Manager's changes —
    /// reaches the table on the next reload. It is also what tells a change the *source* made
    /// to a column's arrangement apart from one the user made in the table (S-075).
    private var adoptedSourceColumns: [LedgerColumn]

    /// Who hears about selection, activation and column changes.
    public weak var delegate: (any LedgerTableControllerDelegate)?

    /// Flat or grouped.
    public private(set) var mode: LedgerTableMode

    /// Columns in display order, pinned first.
    public private(set) var columns: [LedgerColumn] {
        didSet { invalidateColumnCaches() }
    }

    /// Grouping levels, outermost first.
    public private(set) var groupingColumns: [LedgerColumnID] = []

    /// The current outline, including subtotals.
    public private(set) var plan: LedgerGroupPlan = .empty

    /// Selected markup identifiers.
    public private(set) var selectedRowIDs: Set<UUID> = []

    /// The column whose total is spoken in the accessibility summary.
    public var headlineTotalColumn: LedgerColumnID?

    /// Saved column layouts offered in the header context menu.
    ///
    /// The menu is refilled whenever the store changes. It used to be built only in
    /// `rebuildColumns()`, which a Save Layout or Delete Layout never reaches, so the submenu
    /// kept its old items — no new layout, a deleted one still offered, a stale check mark
    /// (R-125).
    public var layoutStore = LedgerColumnLayoutStore() {
        didSet { refreshHeaderMenu() }
    }

    /// NL-UX-09: the row context menu — Zoom To, Select on Canvas, Change Status, Lock, Delete —
    /// routed to the host. `nil` leaves the rows without a menu rather than showing dead items.
    public var rowMenu: LedgerRowMenuConfiguration? {
        didSet { installRowMenus() }
    }

    /// NL-UX-09 (r2-layers): told which markup's row the pointer is over, `nil` when it leaves
    /// the rows or rests on a group heading — the canvas outlines that markup
    /// (`LedgerTableController+HoverAndDrag.swift`).
    public var onHoverMarkup: (@MainActor (UUID?) -> Void)?
    /// The markup whose row the pointer is over.
    public internal(set) var hoveredRowID: UUID?

    /// Called when the user picks "Save Layout…" so the host can present a naming sheet.
    public var onSaveLayoutRequested: (() -> Void)?

    /// Called when the user picks "Add Column…" or "Manage Columns…" in the header menu
    /// (NL-QTY-02). `nil` hides both items: a menu item with nothing behind it is a lie.
    public var onManageColumnsRequested: ((_ addingNew: Bool) -> Void)? {
        didSet { refreshHeaderMenu() }
    }

    /// Called when the header menu changed ``layoutStore`` — applying a saved layout makes it
    /// the active one — so the host can persist the store (BH-705).
    public var onLayoutStoreChange: (@MainActor (LedgerColumnLayoutStore) -> Void)?

    /// Whether group rows show their subtotals. Off leaves only the headings, which is what
    /// the grouping bar's "Subtotals" check box promises (BH-731).
    public var showsSubtotals = true {
        didSet {
            guard showsSubtotals != oldValue else { return }
            reloadRows()
        }
    }

    /// Unit policy used for subtotal text.
    public var unitPolicy: LedgerUnitPolicy = .metric

    /// Rounding used for subtotal text.
    public var rounding: LedgerRounding = .exact

    /// Locale used for subtotal text. The user's current locale unless a test pins one.
    public var locale: Locale = .autoupdatingCurrent

    /// Where Copy writes. `NSPasteboard.general` in the app; a recorder in tests, which
    /// must never touch the real pasteboard (IM-015).
    public var copyPasteboard: any LedgerPasteboardWriting = SystemLedgerPasteboard()

    /// Receives a committed inline edit as a one-markup bulk-edit request, so an edit made
    /// in a cell goes through exactly the path the Bulk Edit panel's Apply uses (IM-013).
    ///
    /// Inline editing is offered only while this is set: a host that cannot write edits
    /// shows read-only cells rather than an editor whose value goes nowhere.
    public var onCommitInlineEdit: (@MainActor (LedgerBulkEditRequest) -> Void)?
    /// Called instead of the system alert sound when a typed number cannot become a value
    /// (NL-QTY-04). A test installs it so a suite never beeps at the person at the machine.
    public var onInlineEditRejected: (@MainActor (LedgerColumn) -> Void)?

    /// The cell an inline editor is open on, or `nil`.
    public private(set) var editingCell: LedgerCellAddress?

    /// Group paths that are collapsed. Everything else is expanded — the default state of
    /// a fresh outline — so persisting this set is what makes a collapsed group stay
    /// collapsed across relaunches.
    public private(set) var collapsedGroupPaths: Set<String> = []

    /// Called whenever ``collapsedGroupPaths`` changes from inside the table, so a host
    /// can persist it.
    public var onCollapsedGroupPathsChange: (@MainActor (Set<String>) -> Void)?

    /// Whether a selection change should be echoed to the delegate. Cleared while the
    /// canvas is pushing a selection in, so the two never ping-pong.
    private var isApplyingExternalSelection = false

    /// Set while expansion changes arrive in bulk — restoring a plan, Expand All, Collapse
    /// All, revealing a selection — so each group does not reload the pinned band and
    /// persist the collapsed set on its own (IM-100).
    private var isBatchingExpansion = false
    /// Whether a batched expansion change altered ``collapsedGroupPaths``.
    private var batchedCollapsedPathsChanged = false
    /// Set while a column width is copied to the peer tables, so the copy does not echo.
    private var isSynchronizingColumnWidth = false

    /// How many times a plan was built, for tests that assert a change builds once.
    private(set) var planBuildCount = 0
    /// How many times the rows were reloaded without a new plan, for tests that assert a
    /// column change redraws the rows already on screen (R-135) or does not (a live resize).
    private(set) var rowReloadCount = 0
    /// Where the current ``plan`` came from (IM-011): the source's own outline, or none, in
    /// which case the rows are listed flat. A table over a presenter that supplies its outline
    /// is always ``LedgerPlanOrigin/supplied``.
    public private(set) var planOrigin: LedgerPlanOrigin = .supplied
    /// Every pinned-band reload, for tests that assert expansion reloads it once.
    var pinnedReloadCountForTesting: Int { pinnedTableView.reloadDataCallCount }

    /// Whether ``plan``'s order is the identity, so a display position is a source index.
    private var planOrderIsIdentity = true
    /// Source index to display position, built on first use when the order is not the identity.
    private var displayPositionBySource: [Int]?

    /// Column identity to column, rebuilt lazily after ``columns`` changes (IM-202).
    private var columnIndexCache: [LedgerColumnID: LedgerColumn]?
    /// The first visible column — the one that carries the row's colour swatch.
    private var leadingVisibleColumnIDCache: LedgerColumnID??
    /// The column a group heading's words are drawn in.
    private var groupHeadingColumnIDCache: LedgerColumnID??

    /// The last editable column the user clicked, which Return opens for editing.
    private(set) var focusedColumnID: LedgerColumnID?
    /// The open inline editor, if any.
    private var inlineEditor: NSView?
    /// Set while an editor is being closed, so the end-of-editing notification it posts
    /// does not commit a second time.
    private var isEndingInlineEdit = false

    // MARK: Views

    private let mainScrollView = NSScrollView()
    private let pinnedScrollView = NSScrollView()
    private lazy var tableView = LedgerTableView()
    private lazy var outlineView = LedgerOutlineView()
    private lazy var pinnedTableView = LedgerTableView()

    /// The pinned column band, for tests that drive a selection the way a person's click
    /// on the Type/Subject columns does (LT-40). Never used by shipping code.
    var pinnedTableViewForTesting: NSTableView { pinnedTableView }
    /// The flat main table, for tests that drive a click on the scrolling columns and count
    /// how many times the delegate hears about it (CR-63). Never used by shipping code.
    var mainTableViewForTesting: NSTableView { tableView }
    /// The grouped outline, for the same tests in grouped mode. Never used by shipping code.
    var outlineViewForTesting: NSOutlineView { outlineView }
    /// The header context menu, one instance shared by the three header views. It is refilled
    /// from the controller's current state each time it opens (`menuNeedsUpdate`) and whenever
    /// the layout store changes, so it can never show a layout list from before the last save
    /// (R-125).
    lazy var headerMenu: NSMenu = {
        let menu = NSMenu(title: NSLocalizedString("Columns", comment: "Ledger header context menu title"))
        menu.autoenablesItems = false
        menu.delegate = self
        return menu
    }()
    var tableViewForMenu: NSTableView { tableView }
    var outlineViewForMenu: NSTableView { outlineView }
    var pinnedTableViewForMenu: NSTableView { pinnedTableView }
    /// The open inline editor, for tests that type into it. Never used by shipping code.
    var inlineEditorForTesting: NSView? { inlineEditor }
    private let itemCache = LedgerOutlineItemCache()

    /// Markup identity to display position, built on first use and dropped whenever the plan
    /// changes. Without it, every reload and every canvas-driven selection walked all rows.
    private var rowIDIndex: [UUID: Int]?

    /// Group path to slice, built on first use and dropped with the plan. Cell construction
    /// asks for a slice by path once per drawn group cell, which used to walk the group tree.
    private var sliceIndex: [String: LedgerGroupSlice]?

    private var pinnedWidthConstraint: NSLayoutConstraint?
    private var isSynchronizingScroll = false

    /// Fixed row height. A fixed height is what lets `NSTableView` compute its scroll
    /// geometry without measuring every row, which is required at this row count.
    public static let rowHeight: CGFloat = max(
        ZPDFSpacing.Control.listRow,
        ZPDFTypography.lineHeight(.body) + ZPDFSpacing.m
    )

    // MARK: Lifecycle

    /// Creates the controller.
    ///
    /// The initial arrangement is the mockup default:
    /// `Page · Type · Label · Subject · Comment · Value · Unit` visible, everything else
    /// after them, hidden. A saved layout applied later reorders freely; only this
    /// *default* is fixed.
    ///
    /// - Parameters:
    ///   - rowSource: Index-addressable row supply.
    ///   - mode: Flat or grouped.
    ///   - groupingColumns: Grouping levels for the grouped mode.
    public init(
        rowSource: any LedgerRowProviding,
        mode: LedgerTableMode = .flat,
        groupingColumns: [LedgerColumnID] = []
    ) {
        self.rowSource = rowSource
        // Grouped with no grouping levels would draw an empty outline over a full plan —
        // the engine returns no groups, so the outline has no children while the summary
        // counts every row (BH-739). With nothing to group by, the ledger is flat.
        self.mode = groupingColumns.isEmpty ? .flat : mode
        let arranged = LedgerColumnLayout.pinnedFirst(
            LedgerDefaultColumns.arranged(rowSource.ledgerColumns)
        )
        self.columns = arranged
        self.adoptedSourceColumns = arranged
        self.groupingColumns = groupingColumns
        super.init(nibName: nil, bundle: nil)
        watchPlanSource()
    }

    /// Lets a core-backed source rebuild the plan when its pending outline arrives (IM-011).
    private func watchPlanSource() {
        (rowSource as? LedgerGroupPlanProviding)?.watchLedgerGroupPlan { [weak self] in
            self?.rebuildPlan()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // The ledger builds its table in code; there is no nib to decode.
        return nil
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = ZPDFColor.nsColor(.surface).cgColor

        configure(scrollView: mainScrollView, documentView: mode == .grouped ? outlineView : tableView)
        configure(scrollView: pinnedScrollView, documentView: pinnedTableView)
        pinnedScrollView.hasHorizontalScroller = false
        pinnedScrollView.hasVerticalScroller = false
        pinnedScrollView.scrollerStyle = .overlay
        pinnedScrollView.drawsBackground = true

        container.addSubview(mainScrollView)
        container.addSubview(pinnedScrollView)

        let pinnedWidth = pinnedScrollView.widthAnchor.constraint(equalToConstant: 0)
        pinnedWidthConstraint = pinnedWidth

        NSLayoutConstraint.activate([
            mainScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mainScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mainScrollView.topAnchor.constraint(equalTo: container.topAnchor),
            mainScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pinnedScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pinnedScrollView.topAnchor.constraint(equalTo: container.topAnchor),
            pinnedScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pinnedWidth
        ])

        view = container
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setUpTables()
        rebuildPlan()
        observeScrolling()
    }

    // MARK: Set-up

    private func configure(scrollView: NSScrollView, documentView: NSView) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.focusRingType = .exterior
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    private func setUpTables() {
        // A programmatically created table has no header view, and without one there is no
        // place to click to sort and nowhere to hang the column context menu.
        // design-d6: the header band is drawn in the chrome's tokens (LedgerTableAppearance).
        tableView.headerView = LedgerTableHeaderView()
        pinnedTableView.headerView = LedgerTableHeaderView()
        outlineView.headerView = LedgerTableHeaderView()

        for table in [tableView, pinnedTableView] {
            table.style = .plain
            table.rowHeight = Self.rowHeight
            table.usesAlternatingRowBackgroundColors = false
            table.usesAutomaticRowHeights = false
            table.allowsMultipleSelection = true
            table.allowsColumnReordering = true
            table.allowsColumnResizing = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.intercellSpacing = NSSize(width: 0, height: 0)
            table.gridStyleMask = []
            table.backgroundColor = ZPDFColor.nsColor(.surface)
            table.focusRingType = .exterior
            table.dataSource = self
            table.delegate = self
        }
        tableView.doubleAction = #selector(handleDoubleClick(_:))
        tableView.action = #selector(handleClick(_:))
        tableView.target = self
        tableView.onCommand = { [weak self] command in self?.handle(command) ?? false }
        tableView.onHoverRow = { [weak self] row in self?.hover(atVisualRow: row) }   // NL-UX-09
        Self.configureDragOut(tableView)                                              // NL-UX-15
        tableView.setAccessibilityLabel(
            NSLocalizedString("Quantity Ledger rows", comment: "Accessibility label of the flat ledger table")
        )

        pinnedTableView.allowsColumnReordering = false
        pinnedTableView.onCommand = { [weak self] command in self?.handle(command) ?? false }
        pinnedTableView.setAccessibilityLabel(
            NSLocalizedString("Pinned ledger columns", comment: "Accessibility label of the frozen leading columns")
        )

        outlineView.style = .plain
        outlineView.rowHeight = Self.rowHeight
        outlineView.usesAutomaticRowHeights = false
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.gridStyleMask = []
        outlineView.backgroundColor = ZPDFColor.nsColor(.surface)
        outlineView.focusRingType = .exterior
        outlineView.indentationPerLevel = ZPDFSpacing.xl
        outlineView.autosaveExpandedItems = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.doubleAction = #selector(handleDoubleClick(_:))
        outlineView.action = #selector(handleClick(_:))
        outlineView.target = self
        outlineView.onCommand = { [weak self] command in self?.handle(command) ?? false }
        outlineView.onHoverRow = { [weak self] row in self?.hover(atVisualRow: row) }   // NL-UX-09
        Self.configureDragOut(outlineView)                                              // NL-UX-15
        outlineView.setAccessibilityLabel(
            NSLocalizedString("Quantity Ledger groups and rows", comment: "Accessibility label of the grouped ledger outline")
        )

        rebuildColumns()
    }

    private func observeScrolling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainClipViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: mainScrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pinnedClipViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: pinnedScrollView.contentView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Mode and grouping

    /// Switches between the flat table and the grouped outline.
    ///
    /// Grouped mode needs grouping levels; asking for it with none leaves the ledger flat
    /// rather than drawing an empty outline (BH-739). ``setGrouping(_:)`` switches the mode
    /// itself, so a host sets levels, not modes.
    public func setMode(_ newMode: LedgerTableMode) {
        guard newMode != mode else { return }
        guard newMode == .flat || !groupingColumns.isEmpty else { return }
        cancelInlineEdit()
        mode = newMode
        loadViewIfNeeded()
        mainScrollView.documentView = newMode == .grouped ? outlineView : tableView
        rebuildColumns()
        rebuildPlan()
    }

    /// Replaces the grouping levels and rebuilds the outline.
    ///
    /// Builds the plan exactly once. A change that also switches mode used to build it
    /// twice — once inside ``setMode(_:)`` and again here (IM-201).
    public func setGrouping(_ newColumns: [LedgerColumnID]) {
        groupingColumns = newColumns
        let target: LedgerTableMode = newColumns.isEmpty ? .flat : .grouped
        if target != mode {
            setMode(target)
            return
        }
        rebuildPlan()
    }

    /// Expands every group.
    ///
    /// Applied to the plan already on screen: expansion changes nothing the plan holds, so
    /// the full rebuild this used to run was pure cost (IM-201). The pinned band reloads
    /// once and the collapsed set is persisted once, however many groups open (IM-100).
    public func expandAllGroups() {
        collapsedGroupPaths = []
        loadViewIfNeeded()
        if mode == .grouped {
            performExpansionBatch { outlineView.expandItem(nil, expandChildren: true) }
        }
        batchedCollapsedPathsChanged = false
        onCollapsedGroupPathsChange?(collapsedGroupPaths)
    }

    /// Collapses every group, with one pinned reload and one persistence call (IM-100).
    public func collapseAllGroups() {
        loadViewIfNeeded()
        collapsedGroupPaths = plan.allPaths
        if mode == .grouped {
            performExpansionBatch { outlineView.collapseItem(nil, collapseChildren: true) }
        }
        batchedCollapsedPathsChanged = false
        onCollapsedGroupPathsChange?(collapsedGroupPaths)
    }

    /// Replaces the collapsed set wholesale — the restore path for persisted state.
    ///
    /// Paths that do not exist in the current plan are kept: a group that is filtered out
    /// today comes back collapsed tomorrow, which is what "collapsed state persists" means.
    public func setCollapsedGroupPaths(_ paths: Set<String>) {
        collapsedGroupPaths = paths
        rebuildPlan()
    }

    // MARK: Columns

    /// Replaces the column set, keeping pinned columns leading.
    public func setColumns(_ newColumns: [LedgerColumn]) {
        columns = LedgerColumnLayout.pinnedFirst(newColumns)
        loadViewIfNeeded()
        rebuildColumns()
        reloadRows()
        delegate?.ledgerTable(self, didChangeColumns: columns)
    }

    /// Shows or hides one column.
    public func setColumn(_ columnID: LedgerColumnID, visible: Bool) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        var updated = columns
        updated[index].visible = visible
        setColumns(updated)
    }

    /// Pins or unpins one column, which also moves it into the leading band.
    public func setColumn(_ columnID: LedgerColumnID, pinned: Bool) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        var updated = columns
        updated[index].pinned = pinned
        setColumns(updated)
    }

    /// Changes one column's alignment.
    public func setColumn(_ columnID: LedgerColumnID, alignment: LedgerColumnAlignment) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        var updated = columns
        updated[index].alignment = alignment
        setColumns(updated)
    }

    /// Moves a column to a new position in display order.
    public func moveColumn(_ columnID: LedgerColumnID, to destination: Int) {
        guard let current = columns.firstIndex(where: { $0.id == columnID }) else { return }
        var updated = columns
        let column = updated.remove(at: current)
        updated.insert(column, at: min(max(0, destination), updated.count))
        setColumns(updated)
    }

    /// Applies a saved layout.
    public func apply(layout: LedgerColumnLayout) {
        setColumns(layout.applied(to: columns))
    }

    /// Installs a persisted layout store and reopens the ledger in its active layout.
    ///
    /// The store's active layout is "the layout that was applied last, so the ledger can
    /// reopen in it", and the header menu ticks it. Installing the store used to refill the
    /// menu and nothing else, so after a relaunch the menu ticked a layout while the table
    /// showed the default arrangement (S-082). An active layout the store no longer holds is
    /// cleared, and the host is told through ``onLayoutStoreChange`` so it can persist that.
    ///
    /// Works before the view is loaded: the arrangement is recorded and drawn when it loads.
    public func restoreLayoutStore(_ store: LedgerColumnLayoutStore) {
        layoutStore = store
        guard let id = store.activeLayoutID else { return }
        guard let layout = store.layout(id: id) else {
            layoutStore.activeLayoutID = nil
            onLayoutStoreChange?(layoutStore)
            return
        }
        columns = layout.applied(to: columns)
        rebuildColumns()
        reloadRows()
        delegate?.ledgerTable(self, didChangeColumns: columns)
    }

    // MARK: Size to fit (IM-200)

    /// The narrowest and widest a column may be, matching the table columns' own limits.
    static let columnWidthRange: ClosedRange<Double> = 28...900

    /// Widens or narrows one column to its header and the text of the rows on screen.
    public func sizeColumnToFit(_ columnID: LedgerColumnID) {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        var updated = columns
        updated[index].width = fittingWidth(for: updated[index])
        guard updated != columns else { return }
        setColumns(updated)
    }

    /// Sizes every visible column to its content, as one change.
    public func sizeAllColumnsToFit() {
        var updated = columns
        for index in updated.indices where updated[index].visible {
            updated[index].width = fittingWidth(for: updated[index])
        }
        guard updated != columns else { return }
        setColumns(updated)
    }

    /// The width that shows a column's header and every cell of the band on screen — the
    /// first rows when nothing is on screen yet — without truncation, clamped to
    /// ``columnWidthRange``. Group headings and subtotals drawn in the column count too.
    func fittingWidth(for column: LedgerColumn) -> Double {
        let padding = Double(ZPDFSpacing.s * 2)
        func width(_ text: String, _ font: NSFont) -> Double {
            guard !text.isEmpty else { return 0 }
            return Double(ceil((text as NSString).size(withAttributes: [.font: font]).width))
        }
        let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        // Room for the sort indicator beside the title.
        var needed = width(column.title, headerFont) + padding + 14
        let cellFont = LedgerCellView.font(for: column)
        let isLeading = leadingVisibleColumnID == column.id
        let swatch = isLeading ? Double(10 + ZPDFSpacing.xs) : 0
        var band = visibleDisplayRange
        if band.isEmpty { band = 0..<min(plan.order.count, 200) }
        for position in band {
            guard let row = row(atDisplayPosition: position) else { continue }
            needed = max(needed, width(LedgerDefaultColumns.displayText(for: row, columnID: column.id), cellFont) + padding + swatch)
        }
        if mode == .grouped {
            let outlineIndent = column.id == columns.first(where: \.visible)?.id
                ? Double(outlineView.indentationPerLevel) * Double(max(1, groupingColumns.count)) + 16
                : 0
            func walk(_ slices: [LedgerGroupSlice]) {
                for slice in slices {
                    if column.id == groupHeadingColumnID {
                        needed = max(needed, width(groupHeading(slice), ZPDFTypography.nsFont(.sectionHeader)) + padding)
                    } else {
                        needed = max(needed, width(groupCellText(slice, column: column), ZPDFTypography.nsFont(.monoNumericStrong)) + padding)
                    }
                    walk(slice.children)
                }
            }
            walk(plan.groups)
            needed += outlineIndent
        }
        return min(Self.columnWidthRange.upperBound, max(Self.columnWidthRange.lowerBound, needed))
    }

    /// Goes back to the default arrangement: the mockup's
    /// `Page · Type · Label · Subject · Comment · Value · Unit · Perimeter` visible and in that
    /// order, every other column hidden after them — a person's own columns included — default
    /// widths, nothing pinned.
    ///
    /// It used to make every column visible — all 41 built-ins at once, a table dozens of
    /// columns wide — and left order, width and pinning as they were (S-080). The arrangement
    /// no longer being a saved layout, the store's active layout is cleared too, so the header
    /// menu stops ticking it and the ledger does not reopen in it.
    ///
    /// L-88: a user's column stayed on screen through a reset, so "reset" left a layout that was
    /// not the default. It is hidden now, not deleted: its definition and its values are
    /// untouched and the header's Show Columns menu brings it back.
    public func resetColumns() {
        setColumns(Self.resetArrangement(rowSource.ledgerColumns))
        if layoutStore.activeLayoutID != nil {
            layoutStore.activeLayoutID = nil
            onLayoutStoreChange?(layoutStore)
        }
    }

    /// What Reset Columns puts on screen: the default arrangement with only the mockup's columns
    /// visible (L-88).
    static func resetArrangement(_ sourceColumns: [LedgerColumn]) -> [LedgerColumn] {
        let defaults = Set(LedgerDefaultColumns.defaultOrder)
        return LedgerDefaultColumns.arranged(sourceColumns).map { column in
            guard column.visible, !defaults.contains(column.id) else { return column }
            var hidden = column
            hidden.visible = false
            return hidden
        }
    }

    private func rebuildColumns() {
        guard isViewLoaded else { return }
        let visible = columns.filter(\.visible)
        rebuild(table: tableView, with: visible)
        rebuild(table: outlineView, with: visible)
        rebuild(table: pinnedTableView, with: visible.filter(\.pinned))
        pointDisclosureAtLeadingColumn()
        let pinnedWidth = visible.filter(\.pinned).reduce(0.0) { $0 + $1.width }
        pinnedWidthConstraint?.constant = pinnedWidth
        pinnedScrollView.isHidden = pinnedWidth <= 0
        refreshHeaderMenu()
        pinnedTableView.headerView?.menu = headerMenu
        tableView.headerView?.menu = headerMenu
        outlineView.headerView?.menu = headerMenu
    }

    /// Puts the outline's disclosure triangle on the first visible column, where the swatch
    /// and the heading rules expect it.
    private func pointDisclosureAtLeadingColumn() {
        guard let first = columns.first(where: \.visible),
              let tableColumn = outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(first.id.rawValue))
        else { return }
        if outlineView.outlineTableColumn !== tableColumn {
            outlineView.outlineTableColumn = tableColumn
        }
    }

    /// Refills the shared header menu from the current columns, layouts and hooks (R-125).
    func refreshHeaderMenu() {
        guard isViewLoaded else { return }
        LedgerColumnMenuBuilder.populate(headerMenu, for: self)
    }

    private func rebuild(table: NSTableView, with visibleColumns: [LedgerColumn]) {
        // L-86: `NSOutlineView` will not remove the column it draws its disclosure in (nor
        // let go of it when told `nil`). Removing every column first left the old outline
        // column in place, the new leading column was added beside it, and the outline read
        // "Page | Page | Type…" after Per Sheet went off and on — or after any column change
        // while grouped. The new columns go in first, the disclosure moves to the new leading
        // one, and only then are the old columns removed, none of which is the outline column.
        let previous = table.tableColumns
        var added: [NSTableColumn] = []
        for column in visibleColumns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id.rawValue))
            tableColumn.headerCell = LedgerTableHeaderCell(textCell: column.title)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 28
            tableColumn.maxWidth = 900
            tableColumn.headerCell.alignment = LedgerCellView.nsAlignment(column.alignment)
            tableColumn.headerToolTip = sortToolTip(for: column, in: table.sortDescriptors)
            // The synthesised Value / Unit display columns have no stored cell the ledger engine
            // can order by; a header click on them was refused by the presenter while the header
            // showed a sort arrow (IM-056 / BH-102). They are not sortable at all.
            tableColumn.sortDescriptorPrototype = Self.isSortable(column)
                ? NSSortDescriptor(key: column.id.rawValue, ascending: true)
                : nil
            table.addTableColumn(tableColumn)
            added.append(tableColumn)
        }
        if let outline = table as? NSOutlineView, let leading = added.first {
            outline.outlineTableColumn = leading
        }
        for existing in previous { table.removeTableColumn(existing) }
        table.headerView?.setAccessibilityLabel(
            NSLocalizedString("Ledger column headers", comment: "Accessibility label of the ledger header row")
        )
    }

    // MARK: Data

    /// Rebuilds the grouping plan and reloads the visible rows.
    ///
    /// The plan comes from the source (``LedgerGroupPlanProviding``); a source that supplies
    /// none is listed flat, and no row is read to build the plan (IM-014). The reload never rewrites
    /// the selection: AppKit's selection notifications during `reloadData` and during the
    /// re-collapse of recorded groups used to recompute ``selectedRowIDs`` from stale indexes
    /// against the new plan, replacing the user's markups with whatever sat at those indexes
    /// (BH-045) or dropping the ones inside collapsed groups (BH-242), and telling the canvas.
    ///
    /// The source's columns are re-read first. The table used to take them only when it was
    /// created or given a new source, and the app never gives it one, so a column added,
    /// renamed, hidden or deleted in the Column Manager never reached it (S-075).
    public func rebuildPlan() {
        adoptSourceColumns()
        guard isViewLoaded else { return }
        let reopen = suspendInlineEdit()
        plan = makePlan()
        planBuildCount += 1
        planOrderIsIdentity = Self.isIdentity(plan.order)
        displayPositionBySource = nil
        rowIDIndex = nil
        sliceIndex = nil
        itemCache.removeAll()
        withSelectionEchoSuppressed {
            if mode == .grouped {
                outlineView.reloadData()
                // Collapsing the recorded groups first and selecting afterwards is what lets
                // a row inside a collapsed group stay in the selection (BH-242).
                performExpansionBatch { applyExpansionState() }
            } else {
                tableView.reloadData()
                pinnedTableView.reloadData()
            }
            restoreSelectionInViews()
        }
        resumeInlineEdit(reopen)
        prefetchVisibleBand()
    }

    /// The plan for the current mode and columns: the source's when it offers a valid one,
    /// otherwise the rows in source order under no headings.
    ///
    /// One aggregation path (IM-011, R-129): every heading and subtotal the table draws is the
    /// source's — for the application, the aggregation core's. A source that supplies no
    /// outline gets a flat identity plan with no totals; the table never folds rows into an
    /// outline or a subtotal of its own.
    private func makePlan() -> LedgerGroupPlan {
        let source = rowSource
        let grouping = mode == .grouped ? groupingColumns : []
        if let provider = source as? LedgerGroupPlanProviding,
           let supplied = provider.ledgerGroupPlan(groupingColumns: grouping, columns: columns),
           supplied.order.count == source.ledgerRowCount,
           supplied.groupingColumns == grouping {
            planOrigin = .supplied
            return supplied
        }
        planOrigin = .unsupplied
        let rowCount = source.ledgerRowCount
        return LedgerGroupPlan(
            order: Array(0..<rowCount),
            groups: [],
            grandSubtotals: LedgerSubtotals(rowCount: rowCount, results: [:]),
            groupingColumns: grouping
        )
    }

    private static func isIdentity(_ order: [Int]) -> Bool {
        for (position, index) in order.enumerated() where position != index { return false }
        return true
    }

    /// Expands every group, then collapses the recorded ones. Parents first, so a nested
    /// group's own state is applied after its ancestors exist in the view.
    private func applyExpansionState() {
        func walk(_ slices: [LedgerGroupSlice]) {
            for slice in slices {
                let item = itemCache.item(for: slice)
                if collapsedGroupPaths.contains(slice.path) {
                    outlineView.collapseItem(item)
                } else {
                    outlineView.expandItem(item)
                    walk(slice.children)
                }
            }
        }
        walk(plan.groups)
    }

    /// Runs expansion changes as one batch: per-group pinned reloads and persistence
    /// callbacks are held back, then the pinned band reloads once, re-mirrors the selection,
    /// and the collapsed set is persisted once if it changed (IM-100).
    private func performExpansionBatch(_ body: () -> Void) {
        let wasBatching = isBatchingExpansion
        isBatchingExpansion = true
        withSelectionEchoSuppressed(body)
        isBatchingExpansion = wasBatching
        guard !wasBatching else { return }
        pinnedTableView.reloadData()
        mirrorSelectionToPinned()
        if batchedCollapsedPathsChanged {
            batchedCollapsedPathsChanged = false
            onCollapsedGroupPathsChange?(collapsedGroupPaths)
        }
    }

    /// Runs view updates whose selection notifications are the table's own doing, not the
    /// user's, so none of them rewrites ``selectedRowIDs`` or reaches the delegate.
    private func withSelectionEchoSuppressed(_ body: () -> Void) {
        let previous = isApplyingExternalSelection
        isApplyingExternalSelection = true
        body()
        isApplyingExternalSelection = previous
    }

    /// Reloads without recomputing the plan. The selection is restored by identity and is
    /// never rewritten by the reload itself (BH-045).
    public func reloadRows() {
        guard isViewLoaded else { return }
        rowReloadCount += 1
        let reopen = suspendInlineEdit()
        withSelectionEchoSuppressed {
            if mode == .grouped {
                outlineView.reloadData()
            } else {
                tableView.reloadData()
            }
            pinnedTableView.reloadData()
            restoreSelectionInViews()
        }
        resumeInlineEdit(reopen)
    }

    /// The display positions currently on screen.
    ///
    /// Always in display-position space — the space ``rowCellContent(displayPosition:column:)``
    /// and the source's prefetch use. In grouped mode the outline's visual rows count headings and skip
    /// collapsed rows, so they are translated rather than returned as they are (BH-740):
    /// the result is the smallest range covering every data row drawn.
    public var visibleDisplayRange: Range<Int> {
        guard isViewLoaded else { return 0..<0 }
        let table: NSTableView = mode == .grouped ? outlineView : tableView
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return 0..<0 }
        return displayRange(coveringVisualRows: rows.location..<(rows.location + rows.length))
    }

    /// The display positions behind a range of visual rows of the active table.
    func displayRange(coveringVisualRows visual: Range<Int>) -> Range<Int> {
        guard mode == .grouped else {
            return visual.clamped(to: 0..<plan.order.count)
        }
        var lower = Int.max
        var upper = Int.min
        for row in visual {
            guard case let .row(position) = content(atVisualRow: row) else { continue }
            lower = min(lower, position)
            upper = max(upper, position)
        }
        guard lower <= upper else { return 0..<0 }
        return lower..<(upper + 1)
    }

    /// Hands the source the band around what is on screen, so the rows about to be drawn
    /// are built ahead and rows far away can be evicted (IM-014). The controller used to
    /// never call it, so the presenter's cache only ever grew.
    func prefetchVisibleBand(visible explicitRange: Range<Int>? = nil) {
        let visible = explicitRange ?? visibleDisplayRange
        guard !visible.isEmpty, !plan.order.isEmpty else { return }
        let lower = max(0, visible.lowerBound - Self.prefetchLeading)
        let upper = min(plan.order.count, visible.upperBound + Self.prefetchTrailing)
        guard lower < upper else { return }
        if planOrderIsIdentity {
            rowSource.prefetchLedgerRows(in: lower..<upper)
            return
        }
        // A plan the engine sorted into groups maps a display band onto scattered source
        // rows; prefetch their span only while it stays close to the band's own size.
        var minimum = Int.max
        var maximum = Int.min
        for position in lower..<upper {
            minimum = min(minimum, plan.order[position])
            maximum = max(maximum, plan.order[position])
        }
        guard minimum <= maximum, maximum - minimum < (upper - lower) * 4 else { return }
        rowSource.prefetchLedgerRows(in: minimum..<(maximum + 1))
    }

    /// Rows prefetched ahead of the visible band. The one prefetch-band rule: the presenter
    /// warms whatever range ``prefetchVisibleBand(visible:)`` hands it.
    static let prefetchLeading = 32
    /// Rows prefetched behind the visible band.
    static let prefetchTrailing = 96

    // MARK: Selection

    /// Replaces the selection from outside the table, for example from the canvas.
    ///
    /// The change is not echoed back to the delegate, which is what stops a selection from
    /// bouncing between the ledger and the canvas.
    ///
    /// In grouped mode the groups holding the selected rows are expanded **before** the
    /// rows are selected: a row inside a collapsed group has no visual row, so selecting
    /// first left the group opening onto an unhighlighted row — or, without scrolling,
    /// never opening at all — while the host believed it selected (BH-243).
    public func applyExternalSelection(_ rowIDs: Set<UUID>, scrollToFirst: Bool = true) {
        isApplyingExternalSelection = true
        defer { isApplyingExternalSelection = false }
        selectedRowIDs = rowIDs
        guard isViewLoaded else { return }
        let positions = rowIDs.compactMap { lookupDisplayPosition($0) }.sorted()
        if mode == .grouped, !positions.isEmpty {
            expandAncestors(ofDisplayPositions: positions)
        }
        restoreSelectionInViews()
        if scrollToFirst, let first = positions.first {
            scroll(toDisplayPosition: first)
        }
    }

    @discardableResult
    private func scroll(toDisplayPosition position: Int) -> Bool {
        guard let row = visualRow(forDisplayPosition: position) else { return false }
        scroll(table: mode == .grouped ? outlineView : tableView, toRow: row)
        return true
    }

    /// The visual row of a display position in the active table, `nil` when it is hidden.
    func visualRow(forDisplayPosition position: Int) -> Int? {
        guard position >= 0, position < plan.order.count else { return nil }
        guard mode == .grouped else { return position }
        let row = outlineView.row(forItem: itemCache.item(displayPosition: position))
        return row >= 0 ? row : nil
    }

    /// The display position of a markup, or `nil` when the filter hides it.
    ///
    /// Backed by an index that is built once per plan, so a lookup is a dictionary hit rather
    /// than a walk over every row.
    public func displayPosition(of rowID: UUID) -> Int? {
        lookupDisplayPosition(rowID)
    }

    /// Resolves an identity to a display position.
    ///
    /// A source with a real index (``LedgerIndexedRowProviding``) answers the source index
    /// directly; only other sources pay for the identity index, which reads every row once
    /// per plan (IM-014).
    private func lookupDisplayPosition(_ rowID: UUID) -> Int? {
        guard rowSource is LedgerIndexedRowProviding else { return rowIDLookup()[rowID] }
        guard let sourceIndex = rowSource.ledgerRowIndex(of: rowID) else { return nil }
        return displayPosition(forSourceIndex: sourceIndex)
    }

    private func displayPosition(forSourceIndex sourceIndex: Int) -> Int? {
        guard sourceIndex >= 0, sourceIndex < plan.order.count else { return nil }
        if planOrderIsIdentity { return sourceIndex }
        if displayPositionBySource == nil {
            var inverse = [Int](repeating: -1, count: plan.order.count)
            for (position, index) in plan.order.enumerated() where index >= 0 && index < inverse.count {
                inverse[index] = position
            }
            displayPositionBySource = inverse
        }
        let position = displayPositionBySource?[sourceIndex] ?? -1
        return position >= 0 ? position : nil
    }

    /// The rows behind a set of markup identifiers, in display order.
    ///
    /// Costs one dictionary hit and one row fetch per identifier. Hosts used to answer this
    /// question by filtering the presenter's whole row array on every selection change.
    public func rows(withIDs rowIDs: Set<UUID>) -> [LedgerRow] {
        guard !rowIDs.isEmpty else { return [] }
        var positions: [Int] = []
        positions.reserveCapacity(rowIDs.count)
        for id in rowIDs {
            guard let position = lookupDisplayPosition(id) else { continue }
            positions.append(position)
        }
        positions.sort()
        var result: [LedgerRow] = []
        result.reserveCapacity(positions.count)
        for position in positions {
            guard let sourceIndex = plan.sourceIndex(displayPosition: position),
                  let row = rowSource.ledgerRow(at: sourceIndex) else { continue }
            result.append(row)
        }
        return result
    }

    /// Builds the identity index if the current plan has not been indexed yet.
    ///
    /// The build is one pass over the plan; every lookup afterwards is O(1) until the plan
    /// is rebuilt. A ledger that never syncs selection never pays for it at all.
    private func rowIDLookup() -> [UUID: Int] {
        if let rowIDIndex { return rowIDIndex }
        var index: [UUID: Int] = [:]
        index.reserveCapacity(plan.order.count)
        for (position, sourceIndex) in plan.order.enumerated() {
            guard let id = rowSource.ledgerRowID(at: sourceIndex) else { continue }
            // First occurrence wins, matching the linear scan this replaced. Identifiers are
            // unique per markup, so this only matters for a malformed source.
            if index[id] == nil { index[id] = position }
        }
        rowIDIndex = index
        return index
    }

    private func restoreSelectionInViews() {
        let table: NSTableView = mode == .grouped ? outlineView : tableView
        var indexes = IndexSet()
        var pinnedPositions: Set<Int> = []
        if !selectedRowIDs.isEmpty {
            for id in selectedRowIDs {
                guard let position = lookupDisplayPosition(id) else { continue }
                pinnedPositions.insert(position)
            }
            // Pin before any item is created, so nothing in this set can be evicted while the
            // rest of the selection is still being resolved.
            itemCache.pin(displayPositions: pinnedPositions)
            for position in pinnedPositions {
                if mode == .grouped {
                    let row = outlineView.row(forItem: itemCache.item(displayPosition: position))
                    if row >= 0 { indexes.insert(row) }
                } else {
                    indexes.insert(position)
                }
            }
        } else {
            itemCache.pin(displayPositions: [])
        }
        withSelectionEchoSuppressed {
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            pinnedTableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    /// Makes the pinned band highlight exactly the rows the main view highlights, without
    /// reporting anything. Needed after anything that shifts visual rows under a selection
    /// kept by item — an expand or collapse — which posts no selection change (BH-246).
    private func mirrorSelectionToPinned() {
        let main: NSTableView = mode == .grouped ? outlineView : tableView
        withSelectionEchoSuppressed {
            pinnedTableView.selectRowIndexes(main.selectedRowIndexes, byExtendingSelection: false)
        }
    }

    /// Expands every group that holds one of the display positions, in one batch with one
    /// persistence call. `positions` must be sorted.
    private func expandAncestors(ofDisplayPositions positions: [Int]) {
        guard !positions.isEmpty else { return }
        func containsAny(_ range: Range<Int>) -> Bool {
            // First position at or after the range start, by binary search.
            var low = 0
            var high = positions.count
            while low < high {
                let mid = (low + high) / 2
                if positions[mid] < range.lowerBound { low = mid + 1 } else { high = mid }
            }
            return low < positions.count && positions[low] < range.upperBound
        }
        var changed = false
        func walk(_ slices: [LedgerGroupSlice]) {
            for slice in slices where containsAny(slice.rowRange) {
                if collapsedGroupPaths.remove(slice.path) != nil { changed = true }
                outlineView.expandItem(itemCache.item(for: slice))
                walk(slice.children)
            }
        }
        performExpansionBatch { walk(plan.groups) }
        if changed { onCollapsedGroupPathsChange?(collapsedGroupPaths) }
    }

    private func scroll(table: NSTableView, toRow row: Int) {
        guard row >= 0, row < table.numberOfRows else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            table.scrollRowToVisible(row)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ZPDFMotion.quick.duration
                table.animator().scrollRowToVisible(row)
            }
        }
    }

    // MARK: Accessibility

    /// The one-line summary a screen reader announces for the whole ledger.
    ///
    /// For example: "Ledger, 412 rows, 3 groups, total 1 240.5 m²".
    public var accessibilitySummary: String {
        var totalText: String?
        if let columnID = headlineTotalColumn, let result = plan.grandSubtotals.result(columnID) {
            // `displayText` spells both refusals — "Mixed units" and "Error" — itself (CR-54).
            totalText = result.displayText(policy: unitPolicy, rounding: rounding)
        }
        return LedgerAccessibilitySummary.text(
            rowCount: plan.order.count,
            groupCount: plan.groupCount,
            totalText: totalText,
            selectionCount: selectedRowIDs.count
        )
    }

    // MARK: Commands

    /// A keyboard command the table understands.
    public enum Command: Hashable, Sendable {
        /// Return or Enter: edit the focused editable cell, or jump to the row's markup.
        case activate
        /// Space: toggle the selected group.
        case toggleGroup
    }

    private func handle(_ command: Command) -> Bool {
        switch command {
        case .activate:
            // Return on a row whose focused column is editable opens that cell; on anything
            // else it keeps its old meaning, the jump to the markup (IM-013).
            if let columnID = focusedColumnID, let position = singleSelectedDisplayPosition(),
               beginInlineEdit(displayPosition: position, columnID: columnID) {
                return true
            }
            guard let id = firstSelectedRowID() else { return false }
            delegate?.ledgerTable(self, didActivate: id)
            return true
        case .toggleGroup:
            guard mode == .grouped,
                  let item = outlineView.item(atRow: outlineView.selectedRow) as? LedgerOutlineItem,
                  item.isGroup else { return false }
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
            return true
        }
    }

    @objc private func handleClick(_ sender: Any?) {
        guard let table = sender as? NSTableView else { return }
        focusColumn(atTableColumnIndex: table.clickedColumn, in: table)
    }

    @objc private func handleDoubleClick(_ sender: Any?) {
        if let table = sender as? NSTableView,
           handleDoubleClick(atVisualRow: table.clickedRow, tableColumnIndex: table.clickedColumn, in: table) {
            return
        }
        guard let id = firstSelectedRowID() else { return }
        delegate?.ledgerTable(self, didActivate: id)
    }

    /// A double click on an editable cell edits it; anywhere else it jumps (IM-013).
    ///
    /// - Returns: `true` when an editor opened.
    @discardableResult
    func handleDoubleClick(atVisualRow row: Int, tableColumnIndex: Int, in table: NSTableView) -> Bool {
        guard row >= 0, tableColumnIndex >= 0, tableColumnIndex < table.tableColumns.count else { return false }
        focusColumn(atTableColumnIndex: tableColumnIndex, in: table)
        guard case let .row(position) = content(atVisualRow: row) else { return false }
        let columnID = LedgerColumnID(table.tableColumns[tableColumnIndex].identifier.rawValue)
        return beginInlineEdit(displayPosition: position, columnID: columnID)
    }

    /// Records the clicked column as the one Return edits, when it is editable.
    func focusColumn(atTableColumnIndex index: Int, in table: NSTableView) {
        guard index >= 0, index < table.tableColumns.count else { return }
        let columnID = LedgerColumnID(table.tableColumns[index].identifier.rawValue)
        focusColumn(columnID)
    }

    /// Makes a column the one Return edits, or clears the focus for a column that cannot be
    /// edited in place.
    func focusColumn(_ columnID: LedgerColumnID?) {
        guard let columnID, let column = column(columnID), isInlineEditable(column) else {
            focusedColumnID = nil
            return
        }
        focusedColumnID = columnID
    }

    @objc private func mainClipViewDidScroll(_ notification: Notification) {
        guard !isSynchronizingScroll else { return }
        isSynchronizingScroll = true
        defer { isSynchronizingScroll = false }
        var origin = pinnedScrollView.contentView.bounds.origin
        origin.y = mainScrollView.contentView.bounds.origin.y
        pinnedScrollView.contentView.scroll(to: origin)
        pinnedScrollView.reflectScrolledClipView(pinnedScrollView.contentView)
        prefetchVisibleBand()
    }

    @objc private func pinnedClipViewDidScroll(_ notification: Notification) {
        guard !isSynchronizingScroll else { return }
        isSynchronizingScroll = true
        defer { isSynchronizingScroll = false }
        var origin = mainScrollView.contentView.bounds.origin
        origin.y = pinnedScrollView.contentView.bounds.origin.y
        mainScrollView.contentView.scroll(to: origin)
        mainScrollView.reflectScrolledClipView(mainScrollView.contentView)
    }

    private func firstSelectedRowID() -> UUID? {
        let table: NSTableView = mode == .grouped ? outlineView : tableView
        let row = table.selectedRow
        guard row >= 0 else { return selectedRowIDs.first }
        switch content(atVisualRow: row) {
        case let .row(position):
            guard let sourceIndex = plan.sourceIndex(displayPosition: position) else { return nil }
            return rowSource.ledgerRowID(at: sourceIndex)
        case .group, .none:
            return nil
        }
    }

    /// The display position of the one selected data row, `nil` for none or several.
    private func singleSelectedDisplayPosition() -> Int? {
        let table: NSTableView = mode == .grouped ? outlineView : tableView
        guard table.selectedRowIndexes.count == 1 else { return nil }
        guard case let .row(position) = content(atVisualRow: table.selectedRow) else { return nil }
        return position
    }

    /// What is drawn at a visual row of the active table.
    public func content(atVisualRow row: Int) -> LedgerVisualRow {
        if mode == .grouped {
            guard let item = outlineView.item(atRow: row) as? LedgerOutlineItem else { return .none }
            if let slice = item.slice { return .group(path: slice.path) }
            if let position = item.displayPosition { return .row(displayPosition: position) }
            return .none
        }
        guard row >= 0, row < plan.order.count else { return .none }
        return .row(displayPosition: row)
    }

    /// The group slice for a path.
    ///
    /// Cell construction asks this once per drawn group cell, so it is a dictionary hit into
    /// an index built once per plan rather than a walk over the group tree.
    public func slice(forPath path: String) -> LedgerGroupSlice? {
        if let sliceIndex { return sliceIndex[path] }
        var index: [String: LedgerGroupSlice] = [:]
        func collect(_ slices: [LedgerGroupSlice]) {
            for slice in slices {
                index[slice.path] = slice
                collect(slice.children)
            }
        }
        collect(plan.groups)
        sliceIndex = index
        return index[path]
    }

    /// The row at a display position, fetched from the source.
    private func row(atDisplayPosition position: Int) -> LedgerRow? {
        guard let sourceIndex = plan.sourceIndex(displayPosition: position) else { return nil }
        return rowSource.ledgerRow(at: sourceIndex)
    }

    // MARK: Column lookup (IM-202)

    /// One column by identity: a dictionary hit into a table built once per column change,
    /// not a linear search per drawn cell.
    public func column(_ id: LedgerColumnID) -> LedgerColumn? {
        if columnIndexCache == nil {
            var index: [LedgerColumnID: LedgerColumn] = [:]
            index.reserveCapacity(columns.count)
            for column in columns where index[column.id] == nil { index[column.id] = column }
            columnIndexCache = index
        }
        return columnIndexCache?[id]
    }

    /// The first visible column, which carries a row's colour swatch.
    private var leadingVisibleColumnID: LedgerColumnID? {
        if let cached = leadingVisibleColumnIDCache { return cached }
        let value = columns.first(where: \.visible)?.id
        leadingVisibleColumnIDCache = .some(value)
        return value
    }

    private func invalidateColumnCaches() {
        columnIndexCache = nil
        leadingVisibleColumnIDCache = nil
        groupHeadingColumnIDCache = nil
    }

    /// Takes the source's columns when they changed since the last adoption, keeping the
    /// user's arrangement of the ones that stay.
    ///
    /// - A column's definition — title, kind, dimension, aggregate, unit, choices, formula —
    ///   is always the source's, so a rename or a retype shows at once.
    /// - Its width, visibility, pinning and alignment stay as the user left them in the table,
    ///   except where the source itself changed one since the last adoption: a column hidden
    ///   or shown in the Column Manager is hidden or shown here too.
    /// - Columns keep the user's order. When the source reorders its user-defined columns
    ///   among themselves (a move in the Column Manager), those columns take the new order in
    ///   the slots they already hold.
    /// - A column the source added appears after the others; one it dropped is removed.
    ///
    /// The guard used to compare only the set of identifiers, and only a new source reached
    /// it at all, so renames, retypes, visibility and every change on a live source were
    /// missed (S-075).
    ///
    /// - Returns: Whether ``columns`` changed.
    @discardableResult
    private func adoptSourceColumns() -> Bool {
        let fresh = LedgerColumnLayout.pinnedFirst(LedgerDefaultColumns.arranged(rowSource.ledgerColumns))
        guard fresh != adoptedSourceColumns else { return false }
        var previousByID: [LedgerColumnID: LedgerColumn] = [:]
        for column in adoptedSourceColumns where previousByID[column.id] == nil { previousByID[column.id] = column }
        let previousUserOrder = adoptedSourceColumns.filter(\.isUserDefined).map(\.id)
        adoptedSourceColumns = fresh

        var freshByID: [LedgerColumnID: LedgerColumn] = [:]
        for column in fresh where freshByID[column.id] == nil { freshByID[column.id] = column }
        var kept: Set<LedgerColumnID> = []
        var merged: [LedgerColumn] = []
        for existing in columns {
            guard var updated = freshByID[existing.id], !kept.contains(existing.id) else { continue }
            let previous = previousByID[existing.id]
            // The user's arrangement wins unless the source changed that very property.
            if previous?.width == updated.width || previous == nil { updated.width = existing.width }
            if previous?.visible == updated.visible || previous == nil { updated.visible = existing.visible }
            if previous?.pinned == updated.pinned || previous == nil { updated.pinned = existing.pinned }
            if previous?.alignment == updated.alignment || previous == nil { updated.alignment = existing.alignment }
            merged.append(updated)
            kept.insert(existing.id)
        }

        // A move in the Column Manager: the kept user-defined columns take the source's new
        // relative order, inside the slots they already occupy.
        let keptUserIDs = Set(merged.filter(\.isUserDefined).map(\.id))
        let sourceUserOrder = fresh.filter { $0.isUserDefined && keptUserIDs.contains($0.id) }.map(\.id)
        let previousKeptOrder = previousUserOrder.filter { keptUserIDs.contains($0) }
        if sourceUserOrder != previousKeptOrder, sourceUserOrder.count == keptUserIDs.count {
            var mergedByID: [LedgerColumnID: LedgerColumn] = [:]
            for column in merged { mergedByID[column.id] = column }
            var nextUser = sourceUserOrder.makeIterator()
            for index in merged.indices where merged[index].isUserDefined {
                if let id = nextUser.next(), let column = mergedByID[id] { merged[index] = column }
            }
        }

        for column in fresh where !kept.contains(column.id) {
            merged.append(column)
            kept.insert(column.id)
        }
        let adopted = LedgerColumnLayout.pinnedFirst(merged)
        guard adopted != columns else { return false }
        columns = adopted
        rebuildColumns()
        delegate?.ledgerTable(self, didChangeColumns: columns)
        return true
    }

    // MARK: Cell construction

    /// Everything one data cell shows, before any view exists.
    struct RowCellContent: Equatable {
        let text: String
        let accessibilityLabel: String
        let swatchColor: ColorRGBA?
        let isDimmed: Bool
        let indent: CGFloat
        let helpTag: String?
    }

    /// What the data cell at a display position shows in `column`, or `nil` past the rows.
    ///
    /// The data source's one path to a row cell (``makeCell(for:visualRow:in:)`` configures
    /// its view from this), and the path the 100 000-row benchmark measures (V-065): the
    /// benchmark used to time a separate `LedgerWindowFetch` that the table never ran, so
    /// its number was not the number a person feels while dragging the scroller.
    func rowCellContent(displayPosition position: Int, column: LedgerColumn) -> RowCellContent? {
        guard let row = row(atDisplayPosition: position) else { return nil }
        let isLeading = leadingVisibleColumnID == column.id
        let text = LedgerDefaultColumns.displayText(for: row, columnID: column.id)
        return RowCellContent(
            text: text,
            // The label reuses the text just formatted instead of formatting it again.
            accessibilityLabel: cellAccessibilityLabel(row: row, column: column, text: text),
            swatchColor: isLeading ? row.colorRGBA : nil,
            isDimmed: !row.matchesFilter || row.hidden,
            // NL-QTY-07: a child row (a derived assembly line, a cutout) steps in under its
            // source in the leading column.
            indent: isLeading && row.parentID != nil ? LedgerCellView.childIndent : 0,
            // T-057: a failed formula cell says which operand failed and why.
            helpTag: row.cellNote(column.id)
        )
    }

    fileprivate func makeCell(
        for tableColumn: NSTableColumn?,
        visualRow: LedgerVisualRow,
        in table: NSTableView
    ) -> NSView? {
        guard let tableColumn else { return nil }
        guard let column = column(LedgerColumnID(tableColumn.identifier.rawValue)) else { return nil }

        let cell = (table.makeView(withIdentifier: LedgerCellView.reuseIdentifier, owner: self) as? LedgerCellView)
            ?? {
                let created = LedgerCellView(frame: .zero)
                created.identifier = LedgerCellView.reuseIdentifier
                return created
            }()

        switch visualRow {
        case let .row(position):
            guard let content = rowCellContent(displayPosition: position, column: column) else {
                cell.configure(text: "", column: column, swatchColor: nil, isDimmed: true, accessibilityLabel: "")
                return cell
            }
            cell.configure(
                text: content.text,
                column: column,
                swatchColor: content.swatchColor?.nsColor,
                isDimmed: content.isDimmed,
                accessibilityLabel: content.accessibilityLabel,
                indent: content.indent,
                helpTag: content.helpTag
            )

        case let .group(path):
            guard let slice = slice(forPath: path) else {
                // A heading whose path the plan no longer has draws blank — never the text,
                // font and swatch the reused cell last showed for another row (BH-741).
                cell.configureAsGroup(text: "", column: column, isHeading: false, swatchColor: nil, accessibilityLabel: "")
                return cell
            }
            let isLeading = leadingVisibleColumnID == column.id
            if column.id == groupHeadingColumnID {
                cell.configureAsGroup(
                    text: groupHeading(slice),
                    column: column,
                    isHeading: true,
                    swatchColor: slice.colorRGBA?.nsColor,
                    accessibilityLabel: slice.accessibilityLabel(
                        totalColumn: headlineTotalColumn,
                        policy: unitPolicy,
                        rounding: rounding
                    )
                )
            } else if isLeading {
                // The disclosure chevron's column is too narrow for the heading text,
                // which lives in ``groupHeadingColumnID``. This cell only carries the
                // group's colour cue.
                cell.configureAsGroup(
                    text: "",
                    column: column,
                    isHeading: true,
                    swatchColor: slice.colorRGBA?.nsColor,
                    accessibilityLabel: ""
                )
            } else {
                let text = groupCellText(slice, column: column)
                cell.configureAsGroup(
                    text: text,
                    column: column,
                    isHeading: false,
                    swatchColor: nil,
                    accessibilityLabel: groupCellAccessibilityLabel(slice, column: column, text: text)
                )
            }

        case .none:
            cell.configure(text: "", column: column, swatchColor: nil, isDimmed: true, accessibilityLabel: "")
        }
        return cell
    }

    /// The subtotal text a group row shows in one non-heading column.
    ///
    /// The number and the unit come from the aggregate's quantity as two separate fields
    /// (``LedgerValueParts``), not from splitting the formatted total at its last space: a
    /// locale whose digits are not ASCII, a grouping separator that is a space, or a unit
    /// with a digit in it all broke that split, leaving the whole total in `Value` and a
    /// blank `Unit` (IM-098).
    func groupCellText(_ slice: LedgerGroupSlice, column: LedgerColumn) -> String {
        guard showsSubtotals else { return "" }
        if column.id == LedgerDefaultColumns.unitColumnID {
            // The unit half of the group's merged total: the summed primary quantity's
            // symbol, in the same column where every child row shows its own.
            guard let valueResult = slice.subtotals.result(LedgerDefaultColumns.valueColumnID) else { return "" }
            return LedgerValueParts.parts(of: valueResult, policy: unitPolicy, rounding: rounding, locale: locale)?.unit ?? ""
        }
        guard let result = slice.subtotals.result(column.id) else { return "" }
        // The display Value column shows the number alone — its unit sits in the Unit
        // column, exactly like the child rows. A quantity column
        // that already declares its unit in the header (Perimeter, Plan Area, …) also shows
        // the bare number, matching its child cells. A mixed-units refusal reads "Mixed
        // units" and a failed one "Error" — two different statements, both spelled by
        // `displayText` (CR-54).
        guard let parts = LedgerValueParts.parts(of: result, policy: unitPolicy, rounding: rounding, locale: locale) else {
            return result.displayText(policy: unitPolicy, rounding: rounding, locale: locale)
        }
        if column.id == LedgerDefaultColumns.valueColumnID
            || parts.unit.isEmpty
            || (!column.displayUnitSymbol.isEmpty && parts.unit == column.displayUnitSymbol) {
            return parts.number
        }
        return "\(parts.number) \(parts.unit)"
    }

    private func groupCellAccessibilityLabel(_ slice: LedgerGroupSlice, column: LedgerColumn, text: String) -> String {
        guard showsSubtotals else { return "" }
        if column.id == LedgerDefaultColumns.unitColumnID {
            return text.isEmpty ? "" : String(
                format: NSLocalizedString(
                    "%1$@: %2$@",
                    comment: "VoiceOver label for a ledger cell: column title, value"
                ),
                column.title, text
            )
        }
        guard let result = slice.subtotals.result(column.id) else { return "" }
        return result.accessibilityText(columnTitle: column.title, policy: unitPolicy, rounding: rounding)
    }

    /// The column a group heading's text is drawn in: the first visible column wide
    /// enough to hold "Length (6)" without truncating. The disclosure chevron stays on
    /// the leading edge; only the words move to where they fit.
    var groupHeadingColumnID: LedgerColumnID? {
        if let cached = groupHeadingColumnIDCache { return cached }
        let visible = columns.filter(\.visible)
        let value = (visible.first { $0.width >= 90 } ?? visible.first)?.id
        groupHeadingColumnIDCache = .some(value)
        return value
    }

    private func groupHeading(_ slice: LedgerGroupSlice) -> String {
        let format = NSLocalizedString(
            "%1$@ (%2$d)",
            comment: "Ledger group heading: group title, number of rows"
        )
        return String(format: format, slice.title, slice.rowCount)
    }

    private func cellAccessibilityLabel(row: LedgerRow, column: LedgerColumn, text value: String) -> String {
        let text = value.isEmpty
            ? NSLocalizedString("empty", comment: "VoiceOver value for a ledger cell with no content")
            : value
        let format = NSLocalizedString(
            "%1$@: %2$@",
            comment: "VoiceOver label for a ledger cell: column title, value"
        )
        var label = String(format: format, column.title, text)
        if !row.matchesFilter {
            label += ", " + NSLocalizedString("filtered out", comment: "VoiceOver suffix for a ledger row that fails the filter")
        }
        if row.locked {
            label += ", " + NSLocalizedString("locked", comment: "VoiceOver suffix for a locked markup")
        }
        // S-090: a row read from a schedule table says so in every cell, as "locked" does.
        if let provenance = row.provenance?.accessibilityLabel {
            label += ", " + provenance
        }
        return label
    }

    // MARK: Sorting (IM-099)

    /// Forwards every sort level the header now carries, outermost first.
    private func forwardSort(from table: NSTableView) {
        let descriptors = Self.sortDescriptors(from: table.sortDescriptors)
        guard !descriptors.isEmpty else { return }
        updateSortToolTips(table.sortDescriptors)
        delegate?.ledgerTable(self, didRequestSort: descriptors)
    }

    /// The ledger's sort levels for AppKit's descriptors, dropping any without a key.
    static func sortDescriptors(from descriptors: [NSSortDescriptor]) -> [LedgerSortDescriptor] {
        var seen: Set<LedgerColumnID> = []
        var result: [LedgerSortDescriptor] = []
        for descriptor in descriptors {
            guard let key = descriptor.key else { continue }
            let column = LedgerColumnID(key)
            guard seen.insert(column).inserted else { continue }
            result.append(LedgerSortDescriptor(column: column, ascending: descriptor.ascending))
        }
        return result
    }

    /// Header tooltips that name each column's sort level, so the secondary order is
    /// visible without guessing which header was clicked first.
    private func updateSortToolTips(_ descriptors: [NSSortDescriptor]) {
        for table in [tableView, outlineView, pinnedTableView] as [NSTableView] {
            for tableColumn in table.tableColumns {
                guard let column = column(LedgerColumnID(tableColumn.identifier.rawValue)) else { continue }
                tableColumn.headerToolTip = sortToolTip(for: column, in: descriptors)
            }
        }
    }

    /// A column's header tooltip: its description, plus its sort level when it has one.
    func sortToolTip(for column: LedgerColumn, in descriptors: [NSSortDescriptor]) -> String {
        let levels = Self.sortDescriptors(from: descriptors)
        guard levels.count > 1, let index = levels.firstIndex(where: { $0.column == column.id }) else {
            return column.accessibilityLabel
        }
        let direction = levels[index].ascending
            ? NSLocalizedString("ascending", comment: "Ledger sort direction in a header tooltip")
            : NSLocalizedString("descending", comment: "Ledger sort direction in a header tooltip")
        return String(
            format: NSLocalizedString(
                "%1$@ — sort level %2$d of %3$d, %4$@",
                comment: "Ledger header tooltip: column description, sort level, number of levels, direction"
            ),
            column.accessibilityLabel, index + 1, levels.count, direction
        )
    }

    // MARK: Copy (IM-015)

    /// Whether Copy has anything to copy.
    public var canCopy: Bool {
        guard isViewLoaded else { return false }
        let table: NSTableView = mode == .grouped ? outlineView : tableView
        return !table.selectedRowIndexes.isEmpty
    }

    /// Copies the selected rows as a spreadsheet-ready table: the visible column headers,
    /// then one line per selected row in display order, with the same text the cells draw.
    /// A selected group heading contributes its subtotal line.
    @objc public func copy(_ sender: Any?) {
        guard let text = copyText() else { return }
        copyPasteboard.write(LedgerCopyPayload(tabSeparatedText: text))
    }

    /// The tab-separated text Copy writes, or `nil` when nothing is selected.
    public func copyText() -> String? {
        guard canCopy else { return nil }
        let table: NSTableView = mode == .grouped ? outlineView : tableView
        return tabularText(visualRows: table.selectedRowIndexes)
    }

    /// The tab-separated text for some visual rows of the active table — Copy's selection, or
    /// the rows a drag carries out (NL-UX-15) — or `nil` when none of them draws anything.
    ///
    /// Written by ``LedgerTabularText``, so a Subject, Label or Comment that starts like a
    /// formula is pasted as text, and a rendered number stays a number (X-030).
    public func tabularText(visualRows: IndexSet) -> String? {
        let visible = columns.filter(\.visible)
        var lines: [[LedgerTabularField]] = [visible.map { .text($0.title) }]
        for visualRow in visualRows {
            switch content(atVisualRow: visualRow) {
            case let .row(position):
                guard let row = row(atDisplayPosition: position) else { continue }
                lines.append(visible.map { rowCellField(row, column: $0) })
            case let .group(path):
                guard let slice = slice(forPath: path) else { continue }
                lines.append(visible.map { column in
                    column.id == groupHeadingColumnID ? .text(groupHeading(slice)) : groupCellField(slice, column: column)
                })
            case .none:
                continue
            }
        }
        guard lines.count > 1 else { return nil }
        return LedgerTabularText.document(lines)
    }

    /// A row's cell as Copy writes it: the text the cell draws, a number when the cell holds a
    /// rendered number — and the Value column, which is always the row's primary quantity.
    func rowCellField(_ row: LedgerRow, column: LedgerColumn) -> LedgerTabularField {
        LedgerTabularField(
            LedgerDefaultColumns.displayText(for: row, columnID: column.id),
            isNumber: column.id == LedgerDefaultColumns.valueColumnID || LedgerTabularText.isNumber(row.value(column.id))
        )
    }

    /// A group line's cell as Copy writes it: a subtotal with a number behind it is a number; a
    /// unit symbol and a "Mixed units" or "Error" refusal are text.
    func groupCellField(_ slice: LedgerGroupSlice, column: LedgerColumn) -> LedgerTabularField {
        let text = groupCellText(slice, column: column)
        guard column.id != LedgerDefaultColumns.unitColumnID,
              let result = slice.subtotals.result(column.id),
              LedgerValueParts.parts(of: result, policy: unitPolicy, rounding: rounding, locale: locale) != nil else {
            return .text(text)
        }
        return .number(text)
    }

    // MARK: Inline editing (IM-013)

    /// Whether a column's cells can be edited in place: an editable text column, or an
    /// editable choice column with options, while a host is listening for the commit.
    public func isInlineEditable(_ column: LedgerColumn) -> Bool {
        guard onCommitInlineEdit != nil, column.visible, column.isEditable, column.kind.isDirectlyEditable,
              !LedgerDefaultColumns.isDisplayColumn(column.id) else { return false }
        // NL-QTY-01: an edit must have somewhere to go — a command of its own (Subject, Label,
        // Comment, Status) or a stored per-row value. An editable column with neither used to
        // open an editor whose commit the app then dropped without a word.
        guard Self.inlineCommandColumns.contains(column.id) || column.holdsUserValues else { return false }
        switch column.kind {
        case .text: return true
        case .choice: return !column.choices.isEmpty
        // NL-QTY-04: a typed rate or a number column — parsed in the user's locale, stored in
        // the same cell shape the Bulk Edit panel stores.
        case .number, .currency: return true
        case .date, .checkbox, .formula: return false
        }
    }

    /// The standard columns an inline edit reaches through their own command rather than as
    /// a stored per-row value.
    static let inlineCommandColumns: Set<LedgerColumnID> = [.subject, .label, .comment, .status]

    /// The text an inline editor opens with: the formatted cell for text, the bare editable
    /// number for a number or money cell — "5 400" rather than "5 400,00 kr", in the unit the
    /// column displays — so what is typed back parses.
    func inlineEditingText(row: LedgerRow, column: LedgerColumn) -> String {
        switch column.kind {
        case .number, .currency:
            return LedgerBulkEditModel.editableNumberText(row.value(column.id), column: column, locale: locale) ?? ""
        default:
            return LedgerDefaultColumns.displayText(for: row, columnID: column.id)
        }
    }

    /// The columns Tab visits, in display order.
    public var inlineEditableColumns: [LedgerColumn] { columns.filter(isInlineEditable) }

    /// Opens an editor over one cell.
    ///
    /// An editor already open elsewhere commits first. Locked rows, rows not on screen and
    /// columns that cannot be edited in place open nothing.
    ///
    /// - Returns: `true` when the editor opened.
    @discardableResult
    public func beginInlineEdit(displayPosition: Int, columnID: LedgerColumnID) -> Bool {
        guard isViewLoaded, let column = column(columnID), isInlineEditable(column),
              let row = row(atDisplayPosition: displayPosition), !row.locked,
              let visualRow = visualRow(forDisplayPosition: displayPosition) else { return false }
        let table: NSTableView = mode == .grouped ? outlineView : tableView
        let columnIndex = table.column(withIdentifier: NSUserInterfaceItemIdentifier(columnID.rawValue))
        guard columnIndex >= 0 else { return false }
        if editingCell != nil { commitInlineEdit() }

        if table.selectedRowIndexes != IndexSet(integer: visualRow) {
            // An ordinary selection change: the canvas follows the row being edited.
            table.selectRowIndexes(IndexSet(integer: visualRow), byExtendingSelection: false)
        }
        let address = LedgerCellAddress(displayPosition: displayPosition, columnID: columnID)
        let editor: NSView
        switch column.kind {
        case .choice:
            let current: String? = {
                if case let .choice(value) = row.value(columnID) { return value }
                return nil
            }()
            let popUp = LedgerInlinePopUpButton(address: address, column: column, current: current)
            popUp.target = self
            popUp.action = #selector(inlinePopUpDidChoose(_:))
            popUp.onCommand = { [weak self] command in self?.performInlineEditCommand(command) }
            editor = popUp
        default:
            let field = LedgerInlineTextField(
                address: address,
                text: inlineEditingText(row: row, column: column),
                column: column
            )
            field.delegate = self
            editor = field
        }
        editor.frame = table.frameOfCell(atColumn: columnIndex, row: visualRow)
        table.addSubview(editor)
        inlineEditor = editor
        editingCell = address
        focusedColumnID = columnID
        table.window?.makeFirstResponder(editor)
        return true
    }

    /// Performs what a key press inside an editor asks for.
    public func performInlineEditCommand(_ command: LedgerInlineEditCommand) {
        switch command {
        case .commit: commitInlineEdit()
        case .cancel: cancelInlineEdit()
        case .next: moveInlineEdit(forward: true)
        case .previous: moveInlineEdit(forward: false)
        }
    }

    /// Keeps the editor's value — one bulk-edit request for one markup — and closes it.
    ///
    /// A value equal to what the cell already holds sends nothing.
    public func commitInlineEdit() {
        guard let address = editingCell, let editor = inlineEditor else { return }
        let request = inlineEditRequest(address: address, editor: editor)
        closeInlineEditor()
        if let request { onCommitInlineEdit?(request) }
    }

    /// Closes the editor and leaves the cell as it was.
    public func cancelInlineEdit() {
        guard editingCell != nil else { return }
        closeInlineEditor()
    }

    /// Commits, then opens the next (or previous) editable cell: the next editable column of
    /// the same row, then the first editable column of the next row on screen.
    public func moveInlineEdit(forward: Bool) {
        guard let address = editingCell else { return }
        let editable = inlineEditableColumns.map(\.id)
        commitInlineEdit()
        guard let target = neighbourCell(of: address, editable: editable, forward: forward) else { return }
        beginInlineEdit(displayPosition: target.displayPosition, columnID: target.columnID)
    }

    private func neighbourCell(
        of address: LedgerCellAddress,
        editable: [LedgerColumnID],
        forward: Bool
    ) -> LedgerCellAddress? {
        guard !editable.isEmpty, let columnIndex = editable.firstIndex(of: address.columnID) else { return nil }
        let nextColumn = columnIndex + (forward ? 1 : -1)
        if editable.indices.contains(nextColumn) {
            return LedgerCellAddress(displayPosition: address.displayPosition, columnID: editable[nextColumn])
        }
        guard let visualRow = visualRow(forDisplayPosition: address.displayPosition) else { return nil }
        let table: NSTableView = mode == .grouped ? outlineView : tableView
        let rowCount = mode == .grouped ? table.numberOfRows : plan.order.count
        var candidate = visualRow + (forward ? 1 : -1)
        while candidate >= 0, candidate < rowCount {
            if case let .row(position) = content(atVisualRow: candidate),
               let row = row(atDisplayPosition: position), !row.locked {
                return LedgerCellAddress(
                    displayPosition: position,
                    columnID: forward ? editable[0] : editable[editable.count - 1]
                )
            }
            candidate += forward ? 1 : -1
        }
        return nil
    }

    private func inlineEditRequest(address: LedgerCellAddress, editor: NSView) -> LedgerBulkEditRequest? {
        guard let row = row(atDisplayPosition: address.displayPosition) else { return nil }
        let current = row.value(address.columnID)
        let newValue: LedgerCellValue
        if let field = editor as? LedgerInlineTextField {
            let text = field.stringValue
            guard text != field.originalText else { return nil }
            switch field.column.kind {
            case .number, .currency:
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    newValue = .empty
                } else {
                    let rowCurrency: String? = {
                        if case let .currency(_, code) = current, !code.isEmpty { return code }
                        return nil
                    }()
                    guard let decimal = LedgerNumberParsing.decimal(from: trimmed),
                          let cell = LedgerBulkEditModel.numberCell(
                              decimal, for: field.column, fallbackCurrencyCode: rowCurrency
                          ) else {
                        // Not a number, or money with no currency to put it in: the cell keeps
                        // its value and the person hears that the edit did not take.
                        if let onInlineEditRejected { onInlineEditRejected(field.column) } else { NSSound.beep() }
                        return nil
                    }
                    newValue = cell
                }
                if LedgerBulkEditModel.isSameCell(current, newValue, dimension: field.column.dimension) {
                    return nil
                }
            default:
                // T-050: an emptied Subject is refused here, as an unparseable number is, and
                // as the Bulk Edit panel refuses it (`unclearableColumns`): the application
                // writes a Subject only from text, so `.empty` used to build an empty batch,
                // report success and close the editor on the old value with no word said.
                if text.isEmpty, LedgerBulkEditModel.unclearableColumns.contains(field.column.id) {
                    if let onInlineEditRejected { onInlineEditRejected(field.column) } else { NSSound.beep() }
                    return nil
                }
                newValue = text.isEmpty ? .empty : .text(text)
            }
        } else if let popUp = editor as? LedgerInlinePopUpButton {
            guard popUp.selectedValue != popUp.originalValue else { return nil }
            newValue = popUp.selectedValue.map(LedgerCellValue.choice) ?? .empty
        } else {
            return nil
        }
        guard newValue != current else { return nil }
        return LedgerBulkEditRequest(markupIDs: [row.markupID], values: [address.columnID: newValue])
    }

    private func closeInlineEditor() {
        isEndingInlineEdit = true
        defer { isEndingInlineEdit = false }
        let hadFocus = inlineEditor.map { editor in
            guard let responder = editor.window?.firstResponder as? NSView else { return false }
            return responder === editor || responder.isDescendant(of: editor)
                || (responder as? NSText)?.delegate === editor as? NSTextField
        } ?? false
        inlineEditor?.removeFromSuperview()
        inlineEditor = nil
        editingCell = nil
        if hadFocus {
            let table: NSTableView = mode == .grouped ? outlineView : tableView
            table.window?.makeFirstResponder(table)
        }
    }

    @objc private func inlinePopUpDidChoose(_ sender: Any?) {
        commitInlineEdit()
    }

    /// An open editor that is about to lose its row to a reload: the markup, the column and
    /// what has been typed so far, so it reopens where that row lands.
    private struct SuspendedInlineEdit {
        let markupID: UUID
        let columnID: LedgerColumnID
        let text: String?
        let choice: String??
    }

    private func suspendInlineEdit() -> SuspendedInlineEdit? {
        guard let address = editingCell, let editor = inlineEditor,
              let sourceIndex = plan.sourceIndex(displayPosition: address.displayPosition),
              let markupID = rowSource.ledgerRowID(at: sourceIndex) else {
            cancelInlineEdit()
            return nil
        }
        let suspended = SuspendedInlineEdit(
            markupID: markupID,
            columnID: address.columnID,
            text: (editor as? LedgerInlineTextField)?.stringValue,
            choice: (editor as? LedgerInlinePopUpButton).map { popUp -> String? in popUp.selectedValue }
        )
        closeInlineEditor()
        return suspended
    }

    private func resumeInlineEdit(_ suspended: SuspendedInlineEdit?) {
        guard let suspended, let position = lookupDisplayPosition(suspended.markupID),
              beginInlineEdit(displayPosition: position, columnID: suspended.columnID) else { return }
        if let text = suspended.text, let field = inlineEditor as? LedgerInlineTextField {
            field.stringValue = text
        }
        if let choice = suspended.choice, let popUp = inlineEditor as? LedgerInlinePopUpButton {
            popUp.select(value: choice)
        }
    }
}

// MARK: - Inline editor keys

extension LedgerTableController: NSTextFieldDelegate {

    /// Return keeps the value, Tab and Shift-Tab keep it and move, Escape restores it.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === inlineEditor else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            performInlineEditCommand(.commit)
        case #selector(NSResponder.insertTab(_:)):
            performInlineEditCommand(.next)
        case #selector(NSResponder.insertBacktab(_:)):
            performInlineEditCommand(.previous)
        case #selector(NSResponder.cancelOperation(_:)):
            performInlineEditCommand(.cancel)
        default:
            return false
        }
        return true
    }

    /// Clicking away keeps what was typed, like every other text field on the Mac.
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard !isEndingInlineEdit, let control = obj.object as? NSControl, control === inlineEditor else { return }
        commitInlineEdit()
    }
}

// MARK: - Copy validation

extension LedgerTableController: NSMenuItemValidation {

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) { return canCopy }
        return true
    }
}

// MARK: - Flat table data source

extension LedgerTableController: NSTableViewDataSource {

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === pinnedTableView {
            return mode == .grouped ? outlineView.numberOfRows : plan.order.count
        }
        return plan.order.count
    }
}

extension LedgerTableController: NSTableViewDelegate {

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let visual: LedgerVisualRow
        if tableView === pinnedTableView {
            visual = content(atVisualRow: row)
        } else {
            visual = row < plan.order.count ? .row(displayPosition: row) : .none
        }
        return makeCell(for: tableColumn, visualRow: visual, in: tableView)
    }

    /// design-d6: rows draw their own hairline and rounded selection (LedgerTableAppearance).
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = LedgerTableRowView()
        if tableView === pinnedTableView, case .group = content(atVisualRow: row) {
            rowView.isGroupHeading = true
        }
        return rowView
    }

    /// Truncated labels and comments can be read by hovering (IM-200).
    public func tableView(_ tableView: NSTableView, shouldShowCellExpansionFor tableColumn: NSTableColumn?, row: Int) -> Bool {
        true
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        guard !isApplyingExternalSelection else { return }
        // A click on the PINNED band (Type/Subject — the leading ~230 pt of every row) used
        // to be dropped here (`table !== pinnedTableView` returned), so the row highlighted
        // and the presenter never heard about it: canvas selection stayed empty and
        // Export/Copy Snippet stayed disabled however deliberately the row was chosen
        // (LT-40, 2026-08-29). Sync was one-way main→pinned; a pinned click now mirrors
        // into the live main view first, then reports exactly like a main-view click —
        // the mirror is echo-guarded by the same external-selection flag.
        if table === pinnedTableView {
            isApplyingExternalSelection = true
            let main: NSTableView = mode == .grouped ? outlineView : tableView
            main.selectRowIndexes(table.selectedRowIndexes, byExtendingSelection: false)
            isApplyingExternalSelection = false
        }
        var ids: Set<UUID> = []
        for row in table.selectedRowIndexes {
            guard case let .row(position) = content(atVisualRow: row),
                  let sourceIndex = plan.sourceIndex(displayPosition: position),
                  let id = rowSource.ledgerRowID(at: sourceIndex) else { continue }
            ids.insert(id)
        }
        selectedRowIDs = ids
        if table !== pinnedTableView {
            // The main→pinned mirror is echo-guarded exactly like the pinned→main one above.
            // Unguarded, the pinned band's own `selectionDidChange` re-mirrored and reported a
            // second time, so one click ran `presenter.select` and the bulk-edit adoption
            // twice (CR-63, a regression of the LT-40 fix).
            isApplyingExternalSelection = true
            pinnedTableView.selectRowIndexes(table.selectedRowIndexes, byExtendingSelection: false)
            isApplyingExternalSelection = false
        }
        delegate?.ledgerTable(self, didChangeSelection: ids)
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        forwardSort(from: tableView)
    }

    public func tableViewColumnDidMove(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table === tableView else { return }
        syncColumnOrder(from: table)
    }

    /// Refuses a column drag that would cross the edge of the pinned band (S-087).
    public func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        allowsColumnReorder(in: tableView, from: columnIndex, to: newColumnIndex)
    }

    /// Whether a column drag keeps the pinned band intact.
    ///
    /// The main table and the outline own every column, the pinned ones leading under the
    /// pinned overlay. A drop that put an unpinned column in front of a pinned one — or a
    /// pinned one after an unpinned one — left the table's own order different from
    /// ``columns`` (which always leads with the pinned band), so the overlay covered one column
    /// while the pinned column also showed beside it until the next rebuild (S-087). A drag
    /// stays inside its band; pinning is changed from the header menu.
    func allowsColumnReorder(in table: NSTableView, from columnIndex: Int, to newColumnIndex: Int) -> Bool {
        // The pinned band never reorders; it follows the main table.
        if table === pinnedTableView { return false }
        // AppKit asks with -1 when the drag begins; refusing that would forbid every drag.
        guard newColumnIndex >= 0 else { return true }
        let pinnedCount = table.tableColumns.prefix { tableColumn in
            column(LedgerColumnID(tableColumn.identifier.rawValue))?.pinned == true
        }.count
        return (columnIndex < pinnedCount) == (newColumnIndex < pinnedCount)
    }

    public func tableViewColumnDidResize(_ notification: Notification) {
        handleColumnResize(notification)
    }

    /// Records a column's new width and gives it to the same column in every other table.
    ///
    /// The main table owns every column, pinned ones included, under the pinned overlay; a
    /// drag in the pinned band used to widen only the band, so the main table's first
    /// unpinned column slid under the overlay until the next full column rebuild (BH-245).
    fileprivate func handleColumnResize(_ notification: Notification) {
        guard !isSynchronizingColumnWidth,
              let table = notification.object as? NSTableView,
              let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        let columnID = LedgerColumnID(column.identifier.rawValue)
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
        guard columns[index].width != Double(column.width) else { return }
        // The width decides which column carries a group heading (the first one at least
        // 90 pt wide), so a resize across that line moves the headings. Only then are the rows
        // redrawn, so a live resize drag does not reload on every notification (R-135).
        let headingBefore = groupHeadingColumnID
        columns[index].width = Double(column.width)
        isSynchronizingColumnWidth = true
        for peer in [tableView, outlineView, pinnedTableView] as [NSTableView] where peer !== table {
            peer.tableColumn(withIdentifier: column.identifier)?.width = column.width
        }
        isSynchronizingColumnWidth = false
        if columns[index].pinned {
            let pinnedWidth = columns.filter { $0.visible && $0.pinned }.reduce(0.0) { $0 + $1.width }
            pinnedWidthConstraint?.constant = pinnedWidth
        }
        if groupHeadingColumnID != headingBefore { reloadRows() }
        delegate?.ledgerTable(self, didChangeColumns: columns)
    }

    /// Adopts a column drag's order.
    ///
    /// The swatch column (the first visible one), the heading column and the outline's
    /// disclosure column all follow from the order. Reassigning ``columns`` recomputed the
    /// first two for rows drawn afterwards, but the rows already on screen kept drawing them
    /// in the old column and the disclosure triangle stayed where it was, so one table showed
    /// both until the next full rebuild (R-135). When either moves, the disclosure is
    /// re-pointed and the rows are redrawn.
    fileprivate func syncColumnOrder(from table: NSTableView) {
        let leadingBefore = leadingVisibleColumnID
        let headingBefore = groupHeadingColumnID
        var reordered: [LedgerColumn] = []
        var seen: Set<LedgerColumnID> = []
        for tableColumn in table.tableColumns {
            let columnID = LedgerColumnID(tableColumn.identifier.rawValue)
            if let column = column(columnID) {
                reordered.append(column)
                seen.insert(columnID)
            }
        }
        for column in columns where !seen.contains(column.id) { reordered.append(column) }
        let pinnedLeading = LedgerColumnLayout.pinnedFirst(reordered)
        columns = pinnedLeading
        if pinnedLeading.map(\.id) != reordered.map(\.id) {
            // A move that crossed the pinned band — the drag refusal above keeps a person from
            // making one, a programmatic `moveColumn` does not — is put back: the table's own
            // order must match ``columns`` or the overlay hides one column and the pinned one
            // shows twice (S-087). The rebuild re-points the disclosure too.
            rebuildColumns()
            reloadRows()
        } else if leadingVisibleColumnID != leadingBefore || groupHeadingColumnID != headingBefore {
            pointDisclosureAtLeadingColumn()
            reloadRows()
        }
        delegate?.ledgerTable(self, didChangeColumns: columns)
    }
}

// MARK: - Grouped outline data source

extension LedgerTableController: NSOutlineViewDataSource {

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? LedgerOutlineItem else {
            // A grouped plan with rows but no groups is the pending plan a core-backed source
            // supplies while the core regroups (IM-011): its rows are listed at the root
            // rather than hidden behind headings that do not exist yet.
            return plan.groups.isEmpty ? plan.order.count : plan.groups.count
        }
        guard let slice = node.slice else { return 0 }
        return slice.isLeaf ? slice.rowRange.count : slice.children.count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? LedgerOutlineItem, let slice = node.slice else {
            if plan.groups.isEmpty { return itemCache.item(displayPosition: index) }
            return itemCache.item(for: plan.groups[index])
        }
        if slice.isLeaf {
            return itemCache.item(displayPosition: slice.rowRange.lowerBound + index)
        }
        return itemCache.item(for: slice.children[index])
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? LedgerOutlineItem, let slice = node.slice else { return false }
        return slice.rowCount > 0
    }
}

extension LedgerTableController: NSOutlineViewDelegate {

    public func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? LedgerOutlineItem else { return nil }
        let visual: LedgerVisualRow
        if let slice = node.slice {
            visual = .group(path: slice.path)
        } else if let position = node.displayPosition {
            visual = .row(displayPosition: position)
        } else {
            visual = .none
        }
        return makeCell(for: tableColumn, visualRow: visual, in: outlineView)
    }

    /// design-d6: group headings sit on a raised band; every row draws its own hairline and
    /// rounded selection (LedgerTableAppearance).
    public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = LedgerTableRowView()
        rowView.isGroupHeading = (item as? LedgerOutlineItem)?.isGroup ?? false
        return rowView
    }

    /// Truncated labels and comments can be read by hovering (IM-200).
    public func outlineView(_ outlineView: NSOutlineView, shouldShowCellExpansionFor tableColumn: NSTableColumn?, item: Any) -> Bool {
        true
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingExternalSelection else { return }
        var ids: Set<UUID> = []
        for row in outlineView.selectedRowIndexes {
            guard case let .row(position) = content(atVisualRow: row),
                  let sourceIndex = plan.sourceIndex(displayPosition: position),
                  let id = rowSource.ledgerRowID(at: sourceIndex) else { continue }
            ids.insert(id)
        }
        selectedRowIDs = ids
        // Echo-guarded for the same reason as the flat table's mirror (CR-63).
        isApplyingExternalSelection = true
        pinnedTableView.selectRowIndexes(outlineView.selectedRowIndexes, byExtendingSelection: false)
        isApplyingExternalSelection = false
        delegate?.ledgerTable(self, didChangeSelection: ids)
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? LedgerOutlineItem,
              let slice = node.slice else { return }
        let changed = collapsedGroupPaths.remove(slice.path) != nil
        guard !isBatchingExpansion else {
            if changed { batchedCollapsedPathsChanged = true }
            return
        }
        if changed { onCollapsedGroupPathsChange?(collapsedGroupPaths) }
        pinnedTableView.reloadData()
        // The outline keeps a selection by item across the index shift and posts nothing;
        // the pinned band, reloaded by index, must be told where the rows went (BH-246).
        mirrorSelectionToPinned()
        delegate?.ledgerTable(self, didSetExpanded: true, groupPath: slice.path)
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? LedgerOutlineItem,
              let slice = node.slice else { return }
        let changed = collapsedGroupPaths.insert(slice.path).inserted
        guard !isBatchingExpansion else {
            if changed { batchedCollapsedPathsChanged = true }
            return
        }
        if changed { onCollapsedGroupPathsChange?(collapsedGroupPaths) }
        pinnedTableView.reloadData()
        mirrorSelectionToPinned()
        delegate?.ledgerTable(self, didSetExpanded: false, groupPath: slice.path)
    }

    public func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        forwardSort(from: outlineView)
    }

    /// The outline reports column moves under its own name, not the table's; without this a
    /// reorder in grouped mode never reached ``columns`` and snapped back on the next
    /// column rebuild (BH-244).
    public func outlineViewColumnDidMove(_ notification: Notification) {
        guard let table = notification.object as? NSOutlineView, table === outlineView else { return }
        syncColumnOrder(from: table)
    }

    /// The outline keeps the pinned band intact exactly like the flat table (S-087).
    public func outlineView(_ outlineView: NSOutlineView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        allowsColumnReorder(in: outlineView, from: columnIndex, to: newColumnIndex)
    }

    /// The outline's resize notification, handled exactly like the flat table's (BH-244).
    public func outlineViewColumnDidResize(_ notification: Notification) {
        handleColumnResize(notification)
    }
}

/// An `NSTableView` that reports Return and Space to the controller.
@MainActor
final class LedgerTableView: NSTableView {

    /// Handles a keyboard command; returning `true` swallows the event.
    var onCommand: ((LedgerTableController.Command) -> Bool)?
    /// NL-UX-09: the visual row under the pointer, `-1` when it leaves.
    var onHoverRow: ((Int) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        LedgerRowHoverTracking.install(on: self)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHoverRow?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverRow?(-1)
    }

    /// Every `reloadData`, for tests that count pinned-band reloads (IM-100).
    private(set) var reloadDataCallCount = 0

    override func reloadData() {
        reloadDataCallCount += 1
        super.reloadData()
    }

    override func keyDown(with event: NSEvent) {
        if let command = LedgerKeyCommandMapping.command(for: event), onCommand?(command) == true { return }
        super.keyDown(with: event)
    }
}

/// An `NSOutlineView` that reports Return and Space to the controller.
@MainActor
final class LedgerOutlineView: NSOutlineView {

    /// Handles a keyboard command; returning `true` swallows the event.
    var onCommand: ((LedgerTableController.Command) -> Bool)?
    /// NL-UX-09: the visual row under the pointer, `-1` when it leaves.
    var onHoverRow: ((Int) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        LedgerRowHoverTracking.install(on: self)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHoverRow?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverRow?(-1)
    }

    override func keyDown(with event: NSEvent) {
        if let command = LedgerKeyCommandMapping.command(for: event), onCommand?(command) == true { return }
        super.keyDown(with: event)
    }
}

/// Maps key events to table commands, kept in one place so both views agree.
enum LedgerKeyCommandMapping {

    /// The command a key event stands for, or `nil` to let AppKit handle it.
    static func command(for event: NSEvent) -> LedgerTableController.Command? {
        switch event.keyCode {
        case 36, 76: return .activate
        case 49: return .toggleGroup
        default: return nil
        }
    }
}

/// A formatted total as two fields — the number and the unit — rather than one string to
/// be split again (IM-098).
///
/// Quantities go through `LedgerNumberFormatting.displayParts`, the function the combined
/// `displayText` joins, so `"\(number) \(unit)"` is exactly what the totals row prints; the
/// split just never has to be recovered from text.
enum LedgerValueParts {

    /// The number text and unit symbol of an aggregate, or `nil` for a refusal or an
    /// unavailable total, which have no number to show.
    static func parts(
        of result: LedgerAggregateResult,
        policy: LedgerUnitPolicy,
        rounding: LedgerRounding,
        locale: Locale
    ) -> (number: String, unit: String)? {
        switch result.value {
        case let .quantity(quantity):
            // The same function `LedgerNumberFormatting.display` joins, so the header's two
            // halves are exactly the totals row's one string.
            let parts = LedgerNumberFormatting.displayParts(quantity, policy: policy, rounding: rounding, locale: locale)
            return (parts.numberText, parts.unitSymbol)
        case .mixedUnits, .failed, .unavailable:
            return nil
        }
    }
}

extension LedgerTableController {
    /// Whether a header click may sort by this column: every column except the synthesised
    /// Value and Unit display columns (IM-056 / BH-102).
    nonisolated static func isSortable(_ column: LedgerColumn) -> Bool {
        !LedgerDefaultColumns.isDisplayColumn(column.id)
    }
}
