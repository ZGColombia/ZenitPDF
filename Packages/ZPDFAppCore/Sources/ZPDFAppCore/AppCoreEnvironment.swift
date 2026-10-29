import Foundation
import Observation
import ZPDFContracts
import ZPDFQuantityLedger
import ZPDFSnapEngine
import ZPDFUIPresentation

/// One document's presenters, wired to one session and one undo stack.
///
/// The presenters do not know about each other. Selecting a ledger row highlights the
/// markup on the canvas because *this* type connects the two closures, not because the
/// ledger imports the canvas. That is what keeps each presenter testable on its own and
/// keeps the wiring — which is where cross-pane bugs live — in one readable place.
@MainActor
@Observable
public final class AppCoreEnvironment {

    /// The engine-side state.
    public let session: TakeoffSession
    /// The only door document mutations go through.
    public let commands: DocumentCommandBus

    /// Open documents, pages, zones and Scale Regions.
    public let document: AppDocumentPresenter
    /// Called after the current page changed and the canvas followed — for app-tier features
    /// that react to a page turn, such as the per-page scale proposal.
    public var afterPageChange: (@MainActor (ZPDFUIPresentation.PageDescriptor) -> Void)?
    /// The Search panel's presenter, which follows the sheet on screen so its "Current Page"
    /// scope means that sheet (R-048). Owned by the document; attached with ``attachSearch(_:)``.
    @ObservationIgnored public private(set) weak var search: AppSearchPresenter?

    /// Attaches the Search panel's presenter and tells it which sheet is on screen now.
    public func attachSearch(_ presenter: AppSearchPresenter) {
        search = presenter
        followPageInSearch()
    }

    /// Makes this window's sheet the one the shared Search panel's "Current Page" means (S-033).
    ///
    /// Several windows on one document share one ``AppSearchPresenter``. Each window's page turns
    /// used to write the presenter's current page, so a Current Page search in window 1 listed the
    /// hits of the sheet window 2 turned to last. The app calls this when a window becomes the one
    /// the person works in; from then on only that window's page turns move the scope.
    public func takeSearchFocus() {
        guard let search else { return }
        search.currentPageOwner = self
        if let page = document.currentPageID { search.setCurrentPage(page) }
    }

    /// The sheet on screen, handed to the Search panel when this window owns its Current Page.
    func followPageInSearch(_ pageID: UUID? = nil) {
        guard let search, let page = pageID ?? document.currentPageID else { return }
        guard search.currentPageOwner == nil || search.currentPageOwner === self else { return }
        search.setCurrentPage(page)
    }

    /// Builds one page's snap index — extraction and install — supplied by the app, which owns
    /// the extraction service (K-01). The environment asks for it the first time each sheet is
    /// on screen, the sheet on screen now included, so Vector Snap works on every page and not
    /// only on the first. See `AppCoreEnvironment+SnapIndex.swift`.
    @ObservationIgnored public var snapIndexSource: (@MainActor (ZPDFContracts.PageDescriptor) async -> SnapIndexBuild)? {
        didSet { if let page = document.currentPageID { ensureSnapIndex(forPage: page) } }
    }
    /// Pages whose snap index is being built now, so a page turned to twice builds once.
    @ObservationIgnored var snapIndexBuildsInFlight: Set<UUID> = []
    /// Why a page's vector geometry could not be read, kept so turning back to it says so again.
    @ObservationIgnored var snapIndexFailures: [UUID: String] = [:]
    /// The drawing canvas.
    public let canvas: AppCanvasPresenter
    /// The Quantity Ledger.
    public let ledger: AppLedgerPresenter

    /// Where the office rate library lives (NL-QTY-05). The shipping location by default; a test
    /// injects a temporary directory so nothing is written to the person's own library.
    public var rateLibraryStore: RateLibraryStore = .standard()
    /// The measurement palette and the measurement in progress.
    public let measurement: AppMeasurementToolPresenter
    /// The markup tools — Text, Callout and the seven Shapes — and the markup in progress.
    public let markup: AppMarkupToolPresenter
    /// The Tool Library.
    public let toolLibrary: AppToolLibraryPresenter
    /// The status bar and the warning tray.
    public let status: AppStatusPresenter
    /// The audit-trail feed behind the History tab (ADR-0007). Detached
    /// until the document supplies a project database; the ledger presenter surfaces it
    /// to the shell as ``LedgerAuditPresenting``.
    public let history: AppHistoryPresenter
    /// Review threads — replies on markups — and the Comments tab's thread (NL-COLLAB-01/02).
    /// Follows the History into whatever project database it attaches to.
    public let review: AppReviewPresenter

    /// The most recent document snapshot every presenter was fed from.
    public private(set) var snapshot: DocumentSnapshot

    /// What the open document is called, for a stamp's `documentName` field.
    ///
    /// Settable rather than derived: the display name lives in the project package, which
    /// this package deliberately does not open. The window controller sets all three when
    /// it opens a document; unset they resolve to an empty string, which a stamp renders as
    /// nothing rather than as a placeholder nobody typed.
    public var documentDisplayName: String = ""

    /// The document's active revision name, for a stamp's `revision` field.
    public var documentRevisionName: String = ""

    /// The project's name, for a stamp's `projectName` field.
    public var projectDisplayName: String = ""

    /// Called when a committed measurement lies in more than one Scale Region.
    ///
    /// Unset, the measurement is **not created** and the reason is posted to the warning
    /// tray. That is the deliberate default: a build whose crossing prompt is not wired must
    /// refuse the measurement, never fall back to a scale nobody chose (spec §10.4).
    public var onScaleRegionCrossing: (@MainActor (PendingScaleRegionCrossing) -> Void)?

    /// Called after every presenter refresh, with the snapshot they were all fed from.
    ///
    /// The panels outside this package — Scale Regions, Project Zones — hold state derived
    /// from the takeoff (a region's markup count, a zone's subtotal, the overlap set) and had
    /// no way to hear that it changed. Without this they were correct only immediately after
    /// their own edits, and stale after everyone else's.
    public var onDidRefresh: (@MainActor (DocumentSnapshot) -> Void)?

    /// Raised whenever a Tool Library preset arms, with the tool the canvas will use, so the
    /// shell mirrors the arming onto the toolbar and the status bar
    /// (`ProjectShellEnvironment.libraryArmed(_:)`). Without the mirror the presenter was
    /// armed while the toolbar and status bar still said Select — the Library looked
    /// decorative and the next clicks read as dead (LT-37, 2026-08-29).
    ///
    /// The tool is the preset's drawing tool in Draw (``ToolPresetSummary/drawingTool``) and
    /// Select when it arms none: Apply, Place, or a kind nobody draws by hand. Those used to
    /// raise nothing, so the chip lit before the arm stayed lit over presenters this arming had
    /// put down, and choosing it again was no change at all (X-018).
    public var onLibraryArmedTool: (@MainActor (ZenitToolMode) -> Void)?

    /// Raises ``onLibraryArmedTool`` for an armed preset: its drawing tool in Draw, else Select.
    func showLibraryTool(of preset: ToolPresetSummary, in mode: ToolSetMode) {
        onLibraryArmedTool?(mode == .draw ? (preset.drawingTool ?? .select) : .select)
    }

    /// The double-count guard's overlap regions per page, for the canvas hatch (NL-MEASURE-13,
    /// `AppCoreEnvironment+DoubleCount.swift`). Empty while the guard is off.
    public internal(set) var doubleCountRegions: [PageID: [PolygonGeometry]] = [:]
    /// Called when ``doubleCountRegions`` changed, so the canvas redraws its hatch.
    public var onDoubleCountRegionsChanged: (@MainActor () -> Void)?
    /// The double-count warnings the guard last left in the tray, by identity: one that is gone
    /// from the tray at the next refresh was dismissed by the person (V-034).
    var doubleCountPosted: [UUID: AppWarning] = [:]
    /// The double-count warnings the person dismissed, each with the words it had. Not posted
    /// again while the pair says the same; forgotten when the pair stops overlapping (V-034).
    var dismissedDoubleCounts: [UUID: String] = [:]

    /// Crossings waiting for an answer, by identity. Normally empty, and at most one deep in
    /// practice — the panel refuses to start a second question while one is open.
    private var pendingCrossings: [UUID: PendingScaleRegionCrossing] = [:]
    /// The snap-settings write in flight, so toggle clicks reach the engine in order.
    private var snapSettingsTask: Task<Void, Never>?
    /// The document's ledger column set as of the last refresh, for the synchronous paths
    /// that resolve a preset's custom column defaults — arming a Draw preset, building a batch
    /// stamp producer. Column changes always end in a refresh, which renews it.
    private(set) var ledgerColumnsCache: LedgerColumnSet?

    private let documentID: DocumentID

    /// NL-UX-20: the document's own core when this environment is a second window's view of the
    /// same document. The view shares its session, command bus, undo stack, History and review
    /// threads; its page, viewport, selection, armed tool, ledger view and status strip are its
    /// own. `nil` for the document's own core. See `AppCoreEnvironment+WindowView.swift`.
    @ObservationIgnored public private(set) weak var primaryEnvironment: AppCoreEnvironment?
    /// NL-UX-20: the second windows' views of this core, refreshed with it.
    @ObservationIgnored var windowViewLinks: [WindowViewLink] = []

    /// Builds an environment over a session that already has its pages.
    public static func make(
        session: TakeoffSession,
        documentID: DocumentID,
        undoManager: UndoManager = UndoManager()
    ) async throws -> AppCoreEnvironment {
        let snapshot = try await session.snapshot()
        let environment = AppCoreEnvironment(
            session: session,
            documentID: documentID,
            snapshot: snapshot,
            undoManager: undoManager
        )
        // The document hydrates before it builds its environment, so the repairs an open made
        // are waiting here to be said.
        environment.reportHydrationRepairs(await session.takeHydrationRepairs())
        environment.reportColumnRefusals(await session.takeColumnRefusals())
        environment.ledgerColumnsCache = await session.ledgerColumns
        // NL-QTY-07-UI: the project's own recipes, restored before the environment was built.
        environment.ledger.projectAssemblies = await session.projectAssemblyRecipes.recipes
        environment.installAssemblyRecipeSeam()
        return environment
    }

    /// NL-UX-20: a second window's view of the document `primary` belongs to — the per-window
    /// environment factory.
    ///
    /// The view is built over the **same** session, command bus (so the same undo stack), History
    /// and review presenter, and is refreshed after every change the bus publishes, from whichever
    /// window it came. Everything a window looks at is its own: the page on screen, the viewport,
    /// the canvas and ledger selection, the armed tool, the Tool Library's armed preset and the
    /// status strip. Warnings stay one tray: the view forwards what it posts to the document's own
    /// presenter and mirrors that presenter's list. Keep the post-init steps in step with
    /// ``make(session:documentID:undoManager:)``.
    public static func makeWindowView(of primary: AppCoreEnvironment) async throws -> AppCoreEnvironment {
        let root = primary.primaryEnvironment ?? primary
        let session = root.session
        let snapshot = try await session.snapshot(ledger: root.ledger.request)
        let view = AppCoreEnvironment(
            session: session,
            documentID: root.documentID,
            snapshot: snapshot,
            undoManager: root.commands.undoManager,
            sharing: root
        )
        view.ledgerColumnsCache = await session.ledgerColumns
        view.ledger.projectAssemblies = await session.projectAssemblyRecipes.recipes
        view.installAssemblyRecipeSeam()
        view.linkAsWindowView(of: root)
        return view
    }

    private init(
        session: TakeoffSession,
        documentID: DocumentID,
        snapshot: DocumentSnapshot,
        undoManager: UndoManager,
        sharing primary: AppCoreEnvironment? = nil
    ) {
        self.session = session
        self.documentID = documentID
        self.snapshot = snapshot
        self.primaryEnvironment = primary
        // NL-UX-20: a second window's view drives the document's own bus — one undo stack.
        self.commands = primary?.commands ?? DocumentCommandBus(session: session, undoManager: undoManager)
        self.document = AppDocumentPresenter(session: session)
        self.canvas = AppCanvasPresenter(
            session: session,
            pageID: snapshot.pages.first?.id ?? UUID(),
            pageIndex: snapshot.pages.first?.index ?? 0
        )
        self.ledger = AppLedgerPresenter(session: session, projection: snapshot.ledger)
        self.measurement = AppMeasurementToolPresenter(
            session: session,
            documentID: documentID,
            pageID: PageID(snapshot.pages.first?.id ?? UUID()),
            units: snapshot.units
        )
        self.markup = AppMarkupToolPresenter(
            documentID: documentID,
            pageID: PageID(snapshot.pages.first?.id ?? UUID())
        )
        self.toolLibrary = AppToolLibraryPresenter()
        self.status = AppStatusPresenter(units: snapshot.units)
        // NL-UX-20: one audit trail and one set of review threads per document, whichever
        // window an edit or a reply came from.
        self.history = primary?.history ?? AppHistoryPresenter()
        self.review = primary?.review ?? AppReviewPresenter(undoManager: undoManager)
        if primary == nil {
            self.review.actorNameProvider = { AuthorIdentity.current() }
            self.review.history = history
            self.history.onAttach = { [weak review] database, projectID in
                review?.attach(database: database, projectID: projectID)
            }
            self.history.onMigrate = { [weak review] from, fromProject, to, toProject in
                review?.migrate(from: from, oldProjectID: fromProject, to: to, newProjectID: toProject)
            }
            // The author name is resolved at record time from the
            // app-level preference (machine account name unless the user chose otherwise),
            // so a Settings change signs the *next* entry, never rewrites a past one. The
            // History feed formats values through the ledger's own formatter.
            self.history.actorNameProvider = { AuthorIdentity.current() }
        }
        self.history.formatter = snapshot.ledger.formatter
        self.measurement.authorProvider = { AuthorIdentity.current() }
        self.markup.authorProvider = { AuthorIdentity.current() }
        self.ledger.history = history
        wire()
        // NL-COLLAB-04: the Review List reads every markup from the snapshot. The document's
        // own core answers it; a second window's view must not take the shared presenter over.
        if primary == nil {
            self.review.markupsProvider = { [weak self] in self?.snapshot.markups ?? [] }
            // W-027: a review round stores, and later compares against, the ledger's own totals.
            self.review.ledgerTotalsProvider = { [weak self] in
                self.map { ReviewRoundTotals(store: $0.ledger.projection.view.store) }
            }
        }
        adopt(snapshot)
    }

    // MARK: Wiring

    /// The tool options bar's value for a preset's saved depth, wall height or slope — the
    /// text the field shows and the exact value the engine keeps while it shows it — or `nil`
    /// when the tool needs no parameter and when the preset saved none for the one it needs.
    ///
    /// Handed to the presenter as *text* rather than pushed straight into
    /// `MeasurementParameters`, and that is the whole point of the function existing. The field
    /// the estimator reads and the value the engine uses have to be the same number, or the
    /// status bar goes on saying "Volume is waiting for a depth" over a tool that has one.
    /// `setParameterText(_:exactValue:)` is the single door that keeps the two in step, so a
    /// preset goes through it like a keystroke does.
    ///
    /// A slope is included. The comment that stood here said `ToolPresetSummary` had no slope
    /// field; `measurementDefaults.slopePercent` is exactly that field, and returning `nil` for
    /// it left every True Sloped preset — the built-in `Roof 6:12` among them — armed with its
    /// slope in the parameter block and an empty field, so the tool could never commit while
    /// the status bar asked for a slope it already had (BH-002).
    ///
    /// A preset stores lengths in SI base units, so a length is divided by the display unit's
    /// exact `Decimal` factor. That quotient does not terminate for feet or inches (0.2 m is
    /// 0.656167979… ft) and used to reach the 56-point field as all 38 digits of `Decimal`'s
    /// expansion (BH-084); the text is now rounded to ``presetParameterFractionDigits`` places
    /// and the exact value rides alongside it, so rounding the display costs nothing measured.
    static func presetParameterEntry(
        of preset: ToolPresetSummary,
        for kind: Shown.Kind
    ) -> (text: String, exactValue: Decimal)? {
        switch kind.requiredParameter {
        case .depth, .wallHeight:
            let saved = kind.requiredParameter == .depth ? preset.defaultDepth : preset.defaultHeight
            guard let saved, saved.dimension == .length else { return nil }
            let display = saved.value / preset.displayLengthUnit.metresPerUnit
            return (displayText(display), saved.value)
        case .slopePercent:
            guard let percent = preset.measurementDefaults.slopePercent, percent.isFinite, percent > 0 else {
                return nil
            }
            let exact = ToolPresetParameterBridge.decimal(percent)
            return (displayText(exact), exact)
        case .totalRiseDrop, .none:
            // A rise or drop belongs to the run in front of the estimator, not to a tool.
            return nil
        }
    }

    /// The options bar's text for a preset value: exact when it has few enough places, rounded
    /// to ``presetParameterFractionDigits`` otherwise.
    static func displayText(_ value: Decimal) -> String {
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, presetParameterFractionDigits, .plain)
        return "\(rounded)"
    }

    /// Six places: a micrometre in metres, well under a thousandth of an inch in feet.
    static let presetParameterFractionDigits = 6

    /// The options bar text alone, for callers that only show it.
    static func parameterText(of preset: ToolPresetSummary, for kind: Shown.Kind) -> String? {
        presetParameterEntry(of: preset, for: kind)?.text
    }

    private func wire() {
        // Selection travels both ways by identity, and each side applies the other's
        // selection through the "external" path so the two do not echo each other forever.
        ledger.onSelectionChange = { [weak self] ids in
            // A derived row selects its source (NL-QTY-07, ADR-0024 §4).
            guard let self else { return }
            self.canvas.applyExternalSelection(self.ledger.canvasSelection(for: ids))
        }
        canvas.onSelectionChange = { [weak self] ids in
            self?.ledger.applyExternalSelection(ids)
        }

        // The ledger filter reaches the drawing. `AppCanvasPresenter` has always been able
        // to narrow itself to a matched set; nothing called it, so a ledger filtered to one
        // subject left the canvas showing everything and the filter panel's three-way
        // canvas control was inert. Behaviour first, then the set, so a single recompute
        // sees both.
        ledger.onCanvasFilterChange = { [weak self] ids, behavior in
            guard let self else { return }
            self.canvas.setFilterBehavior(behavior)
            self.canvas.setFilterMatches(ids.map { $0.union(self.markupsWithoutLedgerRows()) })
        }
        // What Hide takes off the sheet is no snap target for a click either (V-003): the
        // palette reads the canvas presenter's set at each click, so the two cannot disagree.
        measurement.snapExclusions = { [weak self] in self?.canvas.snapExcludedMarkupIDs ?? [] }

        // Changing pages moves the canvas, the measurement palette and the status bar
        // together — a palette still armed on the previous page is how a measurement ends
        // up on the wrong sheet.
        document.onPageChange = { [weak self] page in
            guard let self else { return }
            self.canvas.showPage(page)
            self.measurement.setPage(PageID(page.id))
            self.markup.setPage(PageID(page.id))
            self.followPageInSearch(page.id)
            self.ensureSnapIndex(forPage: page.id)
            self.refreshStatus()
            self.afterPageChange?(page)
        }

        // Warnings are posted on the document presenter and rendered from the status
        // presenter's tray; nothing connected the two, so every posted warning went into a
        // list no view read. It does now, which is what gives the failure below somewhere
        // to appear.
        document.onWarningsChange = { [weak self] warnings in
            self?.status.setWarnings(warnings)
            // NL-UX-20: one tray per document, shown in every window.
            self?.mirrorWarningsToWindowViews(warnings)
        }
        // The tray's dismissals go to the list that owns the warnings, so they last (S-029).
        status.onDismissWarning = { [weak self] id in self?.document.dismissWarning(id: id) }
        status.onDismissAllWarnings = { [weak self] in self?.document.dismissAllWarnings() }

        // A committed measurement becomes a command, so it lands on the undo stack. There
        // is no path from the palette straight into the session.
        measurement.onCommit = { [weak self] record in
            guard let self else { return }
            Task { await self.commit(record, family: .measurement) }
        }
        measurement.onSnapFeedback = { [weak self] _ in
            self?.refreshStatus()
        }
        // A click the armed tool refused says why in the status line (L-102).
        measurement.onToolRefused = { [weak self] reason in
            self?.status.setActiveToolNote(reason)
        }

        // A cutout is the one measurement that does not go out as `.addMarkup`. It is a
        // hole in a named parent, so it goes through `.addCutout`, which unions it with
        // the parent's other holes, recomputes the parent's net value through Clipper2 and
        // brings its own undo inverse. Routing it here rather than in the canvas keeps the
        // rule that nothing outside this file constructs a document command.
        measurement.onCommitCutout = { [weak self] parent, record in
            guard let self else { return }
            Task { await self.commitCutout(parent: parent, record: record) }
        }

        // The markup family goes through the *same* door. That single line is what gives
        // a rectangle, a callout and a text box undo in one ⌘Z, a History entry, an audit
        // trail record and survival through save → reopen, with no second commit path to
        // keep in step: the rules that apply to one family apply to all of them.
        markup.onCommit = { [weak self] record in
            guard let self else { return }
            Task { await self.commit(record, family: .markup) }
        }

        // Arming a preset configures the palette; committing disarms it unless reuse-tool
        // is on.
        //
        // This used to arm the *measurement* family only, and only with the subject and the
        // ink: a Text or a Shape preset armed nothing at all, and a Volume preset carrying a
        // saved depth armed a tool that still refused to commit because `parameters` was
        // `.default` — a tool that silently drops its commit. A preset is now total over what it
        // can say: which family, which tool, what ink, and the measurement parameters the engine
        // needs before it will produce a number.
        toolLibrary.onArm = { [weak self] preset, mode in
            guard let self else { return }
            guard let preset, mode == .draw else {
                // Apply and Place deliberately disarm both drawing families. A brush that also
                // armed the Area tool would draw a new area on the first click that missed a
                // markup, and a stamp that armed Rectangle would leave a rectangle behind every
                // time the estimator meant to stamp. What those two modes do with a click is
                // decided by the canvas, which reads `armedSetMode` and routes there instead.
                self.measurement.deactivate()
                self.markup.deactivate()
                // Place mode still needs the symbol: a Place click on a Count preset drops a
                // count mark, and it drops it through `placementRecord`, which reads the preset
                // directly. What is cleared here is the *drawing* tool's copy, so a Count drawn
                // after a Place-armed preset was disarmed does not inherit its glyph.
                self.measurement.countSymbol = nil
                // …and the subject, for exactly the same reason, which this line was missing.
                //
                // Reported 2026-08-26: after choosing Count, the summary showed the subject
                // "Doors". `Doors` is the built-in **Door Count** preset's subject. Arming it set
                // `defaultSubject`, disarming it cleared the glyph and left the subject behind,
                // and every plain Count committed afterwards inherited it — `commitActiveMeasurement`
                // takes the tool name only when `defaultSubject` is empty. A shared mutable
                // default with one of its two fields cleaned up is the failure the comment above
                // already describes; it just did not cover the field next to it.
                self.clearMeasurementPresetDefaults()
                self.clearMarkupPresetDefaults()
                // The toolbar shows Select, naming the preset (X-018): a drawing chip left lit
                // here collects nothing, and choosing it again was the same selection, so it
                // neither disarmed the preset nor drew. Before the note, which the toolbar's
                // own status refresh would otherwise overwrite.
                if let preset { self.showLibraryTool(of: preset, in: mode) }
                self.status.setActiveToolNote(preset.map { _ in mode.shortHelp } ?? "")
                return
            }
            self.status.setActiveToolNote("")
            if let kind = preset.measurementKind {
                self.markup.deactivate()
                self.clearMarkupPresetDefaults()
                self.measurement.defaultSubject = preset.defaultSubject
                // Spec 12.13: a count mark's glyph is a property of the mark, chosen on
                // the preset. `nil` for every preset that names no symbol, so a plain Count
                // still commits a record with no symbol on it rather than one carrying the last
                // preset's glyph — the failure a shared mutable default always eventually has.
                self.measurement.countSymbol = CountSymbolCatalogue.symbol(for: preset)
                self.measurement.color = RGBAColor(shown: preset.colorRGBA)
                // The rest of what a preset says about the row it makes: its label, status and
                // custom column values, which Place and Apply always honoured and Draw dropped
                // (BH-085). Custom values are resolved against the document's own columns.
                self.measurement.defaultLabel = preset.labelPattern
                self.measurement.defaultStatus = Domain.Status(shown: preset.defaultStatus)
                self.measurement.defaultCustomValues = self.presetCustomValues(preset)
                self.measurement.setLengthUnit(preset.displayLengthUnit)
                // Order is load-bearing: `activate(kind:)` re-seeds the options-bar field from
                // whatever that tool was last given, so a parameter written before it would be
                // overwritten one line later and the preset's depth would silently vanish.
                // Re-arming the same kind keeps the tool as it is; the preset's own block
                // replaces the previous one a few lines down.
                self.measurement.activate(kind: kind)
                if let entry = Self.presetParameterEntry(of: preset, for: kind) {
                    self.measurement.setParameterText(entry.text, exactValue: entry.exactValue)
                }
                // The options bar carries one number per tool (`MeasurementParameterRequirement`);
                // the rest of a preset's parameters — the second gable height, the fall-line azimuth,
                // the cutout and perimeter policies, the volume depth reference — have no field
                // there and used to be dropped on the floor at exactly this point. They go
                // straight into the presenter's parameter block instead, so a `Roof 6:12` preset
                // arms a tool that already knows which way the roof falls.
                self.measurement.setPresetParameters(
                    ToolPresetParameterBridge.parameters(applying: preset.measurementDefaults)
                )
                self.status.setActiveTool(
                    name: kind.displayName,
                    note: String(
                        format: NSLocalizedString(
                            "Armed from the Tool Library: %@",
                            comment: "Status note after a Tool Library preset arms a tool"
                        ),
                        preset.name
                    )
                )
                self.showLibraryTool(of: preset, in: mode)
                return
            }
            // A non-measuring preset is a markup preset. Its ink still reaches the measurement
            // presenter, because Reuse Tool can hand the same preset to either family, but the
            // tool it arms is the markup one — and only when that family can actually draw the
            // kind, which is the honest-refusal rule `ZenitToolMode.isDrawable` already states.
            self.measurement.deactivate()
            self.measurement.countSymbol = nil
            self.clearMeasurementPresetDefaults()
            guard ZenitToolMode.isDrawable(preset.markupKind) else {
                self.markup.deactivate()
                self.clearMarkupPresetDefaults()
                self.showLibraryTool(of: preset, in: mode)   // Select: nothing draws it (X-018)
                return
            }
            // The whole row a preset describes, as for a measurement (W-030): one preset made two
            // record shapes — label, status and ledger values when placed or applied, the subject
            // alone when the same cloud or rectangle was drawn by hand.
            self.markup.defaultSubject = preset.defaultSubject
            self.markup.defaultLabel = preset.labelPattern
            self.markup.defaultStatus = Domain.Status(shown: preset.defaultStatus)
            self.markup.defaultCustomValues = self.presetCustomValues(preset)
            self.markup.activate(
                kind: preset.markupKind,
                // NL-MARKUP-15: the preset's whole look, not only its colour.
                style: preset.placementStyle
            )
            do {
                let markupKind = preset.markupKind
                self.status.setActiveTool(
                    name: markupKind.displayName,
                    note: String(
                        format: NSLocalizedString(
                            "Armed from the Tool Library: %@",
                            comment: "Status note after a Tool Library preset arms a tool"
                        ),
                        preset.name
                    )
                )
                self.showLibraryTool(of: preset, in: mode)
            }
        }
        toolLibrary.onSetModeChange = { [weak self] panel, mode in
            guard let self else { return }
            // Only the set that owns the armed preset changes what the next click does. A flip
            // on another panel wrote its mode's help into the status bar while the armed Length
            // tool was still in Draw, and the next click drew (BH-412).
            if let armed = self.toolLibrary.activePreset, armed.panel != panel { return }
            self.status.setActiveToolNote(mode == .draw ? "" : mode.shortHelp)
        }
        // Revealing a markup on another sheet changes the page. The canvas presenter raises the
        // request; the document presenter owns the answer. See `AppCanvasPresenter.onRequestPage`.
        canvas.onRequestPage = { [weak self] pageID in
            guard let self, self.document.currentPageID != pageID else { return }
            self.document.goToPage(id: pageID)
        }
        toolLibrary.onReuseToolChange = { [weak self] enabled in
            self?.status.setReuseToolEnabled(enabled)
        }
        status.onReuseToolChange = { [weak self] enabled in
            guard let self, self.toolLibrary.reuseToolEnabled != enabled else { return }
            self.toolLibrary.setReuseToolEnabled(enabled)
        }

        // A snap toggle is a session setting, not a view state: the engine has to see it,
        // or the status bar would claim something the next click would contradict.
        //
        // Serialised, so two quick clicks land in the order they were made; and a refusal is
        // said and undone rather than swallowed. `setSnapSettings` validates first — a grid with
        // no spacing, an angle out of range — and the `try?` that stood here left the toggle on
        // in the status bar while the engine kept the old kinds (BH-413).
        status.onSnapSettingsChange = { [weak self] toggles in
            guard let self else { return }
            let previous = self.snapSettingsTask
            self.snapSettingsTask = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                var settings = await self.session.currentSnapSettings
                let before = settings.enabledKinds
                settings.enabledKinds = toggles.snapKinds()
                do {
                    try await self.session.setSnapSettings(settings)
                } catch {
                    self.status.adoptSnapToggles(SnapSourceToggles(
                        grid: before.contains(.grid),
                        vector: before.contains(.endpoint),
                        markup: before.contains(.markupVertex)
                    ))
                    self.reportSnapSettingsRefusal(error)
                }
            }
        }

        // NL-UX-20: the bus and its audit hooks belong to the document's own core. A second
        // window's view shares the bus and is refreshed through ``refresh()``'s fan-out, so it
        // must not take the hooks over.
        if primaryEnvironment == nil {
            // Every applied, undone or redone command refreshes the presenters, so an undo is
            // visible in the ledger *and* on the canvas rather than in one of them.
            commands.onChange = { [weak self] _ in
                await self?.refresh()
                // NL-MEASURE-13: overlapping same-subject areas, said in the tray.
                await self?.refreshDoubleCountWarnings()
            }

            // Every mutation lands in the audit trail; every ⌘Z appends its compensating
            // entry (ADR-0007 §2). The bus carries the entry id between the two, so a
            // compensation names exactly the entry it undoes.
            commands.onAuditApply = { [weak self] outcome in
                guard let self else { return nil }
                return self.history.recordApplied(outcome, snapshot: self.snapshot)
            }
            commands.onAuditRevert = { [weak self] token in
                self?.history.recordCompensation(of: token)
            }
            // A bulk edit is one undo step but many changed markups, so its trail is a group
            // of per-markup entries rather than one entry naming an arbitrary member of the
            // selection (ADR-0007 §2). The token the bus carries is the group.
            commands.onAuditApplyBatch = { [weak self] outcome, actionName in
                guard let self else { return nil }
                return self.history.recordAppliedBatch(
                    outcome,
                    actionName: actionName,
                    snapshot: self.snapshot
                )
            }
        }

        // Multi-selection editing from the ledger pane. The presenter publishes
        // `LedgerBulkEditPresenting`; this is the only thing behind it, so the pane's
        // Apply and the command bus cannot drift apart.
        ledger.onBulkEdit = { [weak self] request in
            guard let self else {
                return .failure(NSLocalizedString(
                    "This ledger cannot be edited.",
                    comment: "Bulk edit refusal when no document is attached to the ledger"
                ))
            }
            return await self.applyBulkEdit(request)
        }
        // NL-QTY-02: the Column Manager writes through the same bus.
        ledger.onApplyColumnSpecs = { [weak self] specs, actionName in
            guard let self else {
                return .failure(NSLocalizedString(
                    "This ledger cannot be edited.",
                    comment: "Bulk edit refusal when no document is attached to the ledger"
                ))
            }
            return await self.applyColumnSpecs(specs, actionName: actionName)
        }
        // Explain the numbers of a selection.
        ledger.explainSeam = { [weak self] ids in
            await self?.explain(ids) ?? LedgerExplanation(rows: [], totals: [])
        }
        // NL-QTY-05: the rate library.
        ledger.rateLibrarySeam = LedgerRateLibrarySeam(
            entries: { [weak self] in self?.rateLibraryEntries() ?? [] },
            importList: { [weak self] text in
                guard let self else { throw DocumentCommandError.ledgerFailed("no document") }
                return try self.importRateList(text)
            },
            remove: { [weak self] id in try self?.removeRateEntry(id) },
            apply: { [weak self] id, rows in
                await self?.applyRateEntry(id, to: rows) ?? .failure("no document")
            },
            pending: { [weak self] in await self?.pendingRateUpdates() ?? [] },
            update: { [weak self] rows in await self?.applyRateUpdates(rows) ?? .failure("no document") }
        )
        // NL-QTY-16: snapshots live in the project database the audit trail is attached to.
        ledger.snapshotSeam = LedgerSnapshotSeam(
            list: { [weak self] in await self?.ledgerSnapshots() ?? [] },
            take: { [weak self] name in
                guard let self else { throw DocumentCommandError.ledgerFailed("no document") }
                return try await self.takeLedgerSnapshot(named: name)
            },
            report: { [weak self] id in
                guard let self else { throw DocumentCommandError.ledgerFailed("no document") }
                return try await self.ledgerChangeReport(since: id)
            },
            delete: { [weak self] id in await self?.deleteLedgerSnapshot(id) ?? false }
        )
        // NL-QTY-09: the summary matrix is three projections of the one aggregation core.
        let matrixSession = session
        ledger.buildMatrix = { rows, columns, filter in
            try await matrixSession.summaryMatrix(rows: rows, columns: columns, filter: filter)
        }
        // NL-QTY-10: a live summary lands on the sheet the canvas shows, top-left.
        ledger.onPlaceSummary = { [weak self] spec in
            guard let self else {
                return .failure(NSLocalizedString(
                    "This ledger cannot be edited.",
                    comment: "Bulk edit refusal when no document is attached to the ledger"
                ))
            }
            return await self.placeLiveSummaryOnCurrentPage(spec)
        }
        // NL-QTY-07: assemblies are assigned through the same bus.
        ledger.onApplyAssembly = { [weak self] assemblyID, parameters, markupIDs in
            guard let self else {
                return .failure(NSLocalizedString(
                    "This ledger cannot be edited.",
                    comment: "Bulk edit refusal when no document is attached to the ledger"
                ))
            }
            return await self.applyAssembly(assemblyID, parameters: parameters, to: markupIDs)
        }
    }

    /// The markups that never have a ledger row — text, callouts, unclassified shapes — by the
    /// session's own rule (`ledgerMarkups`: produces a quantity, or carries a subject).
    ///
    /// A ledger filter says nothing about them, so they are always in the canvas's matched set.
    /// The set used to be the ledger's row index alone, and "hide non-matching" made every
    /// annotation on the sheet vanish although it failed no rule (BH-448).
    func markupsWithoutLedgerRows() -> Set<UUID> {
        Set(snapshot.markups.lazy.filter { summary in
            !Domain.Kind(shown: summary.kind).producesQuantity
                && summary.subject.trimmingCharacters(in: .whitespaces).isEmpty
        }.map(\.id))
    }

    /// Clears every row default a Draw-mode preset put on the measurement presenter.
    private func clearMeasurementPresetDefaults() {
        measurement.defaultSubject = ""
        measurement.defaultLabel = ""
        measurement.defaultStatus = .none
        measurement.defaultCustomValues = [:]
    }

    /// The markup family's copy of the same four defaults (W-030), cleared on the same terms.
    private func clearMarkupPresetDefaults() {
        markup.defaultSubject = ""
        markup.defaultLabel = ""
        markup.defaultStatus = .none
        markup.defaultCustomValues = [:]
    }

    /// A Draw-armed preset's custom column defaults as cell values, against the document's
    /// columns — the one resolver Place, batch stamping and Apply use too.
    private func presetCustomValues(_ preset: ToolPresetSummary) -> [ColumnID: Domain.CellValue] {
        ledgerColumnsCache.map {
            Self.resolvedCustomValues(preset.customDefaults, columns: $0, currencyCode: ledger.defaultCurrencyCode).values
        } ?? [:]
    }

    /// A preset's custom column defaults as ledger cell values, and the column names that could
    /// not take their value — a key the document has no column for, or text a number or choice
    /// column cannot hold.
    ///
    /// One resolver for Draw, Place, batch stamping and Apply, so the four cannot disagree
    /// about which of a preset's values reach a row, and so a value that does not fit is
    /// *reported* rather than dropped in silence (BH-116).
    ///
    /// A default is text, and it is read the way the column reads a typed value (V-032): a
    /// number or currency by the strict decimal rule, a choice by its option, a checkbox by
    /// true/false, a date as an ISO day. Every default used to go in as text, which only a text
    /// column takes, so "2" for Repeat ×, "12.50" for Unit Cost or an option for a choice column
    /// was skipped on every placement. A currency default is in `currencyCode`, the ledger's.
    static func resolvedCustomValues(
        _ defaults: [String: String],
        columns: LedgerColumnSet,
        currencyCode: String
    ) -> (values: [ColumnID: Domain.CellValue], skipped: [String]) {
        var values: [ColumnID: Domain.CellValue] = [:]
        var skipped: [String] = []
        for (key, text) in defaults.sorted(by: { $0.key < $1.key }) {
            guard let definition = columns.column(key: key),
                  let typed = typedDefault(text, for: definition, currencyCode: currencyCode),
                  let value = LedgerBridge.domainCellValue(typed, definition: definition)
            else {
                skipped.append(key)
                continue
            }
            values[definition.id] = value
        }
        return (values, skipped)
    }

    /// A preset default's text as the value a person typing it into this column's cell gives,
    /// or `nil` when the column cannot read it. ``LedgerBridge/domainCellValue(_:definition:)``
    /// then checks it as it checks a typed cell: Repeat × whole counts, a choice's option.
    static func typedDefault(
        _ text: String,
        for definition: LedgerColumnDefinition,
        currencyCode: String
    ) -> ZPDFUIPresentation.LedgerCellValue? {
        if definition.kind == .text { return .text(text) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        switch definition.kind {
        case .text:
            return .text(text)
        case .number:
            return LedgerColumnValueConversion.decimal(fromText: trimmed).map { .number($0) }
        case .currency:
            let code = definition.dimension?.currencyCode ?? currencyCode
            return LedgerColumnValueConversion.decimal(fromText: trimmed).map { .currency(amount: $0, code: code) }
        case .choice:
            // The option's own value, or the one that differs from it only in case.
            let option = definition.choices.first { $0.value == trimmed }
                ?? definition.choices.first { $0.value.lowercased() == trimmed.lowercased() }
            return option.map { .choice($0.value) }
        case .checkbox:
            return LedgerColumnValueConversion.checkbox(fromText: trimmed).map { .checkbox($0) }
        case .date:
            return LedgerColumnValueConversion.date(fromText: trimmed).map { .date($0) }
        case .formula:
            return nil
        }
    }

    // MARK: Committing

    /// Which family a failed commit came from, so the warning names the right thing.
    enum CommitFamily {
        case measurement
        case markup
    }

    /// Sends a committed record through the command bus and **reports a refusal**.
    ///
    /// This used to be `try? await commands.perform(.addMarkup(record))`, on both commit
    /// paths. `TakeoffSession.recompute` turns a calculator's refusal into
    /// `DocumentCommandError.measurementFailed`, and the `try?` dropped it on the floor:
    /// the estimator placed the points, watched a live preview, pressed Return, and
    /// nothing appeared with nothing said. A silent failure is never acceptable, and that
    /// silence is how the defect stayed invisible for as long as it did.
    ///
    /// The reason goes to the warning tray rather than to a modal: the estimator is
    /// mid-drawing, and a sheet in front of the canvas at that moment is its own defect.
    func commit(_ record: MarkupRecord, family: CommitFamily) async {
        var stored = record
        // Scale Regions decide the transform, so they are resolved before the measurement
        // exists rather than corrected afterwards. A markup family record (Text, Callout,
        // a Shape) produces no quantity, so nothing about it depends on which scale applies.
        if family == .measurement, stored.scaleRegionID == nil {
            switch await scaleRegionDecision(for: stored) {
            case .pageDefault:
                break
            case let .region(regionID, scaleID):
                stored.scaleRegionID = regionID
                stored.scaleID = scaleID
            case let .ask(crossing):
                guard let onScaleRegionCrossing else {
                    reportUnaskableCrossing()
                    return
                }
                pendingCrossings[crossing.id] = crossing
                onScaleRegionCrossing(crossing)
                return
            }
        }
        do {
            try await commands.perform(.addMarkup(stored))
        } catch {
            reportCommitFailure(error, family: family)
        }
    }

    /// Sends a committed cutout through the command bus and **reports a refusal**.
    ///
    /// The cutout twin of ``commit(_:family:)``. This was
    /// `try? await commands.perform(.addCutout(…))`: a locked parent, or a ring the engine
    /// refuses, produced nothing on the canvas and nothing in the tray — the estimator drew
    /// the hole, pressed Return, and the area kept its gross value with no word about why
    /// (CR-10). Same warning identity as a refused measurement, so the tray never stacks.
    func commitCutout(parent: MarkupID, record: MarkupRecord) async {
        do {
            try await commands.perform(.addCutout(parent: parent, cutout: record))
        } catch {
            reportCommitFailure(error, family: .measurement)
        }
    }

    // MARK: Scale Region crossings (spec §10.4)

    /// The crossings still waiting for an answer.
    public var pendingScaleRegionCrossings: [PendingScaleRegionCrossing] {
        pendingCrossings.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Applies one of the three legal outcomes to a waiting crossing.
    ///
    /// - Returns: `false` when the crossing is not outstanding — a double-answered prompt,
    ///   which must not create the measurement twice.
    @discardableResult
    public func resolveScaleRegionCrossing(
        id: UUID,
        outcome: ScaleRegionCrossingOutcome
    ) async -> Bool {
        guard let crossing = pendingCrossings.removeValue(forKey: id) else { return false }
        switch outcome {
        case .block:
            // Nothing is created, and nothing is said in the tray: refusing is what the
            // person just asked for, and a warning about an outcome they chose is noise.
            return true

        case let .useScale(regionID):
            var stored = crossing.record
            if let regionID {
                // The region was chosen by the person; if it has gone while the question was
                // open — deleted, or its creation undone — the answer names nothing, and the
                // page scale is not what they chose. Refused out loud instead of measured at a
                // scale nobody picked (BH-088).
                guard let region = await session.scaleRegion(regionID) else {
                    reportVanishedScaleRegion()
                    return true
                }
                stored.scaleRegionID = regionID
                stored.scaleID = region.scaleID
            } else {
                stored.scaleRegionID = nil
                stored.scaleID = nil
            }
            do {
                try await commands.perform(.addMarkup(stored))
            } catch {
                reportCommitFailure(error, family: .measurement)
            }
            return true

        case .splitAtBoundary:
            guard let parts = crossing.splitParts, parts.count >= 2,
                  ScaleRegionSplitter.isCuttable(crossing.record) else {
                // Offering an outcome and then not delivering it is worse than never
                // offering it, so this says so rather than quietly falling back.
                reportCommitFailure(
                    DocumentCommandError.measurementFailed("this geometry cannot be cut at a region boundary"),
                    family: .measurement
                )
                return true
            }
            var commands: [DocumentCommand] = []
            commands.reserveCapacity(parts.count)
            for (index, part) in parts.enumerated() {
                var piece = crossing.record
                piece.id = MarkupID(UUID())
                // A chain piece keeps its arcs; an area piece is its polygon (ADR-0030 §5.6).
                piece.geometry = part.geometry(pageID: crossing.record.pageID)
                if let regionID = part.regionID {
                    guard let region = await session.scaleRegion(regionID) else {
                        // A piece's region vanished while the question was open; measuring that
                        // piece at the page scale is the silent choice spec §10.4 forbids (BH-088).
                        reportVanishedScaleRegion()
                        return true
                    }
                    piece.scaleRegionID = regionID
                    piece.scaleID = region.scaleID
                } else {
                    piece.scaleRegionID = nil
                    piece.scaleID = nil
                }
                if !piece.label.isEmpty {
                    piece.label = String(
                        format: NSLocalizedString(
                            "%1$@ (%2$d of %3$d)",
                            comment: "Label of one piece of a measurement split at a Scale Region boundary"
                        ),
                        piece.label,
                        index + 1,
                        parts.count
                    )
                }
                commands.append(.addMarkup(piece))
            }
            do {
                // One undo step: the person drew one measurement, and one Cmd-Z must take
                // all of its pieces back.
                try await self.commands.performBatch(
                    commands,
                    actionName: NSLocalizedString(
                        "Split at Scale Region",
                        comment: "Undo action name for a measurement split at a region boundary"
                    )
                )
            } catch {
                reportCommitFailure(error, family: .measurement)
            }
            return true
        }
    }

    /// Says that a snap toggle was refused by the engine and has been put back.
    private func reportSnapSettingsRefusal(_ error: any Error) {
        document.post(
            AppWarning(
                id: Self.snapSettingsWarningID,
                severity: .warning,
                title: NSLocalizedString(
                    "That snap setting could not be applied.",
                    comment: "Warning headline when the snap engine refuses a settings change"
                ),
                message: String(
                    format: NSLocalizedString(
                        "The snap toggles show what is in effect. %@",
                        comment: "Warning detail when a snap settings change is refused; the placeholder is the reason, as a sentence"
                    ),
                    UserFacingRefusal.sentence(for: error)
                ),
                source: NSLocalizedString("Snap", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            )
        )
    }

    /// The one identity a refused snap setting uses.
    static let snapSettingsWarningID = UUID(uuidString: "8B0C6E64-4E2A-4C3E-9F2E-4E9E2B7B1A05")!

    /// Says that a crossing's answer named a Scale Region that no longer exists.
    private func reportVanishedScaleRegion() {
        document.post(
            AppWarning(
                id: Self.commitFailureWarningID,
                severity: .danger,
                title: NSLocalizedString(
                    "The measurement was not recorded.",
                    comment: "Warning headline when a measurement commit is refused by the engine"
                ),
                message: NSLocalizedString(
                    "The Scale Region you chose was removed while the question was open, and Zenit will not measure at a scale you did not choose. Draw the measurement again.",
                    comment: "Warning detail when a crossing's chosen Scale Region no longer exists"
                ),
                source: NSLocalizedString("Measurement", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            )
        )
    }

    /// Says out loud that a measurement was refused because nothing could ask the question.
    private func reportUnaskableCrossing() {
        document.post(
            AppWarning(
                id: Self.commitFailureWarningID,
                severity: .danger,
                title: NSLocalizedString(
                    "The measurement was not recorded.",
                    comment: "Warning headline when a measurement commit is refused by the engine"
                ),
                message: NSLocalizedString(
                    "It crosses two Scale Regions, and Zenit will not choose a scale for you. Open Scale Regions and redraw it inside one region.",
                    comment: "Warning detail when a crossing cannot be presented"
                ),
                source: NSLocalizedString("Measurement", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            )
        )
    }

    /// Puts a refused commit in front of the user, in words.
    ///
    /// The engine's own text (`"missingParameter(depth)"`) is exactly what
    /// UX_COPY_STANDARD forbids as a headline, so the headline says what happened and the
    /// detail carries the engine's description for a bug report. Only one of these is ever
    /// outstanding: a fixed identity means a second failed commit replaces the first
    /// rather than stacking a tray full of the same sentence.
    func reportCommitFailure(_ error: any Error, family: CommitFamily) {
        let title: String
        switch family {
        case .measurement:
            title = NSLocalizedString(
                "The measurement was not recorded.",
                comment: "Warning headline when a measurement commit is refused by the engine"
            )
        case .markup:
            title = NSLocalizedString(
                "The markup was not recorded.",
                comment: "Warning headline when a markup commit is refused by the engine"
            )
        }
        document.post(
            AppWarning(
                id: Self.commitFailureWarningID,
                severity: .danger,
                title: title,
                // The reason in words (L-102): this used to paste `String(describing: error)` after
                // "The engine reported:", which put engine case names and identifiers in the tray.
                message: String(
                    format: NSLocalizedString(
                        "Nothing was added to the drawing or the ledger. %@",
                        comment: "Detail of a refused commit; the placeholder is the reason, as a sentence"
                    ),
                    UserFacingRefusal.sentence(for: error)
                ),
                source: NSLocalizedString("Measurement", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            )
        )
    }

    /// The one identity a refused commit uses, so the tray never fills with repeats.
    static let commitFailureWarningID = UUID(uuidString: "8B0C6E64-4E2A-4C3E-9F2E-4E9E2B7B1A01")!

    // MARK: Refresh

    /// Rebuilds every presenter from a fresh snapshot — and, while a second window shows the same
    /// document (NL-UX-20), every other window's presenters too, so an edit made in either window
    /// is on screen in both.
    public func refresh() async {
        await refreshOwnPresenters()
        await refreshLinkedWindowViews()
    }

    /// This environment's presenters only: ``refresh()`` without the NL-UX-20 fan-out.
    func refreshOwnPresenters() async {
        await refresh { [session] request in try await session.snapshot(ledger: request) }
    }

    /// The refresh behind ``refresh()``, over an injected snapshot source.
    ///
    /// A snapshot that cannot be built is **reported**, never swallowed. This was
    /// `guard let snapshot = try? await …`: a ledger the engine refused to rebuild left every
    /// presenter on the previous snapshot with nothing said, so the canvas kept the markup
    /// the person had just drawn and the ledger did not, indefinitely (CR-15). The previous
    /// snapshot stays on screen — an empty ledger would read as "you have no quantities" —
    /// and the tray says the screen is stale and why. The warning clears itself on the next
    /// refresh that succeeds.
    func refresh(from source: (LedgerRequest) async throws -> DocumentSnapshot) async {
        do {
            let snapshot = try await source(ledger.request)
            adopt(snapshot)
            ledgerColumnsCache = await session.ledgerColumns
            document.dismissWarning(id: Self.refreshFailureWarningID)
            reportHydrationRepairs(await session.takeHydrationRepairs())
            reportColumnRefusals(await session.takeColumnRefusals())
        } catch {
            reportRefreshFailure(error)
        }
    }

    /// The one identity a hydration repair uses, so a reopen replaces rather than stacks it.
    static let hydrationRepairWarningID = UUID(uuidString: "8B0C6E64-4E2A-4C3E-9F2E-4E9E2B7B1A03")!

    /// Says which cutouts the open detached because they lay wholly outside their parents.
    ///
    /// ADR-0015 refuses such a cutout when it is drawn; a saved one is repaired on open
    /// (``TakeoffSession/hydrate(markups:scales:pageScaleIDs:calibrationEvidence:scaleRegions:projectZones:)``)
    /// and reported here, through the same tray every other refusal uses — one warning for the
    /// whole open, naming the measurements it touched.
    func reportHydrationRepairs(_ repairs: [TakeoffSession.CutoutDetachment]) {
        guard !repairs.isEmpty else { return }
        let names = repairs.map { repair -> String in
            let subject = repair.parentSubject.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = repair.parentLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (subject.isEmpty, label.isEmpty) {
            case (false, false): return "\(subject) — \(label)"
            case (false, true): return subject
            case (true, false): return label
            case (true, true):
                return NSLocalizedString("an unnamed measurement", comment: "Stand-in name for a measurement without subject or label")
            }
        }
        let title: String
        if repairs.count == 1 {
            title = String(
                format: NSLocalizedString(
                    "A cutout that touched nothing was detached from “%@”.",
                    comment: "Warning headline after opening a project; the placeholder names the parent measurement"
                ),
                names[0]
            )
        } else {
            title = String(
                format: NSLocalizedString(
                    "%d cutouts that touched nothing were detached.",
                    comment: "Warning headline after opening a project; the placeholder is a count"
                ),
                repairs.count
            )
        }
        document.post(
            AppWarning(
                id: Self.hydrationRepairWarningID,
                severity: .warning,
                title: title,
                message: String(
                    format: NSLocalizedString(
                        "It lay entirely outside the area it was cut from and subtracted nothing. It stays on the drawing as a plain polygon, and the area shows its full value. Detached from: %@.",
                        comment: "Warning detail after opening a project; the placeholder lists the parent measurements"
                    ),
                    names.joined(separator: ", ")
                ),
                source: NSLocalizedString("Measurement", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            )
        )
    }

    /// The one identity a refused stored column uses, so a reopen replaces rather than stacks it.
    static let columnRefusalWarningID = UUID(uuidString: "8B0C6E64-4E2A-4C3E-9F2E-4E9E2B7B1A04")!

    /// Says which stored ledger columns this build refused on open, and that they are kept (R-136).
    ///
    /// ``TakeoffSession/restoreCustomColumns(_:)`` holds such a column instead of dropping it and
    /// every save writes it back unchanged; this is the other half — the person is told which
    /// column is missing from the ledger, why, and how to bring it back. One warning per open.
    func reportColumnRefusals(_ refusals: [TakeoffSession.HeldCustomColumn]) {
        guard !refusals.isEmpty else { return }
        let names = refusals.map { held -> String in
            let title = held.definition.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? held.definition.key : title
        }
        let title: String
        if refusals.count == 1 {
            title = String(
                format: NSLocalizedString(
                    "The ledger column “%@” could not be loaded.",
                    comment: "Warning headline after opening a project; the placeholder names a stored ledger column this build refused"
                ),
                names[0]
            )
        } else {
            title = String(
                format: NSLocalizedString(
                    "%d ledger columns could not be loaded.",
                    comment: "Warning headline after opening a project; the placeholder is a count of refused ledger columns"
                ),
                refusals.count
            )
        }
        let reasons = zip(names, refusals).map { name, held in
            String(
                format: NSLocalizedString(
                    "“%1$@”: %2$@",
                    comment: "One refused ledger column in a warning: its name, then the ledger's reason"
                ),
                name, held.reason
            )
        }
        document.post(
            AppWarning(
                id: Self.columnRefusalWarningID,
                severity: .warning,
                title: title,
                message: String(
                    format: NSLocalizedString(
                        "This version refuses its definition, so the ledger does not show it: %@ The definition is kept in the project unchanged. To use the column again, add a column with the same name and a formula this version accepts; it replaces the kept one when the project is saved.",
                        comment: "Warning detail after opening a project with refused ledger columns; the placeholder lists each column with its reason"
                    ),
                    reasons.joined(separator: " ")
                ),
                source: NSLocalizedString("Quantity Ledger", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            )
        )
    }

    /// The one identity a failed refresh uses, so a rebuild that keeps failing replaces its
    /// own warning rather than filling the tray.
    static let refreshFailureWarningID = UUID(uuidString: "8B0C6E64-4E2A-4C3E-9F2E-4E9E2B7B1A02")!

    /// Says out loud that the presenters are showing a stale document.
    private func reportRefreshFailure(_ error: any Error) {
        document.post(
            AppWarning(
                id: Self.refreshFailureWarningID,
                severity: .danger,
                title: NSLocalizedString(
                    "The ledger could not be rebuilt.",
                    comment: "Warning headline when the document snapshot behind the presenters cannot be rebuilt"
                ),
                message: String(
                    format: NSLocalizedString(
                        "The ledger and the canvas still show the document as it was before the last change. The engine reported: %@",
                        comment: "Detail of a failed presenter refresh; the placeholder is the engine's own description"
                    ),
                    String(describing: error)
                ),
                source: NSLocalizedString("Quantity Ledger", comment: "Warning source"),
                isDismissible: true,
                timestamp: Date()
            )
        )
    }

    /// Feeds one snapshot to every presenter.
    ///
    /// One snapshot, one pass: the ledger, the canvas and the status bar are updated from
    /// the same instant of the document, which is the invariant the whole snapshot design
    /// exists to hold.
    public func adopt(_ snapshot: DocumentSnapshot) {
        self.snapshot = snapshot
        history.formatter = snapshot.ledger.formatter
        history.noteMarkupNames(from: snapshot)
        document.adopt(snapshot)
        canvas.adopt(snapshot)
        measurement.adopt(snapshot)
        markup.adopt(documentID: documentID)
        ledger.adopt(snapshot.ledger)
        ledger.adopt(derivations: snapshot.derivations)
        refreshStatus()
        onDidRefresh?(snapshot)
    }

    /// Rebuilds the status bar from the current snapshot and viewport.
    ///
    /// The scale segment is derived **synchronously** from the snapshot's scale *for the page
    /// the document presenter is on* (``DocumentSnapshot/scale(onPage:)``). It used to be fetched
    /// from the session actor in a
    /// detached task after an `adopt(scale: nil)` — which meant every canvas layout pass
    /// (scroll, cursor move, zoom) first wrote "No scale" and then raced an async correction
    /// against the next layout pass's "No scale". Under a moving pointer the synchronous
    /// write was always last, so a freshly calibrated document kept reading "Scale: No
    /// scale". One snapshot, one synchronous write, no race.
    public func refreshStatus() {
        let geometryIndex = canvas.isVectorSnapAvailable
            ? GeometryIndexStatus.ready
            : GeometryIndexStatus.unavailable
        status.adopt(
            document: snapshot,
            viewport: canvas.viewport,
            // The current page's scale, not a document-wide one. Reading "Scale: 1:100" while
            // looking at the 1:20 detail sheet is the same wrong number as measuring against it.
            scale: snapshot.scale(onPage: document.currentPageID),
            scaleRegionName: canvas.activeScaleRegion?.name,
            geometryIndex: geometryIndex,
            snapToggles: status.toggles,
            reuseToolEnabled: toolLibrary.reuseToolEnabled
        )
    }

    /// Reports whether the active page has vector geometry, and refreshes the status bar's
    /// geometry-index segment with it.
    public func setVectorSnapAvailability(_ availability: SnapIndexAvailability?) {
        let allows = availability?.allowsVectorCandidates ?? false
        canvas.setVectorSnapAvailable(allows)
        status.updateGeometryIndex(allows ? .ready : .unavailable)
    }
}
