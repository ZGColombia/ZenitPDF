import CoreGraphics
import Foundation
import ZPDFContracts
import ZPDFGeometry
import ZPDFMeasurementEngine
import ZPDFQuantityLedger
import ZPDFSnapEngine
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// The document's engine-side state, and the only place engines are called.
///
/// An `actor`, so every measurement, snap resolve and ledger rebuild happens off the main
/// thread by construction rather than by discipline. Presenters never hold a reference to
/// engine state; they `await` a `Sendable` snapshot and render that. The two consequences
/// that matter:
///
/// - **The main thread cannot block on an engine.** There is no synchronous path from a
///   presenter into this type.
/// - **A snapshot is a consistent instant.** Rows, totals, canvas markups and the status
///   bar in one snapshot all describe the same document state, so a half-updated screen —
///   the way a user ends up measuring against the wrong scale — is not expressible.
public actor TakeoffSession {

    // MARK: Identity

    /// The document being taken off.
    public let documentID: DocumentID

    // MARK: Engine state

    private var pages: [ZPDFContracts.PageDescriptor]
    private var pageOrder: [PageID]
    /// Every page this session has held, in the set or removed from it (NL-DOCS-04/07), so a
    /// page taken out by an undo, a Remove from Set or an undone insertion can come back.
    var knownPages: [PageID: ZPDFContracts.PageDescriptor] = [:]
    /// The known pages in the order they were first held — where a restored sheet returns to.
    var knownPageOrder: [PageID] = []
    /// Markups standing on a page removed from the set, with their place in the markup order:
    /// out of the canvas and the ledger, still saved, back exactly when the page returns.
    var setAsideMarkups: [MarkupID: (record: MarkupRecord, position: Int)] = [:]
    /// Each sheet's view (NL-DOCS-07 rotation, NL-DOCS-16 crop). Display only.
    var pageViewTable: [PageID: PageViewSettings] = [:]
    /// Each named sheet's identity (NL-DOCS-05), keyed by page. Data over an immutable page.
    var sheetIdentityTable: [PageID: SheetIdentity] = [:]
    private var markups: MarkupTable
    private var markupOrder: [MarkupID]
    private var scales: [ScaleID: ScaleTransform]
    /// Scales whose next change keeps the values measured under the old version (NL-MEASURE-03,
    /// ADR-0030 §2). One-shot: consumed by the change of that scale, set only for the duration of
    /// a synchronous session call (`TakeoffSession+KeepValues.swift`).
    var keepExistingForScales: Set<ScaleID> = []
    /// Which scale is **the page's own** scale, per page (spec 10.5).
    ///
    /// This replaced a single document-wide `defaultScaleID`. The old field made a second sheet
    /// inherit the first sheet's calibration unconditionally: `scale(for:)` fell back to it
    /// without ever consulting the markup's page, so on a set that mixes a 1:100 plan with a
    /// 1:20 detail every measurement off the calibrated sheet was computed against the wrong
    /// transform, and calibrating a second sheet *revised the same scale* and silently rewrote
    /// the first sheet's numbers. A dictionary keyed by page is what makes both unexpressible.
    private var pageScaleIDs: [PageID: ScaleID]
    private var scaleRegionSet: [ScaleRegionDefinition]
    private var projectZoneSet: [ProjectZoneDefinition]
    /// ADR-0032: the project's markup layers; `Layers/TakeoffSession+MarkupLayers.swift`.
    var markupLayerSet: MarkupLayerSet = .initial
    /// ADR-0032: the layer new markups are placed on.
    var activeMarkupLayerID: LayerID = MarkupLayer.defaultID
    /// NL-QTY-07-UI: the assembly recipes saved in this project; `Ledger/ProjectAssemblyRecipes.swift`.
    var projectAssemblyRecipes: ProjectAssemblyRecipes = .none
    /// Internal (not private) since ADR-0032, so the layer extension can publish layer names.
    var names: ProjectNameTable
    private var columnSet: LedgerColumnSet {
        didSet { columnSetGeneration &+= 1 }
    }
    /// Bumped whenever the column set is replaced, so the ledger cache can tell (IM-002).
    private var columnSetGeneration: UInt64 = 0
    /// Bumped whenever the markup table is replaced wholesale — a hydrate — so both snapshot
    /// caches start again instead of trusting change sets that no longer describe the table.
    private var markupTableEpoch: UInt64 = 0
    /// The live ledger view, kept between rebuilds so an edit updates one row (IM-002).
    private var ledgerCache: LedgerCache?
    /// Markup summaries and derivations, kept between snapshots (IM-001).
    private var summaryCache: SummaryCache?
    /// The double-count guard's overlaps per compared group, kept between commands (U-038).
    var doubleCountCache = DoubleCountGuard.OverlapCache()
    private var snapIndexes: [PageID: SnapIndex] {
        // Every install, rebuild, markup upsert and boundary change passes here, so a view's
        // filtered copy can never outlive the index it was cut from (V-003).
        didSet { viewFilteredSnapIndexes.removeAll() }
    }
    /// Per page, the index a view last resolved against with markups it took off the sheet left
    /// out — the ledger filter's Hide (V-003) — and the exclusion it was cut for. A pointer move
    /// resolves with the same set as the one before, so the copy is cut once per filter or
    /// index change, not per event.
    private var viewFilteredSnapIndexes: [PageID: ViewFilteredSnapIndex] = [:]
    private var snapEngine: SnapEngine
    private var snapSettings: SnapSettings
    private let measurementEngine: MeasurementEngine
    /// Build identity stamped into every derivation (ADR-0007).
    private let engineVersion: String
    /// The picked points and entered length behind each calibrated scale, by scale.
    ///
    /// Held beside the scales rather than inside them: ``ScaleTransform`` is the transform, and
    /// the evidence is how a person arrived at it. It is what lets a derivation say *"two points
    /// 412.7 pt apart, entered as 5.000 m"* instead of only naming a ratio.
    private var calibrationEvidence: [ScaleID: CalibrationEvidence]
    private let clock: @Sendable () -> Date
    private var units: DisplayUnitSelection
    /// The locale every display string is formatted in. Fixed for the session's life, so the
    /// main-actor presenters read it without a hop: the measurement presenter's live values and
    /// Temporary Measures render in it too, rather than in `en_US_POSIX` beside a ledger in the
    /// person's locale (L-104: "5.20 m" next to "5,20 m").
    nonisolated let localeIdentifier: String

    /// The formatter every display string in a snapshot is rendered with.
    ///
    /// Rebuilt per read rather than stored, because it is three enum cases and an `Int`;
    /// storing it would mean remembering to invalidate it when the units change.
    var snapshotFormatter: QuantityFormatter {
        QuantityFormatter(units: units, localeIdentifier: localeIdentifier)
    }

    /// The names behind the identifiers a record carries.
    var nameTable: ProjectNameTable { names }

    /// The `/UserUnit` of a page, `1` for a page that declares none or that the document does
    /// not hold. The nominal ratio a scale displays divides its factor by this (CR-128).
    func userUnit(onPage pageID: PageID?) -> Double {
        guard let pageID, let page = knownPages[pageID] else { return 1 }
        let unit = page.userUnit
        return (unit.isFinite && unit > 0) ? unit : 1
    }

    /// The validated column set the ledger store is built over.
    var ledgerColumns: LedgerColumnSet { columnSet }

    // MARK: Creation

    /// Opens a session over a document's pages.
    ///
    /// - Parameters:
    ///   - documentID: the document these pages belong to.
    ///   - pages: page descriptors, in document order.
    ///   - units: output units and precision.
    ///   - localeIdentifier: the locale display strings are formatted in.
    ///   - measurementOptions: engine tuning, defaulted to the shipping options.
    ///   - clock: the timestamp source, injected so a test gets deterministic records.
    public init(
        documentID: DocumentID,
        pages: [ZPDFContracts.PageDescriptor] = [],
        units: DisplayUnitSelection = .metric,
        localeIdentifier: String = "en_US_POSIX",
        measurementOptions: MeasurementEngineOptions = .default,
        snapSettings: SnapSettings = .default,
        engineVersion: String = TakeoffSession.defaultEngineVersion,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.documentID = documentID
        self.pages = pages
        self.pageOrder = pages.map(\.id)
        self.knownPages = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.knownPageOrder = pages.map(\.id)
        self.markups = [:]
        self.markupOrder = []
        self.scales = [:]
        self.pageScaleIDs = [:]
        self.scaleRegionSet = []
        self.projectZoneSet = []
        self.names = ProjectNameTable.pages(pages)
        self.names.layers = MarkupLayerSet.initial.names   // ADR-0032: "Default" from the start
        self.columnSet = try Self.baseColumnSet(displayPolicy: units.domainPolicy)
        self.snapIndexes = [:]
        self.snapEngine = SnapEngine()
        self.snapSettings = snapSettings
        self.measurementEngine = MeasurementEngine(options: measurementOptions)
        self.engineVersion = engineVersion
        self.calibrationEvidence = [:]
        self.clock = clock
        self.units = units
        self.localeIdentifier = localeIdentifier
    }

    // MARK: Document state

    /// Changes the output units. Every stored measurement keeps its SI value; only the
    /// strings a snapshot carries change, which is why this does not touch the engine.
    public func setUnits(_ newUnits: DisplayUnitSelection) throws {
        units = newUnits
        columnSet = try makeColumnSet(displayPolicy: newUnits.domainPolicy)
    }

    /// Columns added at runtime — today the text columns a table import mints (feature 31,
    /// ADR-0012). Kept separately so a units change, which rebuilds the set, re-appends
    /// them instead of silently dropping the imported schedule's columns.
    private var customColumnDefinitions: [LedgerColumnDefinition] = []

    /// Appends runtime columns to the ledger's set.
    ///
    /// - Throws: whatever ``LedgerColumnSet`` refuses — a duplicate key stays a loud error,
    ///   never a silently renamed column.
    ///
    /// Atomic: a refused set leaves the runtime columns as they were. They used to be appended
    /// before the set was validated and never taken out again, so every later units change and
    /// import threw the same error about a column the person never got (BH-430).
    public func addCustomColumns(_ definitions: [LedgerColumnDefinition]) throws {
        let previous = customColumnDefinitions
        customColumnDefinitions.append(contentsOf: definitions)
        do {
            columnSet = try makeColumnSet(displayPolicy: units.domainPolicy)
        } catch {
            customColumnDefinitions = previous
            throw error
        }
    }

    /// Replaces the runtime columns outright (NL-QTY-02). Atomic like ``addCustomColumns(_:)``:
    /// a set the ledger refuses — a duplicate key, a formula that does not compile, a cycle —
    /// leaves the columns as they were and throws.
    func replaceCustomColumns(_ definitions: [LedgerColumnDefinition]) throws {
        let previous = customColumnDefinitions
        customColumnDefinitions = definitions
        do {
            columnSet = try makeColumnSet(displayPolicy: units.domainPolicy)
        } catch {
            customColumnDefinitions = previous
            throw error
        }
    }

    /// The built-in columns plus the columns Zenit reserves — today `Repeat ×`, the per-row
    /// multiplier the value path applies to extensive quantities — plus any runtime columns
    /// (a table import's). Assembled here, never persisted: the set is rebuilt on every
    /// open, so the reserved column cannot collide with a stored copy of itself.
    private func makeColumnSet(displayPolicy: DisplayUnitPolicy) throws -> LedgerColumnSet {
        var definitions = try Self.baseColumnDefinitions(displayPolicy: displayPolicy)
        for extra in customColumnDefinitions {
            var shifted = extra
            shifted.order = definitions.count
            definitions.append(shifted)
        }
        return try LedgerColumnSet(columns: definitions)
    }

    /// The built-ins plus `Repeat ×`, before any runtime additions — what a fresh session
    /// starts with.
    private static func baseColumnDefinitions(
        displayPolicy: DisplayUnitPolicy
    ) throws -> [LedgerColumnDefinition] {
        var definitions = try LedgerColumnSet.standard(displayPolicy: displayPolicy).columns
        definitions.append(RepetitionColumn.definition(order: definitions.count))
        // ADR-0024: the hidden column an assembly assignment is stored in.
        definitions.append(AssemblyColumn.definition(order: definitions.count))
        // ADR-0025: the hidden column a live summary's specification is stored in.
        definitions.append(LiveSummaryColumn.definition(order: definitions.count))
        return definitions
    }

    /// Internal, not private: TableImportTests builds a store over this exact set to
    /// prove imported rows read back as `.read` through the ledger.
    static func baseColumnSet(displayPolicy: DisplayUnitPolicy) throws -> LedgerColumnSet {
        try LedgerColumnSet(columns: baseColumnDefinitions(displayPolicy: displayPolicy))
    }

    /// The units in force.
    public var displayUnits: DisplayUnitSelection { units }

    /// The pages, in document order.
    ///
    /// Through the ``knownPages`` index, which holds every page the set has held: a linear
    /// search of `pages` per page made each snapshot O(pages²), several times over (R-060). The
    /// order is `pageOrder`, the truth `atomically` rolls back.
    public var pageDescriptors: [ZPDFContracts.PageDescriptor] {
        pageOrder.compactMap { knownPages[$0] }
    }

    /// The scale a measurement on `page` resolves to, in the specified order (spec 10.5).
    ///
    /// 1. the scale the caller named, when it named one — a Scale Region's scale, resolved by
    ///    the caller and carried as the markup's `scaleRegionID`/`scaleID` pair;
    /// 2. else **the page's own scale**;
    /// 3. else nothing.
    ///
    /// Nothing means nothing. There is no document-wide fallback, so a sheet nobody calibrated
    /// resolves to `nil` however many *other* sheets are calibrated, and the caller refuses the
    /// measurement rather than computing it against a sibling page's transform.
    ///
    /// A named scale that belongs to a different page is **not** honoured either: it is dropped
    /// and the page's own scale answers instead, so a stale `scaleID` left on a markup that was
    /// moved between pages cannot carry the old sheet's ratio with it.
    public func scale(onPage page: PageID, scaleID: ScaleID? = nil) -> ScaleTransform? {
        if let scaleID, let named = scales[scaleID], named.pageID == page { return named }
        guard let own = pageScaleIDs[page] else { return nil }
        return scales[own]
    }

    /// The scale assigned to a page, without the named-scale rung above it.
    public func pageScale(_ page: PageID) -> ScaleTransform? {
        pageScaleIDs[page].flatMap { scales[$0] }
    }

    /// Every page that has its own scale, and the scale it has.
    public var pageScales: [PageID: ScaleTransform] {
        pageScaleIDs.compactMapValues { scales[$0] }
    }

    /// The first page's own scale.
    ///
    /// Not "the document scale" — there is no such thing any more. It exists for the two places
    /// that legitimately have no page in hand: the legacy `takeoff_state.default_scale_id`
    /// column, which older builds read, and a document-wide readout that has not been told
    /// which sheet is on screen.
    public var firstPageScale: ScaleTransform? {
        pageOrder.first.flatMap { pageScale($0) }
    }

    /// Whether the page has a scale of its own.
    public func isCalibrated(page: PageID) -> Bool { pageScaleIDs[page] != nil }

    /// The first page in document order, or `nil` for a document with no pages.
    public var firstPageID: PageID? { pageOrder.first }

    /// Every Scale Region the document holds, highest priority first.
    public var scaleRegionDefinitions: [ScaleRegionDefinition] {
        scaleRegionSet.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.name < rhs.name : lhs.priority > rhs.priority
        }
    }

    /// Every Project Zone the document holds, in the panel's order.
    public var projectZoneDefinitions: [ProjectZoneDefinition] {
        projectZoneSet.sorted { lhs, rhs in
            lhs.sortOrder == rhs.sortOrder ? lhs.name < rhs.name : lhs.sortOrder < rhs.sortOrder
        }
    }

    /// One Scale Region by identity.
    public func scaleRegion(_ id: ScaleRegionID) -> ScaleRegionDefinition? {
        scaleRegionSet.first { $0.id == id }
    }

    /// One scale by identity, without the default-scale fallback ``scale(for:)`` applies.
    public func scaleTransform(_ id: ScaleID) -> ScaleTransform? { scales[id] }

    /// Every scale the document holds, in a stable order.
    public var allScales: [ScaleTransform] {
        scales.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    /// The resolver for one page, or `nil` when the page has no regions.
    ///
    /// Built on demand rather than cached: the R-tree costs microseconds over the handful of
    /// regions a sheet carries, and a cache would be one more thing that can disagree with the
    /// region set after an undo.
    ///
    /// - Throws: the geometry package's own rejection of an unusable boundary.
    public func scaleRegionResolver(page pageID: PageID) throws -> ScaleRegionResolver? {
        // A region whose boundary is unusable — an unreadable `polygon_blob` reopens as an
        // empty outline, by design — cannot contain anything, so it is left out of the
        // resolver instead of making the resolver refuse the whole page. Before, one broken
        // row made every measurement on the sheet, including one drawn wholly inside an intact
        // detail region, commit at the page scale with no prompt (BH-096).
        let onPage = scaleRegionSet
            .filter { $0.pageID == pageID }
            .map(\.geometryRegion)
            .filter { $0.bounds != nil }
        guard !onPage.isEmpty else { return nil }
        return try ScaleRegionResolver(pageID: pageID, regions: onPage)
    }

    /// The pairs of regions that share area on one page, as the panel warns about them.
    ///
    /// The detection is the geometry package's, not a second one written here: a weaker
    /// overlap test in the UI would be free to disagree with the one that decides
    /// measurements, and the disagreement would surface as a wrong number.
    public func overlappingScaleRegions(page pageID: PageID) -> [(ScaleRegionID, ScaleRegionID)] {
        let onPage = scaleRegionSet.filter { $0.pageID == pageID }
        guard onPage.count > 1 else { return [] }
        var found: [(ScaleRegionID, ScaleRegionID)] = []
        for (index, region) in onPage.enumerated() {
            for other in onPage.dropFirst(index + 1) {
                guard let resolver = try? ScaleRegionResolver(
                    pageID: pageID,
                    regions: [region.geometryRegion, other.geometryRegion]
                ) else { continue }
                do {
                    try resolver.validateNoOverlap()
                } catch {
                    found.append((region.id, other.id))
                }
            }
        }
        return found
    }

    /// How many markups each Scale Region is currently the scale for.
    ///
    /// The panel refuses to delete a region that still measures something, and this is the
    /// number behind that refusal — counted where the markups are, not where they are drawn.
    public func markupCountsByScaleRegion() -> [ScaleRegionID: Int] {
        var counts: [ScaleRegionID: Int] = [:]
        for record in markups.values {
            guard let regionID = record.scaleRegionID else { continue }
            counts[regionID, default: 0] += 1
        }
        return counts
    }

    /// How many markups are filed into each zone.
    public func markupCountsByZone() -> [ZoneID: Int] {
        var counts: [ZoneID: Int] = [:]
        for record in markups.values {
            guard let zoneID = record.zoneID else { continue }
            counts[zoneID, default: 0] += 1
        }
        return counts
    }

    /// The markups, in insertion order.
    public var orderedMarkups: [MarkupRecord] { markupOrder.compactMap { markups[$0] } }

    /// How many markups carry no quantity — text, callouts, notes, images, shapes, stamps: the
    /// figure the Quantity Ledger bar's Markups chip shows (the number of non-measurement
    /// markups). It used to show the ledger's row count, which leaves
    /// out every such markup without a subject, so four text boxes read "Markups 0" (L-50).
    var nonQuantityMarkupCount: Int {
        markups.values.reduce(0) { $1.kind.producesQuantity ? $0 : $0 + 1 }
    }

    /// The markups the Quantity Ledger has a row for.
    ///
    /// A shape, a text box or a callout is a **markup**, not a measurement — no row in the
    /// ledger unless the user gives it a subject. So a
    /// record earns a row by producing a quantity, or by having been classified. Everything
    /// else stays on the canvas and out of the totals, which is what keeps a rectangle
    /// drawn to circle a detail from turning up in an estimator's quantities.
    public var ledgerMarkups: [MarkupRecord] {
        orderedMarkups.filter { record in
            record.kind.producesQuantity
                || !record.subject.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// One markup.
    public func markup(_ id: MarkupID) -> MarkupRecord? { markups[id] }

    // MARK: Hydration (ADR-0009)

    /// The whole takeoff, as one `Sendable` value — what a save writes.
    public struct TakeoffState: Sendable {
        /// Pages in document order.
        public let pages: [ZPDFContracts.PageDescriptor]
        /// Markups in insertion order.
        public let markups: [MarkupRecord]
        /// Every scale the document holds.
        public let scales: [ScaleTransform]
        /// Which scale is each page's own scale. A page with no entry has no scale, and a
        /// measurement on it is refused rather than computed against another page's.
        public let pageScaleIDs: [PageID: ScaleID]
        /// The calibration evidence behind each hand-calibrated scale (ADR-0007).
        public let calibrationEvidence: [ScaleID: CalibrationEvidence]
        /// Every Scale Region, highest priority first.
        public let scaleRegions: [ScaleRegionDefinition]
        /// Every Project Zone, in the panel's order.
        public let projectZones: [ProjectZoneDefinition]
        /// The runtime ledger columns — a table import's — in the order they were added.
        public var customColumns: [LedgerColumnDefinition] = []
        /// Stored markups hydration refused because their page is not one of this document's.
        /// The archive carries their rows through the save.
        public var heldMarkupIDs: [String] = []
        /// Named sheets (NL-DOCS-05), persisted in `page_set_entry`.
        public var sheetIdentities: [PageID: SheetIdentity] = [:]
        /// Set-wide positions, for a state filtered to one drawing of a multi-drawing set
        /// (NL-DOCS-04). Empty means "the order of ``pages``".
        public var setPositions: [PageID: Int] = [:]
        /// Pages removed from the set (NL-DOCS-07), kept with their markups; not in ``pages``.
        public var excludedPages: [ZPDFContracts.PageDescriptor] = []
        /// Markups on ``excludedPages``, set aside; not in ``markups``.
        public var setAsideMarkups: [MarkupRecord] = []
        /// Each sheet's view (NL-DOCS-07/16), persisted in `page_set_entry`.
        public var pageViews: [PageID: PageViewSettings] = [:]
        /// Pages the archive writes as removed from the set. Filled by ``foldingArrangement()``.
        public var excludedPageIDs: Set<PageID> = []
        /// The set order with each removed page where it stood, so a removed sheet written and
        /// read back returns to its place. Empty when nothing is removed.
        public var arrangedOrder: [PageID] = []
        /// ADR-0032: the project's markup layers, or `nil` when this state does not
        /// carry the project-level list (a later drawing's share of a set). The archive writes the
        /// list only when it is present.
        public var markupLayers: [MarkupLayer]?
        /// ADR-0032: the layer new markups go to, saved with the project.
        public var activeMarkupLayerID: LayerID?
        /// ADR-0032: the takeoff's display units, saved with the project so it reopens in them.
        public var displayUnits: DisplayUnitSelection?
        /// ADR-0031: detected markups' capture methods on pages with no scale yet, which their
        /// (absent) measurement cannot carry. The archive writes them beside the geometry.
        public var uncalibratedCaptures: [MarkupID: CaptureMethod] = [:]
        /// NL-QTY-07-UI: the project's own assembly recipes, or `nil` when this state does not
        /// carry them (a later drawing's share of a set). Project-level, like the layer list.
        public var projectAssemblyRecipes: ProjectAssemblyRecipes?

        public init(
            pages: [ZPDFContracts.PageDescriptor],
            markups: [MarkupRecord],
            scales: [ScaleTransform],
            pageScaleIDs: [PageID: ScaleID],
            calibrationEvidence: [ScaleID: CalibrationEvidence] = [:],
            scaleRegions: [ScaleRegionDefinition] = [],
            projectZones: [ProjectZoneDefinition] = []
        ) {
            self.pages = pages
            self.markups = markups
            self.scales = scales
            self.pageScaleIDs = pageScaleIDs
            self.calibrationEvidence = calibrationEvidence
            self.scaleRegions = scaleRegions
            self.projectZones = projectZones
        }
    }

    /// The takeoff as it stands, for the save pipeline.
    public func takeoffState() -> TakeoffState {
        TakeoffState(
            pages: pageDescriptors,
            markups: orderedMarkups,
            scales: scales.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString },
            pageScaleIDs: pageScaleIDs,
            calibrationEvidence: calibrationEvidence,
            scaleRegions: scaleRegionDefinitions,
            projectZones: projectZoneDefinitions
        ).withCustomColumns(savedCustomColumnDefinitions).holding(refusedMarkupIDs).naming(sheetIdentityTable)
            .arranging(
                excluded: excludedPageDescriptors,
                setAside: setAsideMarkupsForSave,
                views: pageViewTable,
                arrangedOrder: arrangedPageOrder
            )
            .layering(markupLayerSet.layers, active: activeMarkupLayerID, units: units)   // ADR-0032
            .settingAsideCaptures(setAsideCaptureMethods)   // ADR-0031
            .carryingAssemblyRecipes(projectAssemblyRecipes)   // NL-QTY-07-UI
    }

    /// The set-aside markups in markup order, each unfiled from a Project Zone this project no
    /// longer holds (U-028).
    ///
    /// Deleting a zone unfiles the live markups only; a markup on a sheet removed from the set
    /// kept naming the deleted zone, and `markup.zone_id` is a foreign key checked when the save
    /// commits, so every later save failed. The stored record is left as it is: undoing the zone
    /// deletion brings the zone back and the filing with it.
    var setAsideMarkupsForSave: [MarkupRecord] {
        setAsideMarkups.values.sorted { $0.position < $1.position }.map { entry in
            var record = entry.record
            record.zoneID = heldZone(record.zoneID)
            return record
        }
    }

    /// The set order with every removed page put back where it stood among the known pages.
    var arrangedPageOrder: [PageID] {
        var order = pageOrder
        let live = Set(pageOrder)
        for (knownIndex, page) in knownPageOrder.enumerated() where !live.contains(page) {
            let before = Set(knownPageOrder[..<knownIndex])
            let anchor = order.lastIndex { before.contains($0) }
            order.insert(page, at: anchor.map { $0 + 1 } ?? 0)
        }
        return order
    }

    /// Stored markups ``hydrate`` refused because their page is not one of this session's
    /// pages. Never in the ledger, never re-parented onto another
    /// sheet; the caller can say how many there are, and the next save keeps them in the file.
    public private(set) var refusedMarkupIDs: [MarkupID] = []

    /// ADR-0031: capture stamps of detected markups on a page with no scale yet, waiting for
    /// the calibration that measures them. Keyed by markup; each keeps the geometry digest it
    /// describes, so a markup reshaped by hand in the meantime reads as drawn by hand.
    var uncalibratedCaptures: [MarkupID: MeasurementProvenance] = [:]

    /// The capture method set aside for a markup on an uncalibrated page, if any (ADR-0031).
    public func uncalibratedCapture(of id: MarkupID) -> CaptureMethod? {
        setAsideCapture(of: id)
    }

    /// A set-aside stamp counts while its markup has no measurement and still has the geometry
    /// the stamp describes. The table is not consumed when a calibration measures the markup: an
    /// undo of that calibration brings the unmeasured record back, and the stamp with it (R-058).
    /// It used to be removed on first use and was in no undo patch, so calibrate, undo, save lost
    /// the detector's capture method.
    func setAsideCapture(of id: MarkupID) -> CaptureMethod? {
        guard let stamp = uncalibratedCaptures[id],
              let record = markups[id] ?? setAsideMarkups[id]?.record,
              record.measurement == nil, let geometry = record.geometry,
              CaptureMethodCarry.setAside(stamp, geometry: geometry) != nil else { return nil }
        return stamp.captureMethod
    }

    /// Every set-aside capture method that still counts, for the save (ADR-0031).
    var setAsideCaptureMethods: [MarkupID: CaptureMethod] {
        var methods: [MarkupID: CaptureMethod] = [:]
        for id in uncalibratedCaptures.keys {
            if let method = setAsideCapture(of: id) { methods[id] = method }
        }
        return methods
    }

    /// Installs the runtime ledger columns a saved takeoff carries, before ``hydrate`` so the
    /// archived cells find their columns and number cells are re-tagged by them (BH-075).
    ///
    /// One definition at a time, so a definition the session already knows — or one this build
    /// refuses — cannot take the others down with it. Returns the definitions installed.
    ///
    /// A definition this build refuses is **held**, not dropped (R-136): it goes to
    /// ``heldCustomColumns`` with the ledger's reason, every save writes it back unchanged, and
    /// the refusal waits in ``takeColumnRefusals()`` for the environment to say. It used to be
    /// skipped by a `try?`; the save is built from the installed columns and removes the rows it
    /// no longer has, so a formula column saved by an earlier build — `CONVERT(Area, ft2, m2)`,
    /// which the engine now refuses because a measured Area is held in m2 — was erased from the
    /// project by the first save after the open, with nothing said.
    ///
    /// Definitions are retried while any of them installs, so a formula stored ahead of the
    /// column it reads is not refused for its position alone.
    @discardableResult
    public func restoreCustomColumns(_ definitions: [LedgerColumnDefinition]) -> [LedgerColumnDefinition] {
        var installed: [LedgerColumnDefinition] = []
        var seen = Set(customColumnDefinitions.map(\.key)).union(heldCustomColumns.map(\.definition.key))
        var pending: [LedgerColumnDefinition] = []
        for definition in definitions where seen.insert(definition.key).inserted {
            pending.append(definition)
        }
        var reasons: [String: String] = [:]
        var progressed = true
        while progressed, !pending.isEmpty {
            progressed = false
            var refused: [LedgerColumnDefinition] = []
            for definition in pending {
                do {
                    try addCustomColumns([definition])
                    installed.append(definition)
                    progressed = true
                } catch {
                    reasons[definition.key] = LedgerColumnValidation.describe(error)
                    refused.append(definition)
                }
            }
            pending = refused
        }
        for definition in pending {
            let held = HeldCustomColumn(definition: definition, reason: reasons[definition.key] ?? "")
            heldCustomColumns.append(held)
            pendingColumnRefusals.append(held)
        }
        return installed
    }

    /// A stored runtime column this build refused to install (R-136).
    public struct HeldCustomColumn: Hashable, Sendable {
        /// The definition exactly as it was read; every save writes it back unchanged.
        public let definition: LedgerColumnDefinition
        /// Why the ledger refused it, in the ledger's own words.
        public let reason: String
    }

    /// Stored runtime columns ``restoreCustomColumns(_:)`` refused. Never in the ledger; carried
    /// through every save until a column of the same key, or the same title, replaces one.
    public private(set) var heldCustomColumns: [HeldCustomColumn] = []

    /// Refusals the last restore made, waiting for a presenter to say them.
    private var pendingColumnRefusals: [HeldCustomColumn] = []

    /// The columns the last restore refused, once. The environment posts them to the warning
    /// tray, like ``takeHydrationRepairs()``.
    public func takeColumnRefusals() -> [HeldCustomColumn] {
        defer { pendingColumnRefusals = [] }
        return pendingColumnRefusals
    }

    /// The runtime columns a save writes: the installed ones, then every held one that no
    /// installed column has replaced — by key, or by title (the name the warning tells the
    /// person to reuse, since a column made in the Column Manager gets a key of its own).
    var savedCustomColumnDefinitions: [LedgerColumnDefinition] {
        guard !heldCustomColumns.isEmpty else { return customColumnDefinitions }
        func name(_ title: String) -> String {
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let keys = Set(customColumnDefinitions.map(\.key))
        let titles = Set(customColumnDefinitions.map { name($0.title) })
        let carried = heldCustomColumns.map(\.definition).filter {
            !keys.contains($0.key) && !titles.contains(name($0.title))
        }
        return customColumnDefinitions + carried
    }

    /// Installs a saved takeoff into a freshly opened session (ADR-0009).
    ///
    /// Not a command: nothing is registered with undo, because a reopened project starts
    /// with a fresh undo stack — there is no "before the open" to return to. Every
    /// measurement is **recomputed** through the pure engine from its stored geometry,
    /// scale and parameters; the engine is deterministic, so the recomputed values equal
    /// the saved ones digit for digit, and the round-trip suite asserts exactly that
    /// against the stored `measurement_value` strings.
    ///
    /// - Returns: the cutouts detached because they lay wholly outside their parents — a repair
    ///   the environment reports through the warning tray, never a reason to refuse the file.
    /// - Throws: when a markup's recomputation fails for any other reason — a saved geometry the
    ///   engine refuses is a damaged file, not a state to open silently.
    @discardableResult
    public func hydrate(
        markups hydratedMarkups: [MarkupRecord],
        scales hydratedScales: [ScaleTransform],
        pageScaleIDs hydratedPageScales: [PageID: ScaleID],
        calibrationEvidence hydratedEvidence: [ScaleID: CalibrationEvidence] = [:],
        scaleRegions hydratedRegions: [ScaleRegionDefinition] = [],
        projectZones hydratedZones: [ProjectZoneDefinition] = []
    ) throws -> [CutoutDetachment] {
        scaleRegionSet = hydratedRegions
        projectZoneSet = hydratedZones
        refreshStructureNames()
        scales = [:]
        names.scales = [:]
        let hydratedScaleIDs = Set(hydratedScales.map(\.id))
        // Evidence for a scale the document does not hold is dropped rather than kept as an
        // orphan a later scale could inherit by reusing its identifier.
        calibrationEvidence = hydratedEvidence.filter { hydratedScaleIDs.contains($0.key) }
        for scale in hydratedScales {
            scales[scale.id] = scale
            names.scales[scale.id] = ScaleBridge.ratioText(for: scale, userUnit: userUnit(onPage: scale.pageID), localeIdentifier: localeIdentifier)
        }
        // No `?? hydratedScales.first`. The old hydration adopted whatever scale it found first
        // as the document default, which is precisely how a project written with one calibrated
        // sheet reopened with every sheet claiming that calibration. A page with no stored
        // assignment reopens uncalibrated, which is what it is.
        pageScaleIDs = [:]
        let livePages = Set(pageOrder)
        for (page, scaleID) in hydratedPageScales {
            guard livePages.contains(page), let scale = scales[scaleID] else { continue }
            guard scale.pageID == page else {
                throw DocumentCommandError.scaleBelongsToAnotherPage(scale: scaleID, page: page)
            }
            pageScaleIDs[page] = scaleID
        }

        markups = [:]
        markupOrder = []
        markupTableEpoch &+= 1
        refusedMarkupIDs = []
        uncalibratedCaptures = [:]
        for record in hydratedMarkups {
            var stored = record
            // This used to stamp the session's document on every
            // stored markup, whatever page it stood on — a markup whose sheet is not in this
            // document was silently re-parented and shown in its ledger. It is refused instead;
            // only a markup on one of this session's pages is re-stamped with the session's
            // (runtime) document identity.
            guard livePages.contains(stored.pageID) else {
                refusedMarkupIDs.append(stored.id)
                continue
            }
            // A set of several drawings (NL-DOCS-04): the markup carries its page's drawing.
            stored.documentID = drawing(ofPage: stored.pageID)
            // ADR-0014 §3: a project written before the `ratio` tag stored a repeat count and
            // a ratio-typed custom cell as the same bytes a count uses, and every one of them
            // decodes as a count. The column is the authority on what the number means, so
            // each dimensionless cell is re-tagged by the column it sits in — never by value.
            stored.customValues = Self.retaggingCustomValues(stored.customValues, columns: columnSet)
            // X-042: an Arc Length saved with more than three points was measured on its first
            // three; the engine now refuses the rest, so it opens as those three — same value,
            // and the arc it was measured on is what is drawn and snapped. The same repair every
            // other door for saved records applies (SavedMarkupRepair).
            stored = SavedMarkupRepair.opened(stored)
            if markups[stored.id] == nil { markupOrder.append(stored.id) }
            markups[stored.id] = stored
        }
        // Two passes, not one: a parent's holes are rebuilt from its cutouts inside
        // `recompute`, and the archive stores the parent before its cutouts. Recomputing in
        // one pass measured the parent while its cutouts were not installed yet — no holes,
        // gross area — and that is also the pass that normalises an archive written before
        // holes were derived (CR-1): whatever merged rings it carries are discarded here and
        // re-derived from the cutouts the parent actually names.
        var repairs: [CutoutDetachment] = []
        for id in markupOrder {
            guard var stored = markups[id] else { continue }
            // A value kept under an older scale version (NL-MEASURE-03, ADR-0030 §2) opens as it
            // was saved: recomputing it here would quietly apply the new scale the person chose
            // not to apply.
            if keepsStoredValue(stored) { continue }
            let detached = try hydrateRecompute(&stored)
            markups[id] = stored
            for culprit in detached {
                // Both halves of the link go: a cutout naming a parent that no longer names it
                // would be edited as a child and measured as a stranger.
                if var cutout = markups[culprit], cutout.parentMarkupID == stored.id {
                    cutout.parentMarkupID = nil
                    markups[culprit] = cutout
                }
                repairs.append(CutoutDetachment(
                    cutoutID: culprit,
                    parentID: stored.id,
                    parentSubject: stored.subject,
                    parentLabel: stored.label
                ))
            }
        }
        hydrationRepairs.append(contentsOf: repairs)
        return repairs
    }

    // MARK: Scale

    /// Calibrates the document scale from two points and a known real length (spec 10.2).
    ///
    /// Returns the command outcome so the caller can register undo for it, because
    /// calibrating is a document mutation like any other: a user who calibrates against
    /// the wrong grid line has to be able to take it back.
    public func calibrate(
        page: PageID,
        first: PDFPoint,
        second: PDFPoint,
        knownLength: Decimal,
        knownLengthUnit: Domain.Length,
        scaleID: ScaleID? = nil,
        label: String? = nil,
        allowExtreme: Bool = false
    ) throws -> DocumentCommandOutcome {
        let (id, version) = try scaleIdentity(forPage: page, scaleID: scaleID)
        let scale = try ScaleTransform.calibratedTwoPoint(
            id: id,
            pageID: page,
            version: version,
            first: first,
            second: second,
            knownLength: knownLength,
            knownLengthUnit: knownLengthUnit,
            units: scaleUnitPolicy,
            label: label,
            allowExtreme: allowExtreme
        )
        return try installScale(scale, evidence: CalibrationEvidence(
            points: [first, second],
            enteredLength: .length(knownLength, in: knownLengthUnit),
            enteredUnit: knownLengthUnit
        ))
    }

    /// The identifier and next version a new scale on `page` takes: the page's own scale
    /// re-versioned, or a fresh one (``calibrate(page:first:second:knownLength:knownLengthUnit:scaleID:label:allowExtreme:)``
    /// explains each refusal). Shared by every scale entry point.
    func scaleIdentity(forPage page: PageID, scaleID: ScaleID?) throws -> (id: ScaleID, version: Int) {
        guard pageOrder.contains(page) else { throw DocumentCommandError.unknownPage(page) }
        // `page` is required, and the identifier defaults to **this page's** scale rather than
        // to a document-wide one. Before per-page scale it read
        // `scaleID ?? defaultScaleID ?? ScaleID(UUID())`, so calibrating sheet three produced a
        // new *version* of the one scale the whole document shared — and `applyScale` then
        // recomputed sheet one's measurements against sheet three's ratio. Calibrating a page
        // that has no scale now mints a scale for that page and touches nothing else.
        let id = scaleID ?? pageScaleIDs[page] ?? ScaleID(UUID())
        // A *second* scale — a Scale Region's, named by a fresh identifier — needs the page's own
        // scale to exist first. `applyScale` promotes a new scale to the page scale when the page
        // has none, so a region scale calibrated first became the whole sheet's ratio, and the
        // next page calibration re-versioned the region's scale to the sheet's (BH-432). The UI
        // asks for the page first; the session now refuses the same thing itself.
        if let scaleID, scales[scaleID] == nil, pageScaleIDs[page] == nil {
            throw DocumentCommandError.noScale(page)
        }
        if let existing = scales[id], existing.pageID != page {
            throw DocumentCommandError.scaleBelongsToAnotherPage(scale: id, page: page)
        }
        let version = (scales[id]?.version ?? 0) + 1
        return (id, version)
    }

    /// The unit policy a scale minted now carries: the document's display units.
    var scaleUnitPolicy: ScaleUnitPolicy {
        ScaleUnitPolicy(
            length: Domain.Length(shown: units.length),
            area: Domain.Area(shown: units.area),
            volume: Domain.Volume(shown: units.volume),
            angle: .degree,
            precision: units.precision
        )
    }

    /// Installs a scale through `.changeScale`, with its evidence as part of the same patch.
    ///
    /// `evidence: nil` is a scale nobody picked points for — a drawing ratio — and it removes
    /// whatever evidence an earlier calibration left under the same identifier, in both
    /// directions of the undo (ADR-0019: evidence is never fabricated, and never inherited).
    func installScale(_ scale: ScaleTransform, evidence: CalibrationEvidence?) throws -> DocumentCommandOutcome {
        // The evidence is recorded before the command runs, because `applyScale` recomputes
        // every measurement the new scale governs and those recomputations must carry the
        // derivation of the calibration that just happened, not of the one before it.
        let previousEvidence = calibrationEvidence[scale.id]
        calibrationEvidence[scale.id] = evidence
        do {
            let outcome = try apply(.changeScale(scale))
            // The evidence is part of the document, so it is part of the patch in both
            // directions. Undo used to put the previous transform back and leave *this*
            // calibration's evidence in the table, so every derivation recomputed after the
            // undo — and the scale row the next save wrote — cited the points and length of a
            // calibration the document no longer had (CR-5).
            var inverse = outcome.inverse
            inverse.calibrationEvidence = [scale.id: previousEvidence]
            var forward = outcome.forward
            forward.calibrationEvidence = [scale.id: evidence]
            return DocumentCommandOutcome(
                command: outcome.command,
                inverse: inverse,
                forward: forward,
                changedMarkupIDs: outcome.changedMarkupIDs,
                changedPageIDs: outcome.changedPageIDs
            )
        } catch {
            // A refused calibration leaves the document byte-identical to how it started, and
            // the evidence table is part of the document.
            calibrationEvidence[scale.id] = previousEvidence
            throw error
        }
    }

    /// The picked points and entered length behind a scale, when it was calibrated by hand.
    public func evidence(for scaleID: ScaleID) -> CalibrationEvidence? {
        calibrationEvidence[scaleID]
    }

    /// The session's own engine, for a dry run that must agree with a real recompute
    /// (`TakeoffSession+ScaleImpact.swift`).
    var dryRunEngine: MeasurementEngine { measurementEngine }

    /// Removes a scale's evidence ahead of a bulk install (`TakeoffSession+ScaleEntry.swift`).
    func clearEvidence(for scaleID: ScaleID) { calibrationEvidence.removeValue(forKey: scaleID) }

    /// Puts back evidence a refused bulk install cleared.
    func restoreEvidence(_ evidence: CalibrationEvidence?, for scaleID: ScaleID) {
        calibrationEvidence[scaleID] = evidence
        refreshSnapBoundaries()   // U-086: the refused batch's revert refreshed without it
    }

    // MARK: Provenance (ADR-0007)

    /// Build identity stamped into a derivation when the host does not supply one.
    ///
    /// Read from the host bundle's short version string, which is what a person reads off the
    /// About panel, so a derivation names a build they can actually go and get. A package under
    /// test has no such key and says so rather than claiming a version it does not have.
    public static let defaultEngineVersion: String = {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (version?, build?): return "ZenitPDF \(version) (\(build))"
        case let (version?, nil): return "ZenitPDF \(version)"
        default: return "ZenitPDF (unversioned build)"
        }
    }()

    /// The session's clock, in the shape the provenance recorder wants.
    private struct SessionClock: TimestampProviding {
        let source: @Sendable () -> Date
        func now() -> Date { source() }
    }

    /// The provenance-recording engine for one scale.
    ///
    /// Built per calculation rather than stored, because the calibration evidence belongs to
    /// the scale that is actually in force and that is not known until the scale is resolved —
    /// which, now that a scale belongs to a page, depends on which page the markup is on.
    private func recorder(for scale: ScaleTransform) -> ProvenanceRecording {
        ProvenanceRecording(
            engine: measurementEngine,
            context: ProvenanceContext(
                engineVersion: engineVersion,
                calibrationEvidence: calibrationEvidence[scale.id],
                layerName: nil,
                timestamps: SessionClock(source: clock)
            )
        )
    }

    // MARK: Measurement

    /// Runs the measurement engine for a tool.
    ///
    /// A pure call into a pure engine: same geometry, same scale, same parameters, same
    /// result — including the same warnings in the same order.
    public func measure(
        tool: Domain.Tool,
        geometry: MeasurementGeometry,
        parameters: MeasurementParameters = .default,
        scaleID: ScaleID? = nil
    ) throws -> MeasurementResult {
        guard let scale = scale(onPage: geometry.pageID, scaleID: scaleID) else {
            throw DocumentCommandError.noScale(geometry.pageID)
        }
        do {
            return try recorder(for: scale).calculate(
                tool: tool,
                geometry: geometry,
                scale: scale,
                parameters: parameters
            )
        } catch {
            throw DocumentCommandError.measurementFailed(UserFacingRefusal.sessionDetail(for: error))
        }
    }

    /// A live preview of the measurement a half-drawn tool would produce.
    ///
    /// Returns `nil` rather than throwing when the geometry is not yet enough for the
    /// tool: an in-progress polygon with two points is a normal state, not an error, and
    /// making it an error would put a red banner under the user's cursor while they draw.
    public func preview(
        tool: Domain.Tool,
        geometry: MeasurementGeometry,
        parameters: MeasurementParameters = .default,
        scaleID: ScaleID? = nil
    ) -> MeasurementResult? {
        guard let scale = scale(onPage: geometry.pageID, scaleID: scaleID) else { return nil }
        return try? measurementEngine.calculate(
            tool: tool,
            geometry: geometry,
            scale: scale,
            parameters: parameters
        )
    }

    // MARK: Snap

    /// Builds and installs a page's snap index over its vector extraction and its markups.
    ///
    /// Extraction is the slow half and happens outside the session; building is the fast half
    /// and happens here, so a scroll never waits on a scanner.
    ///
    /// - Parameters:
    ///   - page: the page descriptor, which the builder validates.
    ///   - extraction: the page's vector geometry, or `nil` for a scanned sheet — in which
    ///     case the index still carries markup and boundary layers, and Vector Snap
    ///     correctly reports itself unavailable (spec 13.11) rather than silently doing
    ///     nothing.
    ///   - hiddenLayerIDs: marked-content property names of the layers the user has hidden
    ///     A primitive on a hidden layer never becomes a snap entry, so a
    ///     hidden layer is structurally un-snappable rather than merely filtered at query
    ///     time. Pass the set produced by
    ///     `PDFLayerTree.hiddenMarkedContentNames(onPageIndex:effectiveVisibility:)`.
    public func buildSnapIndex(
        page: ZPDFContracts.PageDescriptor,
        extraction: VectorPageExtraction?,
        hiddenLayerIDs: Set<String> = []
    ) throws -> SnapIndexAvailability {
        // The effective record (ADR-0032): a markup on a hidden layer is hidden, and a hidden
        // markup is no snap target (T-072).
        let geometries = markupOrder
            .compactMap { markups[$0] }
            .filter { $0.pageID == page.id }
            .compactMap { snapGeometry(of: $0) }
        let index = try SnapIndexBuilder().build(
            page: page,
            extraction: extraction,
            markups: geometries,
            boundaries: snapBoundaries(onPage: page.id),   // U-086: zones, regions, calibration points
            hiddenLayerIDs: hiddenLayerIDs,
            cancellation: .task
        )
        snapIndexes[page.id] = index
        return index.availability
    }

    /// Whether a page has vector geometry to snap to, or `nil` when no index is installed for it
    /// yet — which ``AppCoreEnvironment`` reads as "build one" (K-01).
    public func snapAvailability(page pageID: PageID) -> SnapIndexAvailability? {
        snapIndexes[pageID]?.availability
    }

    /// Drops the snap indexes of a drawing's pages, all but `keeping`, so each is rebuilt the
    /// next time its page is on screen. A PDF layer change calls it: those indexes were built
    /// under the old layer state, and a sheet other than the one on screen would otherwise go on
    /// snapping to a layer the person just hid, or not to one just shown (K-01).
    public func discardSnapIndexes(ofDrawing drawing: DocumentID, keeping page: PageID?) {
        snapIndexes = snapIndexes.filter { entry in
            entry.key == page || self.drawing(ofPage: entry.key) != drawing
        }
    }

    /// Keeps every installed snap index in step with the markups a mutation touched (ADR-0030
    /// §5.7): each one that now exists is upserted into its page's index, each one that was
    /// removed or moved off a page is taken out of the old page's index.
    ///
    /// An index was built once, at open (and on a layer change), from the markups that existed
    /// then, and nothing updated it: a markup drawn, curved, split, merged, moved or restored by
    /// an undo during the session never became a snap target — arcs included, whose projection
    /// (`SnapMarkupGeometry.from`) was otherwise wired end to end. The vector layer is not touched;
    /// only the markup layer's small tree is updated (`SnapIndex.upsert(markup:)`).
    private func refreshSnapMarkups(_ ids: some Sequence<MarkupID>, previous: [MarkupID: MarkupRecord?]) {
        guard !snapIndexes.isEmpty else { return }
        // A cutout hidden or shown (by its flag or its layer) changes what its parent projects
        // (V-085): the parent carries a hidden cutout's drawn outline, since the canvas still
        // draws that hole. So every changed cutout refreshes its parent too.
        var refreshed = Set(ids)
        for id in refreshed {
            for parent in [markups[id]?.parentMarkupID, (previous[id] ?? nil)?.parentMarkupID].compactMap({ $0 }) {
                refreshed.insert(parent)
            }
        }
        for id in refreshed {
            let current = markups[id]
            if let old = previous[id] ?? nil, old.pageID != current?.pageID {
                snapIndexes[old.pageID]?.remove(markupID: id)
            }
            guard let current, snapIndexes[current.pageID] != nil else { continue }
            // The effective record, so hiding a layer takes its markups out of the index and
            // showing it puts them back (T-072); the raw record kept them as targets.
            if let geometry = snapGeometry(of: current),
               (try? snapIndexes[current.pageID]?.upsert(markup: geometry)) != nil {
                continue
            }
            // No snap geometry any more (or it could not be indexed): nothing stale may stay.
            snapIndexes[current.pageID]?.remove(markupID: id)
        }
        // Every mutation, undo and redo ends here, so the boundary layer follows the zones,
        // regions and calibrations the same step changed (U-086).
        refreshSnapBoundaries()
    }

    /// The snap geometry of `record` as the canvas draws it now: the effective record (a
    /// markup on a hidden layer is hidden, T-072), with the drawn outline of each of its
    /// cutouts that projects nothing itself — hidden, or on a hidden layer — whose hole the
    /// visible parent still draws (V-085).
    ///
    /// `viewHidden` names markups a view has taken off the sheet without hiding them (the
    /// ledger filter's Hide, V-003); a cutout among them counts as hidden here, so its visible
    /// parent carries its drawn outline exactly as it carries a hidden cutout's.
    private func snapGeometry(of record: MarkupRecord, viewHidden: Set<MarkupID> = []) -> SnapMarkupGeometry? {
        let unprojected = record.cutoutMarkupIDs
            .compactMap { markups[$0] }
            .map { markupLayerSet.effective($0) }
            .filter { $0.hidden || viewHidden.contains($0.id) }
        return MarkupBridge.snapGeometry(of: markupLayerSet.effective(record), unprojectedCutouts: unprojected)
    }

    /// A page's snap index as one view sees the page: `excluded` — markups that view does not
    /// draw although they are not hidden, the ledger filter's Hide (V-003) — are no snap
    /// targets, exactly as a hidden markup is none (T-072). `nil` when the page has no index.
    ///
    /// The exclusion is per resolve, not session state: one session serves every window of a
    /// document (NL-UX-20), and each window has its own ledger filter. The shared index is never
    /// touched; a copy is cut with those markups removed (and a visible parent of an excluded
    /// cutout re-projected with that cutout's drawn outline, V-085), and cached per page until
    /// the index or the exclusion changes. Only the small markup layer is copied — the vector
    /// layer is shared by value.
    private func snapIndex(onPage pageID: PageID, excluding excluded: Set<MarkupID>) -> SnapIndex? {
        guard let index = snapIndexes[pageID] else { return nil }
        guard !excluded.isEmpty else { return index }
        // The presenters hand the same stored set on every pointer move, so this comparison is
        // the storage-identity fast path of `Set.==`, not a walk.
        if let cached = viewFilteredSnapIndexes[pageID], cached.requested == excluded {
            return cached.index
        }
        let onPage = excluded.filter { markups[$0]?.pageID == pageID }
        if let cached = viewFilteredSnapIndexes[pageID], cached.excludedOnPage == onPage {
            viewFilteredSnapIndexes[pageID] = ViewFilteredSnapIndex(requested: excluded, excludedOnPage: onPage, index: cached.index)
            return cached.index
        }
        var filtered = index
        let byUUID: (MarkupID, MarkupID) -> Bool = { $0.rawValue.uuidString < $1.rawValue.uuidString }
        for id in onPage.sorted(by: byUUID) {
            filtered.remove(markupID: id)
        }
        let parents = Set(onPage.compactMap { markups[$0]?.parentMarkupID }).subtracting(onPage)
        for parentID in parents.sorted(by: byUUID) {
            guard let parent = markups[parentID], parent.pageID == pageID else { continue }
            if let geometry = snapGeometry(of: parent, viewHidden: onPage),
               (try? filtered.upsert(markup: geometry)) != nil {
                continue
            }
            filtered.remove(markupID: parentID)
        }
        // Assigned to the cache, never to `snapIndexes`, so the `didSet` above does not clear it.
        viewFilteredSnapIndexes[pageID] = ViewFilteredSnapIndex(requested: excluded, excludedOnPage: onPage, index: filtered)
        return filtered
    }

    /// Makes every installed index's boundary layer hold the page's zones, regions and
    /// calibration points as they are now (U-086).
    private func refreshSnapBoundaries() {
        guard !snapIndexes.isEmpty else { return }
        let boundaries = snapBoundaries(onPages: Set(snapIndexes.keys))
        for pageID in snapIndexes.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            snapIndexes[pageID]?.replaceBoundaries(with: boundaries[pageID] ?? [])
        }
    }

    /// Resolves one pointer sample against a page's snap index.
    ///
    /// Mutating, because hysteresis and the `Tab` cycle are state the engine carries
    /// between events (spec 13.9); that state lives in the session so two canvases over
    /// the same document cannot fight over one cursor.
    public func resolveSnap(
        pageID: PageID,
        viewPoint: CGPoint,
        layout: PageViewLayout,
        modifiers: SnapModifiers = .none,
        anchorPagePoint: PDFPoint? = nil,
        activeLayerID: String? = nil,
        sequence: Int = 0,
        excludingMarkupIDs: Set<MarkupID> = []
    ) throws -> SnapResolution {
        // `excludingMarkupIDs`: markups the asking view does not draw although they are not
        // hidden — the ledger filter's Hide (V-003). They are no targets for this resolve, as a
        // hidden markup is none for any (T-072); see `snapIndex(onPage:excluding:)`.
        guard let index = snapIndex(onPage: pageID, excluding: excludingMarkupIDs) else {
            throw DocumentCommandError.unknownPage(pageID)
        }
        let query = SnapQuery(
            event: SnapPointerEvent(
                viewPoint: viewPoint,
                layout: layout,
                modifiers: modifiers,
                anchorPagePoint: anchorPagePoint,
                activeLayerID: activeLayerID,
                sequence: sequence
            ),
            settings: snapSettings
        )
        return try snapEngine.resolve(query, in: index)
    }

    /// Resolves a snap for a point given in **page space**.
    ///
    /// The overload the presenters use. Page space is the only coordinate system the
    /// presenter protocols speak, and turning it into the view point the snap engine wants
    /// needs the page's crop box — a page whose `/CropBox` starts at `(-20, -14)`, which is
    /// legal and common, is off by that much if the conversion is done by hand. So the
    /// conversion happens here, through the same `PageCoordinateConverter` the engine uses
    /// internally, and no call site can get it wrong.
    public func resolveSnap(
        pageID: PageID,
        pagePoint: PDFPoint,
        layout: PageViewLayout,
        modifiers: SnapModifiers = .none,
        anchorPagePoint: PDFPoint? = nil,
        activeLayerID: String? = nil,
        sequence: Int = 0,
        excludingMarkupIDs: Set<MarkupID> = []
    ) throws -> SnapResolution {
        guard let page = pages.first(where: { $0.id == pageID }) else {
            throw DocumentCommandError.unknownPage(pageID)
        }
        let converter = try PageCoordinateConverter(page: page, layout: layout)
        let viewPoint = try converter.pageToView(pagePoint)
        return try resolveSnap(
            pageID: pageID,
            viewPoint: viewPoint,
            layout: layout,
            modifiers: modifiers,
            anchorPagePoint: anchorPagePoint,
            activeLayerID: activeLayerID,
            sequence: sequence,
            excludingMarkupIDs: excludingMarkupIDs
        )
    }

    /// Feeds a discrete snap modifier — a `Tab`, an `Option` tap, an `Escape`.
    @discardableResult
    public func applySnapModifier(_ input: SnapModifierInput) -> SnapModifierEffect {
        snapEngine.apply(input)
    }

    /// Forgets held candidates and the cycle position. Called when a gesture ends.
    public func resetSnapState() { snapEngine.reset() }

    /// Replaces the snap settings and reports what is now enabled.
    public func setSnapSettings(_ settings: SnapSettings) throws {
        try settings.validate()
        snapSettings = settings
    }

    /// The snap settings in force.
    public var currentSnapSettings: SnapSettings { snapSettings }

    // MARK: Commands

    /// Applies one mutation and reports its exact inverse, together with the patch that
    /// reapplies it.
    ///
    /// Every path through this function either completes fully or throws before mutating,
    /// so a refused command leaves the document byte-identical to how it started. That is
    /// what makes an undo stack trustworthy: there is no half-applied entry on it.
    @discardableResult
    public func apply(_ command: DocumentCommand) throws -> DocumentCommandOutcome {
        let outcome = try applyMutation(command)
        // NL-QTY-10 (ADR-0025): live summaries on the sheet follow the change in the same step.
        var inverse = outcome.inverse
        var changed = outcome.changedMarkupIDs
        refreshLiveSummaries(inverse: &inverse, changed: &changed, commands: [command])
        refreshSnapMarkups(Set(inverse.markups.keys).union(changed), previous: inverse.markups)
        return DocumentCommandOutcome(
            command: outcome.command,
            inverse: inverse,
            forward: patch(matching: inverse),
            changedMarkupIDs: changed,
            changedPageIDs: outcome.changedPageIDs
        )
    }

    /// ``apply(_:)``, and when the command changed nothing a person can see, its `modifiedAt`
    /// bumps taken back **inside this same actor call**, answered with `nil` (BH-422, S-027).
    ///
    /// The bus used to take a no-op back with a second, separate `revert` call. A command
    /// performed in between reached the actor first, and the late revert then wrote the no-op's
    /// pre-image over that command's edit — with its undo entry and audit row still standing.
    /// No suspension point separates the apply from the revert here, so nothing can.
    public func apply(_ command: DocumentCommand, revertingNoOp: Bool) throws -> DocumentCommandOutcome? {
        let outcome = try apply(command)
        guard revertingNoOp, outcome.inverse.isNoOp(against: outcome.forward) else { return outcome }
        _ = try? revert(outcome.inverse)
        return nil
    }

    /// ``applyBatch(_:)`` with the same same-call no-op revert as ``apply(_:revertingNoOp:)`` (R-057, S-027).
    public func applyBatch(_ commands: [DocumentCommand], revertingNoOp: Bool) throws -> DocumentBatchOutcome? {
        let outcome = try applyBatch(commands)
        guard revertingNoOp, outcome.inverse.isNoOp(against: outcome.forward) else { return outcome }
        _ = try? revert(outcome.inverse)
        return nil
    }

    /// Writes a live summary's recomputed text (NL-QTY-10); see `LiveSummaryTable.swift`.
    func storeRefreshedSummary(_ record: MarkupRecord) { markups[record.id] = record }

    /// The session's clock, for the "As of" line of a live summary.
    var sessionNow: Date { clock() }

    /// Applies several commands as **one** user-visible step.
    ///
    /// The workflow this exists for is the ledger's bulk edit: eleven markups, four
    /// fields, and an estimator who expects exactly one Cmd-Z to take all of it back. A
    /// loop over ``apply(_:)`` would leave forty-four entries on the undo stack, so the
    /// batch merges the per-command patches instead:
    ///
    /// - the **inverse** keeps the *earliest* recorded state of every identifier, because
    ///   that is what the document looked like before the step began;
    /// - the **forward** is read once at the end over the same identifiers, so it is the
    ///   state after the last command rather than after whichever command touched the
    ///   markup first.
    ///
    /// Atomic, like ``apply(_:)``: a command that throws rolls the whole batch back and
    /// rethrows, so a refused bulk edit leaves the document and the undo stack exactly as
    /// they were. A half-applied bulk edit that the user then has to unpick by hand is the
    /// worst outcome available here, and it is the one this makes impossible.
    @discardableResult
    public func applyBatch(_ commands: [DocumentCommand]) throws -> DocumentBatchOutcome {
        var merged = DocumentCommandInverse()
        var changedMarkups: Set<MarkupID> = []
        var changedPages: Set<PageID> = []
        var applied: [DocumentCommand] = []
        applied.reserveCapacity(commands.count)

        for command in commands {
            do {
                let outcome = try applyMutation(command)
                for (id, record) in outcome.inverse.markups where merged.markups.index(forKey: id) == nil {
                    merged.markups[id] = record
                }
                if merged.markupOrder == nil { merged.markupOrder = outcome.inverse.markupOrder }
                // Every scale the batch touched, the first before-state of each winning — a bulk
                // scale apply is one `.changeScale` per page and one ⌘Z for all of them. Keeping
                // only the first scale undid one page of a bulk apply and left the rest.
                let seenScales = Set(merged.allScales.map(\.id)).union(merged.allRemovedScaleIDs)
                let newScales = outcome.inverse.allScales.filter { !seenScales.contains($0.id) }
                let newRemoved = outcome.inverse.allRemovedScaleIDs.filter { !seenScales.contains($0) }
                if !newScales.isEmpty || !newRemoved.isEmpty {
                    merged.setScales(merged.allScales + newScales, removed: merged.allRemovedScaleIDs + newRemoved)
                }
                if merged.pageScaleIDs == nil { merged.pageScaleIDs = outcome.inverse.pageScaleIDs }
                if merged.pageOrder == nil { merged.pageOrder = outcome.inverse.pageOrder }
                if merged.scaleRegions == nil { merged.scaleRegions = outcome.inverse.scaleRegions }
                if merged.projectZones == nil { merged.projectZones = outcome.inverse.projectZones }
                if merged.markupLayers == nil { merged.markupLayers = outcome.inverse.markupLayers }  // ADR-0032
                if merged.customColumns == nil { merged.customColumns = outcome.inverse.customColumns }
                if let zones = outcome.inverse.setAsideZones {   // V-038
                    var mergedZones = merged.setAsideZones ?? [:]
                    for (id, previous) in zones where mergedZones.index(forKey: id) == nil {
                        mergedZones.updateValue(previous, forKey: id)
                    }
                    merged.setAsideZones = mergedZones
                }
                if let identities = outcome.inverse.sheetIdentities {
                    var mergedIdentities = merged.sheetIdentities ?? [:]
                    for (page, previous) in identities where mergedIdentities.index(forKey: page) == nil {
                        mergedIdentities.updateValue(previous, forKey: page)
                    }
                    merged.sheetIdentities = mergedIdentities
                }
                if let views = outcome.inverse.pageViews {
                    var mergedViews = merged.pageViews ?? [:]
                    for (page, previous) in views where mergedViews.index(forKey: page) == nil {
                        mergedViews.updateValue(previous, forKey: page)
                    }
                    merged.pageViews = mergedViews
                }
                if let evidence = outcome.inverse.calibrationEvidence {
                    var mergedEvidence = merged.calibrationEvidence ?? [:]
                    for (scaleID, previous) in evidence where mergedEvidence.index(forKey: scaleID) == nil {
                        mergedEvidence.updateValue(previous, forKey: scaleID)
                    }
                    merged.calibrationEvidence = mergedEvidence
                }
                changedMarkups.formUnion(outcome.changedMarkupIDs)
                changedPages.formUnion(outcome.changedPageIDs)
                applied.append(command)
            } catch {
                // All or nothing. The rollback uses the same `revert` an undo does, so
                // there is no second restore path that could disagree with the first.
                if !merged.isEmpty { _ = try? revert(merged) }
                throw error
            }
        }

        // NL-QTY-10 (ADR-0025): once for the whole batch, inside the same undo step.
        refreshLiveSummaries(inverse: &merged, changed: &changedMarkups, commands: applied)
        refreshSnapMarkups(Set(merged.markups.keys).union(changedMarkups), previous: merged.markups)
        return DocumentBatchOutcome(
            commands: applied,
            inverse: merged,
            forward: patch(matching: merged),
            changedMarkupIDs: changedMarkups,
            changedPageIDs: changedPages
        )
    }

    /// The current state of exactly the identifiers an inverse mentions.
    ///
    /// The mirror image of an inverse: where the inverse says "these markups looked like
    /// this before", this says "they look like this now". Applying it through
    /// ``revert(_:)`` is a redo.
    func patch(matching inverse: DocumentCommandInverse) -> DocumentCommandInverse {
        var forward = DocumentCommandInverse()
        for id in inverse.markups.keys {
            forward.markups[id] = markups[id]
        }
        if inverse.markupOrder != nil {
            forward.markupOrder = markupOrder
        } else if !inverse.markups.isEmpty {
            // No whole-order snapshot, so the patch records where each markup it may have to
            // re-insert stands right now. Without this a redo appended the restored markups
            // in dictionary order (CR-6).
            let index = Dictionary(
                markupOrder.enumerated().map { ($1, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var positions: [MarkupID: Int] = [:]
            for id in inverse.markups.keys {
                if let position = index[id] { positions[id] = position }
            }
            if !positions.isEmpty { forward.markupPositions = positions }
        }
        var forwardScales: [ScaleTransform] = inverse.allScales.compactMap { scales[$0.id] }
        for removed in inverse.allRemovedScaleIDs {
            // The command installed a scale that did not exist before — the page's first
            // calibration. The redo patch is the scale that is now in force, and the page
            // assignment that now selects it.
            if let current = scales[removed] { forwardScales.append(current) }
            forward.pageScaleIDs = pageScaleIDs
        }
        if !forwardScales.isEmpty { forward.setScales(forwardScales, removed: []) }
        if inverse.pageScaleIDs != nil { forward.pageScaleIDs = pageScaleIDs }
        if inverse.pageOrder != nil { forward.pageOrder = pageOrder }
        if inverse.scaleRegions != nil { forward.scaleRegions = scaleRegionSet }
        if inverse.projectZones != nil { forward.projectZones = projectZoneSet }
        if inverse.markupLayers != nil { forward.markupLayers = markupLayerSet.layers }  // ADR-0032
        if inverse.customColumns != nil { forward.customColumns = customColumnDefinitions }
        if let zones = inverse.setAsideZones {
            forward.setAsideZones = currentSetAsideZones(of: zones.keys)
        }
        if let identities = inverse.sheetIdentities {
            var current: [PageID: SheetIdentity?] = [:]
            for page in identities.keys { current.updateValue(sheetIdentityTable[page], forKey: page) }
            forward.sheetIdentities = current
        }
        if let views = inverse.pageViews {
            var current: [PageID: PageViewSettings?] = [:]
            for page in views.keys { current.updateValue(pageViewTable[page], forKey: page) }
            forward.pageViews = current
        }
        if let evidence = inverse.calibrationEvidence {
            var current: [ScaleID: CalibrationEvidence?] = [:]
            for scaleID in evidence.keys {
                current.updateValue(calibrationEvidence[scaleID], forKey: scaleID)
            }
            forward.calibrationEvidence = current
        }
        return forward
    }

    /// One command, with the locked-layer rule applied to what it did (ADR-0032).
    private func applyMutation(_ command: DocumentCommand) throws -> DocumentCommandOutcome {
        let outcome = try applyMutationBody(command)
        try refuseLockedLayerChanges(outcome)
        return outcome
    }

    private func applyMutationBody(_ command: DocumentCommand) throws -> DocumentCommandOutcome {
        switch command {
        case .addMarkup(let record):
            return try applyAdd(record, command: command)
        case .removeMarkup(let id):
            return try applyRemove(id, command: command)
        case .moveMarkup(let id, let dx, let dy):
            return try applyMove(id, dx: dx, dy: dy, command: command)
        case .changeStyle(let id, let style):
            return try applyEdit(id, command: command) { $0.style = style }
        case .editVertices(let id, let geometry):
            return try applyEdit(id, command: command, recomputes: true) { $0.geometry = geometry }
        case .editParameters(let id, let parameters):
            // `recomputes: true` is the whole point: a depth is an input to the volume, so it
            // goes back through `recompute` — the same call `editVertices` makes and the same
            // one a scale change makes — rather than having a number written beside it.
            return try applyEdit(id, command: command, recomputes: true) { $0.parameters = parameters }
        case .changeScale(let scale):
            return try atomically { try applyScale(scale, command: command) }
        case .recalculateMeasurements(let pageID):
            return try atomically { try applyRecalculate(pageID: pageID, command: command) }
        case .addCutout(let parent, let cutout):
            return try applyCutout(parent: parent, cutout: cutout, command: command)
        case .editCustomValue(let id, let column, let value):
            return try applyEdit(id, command: command) { $0.customValues[column] = value }
        case .editSubject(let id, let subject):
            return try applyEdit(id, command: command) { $0.subject = subject }
        case .editLabel(let id, let label):
            return try applyEdit(id, command: command) { $0.label = label }
        case .editComment(let id, let comment):
            return try applyEdit(id, command: command) { $0.comment = comment }
        case .editText(let id, let text):
            // NL-COLLAB-18: only a kind that draws text has any; anything else is left alone.
            return try applyEdit(id, command: command) { record in
                guard MarkupVisibleText.carriesVisibleText(record) else { return }
                record.caption = text
            }
        case .rotateStamp(let id, let degrees):
            // Optional-chained on purpose: a record with no `StampInstance` is not a stamp, and
            // giving it one here would invent a placement nobody made. The command then edits
            // nothing, the inverse records the record unchanged, and undo is still exact.
            return try applyEdit(id, command: command) { $0.stamp?.rotationDegrees = degrees }
        case .batchStatusChange(let ids, let status):
            return try applyBatchStatus(ids, status: status, command: command)
        case .reorderPage(let from, let to):
            return try applyReorderPage(from: from, to: to, command: command)
        case .setSheetIdentities(let identities, let overwriteManual):
            return try applySetSheetIdentities(identities, overwriteManual: overwriteManual, command: command)
        case .insertPages(let inserted, let position):
            return try applyInsertPages(inserted, at: position, command: command)
        case .setPagesExcluded(let ids, let excluded):
            return try applySetPagesExcluded(ids, excluded: excluded, command: command)
        case .setPageViews(let views):
            return try applySetPageViews(views, command: command)
        case .setScaleRegions(let regions):
            return try atomically { try applySetScaleRegions(regions, command: command) }
        case .setProjectZones(let zones):
            return try applySetProjectZones(zones, command: command)
        case .setMarkupZone(let ids, let zoneID):
            return try applySetMarkupZone(ids, zoneID: zoneID, command: command)
        case .setMarkupScaleRegion(let ids, let regionID, let scaleID):
            return try atomically {
                try applySetMarkupScaleRegion(ids, regionID: regionID, scaleID: scaleID, command: command)
            }
        case .setCustomColumns(let definitions):
            let previous = customColumnDefinitions
            try replaceCustomColumns(definitions)
            return DocumentCommandOutcome(
                command: command,
                inverse: {
                    var inverse = DocumentCommandInverse()
                    inverse.customColumns = previous
                    return inverse
                }(),
                forward: .empty,
                changedMarkupIDs: [],
                changedPageIDs: []
            )
        case .addCustomColumns(let definitions):
            let previous = customColumnDefinitions
            try addCustomColumns(definitions)
            return DocumentCommandOutcome(
                command: command,
                inverse: {
                    var inverse = DocumentCommandInverse()
                    inverse.customColumns = previous
                    return inverse
                }(),
                forward: .empty,
                changedMarkupIDs: [],
                changedPageIDs: []
            )
        case .setLocked(let ids, let locked):
            return try applyFlag(ids, command: command) { record in
                guard record.locked != locked else { return false }
                record.locked = locked
                return true
            }
        case .setHidden(let ids, let hidden):
            // Hiding is an edit, and a locked markup refuses edits.
            for id in ids where markups[id]?.locked == true && markups[id]?.hidden != hidden {
                throw DocumentCommandError.markupLocked(id)
            }
            return try applyFlag(ids, command: command) { record in
                guard record.hidden != hidden else { return false }
                record.hidden = hidden
                return true
            }
        case .arrangeMarkups(let ids, let arrangement):
            return try applyArrange(ids, arrangement: arrangement, command: command)
        case .setMarkupGroup(let ids, let groupID):
            // Grouping is an edit, and a locked markup refuses edits.
            for id in ids where markups[id]?.locked == true && markups[id]?.groupID != groupID {
                throw DocumentCommandError.markupLocked(id)
            }
            return try applyFlag(ids, command: command) { record in
                guard record.groupID != groupID else { return false }
                record.groupID = groupID
                return true
            }
        case .setMarkupLink(let id, let link):
            return try applyEdit(id, command: command) { record in
                guard record.kind == .hyperlink else { return }
                record.link = link
            }
        // ADR-0032: markup layers; `Layers/TakeoffSession+MarkupLayers.swift`.
        case .setMarkupLayers(let layers, _):
            return try applySetMarkupLayers(layers, command: command)
        case .setMarkupLayer(let ids, let layerID):
            return try applySetMarkupLayer(ids, layerID: layerID, command: command)
        case .deleteMarkupLayer(let id, let target):
            return try applyDeleteMarkupLayer(id, moveTo: target, command: command)
        }
    }

    /// NL-MARKUP-13 (ADR-0029): reorders markups within their page. The markup order is the draw
    /// order; the inverse is the whole previous order, which `revert` already restores.
    private func applyArrange(
        _ ids: [MarkupID],
        arrangement: MarkupArrangement,
        command: DocumentCommand
    ) throws -> DocumentCommandOutcome {
        for id in ids where markups[id] == nil { throw DocumentCommandError.unknownMarkup(id) }
        let previous = markupOrder
        let moving = Set(ids)
        // ADR-0036 (the ADR-0032 addendum): draw order is the layer first, then the markup order
        // within it, so a markup is arranged among the markups of its own layer on its own page.
        // Across a layer boundary a step forward would change nothing anyone can see.
        struct ArrangeGroup: Hashable { let page: PageID; let layer: LayerID }
        let layers = markupLayerSet
        func group(of id: MarkupID) -> ArrangeGroup? {
            guard let record = markups[id] else { return nil }
            return ArrangeGroup(page: record.pageID, layer: layers.resolvedLayerID(of: record))
        }
        var groupsTouched: Set<ArrangeGroup> = []
        for id in ids { if let touched = group(of: id) { groupsTouched.insert(touched) } }
        let pagesTouched = Set(groupsTouched.map(\.page))
        var result = previous
        for touched in groupsTouched {
            // The group's own slots in the global order are refilled in the new order, so
            // markups on other pages and other layers never move.
            let slots = result.indices.filter { group(of: result[$0]) == touched }
            let reordered = arrangement.reorder(slots.map { result[$0] }, moving: moving)
            for (slot, id) in zip(slots, reordered) { result[slot] = id }
        }
        guard result != previous else {
            return DocumentCommandOutcome(
                command: command, inverse: .empty, forward: .empty,
                changedMarkupIDs: [], changedPageIDs: []
            )
        }
        markupOrder = result
        var inverse = DocumentCommandInverse()
        inverse.markupOrder = previous
        return DocumentCommandOutcome(
            command: command, inverse: inverse, forward: .empty,
            changedMarkupIDs: moving, changedPageIDs: pagesTouched
        )
    }

    /// A flag written across a selection: no recompute, one inverse entry per changed markup.
    /// Internal since ADR-0032, which moves markups between layers through it.
    func applyFlag(
        _ ids: [MarkupID],
        command: DocumentCommand,
        _ body: (inout MarkupRecord) -> Bool
    ) throws -> DocumentCommandOutcome {
        for id in ids where markups[id] == nil { throw DocumentCommandError.unknownMarkup(id) }
        var inverse = DocumentCommandInverse()
        var changed: Set<MarkupID> = []
        var pagesTouched: Set<PageID> = []
        let now = clock()
        for id in ids {
            guard var record = markups[id] else { continue }
            let before = record
            guard body(&record) else { continue }
            record.modifiedAt = now
            inverse.markups[id] = before
            markups[id] = record
            changed.insert(id)
            pagesTouched.insert(record.pageID)
        }
        return DocumentCommandOutcome(
            command: command, inverse: inverse, forward: .empty,
            changedMarkupIDs: changed, changedPageIDs: pagesTouched
        )
    }

    /// The runtime ledger columns — a table import's — in the order they were added.
    public var runtimeColumnDefinitions: [LedgerColumnDefinition] { customColumnDefinitions }

    /// The document state a command can touch, captured so a refusal part-way through a loop
    /// can put it all back.
    private struct DocumentState {
        let pageOrder: [PageID]
        let markups: MarkupTable
        let markupOrder: [MarkupID]
        let scales: [ScaleID: ScaleTransform]
        let pageScaleIDs: [PageID: ScaleID]
        let scaleRegionSet: [ScaleRegionDefinition]
        let projectZoneSet: [ProjectZoneDefinition]
        let names: ProjectNameTable
        let calibrationEvidence: [ScaleID: CalibrationEvidence]
    }

    /// Runs a command that mutates inside a loop of throwing recomputes, and restores the whole
    /// document if any of them throws.
    ///
    /// ``apply(_:)`` promises that a command either completes or throws before mutating. A
    /// rescale that recomputed markups one to n−1 and then met a markup the new scale refuses —
    /// a circle under a non-uniform region scale — left the scale installed and those markups
    /// restamped, with no undo registered because the command threw (BH-433). The capture is a
    /// copy-on-write reference until something is written, so a command that succeeds pays
    /// only for what it changes.
    private func atomically(
        _ body: () throws -> DocumentCommandOutcome
    ) throws -> DocumentCommandOutcome {
        let saved = DocumentState(
            pageOrder: pageOrder,
            markups: markups,
            markupOrder: markupOrder,
            scales: scales,
            pageScaleIDs: pageScaleIDs,
            scaleRegionSet: scaleRegionSet,
            projectZoneSet: projectZoneSet,
            names: names,
            calibrationEvidence: calibrationEvidence
        )
        do {
            return try body()
        } catch {
            pageOrder = saved.pageOrder
            markups = saved.markups
            markupOrder = saved.markupOrder
            scales = saved.scales
            pageScaleIDs = saved.pageScaleIDs
            scaleRegionSet = saved.scaleRegionSet
            projectZoneSet = saved.projectZoneSet
            names = saved.names
            calibrationEvidence = saved.calibrationEvidence
            throw error
        }
    }

    /// Reverts a command by restoring the exact state its inverse recorded.
    ///
    /// Returns a fresh inverse, so redo is the same mechanism running the other way and
    /// there is no second code path that could disagree with the first.
    @discardableResult
    public func revert(_ inverse: DocumentCommandInverse) throws -> DocumentCommandInverse {
        var redo = DocumentCommandInverse()
        var changedPages: Set<PageID> = []

        // Where each markup this patch removes stands, so the opposite patch can put it back
        // in place rather than at the end (CR-6). Read before anything moves.
        if inverse.markupOrder == nil, inverse.markups.values.contains(where: { $0 == nil }) {
            let index = Dictionary(
                markupOrder.enumerated().map { ($1, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var positions: [MarkupID: Int] = [:]
            for (id, restored) in inverse.markups where restored == nil {
                if let position = index[id] { positions[id] = position }
            }
            if !positions.isEmpty { redo.markupPositions = positions }
        }

        for (id, restored) in inverse.markups {
            redo.markups[id] = markups[id]
            if let existing = markups[id] { changedPages.insert(existing.pageID) }
            if let restored {
                markups[id] = restored
                changedPages.insert(restored.pageID)
            } else {
                markups.removeValue(forKey: id)
            }
        }

        if inverse.markupOrder != nil { redo.markupOrder = markupOrder }
        restoreMarkupOrder(from: inverse)

        if let evidence = inverse.calibrationEvidence {
            var current: [ScaleID: CalibrationEvidence?] = [:]
            for (scaleID, restored) in evidence {
                current.updateValue(calibrationEvidence[scaleID], forKey: scaleID)
                if let restored {
                    calibrationEvidence[scaleID] = restored
                } else {
                    calibrationEvidence.removeValue(forKey: scaleID)
                }
            }
            redo.calibrationEvidence = current
        }

        // Every scale the patch reinstates or removes — one for a calibration, one per page for
        // a bulk apply (NL-MEASURE-02). The single-scale rules are unchanged, applied per entry.
        let assignmentBefore = pageScaleIDs
        var redoScales: [ScaleTransform] = []
        var redoRemoved: [ScaleID] = []
        for scale in inverse.allScales {
            // Reinstating a scale that is not in the document — the redo of a page's first
            // calibration — must say how to remove it again, or reverting this redo restores the
            // page assignment and leaves the scale behind as an orphan that the next save writes
            // (BH-431).
            if let current = scales[scale.id] { redoScales.append(current) } else { redoRemoved.append(scale.id) }
            redo.pageScaleIDs = assignmentBefore
            scales[scale.id] = scale
            names.scales[scale.id] = ScaleBridge.ratioText(for: scale, userUnit: userUnit(onPage: scale.pageID), localeIdentifier: localeIdentifier)
        }
        for removed in inverse.allRemovedScaleIDs {
            // Undo of a page's first calibration: the scale is removed outright. The redo
            // patch carries the scale as it is now, so redoing reinstalls it through the
            // ordinary `scale` path above.
            if let current = scales[removed] { redoScales.append(current) }
            if redo.pageScaleIDs == nil { redo.pageScaleIDs = assignmentBefore }
            scales.removeValue(forKey: removed)
            names.scales.removeValue(forKey: removed)
            pageScaleIDs = pageScaleIDs.filter { $0.value != removed }
        }
        if !redoScales.isEmpty || !redoRemoved.isEmpty {
            redo.setScales(redoScales, removed: redoRemoved)
        }
        if let previousAssignment = inverse.pageScaleIDs {
            if redo.pageScaleIDs == nil { redo.pageScaleIDs = pageScaleIDs }
            pageScaleIDs = previousAssignment
        }

        if let order = inverse.pageOrder {
            redo.pageOrder = pageOrder
            pageOrder = order
            let unfiled = reindexPages()
            if !unfiled.isEmpty { redo.setAsideZones = unfiled.mapValues { Optional($0) } }
        }
        // After the sweep, so a markup this patch set aside again gets its filing back (V-038).
        if let zones = inverse.setAsideZones {
            var current = redo.setAsideZones ?? [:]
            for (id, zone) in zones {
                guard var entry = setAsideMarkups[id] else { continue }
                if current.index(forKey: id) == nil { current.updateValue(entry.record.zoneID, forKey: id) }
                entry.record.zoneID = zone
                setAsideMarkups[id] = entry
            }
            redo.setAsideZones = current
        }

        if let identities = inverse.sheetIdentities {
            var current: [PageID: SheetIdentity?] = [:]
            for (page, previous) in identities {
                current.updateValue(sheetIdentityTable[page], forKey: page)
                sheetIdentityTable[page] = previous
            }
            redo.sheetIdentities = current
            changedPages.formUnion(identities.keys)
        }

        if let views = inverse.pageViews {
            var current: [PageID: PageViewSettings?] = [:]
            for (page, previous) in views {
                current.updateValue(pageViewTable[page], forKey: page)
                pageViewTable[page] = previous
            }
            redo.pageViews = current
            changedPages.formUnion(views.keys)
        }

        if let regions = inverse.scaleRegions {
            redo.scaleRegions = scaleRegionSet
            scaleRegionSet = regions
        }
        if let zones = inverse.projectZones {
            redo.projectZones = projectZoneSet
            projectZoneSet = zones
        }
        if inverse.scaleRegions != nil || inverse.projectZones != nil {
            refreshStructureNames()
        }
        if let columns = inverse.customColumns {
            redo.customColumns = customColumnDefinitions
            let previous = customColumnDefinitions
            customColumnDefinitions = columns
            do {
                columnSet = try makeColumnSet(displayPolicy: units.domainPolicy)
            } catch {
                customColumnDefinitions = previous
                throw DocumentCommandError.ledgerFailed(String(describing: error))
            }
        }

        revertMarkupLayers(inverse, into: &redo)   // ADR-0032
        // An undone layer change restores no markup, so `inverse.markups` does not name the
        // markups it shows or hides again: every markup whose layer's visibility the revert
        // changed is refreshed too (T-072).
        var snapRefresh = Set(inverse.markups.keys)
        if inverse.markupLayers != nil, let replaced = redo.markupLayers {
            let before = MarkupLayerSet(replaced)
            for record in orderedMarkups where before.layer(of: record).visible != markupLayerSet.layer(of: record).visible {
                snapRefresh.insert(record.id)
            }
        }
        refreshSnapMarkups(snapRefresh, previous: redo.markups)
        _ = changedPages
        return redo
    }

    // MARK: Command implementations

    private func applyAdd(_ record: MarkupRecord, command: DocumentCommand) throws -> DocumentCommandOutcome {
        try refuseSetAsideIdentity(record.id)
        var stored = record
        stored.documentID = drawing(ofPage: stored.pageID)
        // ADR-0032: onto its own layer when the project holds it, else onto the active one.
        stored.layerID = storedLayerID(forAdded: record)
        stored.zoneID = heldZone(stored.zoneID)   // U-027
        try recompute(&stored)
        let previous = markups[record.id]
        markups[record.id] = stored
        if previous == nil { markupOrder.append(record.id) }
        return DocumentCommandOutcome(
            command: command,
            inverse: DocumentCommandInverse(
                markups: [record.id: previous],
                markupOrder: previous == nil ? nil : markupOrder
            ),
            forward: .empty,
            changedMarkupIDs: [record.id],
            changedPageIDs: [stored.pageID]
        )
    }

    /// `zoneID` when this project holds that Project Zone, else `nil` (U-027).
    ///
    /// Every whole record that enters the session comes through ``applyAdd(_:command:)`` or
    /// ``applyCutout(parent:cutout:command:)``: a paste from another project or from before the
    /// zone was deleted, a Combine Open Drawings carry, a review import. Such a record can name a
    /// zone this project does not hold, and `markup.zone_id` is a foreign key checked when the
    /// save commits, so one such markup failed every later save and autosave. It arrives
    /// unfiled instead, as ``applySetMarkupZone(_:zoneID:command:)`` would refuse to file it.
    func heldZone(_ zoneID: ZoneID?) -> ZoneID? {
        guard let zoneID, projectZoneSet.contains(where: { $0.id == zoneID }) else { return nil }
        return zoneID
    }

    /// Refuses a new markup whose identity is set aside with a sheet removed from the set.
    ///
    /// That markup is still this document's (NL-DOCS-07). An add under its id put a second copy
    /// live on the removed sheet: the save wrote the id twice (`markups + setAsideMarkups` in
    /// ``foldingArrangement()``), and restoring the sheet inserted it into the markup order a
    /// second time, so the ledger listed it twice (T-020).
    private func refuseSetAsideIdentity(_ id: MarkupID) throws {
        guard setAsideMarkups[id] == nil else {
            // Words, not the markup's identifier: the detail reaches the tray (L-102).
            throw DocumentCommandError.measurementFailed(NSLocalizedString(
                "This markup is on a sheet removed from the set. Restore the sheet to change it.",
                comment: "Refusal sentence: a change to a markup set aside with a removed sheet"
            ))
        }
    }

    private func applyRemove(_ id: MarkupID, command: DocumentCommand) throws -> DocumentCommandOutcome {
        guard let record = markups[id] else { throw DocumentCommandError.unknownMarkup(id) }
        guard !record.locked else { throw DocumentCommandError.markupLocked(id) }
        // Removing a cutout rewrites its parent's net area, and a locked parent is not
        // rewritten through the back door (CR-19). Checked before anything mutates, so the
        // refusal leaves the document untouched like every other refusal here.
        if let parentID = record.parentMarkupID, let parent = markups[parentID], parent.locked {
            throw DocumentCommandError.markupLocked(parentID)
        }

        // A cutout has no meaning without its parent, so deleting a parent deletes them —
        // and the inverse has to bring all of them back, which is exactly why undo is a
        // state patch and not an opposing command.
        var removed: [MarkupID] = [id]
        removed.append(contentsOf: record.cutoutMarkupIDs.filter { markups[$0] != nil })

        var inverse = DocumentCommandInverse(markupOrder: markupOrder)
        var pagesTouched: Set<PageID> = []
        for removedID in removed {
            inverse.markups[removedID] = markups[removedID]
            if let doomed = markups[removedID] { pagesTouched.insert(doomed.pageID) }
            markups.removeValue(forKey: removedID)
        }

        // A removed cutout changes its parent's net area, so the parent is restored too.
        if let parentID = record.parentMarkupID, var parent = markups[parentID] {
            inverse.markups[parentID] = parent
            parent.cutoutMarkupIDs.removeAll { $0 == id }
            do {
                try recompute(&parent)
            } catch {
                // All or nothing: the removed records go back before the refusal travels.
                for (removedID, previous) in inverse.markups { markups[removedID] = previous }
                throw error
            }
            markups[parentID] = parent
            pagesTouched.insert(parent.pageID)
        }

        let doomedSet = Set(removed)
        markupOrder.removeAll { doomedSet.contains($0) }

        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: doomedSet.union(record.parentMarkupID.map { [$0] } ?? []),
            changedPageIDs: pagesTouched
        )
    }

    private func applyMove(
        _ id: MarkupID,
        dx: Double,
        dy: Double,
        command: DocumentCommand
    ) throws -> DocumentCommandOutcome {
        guard let original = markups[id] else { throw DocumentCommandError.unknownMarkup(id) }
        let cutoutIDs = original.cutoutMarkupIDs.filter { markups[$0] != nil }
        guard !cutoutIDs.isEmpty else {
            return try applyEdit(id, command: command, recomputes: true) { record in
                guard let geometry = record.geometry else { return }
                record.geometry = MarkupVertexEditing.translating(geometry, dx: dx, dy: dy)
            }
        }
        // A parent carries its cutouts. The holes are derived from the cutout records, so moving
        // only the parent's outer ring rebuilt the holes at the *old* position: a small move
        // clipped the hole to the overlap and inflated the net area while the cutout row kept
        // its value, and a larger one was refused as `cutoutOutsideParent` (BH-008).
        guard !original.locked else { throw DocumentCommandError.markupLocked(id) }
        for cutoutID in cutoutIDs where markups[cutoutID]?.locked == true {
            throw DocumentCommandError.markupLocked(cutoutID)
        }
        var previous: [MarkupID: MarkupRecord] = [:]
        var moved: [MarkupID: MarkupRecord] = [:]
        let now = clock()
        for cutoutID in cutoutIDs {
            guard var cutout = markups[cutoutID] else { continue }
            previous[cutoutID] = cutout
            if let geometry = cutout.geometry { cutout.geometry = MarkupVertexEditing.translating(geometry, dx: dx, dy: dy) }
            cutout.modifiedAt = now
            try recompute(&cutout)
            moved[cutoutID] = cutout
        }
        for (cutoutID, cutout) in moved { markups[cutoutID] = cutout }
        do {
            let outcome = try applyEdit(id, command: command, recomputes: true) { record in
                guard let geometry = record.geometry else { return }
                record.geometry = MarkupVertexEditing.translating(geometry, dx: dx, dy: dy)
            }
            var inverse = outcome.inverse
            for (cutoutID, record) in previous { inverse.markups[cutoutID] = record }
            return DocumentCommandOutcome(
                command: command,
                inverse: inverse,
                forward: .empty,
                changedMarkupIDs: outcome.changedMarkupIDs.union(cutoutIDs),
                changedPageIDs: outcome.changedPageIDs
            )
        } catch {
            for (cutoutID, record) in previous { markups[cutoutID] = record }
            throw error
        }
    }

    private func applyEdit(
        _ id: MarkupID,
        command: DocumentCommand,
        recomputes: Bool = false,
        _ body: (inout MarkupRecord) -> Void
    ) throws -> DocumentCommandOutcome {
        guard let original = markups[id] else { throw DocumentCommandError.unknownMarkup(id) }
        guard !original.locked else { throw DocumentCommandError.markupLocked(id) }
        // A recomputing edit of a cutout — its vertices, a move — rewrites the parent's net
        // area. A locked parent refuses that exactly as it refuses a direct edit (CR-19).
        if recomputes, let parentID = original.parentMarkupID,
           let parent = markups[parentID], parent.locked {
            throw DocumentCommandError.markupLocked(parentID)
        }
        var edited = original
        body(&edited)
        edited.modifiedAt = clock()
        if recomputes { try recompute(&edited) }
        markups[id] = edited

        var changed: Set<MarkupID> = [id]
        var inverse = DocumentCommandInverse(markups: [id: original])

        // Editing a cutout changes its parent's net area. The parent's previous state goes
        // on the inverse too, so undoing the cutout edit restores the parent's number as
        // well as the cutout's shape.
        if recomputes, let parentID = edited.parentMarkupID, var parent = markups[parentID] {
            inverse.markups[parentID] = parent
            do {
                try recompute(&parent)
            } catch {
                // The parent's holes are derived from this cutout, so the engine can now
                // refuse the *parent* for a cutout moved wholly off it (ADR-0015). The
                // cutout's own edit is taken back first, so the refusal leaves the document
                // exactly as it was.
                markups[id] = original
                throw error
            }
            markups[parentID] = parent
            changed.insert(parentID)
        }

        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: changed,
            changedPageIDs: [edited.pageID]
        )
    }

    private func applyScale(_ scale: ScaleTransform, command: DocumentCommand) throws -> DocumentCommandOutcome {
        // A scale reaches the document only with a page, and only with a page this document
        // holds. Parking a page-less scale on sheet one is the guess this whole item exists to
        // remove; refusing it is the honest answer, and it happens before anything mutates.
        guard let page = scale.pageID else { throw DocumentCommandError.scaleHasNoPage(scale.id) }
        guard pageOrder.contains(page) else { throw DocumentCommandError.unknownPage(page) }
        if let existing = scales[scale.id], existing.pageID != page {
            throw DocumentCommandError.scaleBelongsToAnotherPage(scale: scale.id, page: page)
        }

        var inverse = DocumentCommandInverse(
            scale: scales[scale.id],
            pageScaleIDs: pageScaleIDs,
            // A brand-new scale — this page's first calibration, usually — has no
            // before-state to reinstate, so its inverse is the *removal* of the scale.
            // Without this the inverse is empty, no undo is registered, and the first
            // calibration cannot be taken back (CORE_LOOP, "one ⌘Z returns to the
            // previous scale").
            removedScaleID: scales[scale.id] == nil ? scale.id : nil
        )
        scales[scale.id] = scale
        names.scales[scale.id] = ScaleBridge.ratioText(for: scale, userUnit: userUnit(onPage: scale.pageID), localeIdentifier: localeIdentifier)
        // Only when the page has none. A Scale Region's own calibration installs a *second*
        // scale on a page that already has one, and promoting it to the page scale would move
        // the whole sheet onto the detail's ratio.
        if pageScaleIDs[page] == nil { pageScaleIDs[page] = scale.id }

        // Every measurement taken under an older version of this scale is now wrong. It is
        // restamped here rather than marked stale, because a takeoff that shows an old
        // number next to a new scale is worse than one that recomputes. Scoped to the scale's
        // own page: a markup on another sheet cannot resolve to this scale, so recomputing it
        // would be recomputing it against a transform it never used.
        var changed: Set<MarkupID> = []
        var pagesTouched: Set<PageID> = []
        // Keep existing values (NL-MEASURE-03, ADR-0030 §2): the person chose to leave the
        // numbers measured under the old version as they are. Each keeps its value and its old
        // `scaleVersion`, and is flagged stale so the ledger and the Inspector can say so.
        let keepsValues = keepExistingForScales.remove(scale.id) != nil
        for id in markupOrder {
            guard var record = markups[id], record.pageID == page else { continue }
            guard record.tool != nil, record.geometry != nil else { continue }
            let effective = self.scale(onPage: record.pageID, scaleID: record.scaleID)
            guard effective?.id == scale.id else { continue }
            guard record.isMeasurementStale(against: scale) || record.measurement == nil else { continue }
            if keepsValues, let kept = record.measurement {
                guard let flagged = Self.flaggingStale(kept, current: scale, tool: record.tool) else { continue }
                inverse.markups[id] = record
                record.measurement = flagged
                markups[id] = record
                changed.insert(id)
                pagesTouched.insert(record.pageID)
                continue
            }
            inverse.markups[id] = record
            try recompute(&record)
            markups[id] = record
            changed.insert(id)
            pagesTouched.insert(record.pageID)
        }

        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: changed,
            changedPageIDs: pagesTouched
        )
    }

    private func applyRecalculate(pageID: PageID?, command: DocumentCommand) throws -> DocumentCommandOutcome {
        var inverse = DocumentCommandInverse()
        var changed: Set<MarkupID> = []
        var pagesTouched: Set<PageID> = []
        for id in markupOrder {
            guard var record = markups[id] else { continue }
            if let pageID, record.pageID != pageID { continue }
            guard record.tool != nil, record.geometry != nil else { continue }
            let before = record
            try recompute(&record)
            guard Self.ignoringComputedAt(record) != Self.ignoringComputedAt(before) else { continue }
            inverse.markups[id] = before
            markups[id] = record
            changed.insert(id)
            pagesTouched.insert(record.pageID)
        }
        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: changed,
            changedPageIDs: pagesTouched
        )
    }

    private func applyCutout(
        parent parentID: MarkupID,
        cutout: MarkupRecord,
        command: DocumentCommand
    ) throws -> DocumentCommandOutcome {
        guard var parent = markups[parentID] else { throw DocumentCommandError.unknownMarkup(parentID) }
        guard !parent.locked else { throw DocumentCommandError.markupLocked(parentID) }
        // A cutout cannot be its own parent. The inverse below is a two-key dictionary literal,
        // which traps at run time on a duplicate key, so this used to abort the process instead
        // of refusing the command like every other bad input (BH-434).
        guard cutout.id != parentID else {
            throw DocumentCommandError.measurementFailed("a cutout cannot be its own parent")
        }
        try refuseSetAsideIdentity(cutout.id)

        var stored = cutout
        stored.documentID = drawing(ofPage: parent.pageID)
        stored.parentMarkupID = parentID
        stored.pageID = parent.pageID
        stored.scaleID = parent.scaleID
        stored.scaleRegionID = parent.scaleRegionID
        stored.layerID = parent.layerID   // ADR-0032: a hole shows, locks and prints with its outline
        stored.zoneID = heldZone(stored.zoneID)   // U-027
        try recompute(&stored)

        let inverse = DocumentCommandInverse(
            markups: [stored.id: markups[stored.id], parentID: parent],
            markupOrder: markupOrder
        )

        let previousCutout = markups[stored.id]
        let previousOrder = markupOrder
        markups[stored.id] = stored
        if !markupOrder.contains(stored.id) { markupOrder.append(stored.id) }

        // The parent names the cutout, and `recompute` derives its holes from the cutouts it
        // names: the engine then subtracts them through the same `CutoutSolver` path a polygon
        // with holes takes — there is no second "subtract a cutout" arithmetic anywhere, and
        // there is no merged ring left behind in the parent's own geometry either (CR-1).
        if !parent.cutoutMarkupIDs.contains(stored.id) {
            parent.cutoutMarkupIDs.append(stored.id)
        }
        parent.modifiedAt = clock()
        do {
            try recompute(&parent)
        } catch {
            // A cutout the engine refuses on its parent (wholly outside it, ADR-0015) is not
            // left behind as an orphan polygon that subtracts nothing.
            markups[stored.id] = previousCutout
            markupOrder = previousOrder
            throw error
        }
        markups[parentID] = parent

        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: [stored.id, parentID],
            changedPageIDs: [parent.pageID]
        )
    }

    private func applyBatchStatus(
        _ ids: [MarkupID],
        status: Domain.Status,
        command: DocumentCommand
    ) throws -> DocumentCommandOutcome {
        for id in ids where markups[id] == nil {
            throw DocumentCommandError.unknownMarkup(id)
        }
        // A locked markup refuses a status change as it refuses every other edit (BH-435).
        for id in ids {
            if let record = markups[id], record.locked, record.status != status {
                throw DocumentCommandError.markupLocked(id)
            }
        }
        var inverse = DocumentCommandInverse()
        var changed: Set<MarkupID> = []
        var pagesTouched: Set<PageID> = []
        let now = clock()
        for id in ids {
            guard var record = markups[id], record.status != status else { continue }
            inverse.markups[id] = record
            record.status = status
            record.modifiedAt = now
            markups[id] = record
            changed.insert(id)
            pagesTouched.insert(record.pageID)
        }
        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: changed,
            changedPageIDs: pagesTouched
        )
    }

    private func applyReorderPage(from: Int, to: Int, command: DocumentCommand) throws -> DocumentCommandOutcome {
        guard pageOrder.indices.contains(from) else { throw DocumentCommandError.pageIndexOutOfRange(from) }
        guard to >= 0, to < pageOrder.count else { throw DocumentCommandError.pageIndexOutOfRange(to) }
        var inverse = DocumentCommandInverse(pageOrder: pageOrder)
        let moved = pageOrder.remove(at: from)
        pageOrder.insert(moved, at: to)
        inverse.recordUnfiledOnReturn(reindexPages())
        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: [],
            changedPageIDs: Set(pageOrder)
        )
    }

    // MARK: Recomputation

    /// Recomputes a markup's measurement from its geometry, tool, parameters and scale.
    ///
    /// The one place a `MeasurementResult` is written onto a record. A markup without a
    /// tool or without geometry keeps whatever it has — a text note has no quantity, and
    /// giving it an empty one would put a zero in a total.
    private func recompute(_ record: inout MarkupRecord) throws {
        do {
            try measure(&record)
        } catch {
            throw DocumentCommandError.measurementFailed(UserFacingRefusal.sessionDetail(for: error))
        }
    }

    /// The rings a record's cutouts carve out of it, each with the cutout that owns it, in
    /// `polygons[0].holes` order — so the engine's `cutoutOutsideParent(cutoutIndex:)` can be
    /// traced back to the markup that drew the hole.
    private func holeRings(for record: MarkupRecord) -> [(ring: PolygonRing, owner: MarkupID)] {
        record.cutoutMarkupIDs.flatMap { id -> [(ring: PolygonRing, owner: MarkupID)] in
            guard let cutout = markups[id] else { return [] }
            return Self.cutoutRings(of: cutout.geometry, tool: cutout.tool).map { (ring: $0, owner: id) }
        }
    }

    /// Recomputes a record, rethrowing the engine's own error untranslated.
    private func measure(_ record: inout MarkupRecord) throws {
        guard let tool = record.tool, var stored = record.geometry else { return }
        // X-042 (cycle 2): an Arc Length whose doubled click the engine collapses is kept as the
        // three points it measures, so it is drawn and snapped as that arc rather than as chords
        // (`drawnPointChain` draws an arc for exactly three points). Four distinct points are
        // left as they are, for the engine to refuse.
        if tool == .arcLength { stored = ArcLengthCalculator.measuredGeometry(stored) }
        // The holes are rebuilt from the cutouts the record names *now* — see
        // `rebuildingHoles(in:with:)` for why they are derived rather than kept. A cutout that
        // is named but no longer stored contributes nothing, which is how a deleted cutout
        // gives its area back.
        let geometry = Self.rebuildingHoles(in: stored, with: holeRings(for: record).map(\.ring))
        record.geometry = geometry
        // Resolved against the markup's **own page**. A sibling page's calibration cannot reach
        // it: `scale(onPage:scaleID:)` has no document-wide rung, and a `scaleID` naming a scale
        // that belongs to another page is dropped rather than honoured.
        guard let scale = scale(onPage: record.pageID, scaleID: record.scaleID) else {
            // No scale on this page: the geometry is stored, the number is not invented. The row
            // shows the missing-scale warning rather than a plausible wrong figure.
            // ADR-0031: a detector's capture stamp is set aside until the page is calibrated,
            // for as long as the geometry is the one it describes. A geometry that no longer
            // matches does not erase it: an undo restores the old record as a state patch, with
            // no recompute, and the stamp has to be there for it (S-034). Both readers check the
            // digest, so a stamp kept past a move never answers for the moved geometry.
            if let kept = CaptureMethodCarry.setAside(
                record.measurement?.provenance ?? uncalibratedCaptures[record.id], geometry: geometry) {
                uncalibratedCaptures[record.id] = kept
            }
            record.measurement = nil
            record.scaleVersion = nil
            return
        }
        // Through the provenance-recording engine, so every stored value carries the
        // derivation it was computed from — including `scalePageID`, which is what lets the
        // disclosure say which sheet the scale was calibrated on rather than only its ratio.
        // Read, not removed: see `setAsideCapture(of:)` (R-058). The carry below checks the digest.
        let previous = record.measurement?.provenance ?? uncalibratedCaptures[record.id]
        record.measurement = try recorder(for: scale).calculate(
            tool: tool,
            geometry: geometry,
            scale: scale,
            parameters: record.parameters ?? .default
        )
        // ADR-0031 (NL-AUTO-18): how the geometry was captured describes the
        // geometry, not the calculation — kept while the geometry is the one it describes.
        if let result = record.measurement,
           let carried = CaptureMethodCarry.carried(previous: previous, into: result.provenance) {
            record.measurement = result.attaching(carried)
        }
        record.scaleID = scale.id
        record.scaleVersion = scale.version
    }

    /// A cutout that was detached from its parent on open because it lay wholly outside it.
    public struct CutoutDetachment: Hashable, Sendable {
        /// The cutout, still in the document as a plain polygon.
        public let cutoutID: MarkupID
        /// The parent it no longer subtracts from.
        public let parentID: MarkupID
        /// The parent's subject and label, for the sentence the tray shows.
        public let parentSubject: String
        public let parentLabel: String
    }

    /// Repairs recorded by the last ``hydrate(markups:scales:pageScaleIDs:calibrationEvidence:scaleRegions:projectZones:)``,
    /// waiting for a presenter to say them; drained by ``takeHydrationRepairs()``.
    private var hydrationRepairs: [CutoutDetachment] = []

    /// The repairs the last open made, once. The environment posts them to the warning tray.
    public func takeHydrationRepairs() -> [CutoutDetachment] {
        defer { hydrationRepairs = [] }
        return hydrationRepairs
    }

    /// Recomputes a stored record on open, **repairing** a cutout the engine refuses as lying
    /// wholly outside its parent instead of refusing the document.
    ///
    /// ADR-0015 turned that cutout from a warning into a refusal — right for a cutout being
    /// drawn, wrong for one already saved: a project written before the ADR could carry one,
    /// and a file that opened yesterday must open today. The offending cutout is detached from
    /// the parent's `cutoutMarkupIDs`, the parent is measured again without it, and the caller
    /// reports it. The loop handles several such cutouts on one parent one at a time, because
    /// the engine names one index per refusal. Any other refusal is still the damaged-file
    /// error it always was.
    private func hydrateRecompute(_ record: inout MarkupRecord) throws -> [MarkupID] {
        var detached: [MarkupID] = []
        while true {
            let owners = holeRings(for: record).map(\.owner)
            do {
                try measure(&record)
                return detached
            } catch MeasurementEngineError.measurement(.cutoutOutsideParent(let index)) {
                guard owners.indices.contains(index) else {
                    throw DocumentCommandError.measurementFailed(NSLocalizedString(
                        "A saved cutout lies outside its area and matches none of the area's cutouts.",
                        comment: "Refusal sentence: a damaged project whose stored cutout cannot be repaired on open"
                    ))
                }
                let culprit = owners[index]
                record.cutoutMarkupIDs.removeAll { $0 == culprit }
                detached.append(culprit)
            } catch {
                throw DocumentCommandError.measurementFailed(UserFacingRefusal.sessionDetail(for: error))
            }
        }
    }

    // MARK: Project structure (Scale Regions and Project Zones)

    /// Replaces the Scale Region set and repairs every markup that pointed into it.
    ///
    /// Two things happen after the swap, in this order and for two different reasons:
    ///
    /// 1. A markup whose region no longer exists loses its `scaleRegionID` — otherwise the
    ///    next save writes a foreign key with no parent row and fails at the transaction.
    /// 2. A markup whose region survives is stamped with that region's *current* scale and
    ///    recomputed. Reassigning a region's scale and leaving the numbers that were measured
    ///    under the old one is precisely the silent wrongness this whole feature exists to
    ///    prevent, so the recomputation is not optional and its failure is not swallowed.
    private func applySetScaleRegions(
        _ regions: [ScaleRegionDefinition],
        command: DocumentCommand
    ) throws -> DocumentCommandOutcome {
        for region in regions {
            guard let scale = scales[region.scaleID] else {
                // The region's name, never the scale's identifier: the detail reaches the Scale
                // Regions panel and the tray (L-102).
                throw DocumentCommandError.measurementFailed(String(
                    format: NSLocalizedString(
                        "The Scale Region “%@” uses a scale this document no longer holds. Choose one of the sheet's scales for it.",
                        comment: "Refusal sentence: a Scale Region names a scale that is not in the document; the placeholder is the region's name"
                    ),
                    region.name
                ))
            }
            // A region on one sheet may not carry a scale calibrated on another. The
            // resolution would drop it anyway — `scale(onPage:scaleID:)` refuses a foreign
            // page's scale — and the region would then quietly measure at the page's own
            // ratio while its panel row claimed the detail's. Refusing here is what keeps the
            // number and the provenance the same statement.
            guard scale.pageID == region.pageID else {
                throw DocumentCommandError.scaleBelongsToAnotherPage(
                    scale: region.scaleID, page: region.pageID
                )
            }
        }
        var inverse = DocumentCommandInverse(scaleRegions: scaleRegionSet)
        let live = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) })
        let previous = scaleRegionSet
        scaleRegionSet = regions

        var changed: Set<MarkupID> = []
        var pagesTouched: Set<PageID> = []
        let now = clock()
        for id in markupOrder {
            guard var record = markups[id], let regionID = record.scaleRegionID else { continue }
            let region = live[regionID]
            let wantedScaleID = region?.scaleID
            let clears = region == nil
            guard clears || record.scaleID != wantedScaleID else { continue }
            inverse.markups[id] = record
            record.scaleRegionID = clears ? nil : regionID
            record.scaleID = clears ? nil : wantedScaleID
            record.modifiedAt = now
            do {
                try recompute(&record)
            } catch {
                scaleRegionSet = previous
                throw error
            }
            markups[id] = record
            changed.insert(id)
            pagesTouched.insert(record.pageID)
        }
        refreshStructureNames()
        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: changed,
            changedPageIDs: pagesTouched
        )
    }

    /// Replaces the Project Zone set and unfiles every markup whose zone is gone.
    ///
    /// Zones never touch a measurement, so nothing is recomputed here. The dangling-reference
    /// cleanup is the same foreign-key obligation `markup.zone_id` carries.
    private func applySetProjectZones(
        _ zones: [ProjectZoneDefinition],
        command: DocumentCommand
    ) throws -> DocumentCommandOutcome {
        var inverse = DocumentCommandInverse(projectZones: projectZoneSet)
        projectZoneSet = zones
        let live = Set(zones.map(\.id))

        var changed: Set<MarkupID> = []
        var pagesTouched: Set<PageID> = []
        let now = clock()
        for id in markupOrder {
            guard var record = markups[id], let zoneID = record.zoneID, !live.contains(zoneID)
            else { continue }
            inverse.markups[id] = record
            record.zoneID = nil
            record.modifiedAt = now
            markups[id] = record
            changed.insert(id)
            pagesTouched.insert(record.pageID)
        }
        refreshStructureNames()
        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: changed,
            changedPageIDs: pagesTouched
        )
    }

    /// Files markups into a zone, or out of every zone when `zoneID` is `nil`.
    private func applySetMarkupZone(
        _ ids: [MarkupID],
        zoneID: ZoneID?,
        command: DocumentCommand
    ) throws -> DocumentCommandOutcome {
        for id in ids where markups[id] == nil {
            throw DocumentCommandError.unknownMarkup(id)
        }
        if let zoneID, !projectZoneSet.contains(where: { $0.id == zoneID }) {
            throw DocumentCommandError.ledgerFailed("no Project Zone \(zoneID.rawValue)")
        }
        // Locked markups are not re-filed through the back door (BH-435).
        for id in ids {
            if let record = markups[id], record.locked, record.zoneID != zoneID {
                throw DocumentCommandError.markupLocked(id)
            }
        }
        var inverse = DocumentCommandInverse()
        var changed: Set<MarkupID> = []
        var pagesTouched: Set<PageID> = []
        let now = clock()
        for id in ids {
            guard var record = markups[id], record.zoneID != zoneID else { continue }
            inverse.markups[id] = record
            record.zoneID = zoneID
            record.modifiedAt = now
            markups[id] = record
            changed.insert(id)
            pagesTouched.insert(record.pageID)
        }
        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: changed,
            changedPageIDs: pagesTouched
        )
    }

    /// Assigns markups to a Scale Region and to the scale that region carries.
    ///
    /// Both identifiers are written together, and the measurement is recomputed, because a
    /// markup that names a region but keeps the page scale is a row whose provenance and whose
    /// number disagree.
    private func applySetMarkupScaleRegion(
        _ ids: [MarkupID],
        regionID: ScaleRegionID?,
        scaleID: ScaleID?,
        command: DocumentCommand
    ) throws -> DocumentCommandOutcome {
        for id in ids where markups[id] == nil {
            throw DocumentCommandError.unknownMarkup(id)
        }
        var effectiveScaleID = scaleID
        if let regionID {
            guard let region = scaleRegionSet.first(where: { $0.id == regionID }) else {
                throw DocumentCommandError.measurementFailed(NSLocalizedString(
                    "That Scale Region is no longer on the sheet.",
                    comment: "Refusal sentence: assigning markups to a Scale Region that was deleted"
                ))
            }
            effectiveScaleID = scaleID ?? region.scaleID
        }
        if let effectiveScaleID {
            guard let scale = scales[effectiveScaleID] else {
                throw DocumentCommandError.measurementFailed(NSLocalizedString(
                    "That scale is no longer in this document. Choose one of the sheet's scales.",
                    comment: "Refusal sentence: assigning markups to a scale that is not in the document"
                ))
            }
            // Every named markup must be on the scale's page. Assigning a sheet's markup to a
            // scale from another sheet is the cross-page leak wearing a Scale Region's clothes.
            for id in ids {
                guard let record = markups[id], record.pageID != scale.pageID else { continue }
                throw DocumentCommandError.scaleBelongsToAnotherPage(
                    scale: effectiveScaleID, page: record.pageID
                )
            }
        }
        // A locked markup's scale and measured value are not rewritten: `editVertices` and
        // `editSubject` refuse it, and assigning it to a region is a bigger change than either
        // (BH-435).
        for id in ids {
            guard let record = markups[id], record.locked else { continue }
            if record.scaleRegionID != regionID || record.scaleID != effectiveScaleID {
                throw DocumentCommandError.markupLocked(id)
            }
        }
        var inverse = DocumentCommandInverse()
        var changed: Set<MarkupID> = []
        var pagesTouched: Set<PageID> = []
        let now = clock()
        for id in ids {
            guard var record = markups[id] else { continue }
            guard record.scaleRegionID != regionID || record.scaleID != effectiveScaleID else { continue }
            inverse.markups[id] = record
            record.scaleRegionID = regionID
            record.scaleID = effectiveScaleID
            record.modifiedAt = now
            try recompute(&record)
            markups[id] = record
            changed.insert(id)
            pagesTouched.insert(record.pageID)
        }
        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: changed,
            changedPageIDs: pagesTouched
        )
    }

    /// Re-publishes the zone and Scale Region names the ledger groups and labels by.
    ///
    /// The Quantity Ledger has resolved `record.zoneID` through `names.zones` since it was
    /// written; until a zone could be created it looked up a table nothing ever filled. This
    /// one line is the other half of "group the ledger by Project Zone".
    private func refreshStructureNames() {
        names.zones = Dictionary(uniqueKeysWithValues: projectZoneSet.map { ($0.id, $0.name) })
        names.scaleRegions = Dictionary(
            uniqueKeysWithValues: scaleRegionSet.map { ($0.id, $0.name) }
        )
    }

    /// Rewrites page indices after a reorder, so a page label and a page index never drift
    /// apart (`PDFDocumentProviding` rule 5).
    /// Brings `pages` and the ledger's page positions into ``pageOrder``.
    ///
    /// A page's `index` is **not** rewritten (ADR-0022, NL-DOCS-02): it is the page's index in
    /// its own PDF, which is what the canvas rasterises, text and vector extraction read, and
    /// the archive re-binds stored page identities by. Rewriting it on reorder rendered the
    /// wrong PDF page under a sheet's markups and, after a reopen, gave the sheets each other's
    /// identities. The set position is the place in ``pageOrder``.
    ///
    /// - Returns: the zone each returning markup was unfiled from (``sweepSetAsideMarkups()``).
    @discardableResult
    private func reindexPages() -> [MarkupID: ZoneID] {
        var updated: [ZPDFContracts.PageDescriptor] = []
        for (position, id) in pageOrder.enumerated() {
            guard let page = knownPages[id] else { continue }
            updated.append(page)
            names.pages[id] = LedgerPageInfo(label: page.label, index: position)
        }
        pages = updated
        return sweepSetAsideMarkups()
    }

    /// Replaces the set order and brings the pages, names and set-aside markups into it.
    ///
    /// - Returns: the zone each returning markup was unfiled from, for the command's inverse.
    @discardableResult
    func replacePageOrder(_ order: [PageID]) -> [MarkupID: ZoneID] {
        pageOrder = order
        return reindexPages()
    }

    /// The zone each of `ids` that is set aside is filed in now; a markup not set aside is left
    /// out (V-038).
    func currentSetAsideZones(of ids: some Sequence<MarkupID>) -> [MarkupID: ZoneID?] {
        var current: [MarkupID: ZoneID?] = [:]
        for id in ids {
            if let entry = setAsideMarkups[id] { current.updateValue(entry.record.zoneID, forKey: id) }
        }
        return current
    }

    /// Every page of one drawing the session has held, removed sheets included, in PDF order.
    func knownPages(ofDrawing drawing: DocumentID) -> [ZPDFContracts.PageDescriptor] {
        knownPages.values.filter { $0.documentID == drawing }.sorted { $0.index < $1.index }
    }

    /// Records a page the session now holds (NL-DOCS-04), so it survives leaving the set.
    func rememberPage(_ page: ZPDFContracts.PageDescriptor) {
        if knownPages[page.id] == nil { knownPageOrder.append(page.id) }
        knownPages[page.id] = page
    }

    /// Moves the markups of pages that left the set aside and brings back those whose page
    /// returned (NL-DOCS-07). The snapshot caches start again: rows left or joined the ledger
    /// without a command naming them.
    ///
    /// - Returns: each returning markup that was unfiled from a zone deleted while its sheet was
    ///   out, with that zone — what the command's inverse restores on the set-aside record, so
    ///   undoing the zone deletion refiles it (V-038).
    @discardableResult
    private func sweepSetAsideMarkups() -> [MarkupID: ZoneID] {
        var unfiled: [MarkupID: ZoneID] = [:]
        let live = Set(pageOrder)
        var moved = false
        let leaving = markupOrder.enumerated().filter { _, id in
            markups[id].map { !live.contains($0.pageID) && knownPages[$0.pageID] != nil } ?? false
        }
        if !leaving.isEmpty {
            for (position, id) in leaving {
                guard let record = markups[id] else { continue }
                setAsideMarkups[id] = (record, position)
                markups.removeValue(forKey: id)
            }
            let gone = Set(leaving.map(\.element))
            markupOrder.removeAll { gone.contains($0) }
            moved = true
        }
        let returning = setAsideMarkups
            .filter { live.contains($0.value.record.pageID) }
            .sorted { $0.value.position < $1.value.position }
        if !returning.isEmpty {
            for (id, entry) in returning {
                setAsideMarkups.removeValue(forKey: id)
                // A zone deleted while the sheet was out of the set files it nowhere (U-028).
                var record = entry.record
                if let zone = record.zoneID, heldZone(zone) == nil {
                    unfiled[id] = zone
                    record.zoneID = nil
                }
                markups[id] = record
                markupOrder.insert(id, at: min(entry.position, markupOrder.count))
            }
            moved = true
        }
        if moved {
            markupTableEpoch &+= 1
            ledgerCache = nil
            summaryCache = nil
        }
        return unfiled
    }

    /// The set order, as page identities — what the archive persists as `page.position`.
    public var pageOrderIDs: [PageID] { pageOrder }

    /// The ring(s) a cutout subtracts from its parent.
    ///
    /// `tool` matters for exactly one case: an **ellipse** cutout is stored as the two
    /// corners of its bounding box, because that is the geometry its own calculator
    /// measures. Two points are not a ring, so without this the ellipse cutout would be
    /// recorded, measured, shown as a child row — and subtract nothing.
    static func cutoutRings(of cutout: MeasurementGeometry?, tool: Domain.Tool?) -> [PolygonRing] {
        guard let cutout else { return [] }
        if tool == .ellipseCutout, let box = cutout.ellipseBox {   // U-093: the engine's box
            // An ellipse cutout is measured as the ellipse inscribed in its bounding box —
            // two stored corners when it was dragged, four when the corners were derived,
            // the same ellipse either way. Taking the ring from the *box* is what keeps the
            // hole the parent loses equal to the area the child reports: before this the
            // child said 1.57 m² and the parent lost the box's 2 m².
            return [PolygonRing(
                points: ellipseRing(
                    corner: PDFPoint(x: box.minX, y: box.minY),
                    opposite: PDFPoint(x: box.maxX, y: box.maxY)
                ),
                isClosed: true
            )]
        }
        if cutout.polygons.isEmpty {
            return cutout.points.count >= 3 ? [PolygonRing(points: cutout.points, isClosed: true)] : []
        }
        return cutout.polygons.map(\.outer)
    }

    /// A parent's geometry with its holes **replaced** by `rings`.
    ///
    /// A parent's holes are derived from its cutouts, never accumulated. `applyCutout` used
    /// to append the new ring to the parent's stored polygon and leave it there, so the
    /// parent's own geometry carried every hole it had ever been given: deleting the cutout
    /// edited `cutoutMarkupIDs` and left the ring in place (80 m² area, 4 m² cutout, delete
    /// the cutout → still 76 m²), moving the cutout moved the child and not the hole, and a
    /// save persisted the merged ring so a reopen inherited the wrong number (CR-1).
    /// Rebuilding the whole list on every recompute makes the parent's number a function of
    /// the cutouts it has *now*, and it is also what repairs an archive written before this
    /// change: whatever rings it carries are discarded and re-derived on hydration.
    ///
    /// The parent then measures as a polygon with holes, which is the engine's own cutout
    /// path (`CutoutSolver`, spec 12.4). Nothing subtracts an area from another area here.
    /// A stored hole that is not a cutout's ring does not exist in this product — no tool
    /// draws one — so replacing the list loses nothing a person made.
    static func rebuildingHoles(in parent: MeasurementGeometry, with rings: [PolygonRing]) -> MeasurementGeometry {
        var rebuilt = parent
        if rebuilt.polygons.isEmpty {
            // A point-list polygon keeps its shape until it has a hole to carry: a parent
            // with no cutouts is stored exactly as it was drawn.
            guard !rings.isEmpty, rebuilt.points.count >= 3 else { return rebuilt }
            rebuilt.polygons = [
                PolygonGeometry(outer: PolygonRing(points: rebuilt.points, isClosed: true), holes: rings)
            ]
            rebuilt.points = []
            return rebuilt
        }
        rebuilt.polygons[0].holes = rings
        return rebuilt
    }

    /// Puts the markup order back after a patch: from the whole-order snapshot when the
    /// patch carries one, from recorded positions otherwise — sanitised either way.
    ///
    /// An order is exactly the live identifiers, each once. A batch that added a markup and
    /// then removed another recorded its whole-order snapshot *after* the add, so restoring
    /// it verbatim kept the added markup's id in the order after the undo had removed the
    /// record — a ghost that a later add of the same id appended a second time (CR-6).
    /// Re-inserted markups go back where they stood, lowest position first, so consecutive
    /// positions land consecutively; anything live and mentioned nowhere is appended in
    /// identifier order, so two processes restore the same order.
    private func restoreMarkupOrder(from inverse: DocumentCommandInverse) {
        let live = Set(markups.keys)
        var order: [MarkupID] = []
        var seen: Set<MarkupID> = []
        for id in inverse.markupOrder ?? markupOrder where live.contains(id) && seen.insert(id).inserted {
            order.append(id)
        }
        let missing = live.subtracting(seen)
        guard !missing.isEmpty else {
            markupOrder = order
            return
        }
        let positioned = missing
            .compactMap { id in (inverse.markupPositions?[id]).map { (id: id, position: $0) } }
            .sorted { $0.position < $1.position }
        for entry in positioned {
            order.insert(entry.id, at: min(max(entry.position, 0), order.count))
            seen.insert(entry.id)
        }
        let unpositioned = missing.subtracting(seen)
            .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        order.append(contentsOf: unpositioned)
        markupOrder = order
    }

    /// Custom cells with every dimensionless number tagged as its column declares (ADR-0014 §3).
    static func retaggingCustomValues(
        _ values: [ColumnID: ZPDFContracts.LedgerCellValue],
        columns: LedgerColumnSet
    ) -> [ColumnID: ZPDFContracts.LedgerCellValue] {
        guard !values.isEmpty else { return values }
        var retagged = values
        for (columnID, cell) in values {
            guard case .number(let quantity) = cell, quantity.dimension.isDimensionless,
                  let definition = columns.column(id: columnID) else { continue }
            let corrected = LedgerBridge.retagged(quantity, for: definition)
            if corrected != quantity {
                retagged[columnID] = ZPDFContracts.LedgerCellValue.number(corrected)
            }
        }
        return retagged
    }

    /// `record` with the timestamp of its derivation neutralised, for change detection.
    ///
    /// A recompute always stamps a fresh `computedAt`, so comparing whole records marked
    /// every markup changed on every Recalculate — a document-wide History entry that changed
    /// no number (CR-13). Everything else about the derivation still counts: a new engine
    /// version, a new scale version or a new value is a change worth recording.
    private static func ignoringComputedAt(_ record: MarkupRecord) -> MarkupRecord {
        guard let measurement = record.measurement, let provenance = measurement.provenance else {
            return record
        }
        var neutral = record
        neutral.measurement = MeasurementResult(
            values: measurement.values,
            warnings: measurement.warnings,
            formulaVersion: measurement.formulaVersion,
            provenance: MeasurementProvenance(
                geometryDigest: provenance.geometryDigest,
                scaleID: provenance.scaleID,
                scalePageID: provenance.scalePageID,
                scaleVersion: provenance.scaleVersion,
                scaleSource: provenance.scaleSource,
                calibrationEvidence: provenance.calibrationEvidence,
                slope: provenance.slope,
                parameters: provenance.parameters,
                formulaVersion: provenance.formulaVersion,
                engineVersion: provenance.engineVersion,
                computedAt: .distantPast,
                layerName: provenance.layerName
            )
        )
        return neutral
    }

    /// An axis-aligned ellipse inscribed in the box `corner`…`opposite`, as an **area-preserving**
    /// polygon: its area is exactly πab, the area the cutout row reports (BH-103), and it never
    /// reaches past the box, so a cutout drawn flush with its parent's edge lies inside it
    /// (X-044). The construction is the measurement engine's (`EllipseCutoutRing`).
    static func ellipseRing(corner: PDFPoint, opposite: PDFPoint) -> [PDFPoint] {
        EllipseCutoutRing.points(corner: corner, opposite: opposite)
    }
}

// MARK: - Snapshot caches (IM-001, IM-002)

extension TakeoffSession {

    /// The spec the live coordinator holds — the pane's last — or `nil` before the first build.
    var currentLedgerSpec: LedgerViewSpec? { ledgerCache?.coordinator.view.spec }

    /// The live ledger: one coordinator over one store, updated in place.
    struct LedgerCache {
        var coordinator: LedgerCoordinator
        /// The ledger rows' markup identities, in store order.
        var ids: [MarkupID]
        var index: [MarkupID: Int]
        var columnSetGeneration: UInt64
        var catalog: LedgerNameCatalog
        var epoch: UInt64
    }

    /// Canvas summaries and derivations by markup, and what they were rendered against.
    struct SummaryCache {
        var summaries: [MarkupID: ZPDFUIPresentation.MarkupSummary]
        var derivations: [MarkupID: [LedgerDerivationSection]]
        var names: ProjectNameTable
        var units: DisplayUnitSelection
        var localeIdentifier: String
        var epoch: UInt64
    }

    /// The ledger view for a spec, from the live store.
    ///
    /// Every projection used to build a brand-new `LedgerStore` — re-evaluating every formula
    /// for every row — and then filter, sort and group from scratch, on every filter keystroke,
    /// sort click and document edit (IM-002). The incremental machinery the ledger package
    /// ships for exactly this (`LedgerCoordinator`, `LedgerStore.updatingRows`,
    /// `.editRows`) had no caller. It has one now:
    ///
    /// - rows edited in place — same rows, same order — go through `updatingRows` and
    ///   `.editRows`, which re-evaluates formulas for the edited rows only and repositions them;
    /// - an insert, a delete or a reorder replaces the store (`.replaceStore`);
    /// - a new column set, a new name table (a renamed zone, a new scale) or a reloaded
    ///   document starts again from a fresh store;
    /// - the spec is applied last, and the coordinator takes the cheapest valid path for it.
    ///
    /// The result is the view `LedgerStore(...).makeView(spec)` would give; the differential
    /// tests assert it, row for row and total for total.
    func cachedLedgerView(for spec: LedgerViewSpec) throws -> LedgerView {
        let changed = markups.takeLedgerChanges()
        // ADR-0024: the ledger's rows include each source's derived assembly rows, and a
        // changed source brings its derived rows into the edit list with it.
        let ledger = ledgerRecords
        let affected = ledgerRecordsAffected(by: Set(changed))
        let ids = ledger.map(\.id)
        let catalog = nameTable.ledgerCatalog
        do {
            // Only the column set changed — a formula edited, a column imported: the rows stay,
            // and only the formulas the change can affect are re-evaluated (IM-081).
            if var cache = ledgerCache,
               cache.columnSetGeneration != columnSetGeneration,
               cache.epoch == markupTableEpoch,
               cache.catalog == catalog,
               ids == cache.ids,
               affected.keys.allSatisfy({ cache.index[$0] == nil }) {
                let store = try cache.coordinator.view.store.replacingColumns(ledgerColumns)
                cache.coordinator.apply(.replaceStore(store))
                cache.columnSetGeneration = columnSetGeneration
                cache.coordinator.apply(.setSpec(spec))
                ledgerCache = cache
                return cache.coordinator.view
            }
            if var cache = ledgerCache,
               cache.columnSetGeneration == columnSetGeneration,
               cache.epoch == markupTableEpoch,
               cache.catalog == catalog {
                if ids == cache.ids {
                    var edits: [LedgerStore.LedgerRowEdit] = []
                    for (id, record) in affected {
                        guard let position = cache.index[id] else { continue }
                        edits.append(LedgerStore.LedgerRowEdit(index: position, record: record))
                    }
                    if !edits.isEmpty {
                        edits.sort { $0.index < $1.index }
                        let store = try cache.coordinator.view.store.updatingRows(edits)
                        cache.coordinator.apply(.editRows(store: store, editedIndices: edits.map(\.index)))
                    }
                } else {
                    let store = try makeLedgerStore(ledger, catalog: catalog)
                    cache.coordinator.apply(.replaceStore(store))
                    cache.ids = ids
                    cache.index = Self.positions(of: ids)
                }
                cache.coordinator.apply(.setSpec(spec))
                ledgerCache = cache
                return cache.coordinator.view
            }
            let store = try makeLedgerStore(ledger, catalog: catalog)
            let coordinator = LedgerCoordinator(store: store, spec: spec)
            ledgerCache = LedgerCache(
                coordinator: coordinator,
                ids: ids,
                index: Self.positions(of: ids),
                columnSetGeneration: columnSetGeneration,
                catalog: catalog,
                epoch: markupTableEpoch
            )
            return coordinator.view
        } catch {
            // A refused rebuild leaves nothing half-updated to be trusted next time.
            ledgerCache = nil
            throw DocumentCommandError.ledgerFailed(String(describing: error))
        }
    }

    /// Builds the ledger store with the formula columns evaluated concurrently and
    /// cancellably, and installs it as the live store — the call for opening a saved takeoff,
    /// so the first snapshot reuses it instead of evaluating every row on the session actor
    /// (IM-081; `DocumentLoadPipeline` calls it before `AppCoreEnvironment.make`).
    ///
    /// It reports no progress (R-064, iteration 1 re-fix): the load's placeholder is an
    /// indeterminate "Opening…" for every stage, and a progress callback here had no caller in
    /// the application. The concurrent evaluation is the gain; a determinate bar would first need
    /// the whole load — drawing, index, hydration — to report, not the ledger alone.
    ///
    /// A build the document outran — a markup changed, the columns or the names moved while it
    /// ran — is discarded, and the next snapshot builds as usual.
    public func prebuildLedger() async throws {
        let ledger = ledgerRecords
        let ids = ledger.map(\.id)
        let catalog = nameTable.ledgerCatalog
        let generation = columnSetGeneration
        let epoch = markupTableEpoch
        let revision = markups.revision
        let store = try await LedgerStore.build(
            markups: ledger,
            columns: ledgerColumns,
            names: catalog,
            quantityMultiplierColumn: RepetitionColumn.columnID
        )
        guard generation == columnSetGeneration, epoch == markupTableEpoch,
              revision == markups.revision, catalog == nameTable.ledgerCatalog else { return }
        _ = markups.takeLedgerChanges()
        ledgerCache = LedgerCache(
            coordinator: LedgerCoordinator(store: store),
            ids: ids,
            index: Self.positions(of: ids),
            columnSetGeneration: generation,
            catalog: catalog,
            epoch: epoch
        )
    }

    private func makeLedgerStore(_ ledger: [MarkupRecord], catalog: LedgerNameCatalog) throws -> LedgerStore {
        try LedgerStore(
            markups: ledger,
            columns: ledgerColumns,
            names: catalog,
            quantityMultiplierColumn: RepetitionColumn.columnID
        )
    }

    private static func positions(of ids: [MarkupID]) -> [MarkupID: Int] {
        var index: [MarkupID: Int] = [:]
        index.reserveCapacity(ids.count)
        for (position, id) in ids.enumerated() where index[id] == nil { index[id] = position }
        return index
    }

    /// Every markup's canvas summary, in document order, and every measured value's
    /// derivation — re-rendered only for the markups that changed (IM-001).
    ///
    /// Each snapshot used to rebuild a summary and a derivation for every markup in the
    /// document, so every click, nudge, subject edit and undo cost O(markups) several times
    /// over. A summary depends on its record, the name table and the formatter and on nothing
    /// else, so it is reused until one of those three changes.
    func cachedSummaries() -> (
        summaries: [ZPDFUIPresentation.MarkupSummary],
        derivations: [UUID: [LedgerDerivationSection]]
    ) {
        let changed = markups.takeSummaryChanges()
        let names = nameTable
        let formatter = snapshotFormatter
        var cache: SummaryCache
        if let existing = summaryCache,
           existing.epoch == markupTableEpoch,
           existing.names == names,
           existing.units == formatter.units,
           existing.localeIdentifier == formatter.localeIdentifier {
            cache = existing
            for id in changed {
                if let record = markups[id] {
                    cache.summaries[id] = MarkupBridge.summary(of: record, names: names, formatter: formatter)
                    cache.derivations[id] = Self.derivation(of: record, names: names)
                } else {
                    cache.summaries.removeValue(forKey: id)
                    cache.derivations.removeValue(forKey: id)
                }
            }
        } else {
            var summaries: [MarkupID: ZPDFUIPresentation.MarkupSummary] = [:]
            var derivations: [MarkupID: [LedgerDerivationSection]] = [:]
            summaries.reserveCapacity(markups.count)
            for record in markups.values {
                summaries[record.id] = MarkupBridge.summary(of: record, names: names, formatter: formatter)
                derivations[record.id] = Self.derivation(of: record, names: names)
            }
            cache = SummaryCache(
                summaries: summaries,
                derivations: derivations,
                names: names,
                units: formatter.units,
                localeIdentifier: formatter.localeIdentifier,
                epoch: markupTableEpoch
            )
        }
        summaryCache = cache
        var ordered: [ZPDFUIPresentation.MarkupSummary] = []
        ordered.reserveCapacity(markupOrder.count)
        var derivations: [UUID: [LedgerDerivationSection]] = [:]
        for id in markupOrder {
            guard let summary = cache.summaries[id] else { continue }
            ordered.append(summary)
            if let sections = cache.derivations[id] { derivations[id.rawValue] = sections }
        }
        return (ordered, derivations)
    }

    /// One markup's derivation sections, or `nil` when it carries no provenance.
    static func derivation(of record: MarkupRecord, names: ProjectNameTable) -> [LedgerDerivationSection]? {
        guard let provenance = record.measurement?.provenance else { return nil }
        let pageLabel = provenance.scalePageID.flatMap { names.pages[$0] }.map(\.label)
        return DerivationBridge.sections(
            for: provenance,
            pageLabel: pageLabel?.isEmpty == false ? pageLabel : nil,
            scaleName: names.scales[provenance.scaleID]
        )
    }
}

extension TakeoffSession.TakeoffState {
    /// The state with its runtime ledger columns set.
    func naming(_ identities: [PageID: SheetIdentity]) -> Self {
        var copy = self
        copy.sheetIdentities = identities
        return copy
    }

    func holding(_ refused: [MarkupID]) -> Self {
        var copy = self
        copy.heldMarkupIDs = refused.map { $0.rawValue.uuidString }
        return copy
    }

    func withCustomColumns(_ columns: [LedgerColumnDefinition]) -> Self {
        var copy = self
        copy.customColumns = columns
        return copy
    }

    /// The state with its arrangement (NL-DOCS-07/16) set.
    func arranging(
        excluded: [ZPDFContracts.PageDescriptor],
        setAside: [MarkupRecord],
        views: [PageID: PageViewSettings],
        arrangedOrder: [PageID] = []
    ) -> Self {
        var copy = self
        copy.excludedPages = excluded
        copy.setAsideMarkups = setAside
        copy.pageViews = views
        copy.arrangedOrder = excluded.isEmpty ? [] : arrangedOrder
        return copy
    }

    /// The state as the archive writes it: the removed pages after the set's pages and their
    /// set-aside markups after the rest, with ``excludedPageIDs`` naming the removed ones.
    /// Idempotent — a folded state has nothing left to fold.
    public func foldingArrangement() -> Self {
        guard !excludedPages.isEmpty || !setAsideMarkups.isEmpty else { return self }
        var allPages = pages + excludedPages
        if !arrangedOrder.isEmpty {
            let rank = Dictionary(arrangedOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            allPages = allPages.enumerated().sorted { lhs, rhs in
                let l = rank[lhs.element.id] ?? Int.max
                let r = rank[rhs.element.id] ?? Int.max
                return l != r ? l < r : lhs.offset < rhs.offset
            }.map(\.element)
        }
        var folded = TakeoffSession.TakeoffState(
            pages: allPages,
            markups: markups + setAsideMarkups,
            scales: scales,
            pageScaleIDs: pageScaleIDs,
            calibrationEvidence: calibrationEvidence,
            scaleRegions: scaleRegions,
            projectZones: projectZones
        )
        folded.customColumns = customColumns
        folded.heldMarkupIDs = heldMarkupIDs
        folded.sheetIdentities = sheetIdentities
        folded.setPositions = setPositions
        folded.pageViews = pageViews
        folded.excludedPageIDs = excludedPageIDs.union(excludedPages.map(\.id))
        folded.uncalibratedCaptures = uncalibratedCaptures   // ADR-0031
        // ADR-0032: the project's layer list, active layer and units travel through the fold too
        // (they were dropped whenever a sheet was removed from the set, so a layer
        // change made in such a project was not saved).
        folded.markupLayers = markupLayers
        folded.activeMarkupLayerID = activeMarkupLayerID
        folded.displayUnits = displayUnits
        folded.projectAssemblyRecipes = projectAssemblyRecipes   // NL-QTY-07-UI
        return folded
    }
}

/// A page's snap index with the markups one view took off the sheet left out (V-003), and the
/// exclusion it was cut for: `requested` as the view passed it, `excludedOnPage` the part of it
/// on this page — what the copy actually differs by.
struct ViewFilteredSnapIndex: Sendable {
    let requested: Set<MarkupID>
    let excludedOnPage: Set<MarkupID>
    let index: SnapIndex
}
