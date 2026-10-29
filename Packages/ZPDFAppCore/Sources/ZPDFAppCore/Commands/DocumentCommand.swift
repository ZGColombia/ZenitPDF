import Foundation
import ZPDFContracts

/// Every mutation a document can undergo, as a value (spec 14.5).
///
/// The eleven cases are exactly the eleven names in spec 14.5, and the enumeration is
/// closed: a mutation that is not in this list cannot reach the session, which is what
/// makes "everything the user does is undoable" checkable rather than aspirational.
/// `MarkupCommandKind` is the frozen on-disk spelling and ``kind`` is the mapping to it.
public enum DocumentCommand: Sendable {

    /// Adds a markup. Its measurement is computed by the session, not supplied.
    case addMarkup(MarkupRecord)

    /// Removes a markup, and any cutouts that hang off it.
    case removeMarkup(MarkupID)

    /// Translates a markup's geometry in page space.
    case moveMarkup(id: MarkupID, dx: Double, dy: Double)

    /// Replaces a markup's style.
    case changeStyle(id: MarkupID, style: MarkupStyle)

    /// Replaces a markup's geometry, then recomputes its measurement.
    case editVertices(id: MarkupID, geometry: MeasurementGeometry)

    /// Replaces a markup's measurement parameters, then recomputes its measurement.
    ///
    /// The sibling of ``editVertices(id:geometry:)`` and deliberately shaped like it: depth,
    /// wall height, slope magnitude and azimuth, the cutout and perimeter policies and the
    /// volume depth reference are inputs to the calculation exactly as the vertices are, so
    /// changing one has to run the same engine path and produce the same provenance rather
    /// than a number written in from the side.
    ///
    /// It exists because the Tool Library's Apply mode needs it: applying
    /// "Slab 200 mm" to twelve areas is twelve recomputations, each with its own audit entry,
    /// under one undo. Before this case the only way to change a parameter was to rebuild the
    /// markup, which is a different id, a different creation date and a broken audit trail.
    case editParameters(id: MarkupID, parameters: MeasurementParameters)

    /// Installs a scale. Markups measured against the previous version become stale and
    /// are recomputed, because a takeoff whose numbers predate its scale is a wrong
    /// takeoff that looks right.
    case changeScale(ScaleTransform)

    /// Recomputes measurements, for one page or for the whole document.
    case recalculateMeasurements(pageID: PageID?)

    /// Adds a cutout to a parent markup and recomputes the parent's net area.
    case addCutout(parent: MarkupID, cutout: MarkupRecord)

    /// Writes a user value into one custom ledger cell.
    case editCustomValue(id: MarkupID, column: ColumnID, value: LedgerCellValue)

    /// Sets the review status of several markups at once.
    case batchStatusChange(ids: [MarkupID], status: ZPDFContracts.MarkupStatus)

    /// Renames a markup's subject — the ledger's standard `subject` column, edited from the
    /// inspector's Measurement section or the ledger row.
    case editSubject(id: MarkupID, subject: String)

    /// Turns a placed stamp about its own anchor, in degrees counter-clockwise.
    ///
    /// `StampInstance.rotationDegrees` has been stored, persisted, honoured by the renderer and
    /// settable from a template since stamps were introduced, and until this case there was
    /// **no mutation that could change it** — so the canvas's rotation handle would have had
    /// nowhere to write and a turn would not have survived ⌘Z, a save or a reopen.
    ///
    /// It is a command rather than a style edit or a geometry edit for the reason every other
    /// case here is one: undo is a state patch taken by ``TakeoffSession``, and a rotation
    /// written around the session is a rotation the undo stack does not know happened.
    /// A record that is not a stamp is left alone rather than gaining an instance.
    case rotateStamp(id: MarkupID, degrees: Double)

    /// Rewrites a markup's label — the ledger's standard `label` column, edited from the
    /// ledger row or from a bulk edit across a selection.
    case editLabel(id: MarkupID, label: String)

    /// Rewrites a markup's free-text comment — the Inspector's Notes field and the ledger's
    /// standard `comment` column.
    ///
    /// The comment was stored, persisted (`markup.comment`), searched and shown since the first
    /// schema, and there was **no mutation that could change it**: a Notes edit reached
    /// `applyBulkEdit`, matched no case, produced an empty batch and came back as a success
    /// that changed nothing. Same shape as ``editLabel``: one field, undo as a state patch.
    case editComment(id: MarkupID, comment: String)

    /// Rewrites the words a Text or Callout draws (NL-COLLAB-18) — its `caption`, which is not
    /// its review note. Before this the drawn words lived in `comment`, so a note rewrote the
    /// sheet. Same shape as ``editComment``: one field, undo as a state patch.
    case editText(id: MarkupID, text: String)

    /// Moves a page within the document.
    case reorderPage(from: Int, to: Int)

    /// Names sheets (NL-DOCS-05): a `nil` value clears a page's identity. With
    /// `overwriteManual` false — an automatic reading, the title-block reader's — a page a
    /// person named by hand is left as it is. One undo step for the whole batch.
    case setSheetIdentities([PageID: SheetIdentity?], overwriteManual: Bool)

    /// Puts pages into the set at a position (NL-DOCS-04): the sheets of a drawing added to the
    /// project. The inverse is the previous order; the pages stay known to the session, so a
    /// redo brings them back with the same identities.
    case insertPages([ZPDFContracts.PageDescriptor], at: Int)

    /// Removes sheets from the set, or puts them back (NL-DOCS-07). Nothing is deleted: the
    /// page and its markups are set aside, out of the canvas and the ledger, and saved.
    case setPagesExcluded([PageID], excluded: Bool)

    /// Sets how sheets are shown — view rotation and crop (NL-DOCS-07/16). Display only; a
    /// `nil` value returns a sheet to its own view. One undo step for the batch.
    case setPageViews([PageID: PageViewSettings?])

    /// Replaces the document's whole Scale Region set.
    ///
    /// Whole-set rather than per-region, because a region's `priority` is only meaningful
    /// relative to the others: writing one of them and leaving the rest is exactly how two
    /// regions end up tied, which the resolver reports as ambiguous rather than guessing. The
    /// inverse is the previous set, so undo is exact by construction.
    ///
    /// Markups that referenced a region this command removes have their `scaleRegionID`
    /// cleared and their measurements recomputed against the document default. That is not a
    /// courtesy: `markup.scale_region_id` is a foreign key, so a markup left pointing at a
    /// deleted region would make the next save fail outright.
    case setScaleRegions([ScaleRegionDefinition])

    /// Replaces the document's whole Project Zone set, with the same whole-set reasoning and
    /// the same dangling-reference cleanup for `zoneID`.
    case setProjectZones([ProjectZoneDefinition])

    /// Files several markups into a Project Zone, or out of every zone when `zoneID` is `nil`.
    ///
    /// This is what puts rows under a zone subtotal. It is a batch because filing a selection
    /// is one action to the person doing it, and eleven undo entries for one drag would be a
    /// lie about what Cmd-Z does.
    case setMarkupZone(ids: [MarkupID], zoneID: ZoneID?)

    /// Assigns several markups to a Scale Region and to the scale that region carries, or back
    /// to the page default when both are `nil`. The measurements are recomputed.
    ///
    /// The region and the scale travel together on purpose. A markup that names a region but
    /// keeps the page scale is a row whose provenance says one thing and whose number says
    /// another, and that is the silent wrongness `CORE_LOOP.md` names first.
    case setMarkupScaleRegion(ids: [MarkupID], regionID: ScaleRegionID?, scaleID: ScaleID?)

    /// Appends runtime ledger columns — a table import's — as one undoable step.
    ///
    /// Column addition used to happen around the command bus, so ⌘Z took the imported rows
    /// back and left their columns in the ledger (IM-184). Performed in the same batch
    /// as the rows' `.addMarkup` commands, one ⌘Z removes both.
    case addCustomColumns([LedgerColumnDefinition])

    /// Replaces the whole set of user ledger columns — the Column Manager's add, rename,
    /// retype, reorder and delete (NL-QTY-02). The inverse is the previous list, exactly as for
    /// ``addCustomColumns(_:)``, so undo is the same shape. Stored cell values are untouched:
    /// a deleted column's values stay on their markups, so ⌘Z brings the column back full.
    case setCustomColumns([LedgerColumnDefinition])

    /// Locks or unlocks markups. A locked markup refuses every edit; this is the one command
    /// that changes a locked markup, because it is the way out (IM-023).
    case setLocked(ids: [MarkupID], locked: Bool)

    /// Hides or shows markups on the canvas. Hiding changes no quantity (IM-023).
    case setHidden(ids: [MarkupID], hidden: Bool)

    /// Moves markups in the draw order of their page (NL-MARKUP-13, ADR-0029): the document's
    /// markup order *is* the draw order, and the archive stores it, so arranging adds no field.
    case arrangeMarkups(ids: [MarkupID], arrangement: MarkupArrangement)

    /// Puts markups in one group, or takes them out of any (`nil`) (NL-MARKUP-11, ADR-0029).
    case setMarkupGroup(ids: [MarkupID], groupID: MarkupGroupID?)

    /// Sets or clears a hyperlink markup's destination (NL-MARKUP-17, ADR-0029).
    case setMarkupLink(id: MarkupID, link: MarkupLinkTarget?)

    /// Replaces the project's markup layer list — a new layer, a rename, a reorder or a flag
    /// (ADR-0032). `change` names the step for the Undo menu. The default layer is always kept;
    /// markups on a layer the new list drops move to the default layer in the same step.
    case setMarkupLayers([MarkupLayer], change: MarkupLayerChange)

    /// Moves markups to a layer (ADR-0032). The default layer is stored as no layer id.
    case setMarkupLayer(ids: [MarkupID], layerID: LayerID)

    /// Deletes a layer and moves its markups to `moveMarkupsTo`, one step (ADR-0032). The
    /// default layer cannot be deleted.
    case deleteMarkupLayer(LayerID, moveMarkupsTo: LayerID)

    /// The frozen command name, which is what a persisted undo stack stores.
    public var kind: MarkupCommandKind {
        switch self {
        case .addMarkup: .addMarkup
        case .removeMarkup: .removeMarkup
        case .moveMarkup: .moveMarkup
        case .changeStyle: .changeStyle
        case .editVertices: .editVertices
        // The frozen `MarkupCommandKind` list (spec 14.5, MARKUP_CONTRACT) has no name for a
        // parameter edit, and inventing one would be a contract change requiring an ADR. The
        // column-edit name is the honest nearest, exactly as it is for `editSubject` and
        // `editLabel` below: this writes a field of the takeoff that is neither geometry nor a
        // scale.
        case .editParameters: .editCustomValue
        case .changeScale: .changeScale
        case .recalculateMeasurements: .recalculateMeasurements
        case .addCutout: .addCutout
        case .editCustomValue: .editCustomValue
        case .batchStatusChange: .batchStatusChange
        case .reorderPage: .reorderPage
        // A sheet's name is a field of the set, neither geometry nor a scale; the frozen kind
        // list has no dedicated name, and the column-edit name is the honest nearest, as for
        // every structure edit below.
        case .setSheetIdentities: .editCustomValue
        // Arranging the set is a page operation; the frozen list names only a reorder, the
        // honest nearest for an insertion or a removal from the set. A view rotation or crop
        // is a field of the set, like a sheet name.
        case .insertPages, .setPagesExcluded: .reorderPage
        case .setPageViews: .editCustomValue

        // The frozen `MarkupCommandKind` has no name for a project-structure edit, and
        // inventing one would be a contract change (ADR). `editCustomValue` is the honest
        // nearest for all four: each one writes a field of the takeoff that is not geometry
        // and not a scale. The precedent is `editSubject` directly above.
        case .setScaleRegions: .editCustomValue
        case .setProjectZones: .editCustomValue
        case .setMarkupZone: .editCustomValue
        case .setMarkupScaleRegion: .editCustomValue
        // Subject is the ledger's standard `subject` column; the frozen kind list
        // (spec 14.5, MARKUP_CONTRACT) has no dedicated case, and the column-edit name
        // is the honest nearest. A dedicated case would be a contract change (ADR).
        case .editSubject: .editCustomValue
        // Label is the ledger's standard `label` column. Same reasoning as `editSubject`
        // directly above: the frozen kind list has no dedicated name, and inventing one
        // would be a contract change requiring an ADR.
        case .editLabel: .editCustomValue
        // The comment is the ledger's standard `comment` column, with the same reasoning as
        // `editSubject` and `editLabel`: no dedicated frozen name, and inventing one would be
        // a contract change requiring an ADR.
        case .editComment: .editCustomValue
        // A text box's drawn words, with the same reasoning as `editComment` (ADR-0021).
        case .editText: .editCustomValue
        // A stamp's angle is a property of the placed markup, so the frozen spelling closest
        // to it is the same one `editSubject` and `editLabel` take. A dedicated
        // `MarkupCommandKind` would be a contract change, and the audit note already carries
        // the template and the resolved values that say which stamp turned.
        case .rotateStamp: .editCustomValue
        // A column set, a lock and a visibility flag are fields of the takeoff that are neither
        // geometry nor a scale; the frozen kind list has no dedicated names, and the column-edit
        // name is the honest nearest, as for every structure edit above.
        case .addCustomColumns, .setCustomColumns, .setLocked, .setHidden: .editCustomValue
        // ADR-0029: a draw position, a group and a link are fields of the markup that are
        // neither geometry nor a scale; the frozen kind list has no names for them, and the
        // column-edit name is the honest nearest, as for every structure edit above.
        case .arrangeMarkups, .setMarkupGroup, .setMarkupLink: .editCustomValue
        // ADR-0032: a markup's layer and the project's layer list are fields of the takeoff that
        // are neither geometry nor a scale; the same honest nearest as every structure edit.
        case .setMarkupLayers, .setMarkupLayer, .deleteMarkupLayer: .editCustomValue
        }
    }

    /// Whether the command can change which scale is in force somewhere on the sheet, so
    /// the status bar's scale segment has to be re-read after it.
    ///
    /// Answered from the command, not from ``kind``: the frozen `MarkupCommandKind` folds
    /// `setScaleRegions` and `setMarkupScaleRegion` into `editCustomValue`, and reading
    /// `kind == .changeScale` off that mapping made `DocumentChangeSet.invalidatesScale`
    /// false for exactly the two commands that install or reassign a region's scale (CR-14).
    /// Recalibrating is the obvious case; a region edit is the one that was missed.
    public var invalidatesScale: Bool {
        switch self {
        case .changeScale, .setScaleRegions, .setMarkupScaleRegion: true
        default: false
        }
    }

    /// The localized name that appears in the Edit menu after "Undo".
    ///
    /// `UndoManager` shows it verbatim, so it is a noun phrase in sentence case — "Undo
    /// Add Area", not "Undo added an area".
    public var undoActionName: String {
        switch self {
        case .addMarkup(let record):
            Self.addActionName(for: record)
        case .removeMarkup:
            NSLocalizedString("Delete Markup", comment: "Undo action name for deleting a markup")
        case .moveMarkup:
            NSLocalizedString("Move Markup", comment: "Undo action name for moving a markup")
        case .changeStyle:
            NSLocalizedString("Change Style", comment: "Undo action name for a style change")
        case .editVertices:
            NSLocalizedString("Edit Vertices", comment: "Undo action name for a vertex edit")
        case .editParameters:
            NSLocalizedString(
                "Edit Measurement Parameters",
                comment: "Undo action name for changing a markup's depth, height or slope"
            )
        case .changeScale:
            NSLocalizedString("Change Scale", comment: "Undo action name for a scale change")
        case .recalculateMeasurements:
            NSLocalizedString("Recalculate", comment: "Undo action name for recalculating measurements")
        case .addCutout:
            NSLocalizedString("Add Cutout", comment: "Undo action name for adding a cutout")
        case .editCustomValue:
            NSLocalizedString("Edit Value", comment: "Undo action name for editing a ledger cell")
        case .batchStatusChange:
            NSLocalizedString("Change Status", comment: "Undo action name for a batch status change")
        case .reorderPage:
            NSLocalizedString("Reorder Pages", comment: "Undo action name for moving a page")
        case .setSheetIdentities:
            NSLocalizedString("Name Sheets", comment: "Undo action name for naming sheets (number and title)")
        case .insertPages:
            NSLocalizedString("Add Drawing to Project", comment: "Undo action name for adding a drawing's sheets to the project set")
        case .setPagesExcluded(_, let excluded):
            excluded
                ? NSLocalizedString("Remove from Set", comment: "Undo action name for removing sheets from the set")
                : NSLocalizedString("Restore to Set", comment: "Undo action name for putting removed sheets back into the set")
        case .setPageViews:
            NSLocalizedString("Change Sheet View", comment: "Undo action name for rotating or cropping how a sheet is shown")
        case .setScaleRegions:
            NSLocalizedString("Edit Scale Regions", comment: "Undo action name for a Scale Region change")
        case .setProjectZones:
            NSLocalizedString("Edit Project Zones", comment: "Undo action name for a Project Zone change")
        case .setMarkupZone:
            NSLocalizedString("Assign Zone", comment: "Undo action name for filing markups into a zone")
        case .setMarkupScaleRegion:
            NSLocalizedString("Assign Scale Region", comment: "Undo action name for assigning a Scale Region")
        case .editSubject:
            NSLocalizedString("Edit Subject", comment: "Undo action name for renaming a markup's subject")
        case .editLabel:
            NSLocalizedString("Edit Label", comment: "Undo action name for rewriting a markup's label")
        case .editComment:
            NSLocalizedString("Edit Notes", comment: "Undo action name for rewriting a markup's comment (the Inspector's Notes)")
        case .editText:
            NSLocalizedString("Edit Text", comment: "Undo action name for rewriting the text a text box or callout draws")
        case .rotateStamp:
            NSLocalizedString("Rotate Stamp", comment: "Undo action name for turning a placed stamp")
        case .addCustomColumns:
            NSLocalizedString("Add Ledger Columns", comment: "Undo action name for adding imported ledger columns")
        case .setCustomColumns:
            NSLocalizedString("Edit Ledger Columns", comment: "Undo action name for a Column Manager change")
        case .setLocked(_, let locked):
            locked
                ? NSLocalizedString("Lock", comment: "Undo action name for locking markups")
                : NSLocalizedString("Unlock", comment: "Undo action name for unlocking markups")
        case .setHidden(_, let hidden):
            hidden
                ? NSLocalizedString("Hide", comment: "Undo action name for hiding markups")
                : NSLocalizedString("Show", comment: "Undo action name for showing markups")
        case .arrangeMarkups(_, let arrangement):
            arrangement.actionName
        case .setMarkupGroup(_, let groupID):
            groupID == nil
                ? NSLocalizedString("Ungroup", comment: "Undo action name for ungrouping markups")
                : NSLocalizedString("Group", comment: "Undo action name for grouping markups")
        case .setMarkupLink:
            NSLocalizedString("Change Link", comment: "Undo action name for editing a hyperlink markup's destination")
        case .setMarkupLayers(_, let change):
            change.actionName
        case .setMarkupLayer:
            NSLocalizedString("Move to Layer", comment: "Undo action name for moving markups to another markup layer")
        case .deleteMarkupLayer:
            NSLocalizedString("Delete Layer", comment: "Undo action name for deleting a markup layer")
        }
    }
}

/// Where an arrange command moves markups in their page's draw order (NL-MARKUP-13).
public enum MarkupArrangement: String, Sendable, Hashable, CaseIterable {
    /// Above every other markup on the page.
    case bringToFront
    /// One step up: above the next markup it overlaps in the order.
    case bringForward
    /// One step down.
    case sendBackward
    /// Below every other markup on the page.
    case sendToBack

    /// The command's name in the Edit menu and the undo stack.
    public var actionName: String {
        switch self {
        case .bringToFront: NSLocalizedString("Bring to Front", comment: "Arrange command")
        case .bringForward: NSLocalizedString("Bring Forward", comment: "Arrange command")
        case .sendBackward: NSLocalizedString("Send Backward", comment: "Arrange command")
        case .sendToBack: NSLocalizedString("Send to Back", comment: "Arrange command")
        }
    }

    /// The new order of one page's markups, bottom to top, after moving `moving`.
    ///
    /// Pure. Moved markups keep their relative order. A step moves each block of moved markups
    /// past exactly one unmoved neighbour, so Bring Forward on the topmost markup is a no-op.
    public func reorder<ID: Hashable>(_ order: [ID], moving: Set<ID>) -> [ID] {
        let moved = order.filter { moving.contains($0) }
        guard !moved.isEmpty else { return order }
        let others = order.filter { !moving.contains($0) }
        switch self {
        case .bringToFront:
            return others + moved
        case .sendToBack:
            return moved + others
        case .bringForward:
            var result = order
            var index = result.count - 2
            while index >= 0 {
                if moving.contains(result[index]), !moving.contains(result[index + 1]) {
                    // Move the whole moved block ending here past the neighbour above it.
                    var start = index
                    while start > 0, moving.contains(result[start - 1]) { start -= 1 }
                    let neighbour = result.remove(at: index + 1)
                    result.insert(neighbour, at: start)
                    index = start - 1
                } else {
                    index -= 1
                }
            }
            return result
        case .sendBackward:
            var result = order
            var index = 1
            while index < result.count {
                if moving.contains(result[index]), !moving.contains(result[index - 1]) {
                    var end = index
                    while end < result.count - 1, moving.contains(result[end + 1]) { end += 1 }
                    let neighbour = result.remove(at: index - 1)
                    result.insert(neighbour, at: end)
                    index = end + 1
                } else {
                    index += 1
                }
            }
            return result
        }
    }
}

/// The exact inverse of an applied command, as a value.
///
/// Undo is a state patch rather than an opposing command, and that is a deliberate choice:
/// a command's opposite is not always another command in the spec's list. Deleting a
/// markup that carries three cutouts, or installing a scale that restamps four hundred
/// stale measurements, has no single-case inverse — but it does have an exact previous
/// state, which is what this records.
///
/// Every field is "what these identifiers looked like before", so applying an inverse is
/// idempotent and two inverses compose by replacement rather than by ordering.
public struct DocumentCommandInverse: Sendable {

    /// Markups to restore. A `nil` value means the markup did not exist before and must be
    /// removed again — that is how an added markup's inverse is expressed.
    public var markups: [MarkupID: MarkupRecord?]
    /// The whole markup order, when the command changed it.
    public var markupOrder: [MarkupID]?
    /// Where each markup this patch **re-inserts** stood in the order, when the patch does not
    /// carry the whole order.
    ///
    /// The redo of an add — and of a batch of adds — used to restore its records from the
    /// ``markups`` dictionary and append them in whatever order the keys hashed into, so
    /// eleven markups drawn A…K came back K, C, F… after one undo/redo, differently in every
    /// process (CR-6). Recording the position is what makes the re-insertion exact without
    /// copying a 10 000-entry order onto the undo stack for every single add.
    public var markupPositions: [MarkupID: Int]?
    /// The scale to reinstate, when the command changed one.
    public var scale: ScaleTransform?
    /// The whole page->scale assignment before the command, when the command changed it.
    ///
    /// The whole map rather than one page's entry: installing a scale can assign it to the page
    /// it was calibrated on, and reverting has to put back the state that existed before —
    /// including the *absence* of an entry, which a single optional cannot express.
    public var pageScaleIDs: [PageID: ScaleID]?
    /// A scale to *remove*, because the command installed it and it did not exist before.
    ///
    /// `scale: nil` means "no scale change", so without this field the inverse of the
    /// document's **first** calibration was inexpressible: its before-state has no scale to
    /// reinstate, the inverse came out empty, no undo was registered, and the one mutation
    /// CORE_LOOP promises is always reversible ("one ⌘Z returns to the previous scale")
    /// silently was not — found by the CORE_LOOP acceptance test.
    public var removedScaleID: ScaleID?
    /// The page order to reinstate, when the command changed it.
    public var pageOrder: [PageID]?
    /// The whole Scale Region set to reinstate, when the command changed it.
    public var scaleRegions: [ScaleRegionDefinition]?
    /// The whole Project Zone set to reinstate, when the command changed it.
    public var projectZones: [ProjectZoneDefinition]?
    /// The Project Zone each **set-aside** markup is filed in, to reinstate after the page order
    /// is restored; a `nil` value means unfiled (V-038).
    ///
    /// A markup returning with its sheet is unfiled from a zone deleted while the sheet was out
    /// of the set (U-028), and that happens inside the page-order sweep, not in a markup patch.
    /// Without this the undo of the restore set the markup aside again unfiled, and undoing the
    /// zone deletion after it refiled nothing. Applied only to markups set aside at that moment.
    public var setAsideZones: [MarkupID: ZoneID?]?
    /// The calibration evidence to reinstate per scale, when a calibration changed it.
    ///
    /// A `nil` value means the scale had no evidence before — a preset scale, or a page's
    /// first calibration — and the entry must be removed again. Undo used to restore the
    /// transform and leave the evidence of the calibration being undone in place, so every
    /// derivation recomputed afterwards, and the scale row the next save wrote, cited the
    /// points and entered length of a calibration the document no longer had (CR-5).
    public var calibrationEvidence: [ScaleID: CalibrationEvidence?]?
    /// The runtime ledger columns to reinstate, when the command changed them.
    public var customColumns: [LedgerColumnDefinition]?
    /// Sheet identities to reinstate, per page; a `nil` value means the page had none
    /// (NL-DOCS-05).
    public var sheetIdentities: [PageID: SheetIdentity?]?
    /// Sheet views to reinstate, per page; a `nil` value means the page had its own view
    /// (NL-DOCS-07/16).
    public var pageViews: [PageID: PageViewSettings?]?
    /// The project's markup layer list to reinstate, when the command changed it (ADR-0032).
    public var markupLayers: [MarkupLayer]?
    /// Further scales to reinstate beyond ``scale``, for a step that changed several pages'
    /// scales at once (a bulk apply, NL-MEASURE-02). Empty for every single-scale command.
    public var additionalScales: [ScaleTransform] = []
    /// Further scales to remove beyond ``removedScaleID``, for the same multi-page step.
    public var additionalRemovedScaleIDs: [ScaleID] = []

    /// Records the zones a page-order change unfiled returning markups from, so undoing it sets
    /// them aside filed again (V-038). Nothing is recorded when nothing was unfiled.
    mutating func recordUnfiledOnReturn(_ unfiled: [MarkupID: ZoneID]) {
        guard !unfiled.isEmpty else { return }
        setAsideZones = unfiled.mapValues { Optional($0) }
    }

    /// ``scale`` and ``additionalScales`` together.
    var allScales: [ScaleTransform] { (scale.map { [$0] } ?? []) + additionalScales }
    /// ``removedScaleID`` and ``additionalRemovedScaleIDs`` together.
    var allRemovedScaleIDs: [ScaleID] { (removedScaleID.map { [$0] } ?? []) + additionalRemovedScaleIDs }

    /// Sets the scale lists from flat arrays: the first entry in the single-valued field, the
    /// rest in the additional one, so a one-scale patch looks exactly as it always did.
    mutating func setScales(_ reinstated: [ScaleTransform], removed: [ScaleID]) {
        scale = reinstated.first
        additionalScales = Array(reinstated.dropFirst())
        removedScaleID = removed.first
        additionalRemovedScaleIDs = Array(removed.dropFirst())
    }

    /// Creates an inverse.
    public init(
        markups: [MarkupID: MarkupRecord?] = [:],
        markupOrder: [MarkupID]? = nil,
        scale: ScaleTransform? = nil,
        pageScaleIDs: [PageID: ScaleID]? = nil,
        removedScaleID: ScaleID? = nil,
        pageOrder: [PageID]? = nil,
        scaleRegions: [ScaleRegionDefinition]? = nil,
        projectZones: [ProjectZoneDefinition]? = nil,
        calibrationEvidence: [ScaleID: CalibrationEvidence?]? = nil,
        markupPositions: [MarkupID: Int]? = nil
    ) {
        self.markups = markups
        self.markupOrder = markupOrder
        self.markupPositions = markupPositions
        self.scale = scale
        self.pageScaleIDs = pageScaleIDs
        self.removedScaleID = removedScaleID
        self.pageOrder = pageOrder
        self.scaleRegions = scaleRegions
        self.projectZones = projectZones
        self.calibrationEvidence = calibrationEvidence
    }

    /// A patch that changes nothing. Used as a placeholder while a command is being
    /// applied, before the after-state it describes exists.
    public static let empty = DocumentCommandInverse()

    /// Whether applying this inverse over the state `forward` describes would change nothing a
    /// person can see — the same records (their `modifiedAt` stamp aside), the same order, the
    /// same scales and structure.
    ///
    /// ``isEmpty`` asks only whether any field is *mentioned*. `applyEdit` always mentions the
    /// record it touched, so a Rotate Stamp on a non-stamp, a style set to itself or a subject
    /// retyped identically registered an undo whose effect is nothing and dirtied the document
    /// (BH-422). This is the test that tells the two apart.
    func isNoOp(against forward: DocumentCommandInverse) -> Bool {
        guard removedScaleID == nil, additionalRemovedScaleIDs.isEmpty else { return false }
        if additionalScales != forward.additionalScales { return false }
        for (id, before) in markups {
            let after = forward.markups[id] ?? nil
            switch (before, after) {
            case (nil, nil):
                continue
            case let (before?, after?):
                var lhs = before
                var rhs = after
                lhs.modifiedAt = .distantPast
                rhs.modifiedAt = .distantPast
                guard lhs == rhs else { return false }
            default:
                return false
            }
        }
        if let markupOrder, markupOrder != forward.markupOrder { return false }
        if let scale, scale != forward.scale { return false }
        if let pageScaleIDs, pageScaleIDs != forward.pageScaleIDs { return false }
        if let pageOrder, pageOrder != forward.pageOrder { return false }
        if let scaleRegions, scaleRegions != forward.scaleRegions { return false }
        if let projectZones, projectZones != forward.projectZones { return false }
        if let calibrationEvidence, calibrationEvidence != forward.calibrationEvidence { return false }
        if let customColumns, customColumns != forward.customColumns { return false }
        if let sheetIdentities, sheetIdentities != forward.sheetIdentities { return false }
        if let pageViews, pageViews != forward.pageViews { return false }
        if let markupLayers, markupLayers != forward.markupLayers { return false }
        if let setAsideZones, setAsideZones != forward.setAsideZones { return false }
        return true
    }

    /// Whether the inverse would change anything.
    public var isEmpty: Bool {
        markups.isEmpty && markupOrder == nil && scale == nil && removedScaleID == nil
            && additionalScales.isEmpty && additionalRemovedScaleIDs.isEmpty
            && pageScaleIDs == nil && pageOrder == nil && scaleRegions == nil
            && projectZones == nil && calibrationEvidence == nil && customColumns == nil
            && sheetIdentities == nil && pageViews == nil && markupLayers == nil
            && setAsideZones == nil
    }
}

/// What one applied command changed, so the presenters know what to refresh.
public struct DocumentCommandOutcome: Sendable {

    /// The command that ran.
    public let command: DocumentCommand
    /// The state before the command: applying it undoes the command.
    public let inverse: DocumentCommandInverse
    /// The state after the command, over the same identifiers: applying it redoes the
    /// command.
    ///
    /// Both directions are captured here, at apply time, rather than the redo patch being
    /// derived later. That is what lets ``DocumentCommandBus`` register the opposite
    /// direction with `UndoManager` *synchronously*, inside the undo invocation — and
    /// `UndoManager` decides which of its two stacks a registration lands on by whether it
    /// is undoing at that instant. Registering after an `await` lands on the wrong stack,
    /// and the symptom is a second Undo silently performing a Redo.
    public let forward: DocumentCommandInverse
    /// The markups whose row, canvas geometry or measurement changed.
    public let changedMarkupIDs: Set<MarkupID>
    /// The pages whose snap index and canvas contents changed.
    public let changedPageIDs: Set<PageID>

    /// Creates an outcome.
    public init(
        command: DocumentCommand,
        inverse: DocumentCommandInverse,
        forward: DocumentCommandInverse,
        changedMarkupIDs: Set<MarkupID>,
        changedPageIDs: Set<PageID>
    ) {
        self.command = command
        self.inverse = inverse
        self.forward = forward
        self.changedMarkupIDs = changedMarkupIDs
        self.changedPageIDs = changedPageIDs
    }
}

/// What one *batch* of commands changed, as one user-visible step.
///
/// The batch equivalent of ``DocumentCommandOutcome``: one merged inverse (so one undo
/// entry), one merged forward (so one redo entry), and the commands that actually ran, in
/// order, for the audit fan-out that ADR-0007 §2 requires — one entry per affected markup,
/// all sharing one `undo_group`.
public struct DocumentBatchOutcome: Sendable {

    /// The commands that were applied, in order.
    public let commands: [DocumentCommand]
    /// The state of every touched identifier **before** the batch began.
    public let inverse: DocumentCommandInverse
    /// The state of the same identifiers **after** the batch finished.
    public let forward: DocumentCommandInverse
    /// The markups whose row, canvas geometry or measurement changed.
    public let changedMarkupIDs: Set<MarkupID>
    /// The pages whose snap index and canvas contents changed.
    public let changedPageIDs: Set<PageID>

    /// Creates a batch outcome.
    public init(
        commands: [DocumentCommand],
        inverse: DocumentCommandInverse,
        forward: DocumentCommandInverse,
        changedMarkupIDs: Set<MarkupID>,
        changedPageIDs: Set<PageID>
    ) {
        self.commands = commands
        self.inverse = inverse
        self.forward = forward
        self.changedMarkupIDs = changedMarkupIDs
        self.changedPageIDs = changedPageIDs
    }

    /// Whether the batch changed nothing.
    public var isEmpty: Bool { inverse.isEmpty }
}

/// Everything the session refuses to do, as one error space.
public enum DocumentCommandError: Error, Hashable, Sendable, CustomStringConvertible {

    /// The command named a markup the session does not hold.
    case unknownMarkup(MarkupID)
    /// The command named a page the session does not hold.
    case unknownPage(PageID)
    /// A page index was outside the document.
    case pageIndexOutOfRange(Int)
    /// The markup is locked, and a locked markup is not edited silently.
    case markupLocked(MarkupID)
    /// The command needs a scale and the page has none.
    ///
    /// The refusal a measurement on an uncalibrated sheet earns. It is reachable on *any* page
    /// now: before per-page scale the session fell back to a document-wide default, so once one
    /// sheet was calibrated this error could not be raised for any other — the measurement was
    /// computed against the wrong sheet's ratio instead.
    case noScale(PageID)
    /// A scale was offered for a page it does not belong to.
    ///
    /// Never a silent correction. A scale carries the page it was calibrated on, and pointing a
    /// second page at it would make one ratio mean two different things on two sheets.
    case scaleBelongsToAnotherPage(scale: ScaleID, page: PageID)
    /// A scale reached the document without a page. Refused rather than parked on page one.
    case scaleHasNoPage(ScaleID)
    /// The measurement engine refused. The detail is the engine's own description.
    case measurementFailed(String)
    /// The ledger could not be rebuilt. The detail is the core's own description.
    case ledgerFailed(String)

    public var description: String {
        switch self {
        case .unknownMarkup(let id): "no markup \(id)"
        case .unknownPage(let id): "no page \(id)"
        case .pageIndexOutOfRange(let index): "page index \(index) is out of range"
        case .markupLocked(let id): "markup \(id) is locked"
        case .noScale(let id): "page \(id) has no scale"
        case .scaleBelongsToAnotherPage(let scale, let page):
            "scale \(scale) belongs to another page and cannot be used on page \(page)"
        case .scaleHasNoPage(let scale): "scale \(scale) names no page"
        case .measurementFailed(let detail): "measurement failed: \(detail)"
        case .ledgerFailed(let detail): "ledger rebuild failed: \(detail)"
        }
    }
}
