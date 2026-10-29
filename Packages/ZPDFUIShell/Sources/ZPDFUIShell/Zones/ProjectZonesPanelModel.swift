import Foundation
import Observation
import ZPDFUILedger
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// A Project Zone being created: named, typed and coloured before it exists.
///
/// A zone may have no boundary at all — "Phase 2" is a perfectly good grouping that spans the
/// whole set — so the polygon is optional here in a way a Scale Region's never is. That is the
/// difference between the two objects: a zone organises quantities, a region decides the
/// transform they are measured with.
public struct ProjectZoneDraft: Hashable, Sendable, Identifiable {

    /// Identity the zone will be created under.
    public let id: UUID
    /// The proposed name.
    public var name: String
    /// What the zone represents.
    public var kind: ProjectZoneKind
    /// Parent zone, for a nested zone.
    public var parentID: UUID?
    /// The page the boundary was drawn on, or `nil` for a zone that spans pages.
    public var pageID: PageDescriptor.ID?
    /// That page's label.
    public var pageLabel: String?
    /// The drawn boundary, or empty for a zone with no drawn area.
    public var boundary: [PDFPointValue]
    /// The chosen palette entry's identifier.
    public var colorPaletteID: String

    /// Creates a draft.
    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProjectZoneKind = .room,
        parentID: UUID? = nil,
        pageID: PageDescriptor.ID? = nil,
        pageLabel: String? = nil,
        boundary: [PDFPointValue] = [],
        colorPaletteID: String
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parentID = parentID
        self.pageID = pageID
        self.pageLabel = pageLabel
        self.boundary = boundary
        self.colorPaletteID = colorPaletteID
    }

    /// The colour the zone will be created with.
    public var colorRGBA: ColorRGBA { ZenitMarkupPalette.color(for: colorPaletteID) }

    /// Whether a boundary has been drawn for the zone.
    public var hasBoundary: Bool { boundary.count >= 3 }
}

/// Everything the app tier needs to create one zone. The panel never touches a store.
public struct ProjectZoneCreation: Hashable, Sendable {

    /// Identity to create the zone under.
    public let id: UUID
    /// The zone's name.
    public let name: String
    /// What it represents.
    public let kind: ProjectZoneKind
    /// Parent zone, or `nil`.
    public let parentID: UUID?
    /// The page the boundary lives on, or `nil`.
    public let pageID: PageDescriptor.ID?
    /// The boundary, or empty.
    public let boundary: [PDFPointValue]
    /// Outline colour.
    public let colorRGBA: ColorRGBA

    /// Creates a creation request.
    public init(
        id: UUID,
        name: String,
        kind: ProjectZoneKind,
        parentID: UUID?,
        pageID: PageDescriptor.ID?,
        boundary: [PDFPointValue],
        colorRGBA: ColorRGBA
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.parentID = parentID
        self.pageID = pageID
        self.boundary = boundary
        self.colorRGBA = colorRGBA
    }
}

/// Why the Project Zones panel would not do what was asked.
public enum ProjectZoneRefusal: Hashable, Sendable {

    /// The name is blank.
    case nameEmpty
    /// Another zone already carries that name.
    case nameTaken(String)
    /// The zone named is not in the project any more.
    case unknownZone
    /// A zone cannot be its own parent, nor a descendant's child.
    case circularParent(name: String)
    /// Fewer than three points cannot bound an area.
    case boundaryTooFewPoints(count: Int)
    /// The zone still holds markups, so deleting it would orphan them.
    case zoneNotEmpty(name: String, markupCount: Int)
    /// Nothing is selected on the canvas, so there is nothing to file into a zone.
    case nothingSelected
    /// The panel has no document behind it.
    case notWired

    /// The sentence shown in the panel.
    public var message: String {
        switch self {
        case .nameEmpty:
            return NSLocalizedString(
                "Give the zone a name.",
                comment: "Project Zone refusal: blank name"
            )
        case let .nameTaken(name):
            return String(
                format: NSLocalizedString(
                    "“%@” is already the name of another zone.",
                    comment: "Project Zone refusal: duplicate name"
                ),
                name
            )
        case .unknownZone:
            return NSLocalizedString(
                "That zone is no longer in the project.",
                comment: "Project Zone refusal: stale identity"
            )
        case let .circularParent(name):
            return String(
                format: NSLocalizedString(
                    "“%@” is already inside this zone, so it cannot also contain it.",
                    comment: "Project Zone refusal: circular nesting"
                ),
                name
            )
        case let .boundaryTooFewPoints(count):
            return String(
                format: NSLocalizedString(
                    "A zone boundary needs at least three points; this one has %d.",
                    comment: "Project Zone refusal: too few points"
                ),
                count
            )
        case let .zoneNotEmpty(name, markupCount):
            return String(
                format: NSLocalizedString(
                    "“%1$@” still holds %2$d markups. Move them out before deleting it.",
                    comment: "Project Zone refusal: zone still has markups"
                ),
                name,
                markupCount
            )
        case .nothingSelected:
            return NSLocalizedString(
                "Select the markups to file into the zone first.",
                comment: "Project Zone refusal: empty selection"
            )
        case .notWired:
            return NSLocalizedString(
                "This document cannot store Project Zones yet.",
                comment: "Project Zone refusal: no document behind the panel"
            )
        }
    }
}

/// The controller behind the Navigator's Project Zones page.
///
/// The zone *model* has existed since the presentation layer was written and the ledger has
/// grouped by Project Zone all along — but nothing in the product could create one, so the
/// grouping level had nothing to group. This object is the missing half: creation, naming,
/// colour, nesting, visibility, filing a selection into a zone, and the one action that makes
/// the whole thing pay for itself — grouping the Quantity Ledger by zone.
///
/// It owns no store. Every mutation leaves through an `on…` hook the app tier services through
/// the document command bus, so each one is undoable and survives save and reopen.
@MainActor
@Observable
public final class ProjectZonesPanelModel {

    // MARK: - State

    /// Every zone in the project, as the core last published them.
    public private(set) var zones: [ProjectZoneSummary]
    /// The highlighted zone.
    public var selection: UUID?
    /// The zone being created, or `nil`.
    public private(set) var draft: ProjectZoneDraft?
    /// Whether the canvas has been asked for a boundary and none has arrived yet.
    public private(set) var isAwaitingBoundary: Bool = false
    /// How many markups are selected on the canvas, for the "file into zone" action.
    public private(set) var selectedMarkupCount: Int = 0
    /// The most recent refusal, or `nil`.
    public private(set) var refusal: ProjectZoneRefusal?

    // MARK: - Hooks the app tier services

    /// Arms the polygon tool so a boundary can be drawn for the draft.
    public var onBeginBoundary: (@MainActor () -> Void)?

    /// Raised when the person cancels boundary drawing from the panel's own banner, so the
    /// canvas disarms the polygon tool too. Without it the banner disappeared but the tool
    /// stayed armed and the status bar kept instructing (LT-35, 2026-08-29).
    public var onCancelBoundaryDrawing: (@MainActor () -> Void)?
    /// Creates the zone.
    public var onCreateZone: (@MainActor (ProjectZoneCreation) -> Void)?
    /// Renames a zone.
    public var onRenameZone: (@MainActor (_ zoneID: UUID, _ name: String) -> Void)?
    /// Changes what a zone represents.
    public var onSetZoneKind: (@MainActor (_ zoneID: UUID, _ kind: ProjectZoneKind) -> Void)?
    /// Recolours a zone.
    public var onSetZoneColor: (@MainActor (_ zoneID: UUID, _ color: ColorRGBA) -> Void)?
    /// Re-parents a zone.
    public var onSetZoneParent: (@MainActor (_ zoneID: UUID, _ parentID: UUID?) -> Void)?
    /// Shows or hides a zone boundary.
    public var onSetZoneVisible: (@MainActor (_ zoneID: UUID, _ visible: Bool) -> Void)?
    /// Deletes an empty zone.
    public var onDeleteZone: (@MainActor (_ zoneID: UUID) -> Void)?
    /// Files the canvas selection into a zone.
    public var onAssignSelection: (@MainActor (_ zoneID: UUID) -> Void)?
    /// Regroups the Quantity Ledger by a column. Wired to the docked pane by the shell.
    public var onGroupLedger: (@MainActor (_ column: LedgerColumnID) -> Void)?

    /// Creates the model.
    public init(zones: [ProjectZoneSummary] = []) {
        self.zones = zones
    }

    // MARK: - Reading

    /// Zones in display order: name, so the list does not reshuffle when a count changes.
    ///
    /// BH-826: a person's order, not code-unit order — "Zone 2" before "Zone 10", and a
    /// lowercase initial among the capitals.
    public var ordered: [ProjectZoneSummary] {
        zones.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Zones in tree order — each parent followed by its children, depth-first, names in
    /// ``ordered`` order at each level — which is the only order in which indentation by
    /// depth points at the right parent (BH-825). A zone whose parent is missing, or which
    /// sits in a cycle, is listed at the top level rather than dropped.
    public var treeOrdered: [ProjectZoneSummary] {
        let known = Set(zones.map(\.id))
        var result: [ProjectZoneSummary] = []
        var visited = Set<UUID>()
        func visit(_ zone: ProjectZoneSummary) {
            guard visited.insert(zone.id).inserted else { return }
            result.append(zone)
            for child in ordered where child.parentID == zone.id { visit(child) }
        }
        for zone in ordered where zone.parentID == nil || !known.contains(zone.parentID!) { visit(zone) }
        for zone in ordered where !visited.contains(zone.id) { visit(zone) }
        return result
    }

    /// One zone by identity.
    public func zone(_ id: UUID) -> ProjectZoneSummary? {
        zones.first { $0.id == id }
    }

    /// The zones directly inside one zone, or the top level when `parent` is `nil`.
    public func children(of parent: UUID?) -> [ProjectZoneSummary] {
        ordered.filter { $0.parentID == parent }
    }

    /// How many markups the whole project has filed into zones.
    public var filedMarkupCount: Int {
        zones.reduce(0) { $0 + $1.markupCount }
    }

    /// Whether grouping the ledger by zone would show anything but one empty group.
    ///
    /// The menu item stays enabled either way — grouping an empty column is not wrong, it is
    /// just empty — but the panel says which of the two it is going to be.
    public var ledgerGroupingWouldBeEmpty: Bool { filedMarkupCount == 0 }

    /// The colours a new zone can take, unused ones first.
    public var availableColors: [ZenitMarkupPalette.Entry] {
        let used = Set(zones.map(\.colorRGBA))
        let unused = ZenitMarkupPalette.entries.filter { !used.contains($0.color) }
        return unused.isEmpty ? ZenitMarkupPalette.entries : unused
    }

    // MARK: - Applying core state

    /// Replaces the zone list. The core is the authority.
    public func setZones(_ zones: [ProjectZoneSummary]) {
        self.zones = zones
        if let selection, !zones.contains(where: { $0.id == selection }) { self.selection = nil }
        // BH-828: an undone parent leaves the open draft pointing at nothing; it goes back to
        // the top level rather than being created under a zone that no longer exists.
        if let parentID = draft?.parentID, !zones.contains(where: { $0.id == parentID }) {
            draft?.parentID = nil
        }
    }

    /// Reports how many markups the canvas has selected.
    public func setSelectedMarkupCount(_ count: Int) {
        selectedMarkupCount = max(0, count)
    }

    // MARK: - Creating a zone

    /// Opens a draft. A zone with no boundary is legitimate, so this needs no polygon first.
    ///
    /// BH-827: an open draft is kept — the "+" in the header is visible the whole time, and a
    /// stray click used to replace a named, coloured, bounded draft with a fresh "Zone 3".
    /// BH-302: a boundary capture in progress is ended through the same hook the canvas
    /// listens to, so the polygon tool and the status-bar instruction are disarmed too.
    public func beginZone(parentID: UUID? = nil) {
        if draft != nil {
            if let parentID { setDraftParent(parentID) }
            return
        }
        refusal = nil
        stopBoundaryCapture()
        draft = ProjectZoneDraft(
            name: suggestedName(),
            kind: .room,
            parentID: parentID,
            colorPaletteID: availableColors[0].id
        )
    }

    /// Asks the canvas for a boundary polygon for the open draft, opening a draft first when
    /// the person went straight for "draw a zone" without naming one.
    @discardableResult
    public func beginBoundary() -> Bool {
        if draft == nil { beginZone() }
        guard let onBeginBoundary else { return refuse(.notWired) }
        refusal = nil
        isAwaitingBoundary = true
        onBeginBoundary()
        return true
    }

    /// Accepts the polygon the canvas produced.
    @discardableResult
    public func completeBoundary(
        _ boundary: [PDFPointValue],
        pageID: PageDescriptor.ID,
        pageLabel: String
    ) -> Bool {
        isAwaitingBoundary = false
        guard draft != nil else { return refuse(.notWired) }
        guard boundary.count >= 3 else { return refuse(.boundaryTooFewPoints(count: boundary.count)) }
        refusal = nil
        draft?.boundary = boundary
        draft?.pageID = pageID
        draft?.pageLabel = pageLabel
        return true
    }

    /// Renames the draft.
    public func setDraftName(_ name: String) {
        guard draft != nil else { return }
        draft?.name = name
        refusal = nil
    }

    /// Sets what the draft zone represents.
    public func setDraftKind(_ kind: ProjectZoneKind) {
        draft?.kind = kind
    }

    /// Recolours the draft.
    public func setDraftColor(paletteID: String) {
        guard ZenitMarkupPalette.entries.contains(where: { $0.id == paletteID }) else { return }
        draft?.colorPaletteID = paletteID
    }

    /// Nests the draft inside an existing zone, or puts it at the top level.
    public func setDraftParent(_ parentID: UUID?) {
        guard parentID == nil || zone(parentID!) != nil else { _ = refuse(.unknownZone); return }
        draft?.parentID = parentID
    }

    /// Whether ``commitDraft()`` would succeed, so the button can be disabled for a reason
    /// the panel also states in words.
    public var canCommitDraft: Bool {
        guard let draft else { return false }
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !zones.contains { $0.name == trimmed }
    }

    /// Creates the zone, or refuses and says why.
    @discardableResult
    public func commitDraft() -> Bool {
        guard let draft else { return refuse(.notWired) }
        // BH-828: a parent undone while the draft was open is not forwarded.
        let parentID = draft.parentID.flatMap { id in zone(id) == nil ? nil : id }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return refuse(.nameEmpty) }
        guard !zones.contains(where: { $0.name == name }) else { return refuse(.nameTaken(name)) }
        guard let onCreateZone else { return refuse(.notWired) }
        refusal = nil
        onCreateZone(
            ProjectZoneCreation(
                id: draft.id,
                name: name,
                kind: draft.kind,
                parentID: parentID,
                pageID: draft.hasBoundary ? draft.pageID : nil,
                boundary: draft.hasBoundary ? draft.boundary : [],
                colorRGBA: draft.colorRGBA
            )
        )
        selection = draft.id
        self.draft = nil
        // BH-303: creating the zone ends any boundary capture that was still armed, so the
        // banner does not stay up over no draft and a later polygon is not dropped with a
        // false "cannot store Project Zones" refusal.
        stopBoundaryCapture()
        return true
    }

    /// Throws the draft away. The panel's Cancel routes here.
    public func cancelZoneCreation() {
        let wasDrawing = isAwaitingBoundary
        draft = nil
        isAwaitingBoundary = false
        refusal = nil
        if wasDrawing { onCancelBoundaryDrawing?() }
    }

    /// Stops drawing the boundary but keeps the named draft (BH-304).
    ///
    /// Picking another tool, pressing Escape on the canvas or the banner's "stop drawing"
    /// used to throw away the name, type and colour with the capture. The person stopped
    /// drawing; they did not abandon the zone.
    public func stopBoundaryDrawing() {
        guard isAwaitingBoundary else { return }
        stopBoundaryCapture()
    }

    /// Ends a capture in progress and tells the canvas, once.
    private func stopBoundaryCapture() {
        guard isAwaitingBoundary else { return }
        isAwaitingBoundary = false
        onCancelBoundaryDrawing?()
    }

    // MARK: - Renaming and nesting from the panel (BH-301, IM-142)

    /// The zone whose name is being edited in its row, or `nil`.
    public var renamingZoneID: UUID?
    /// The text in the row's rename field.
    public var renameDraft: String = ""

    /// Opens a zone's name for editing in its row.
    public func beginRename(zoneID: UUID) {
        guard let subject = zone(zoneID) else { return }
        renamingZoneID = zoneID
        renameDraft = subject.name
    }

    /// Commits the row's rename. Unchanged text closes the field without an edit; a refused
    /// name keeps the field open with the refusal stated.
    @discardableResult
    public func commitRename() -> Bool {
        guard let zoneID = renamingZoneID, let subject = zone(zoneID) else {
            renamingZoneID = nil
            return false
        }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == subject.name {
            renamingZoneID = nil
            return true
        }
        guard rename(zoneID: zoneID, to: trimmed) else { return false }
        renamingZoneID = nil
        return true
    }

    /// Closes the rename field without an edit.
    public func cancelRename() {
        renamingZoneID = nil
        refusal = nil
    }

    /// The zones a zone may be moved into: every zone but itself and its descendants, in tree
    /// order. `nil` lists every zone (for a draft).
    public func parentChoices(for zoneID: UUID?) -> [ProjectZoneSummary] {
        treeOrdered.filter { candidate in
            guard let zoneID else { return true }
            return candidate.id != zoneID && !isDescendant(candidate.id, of: zoneID)
        }
    }

    /// The Delete item's title: it says why it is unavailable instead of being silently off.
    public static func deleteTitle(markupCount: Int) -> String {
        guard markupCount > 0 else {
            return NSLocalizedString("Delete Zone", comment: "Zone row menu")
        }
        return LocalizedPlural.string(
            "Delete Zone (move its %lld markups first)",
            count: markupCount,
            one: NSLocalizedString(
                "Delete Zone (move its %lld markup first)",
                comment: "Zone row menu: delete is unavailable while one markup is filed in the zone"
            ),
            other: NSLocalizedString(
                "Delete Zone (move its %lld markups first)",
                comment: "Zone row menu: delete is unavailable while markups are filed in the zone"
            )
        )
    }

    // MARK: - Editing a zone

    /// Renames an existing zone.
    @discardableResult
    public func rename(zoneID: UUID, to name: String) -> Bool {
        guard zone(zoneID) != nil else { return refuse(.unknownZone) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return refuse(.nameEmpty) }
        guard !zones.contains(where: { $0.id != zoneID && $0.name == trimmed }) else {
            return refuse(.nameTaken(trimmed))
        }
        refusal = nil
        onRenameZone?(zoneID, trimmed)
        return true
    }

    /// Changes what a zone represents.
    @discardableResult
    public func setKind(_ kind: ProjectZoneKind, zoneID: UUID) -> Bool {
        guard zone(zoneID) != nil else { return refuse(.unknownZone) }
        refusal = nil
        onSetZoneKind?(zoneID, kind)
        return true
    }

    /// Recolours a zone from the named palette, so it keeps a spoken colour name.
    @discardableResult
    public func setColor(paletteID: String, zoneID: UUID) -> Bool {
        guard zone(zoneID) != nil else { return refuse(.unknownZone) }
        guard let entry = ZenitMarkupPalette.entries.first(where: { $0.id == paletteID }) else {
            return false
        }
        refusal = nil
        onSetZoneColor?(zoneID, entry.color)
        return true
    }

    /// Shows or hides one zone boundary.
    @discardableResult
    public func setVisible(_ visible: Bool, zoneID: UUID) -> Bool {
        guard zone(zoneID) != nil else { return refuse(.unknownZone) }
        refusal = nil
        onSetZoneVisible?(zoneID, visible)
        return true
    }

    /// Moves a zone under another one, refusing the two ways that would make a cycle.
    @discardableResult
    public func setParent(_ parentID: UUID?, zoneID: UUID) -> Bool {
        guard let subject = zone(zoneID) else { return refuse(.unknownZone) }
        if let parentID {
            guard let parent = zone(parentID) else { return refuse(.unknownZone) }
            guard parentID != zoneID else { return refuse(.circularParent(name: subject.name)) }
            guard !isDescendant(parentID, of: zoneID) else {
                return refuse(.circularParent(name: parent.name))
            }
        }
        refusal = nil
        onSetZoneParent?(zoneID, parentID)
        return true
    }

    /// Deletes a zone, refusing while it still holds markups.
    ///
    /// Deleting a zone that holds forty markups is not a small action, and the count in the
    /// refusal is the number the estimator needs to decide what to do about it.
    @discardableResult
    public func delete(zoneID: UUID) -> Bool {
        guard let subject = zone(zoneID) else { return refuse(.unknownZone) }
        guard subject.markupCount == 0 else {
            return refuse(.zoneNotEmpty(name: subject.name, markupCount: subject.markupCount))
        }
        refusal = nil
        onDeleteZone?(zoneID)
        if selection == zoneID { selection = nil }
        return true
    }

    // MARK: - Zone as a grouping key

    /// Files the canvas selection into a zone. This is what puts rows in the grouping.
    @discardableResult
    public func assignSelection(to zoneID: UUID) -> Bool {
        guard zone(zoneID) != nil else { return refuse(.unknownZone) }
        guard selectedMarkupCount > 0 else { return refuse(.nothingSelected) }
        guard let onAssignSelection else { return refuse(.notWired) }
        refusal = nil
        onAssignSelection(zoneID)
        return true
    }

    /// Groups the Quantity Ledger by Project Zone.
    ///
    /// The ledger has offered this grouping level since it was written; until zones could be
    /// created it grouped by a column nothing could fill. The action lives here because this
    /// is the panel where the person has just made the zones.
    @discardableResult
    public func groupLedgerByZone() -> Bool {
        guard let onGroupLedger else { return refuse(.notWired) }
        refusal = nil
        onGroupLedger(.projectZone)
        return true
    }

    // MARK: - Private

    private func isDescendant(_ candidate: UUID, of ancestor: UUID) -> Bool {
        var current = zone(candidate)?.parentID
        var guardCount = zones.count + 1
        while let id = current, guardCount > 0 {
            if id == ancestor { return true }
            current = zone(id)?.parentID
            guardCount -= 1
        }
        return false
    }

    @discardableResult
    private func refuse(_ reason: ProjectZoneRefusal) -> Bool {
        refusal = reason
        return false
    }

    private func suggestedName() -> String {
        let format = NSLocalizedString(
            "Zone %d",
            comment: "Default name for a newly created Project Zone, with its number"
        )
        let taken = Set(zones.map(\.name))
        var number = zones.count + 1
        var candidate = String(format: format, number)
        while taken.contains(candidate) {
            number += 1
            candidate = String(format: format, number)
        }
        return candidate
    }
}
