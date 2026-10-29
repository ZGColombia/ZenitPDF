import Foundation
import ZPDFContracts

/// Markup layers in the session (ADR-0032).
///
/// The layer list is project state beside the Project Zones: edited only through commands, undone
/// by state patches (``DocumentCommandInverse/markupLayers``), saved by the archive. Three rules
/// hold everywhere in this file:
///
/// - **Stored records are never rewritten by a flag.** Hiding or locking a layer changes the list,
///   not the markups; ``effectiveMarkups`` folds the flags in for the canvas and the outputs.
/// - **A quantity never depends on a layer.** The ledger reads ``TakeoffSession/ledgerMarkups``,
///   which no layer flag filters; only a ledger filter by layer narrows it.
/// - **A locked layer behaves as if every markup on it were locked**: a command that would change
///   one is taken back and refused with the same error a locked markup gives.
extension TakeoffSession {

    // MARK: Reading

    /// The project's layers, top first.
    public var markupLayers: [MarkupLayer] { markupLayerSet.layers }

    /// The layer list as one validated value.
    public var markupLayerList: MarkupLayerSet { markupLayerSet }

    /// The layer a new markup is placed on when the person has chosen it — resolved, so a layer
    /// that has gone reads as the default layer.
    public var activeMarkupLayer: LayerID { markupLayerSet.resolve(activeMarkupLayerID) }

    /// Chooses the layer new markups go to. Not a command: it is a working choice, like the tool
    /// that is armed, and changes nothing a person could undo. A layer the project does not hold
    /// is ignored.
    public func setActiveMarkupLayer(_ id: LayerID) {
        guard markupLayerSet.contains(id) else { return }
        activeMarkupLayerID = id
    }

    /// The markups in draw order (ADR-0036, the ADR-0032 addendum): a layer's place in the list
    /// sets the stacking — the top layer draws above the ones below it — and within a layer the
    /// document's markup order applies. What the canvas draws and hit-tests top-down; never the
    /// order the archive writes or the ledger lists, which stay ``orderedMarkups``.
    public var drawOrderedMarkups: [MarkupRecord] {
        markupLayerSet.drawOrder(orderedMarkups)
    }

    /// The markups in draw order with their layer's flags folded into their own: hidden when the
    /// layer is hidden, locked when it is locked, not printable when it is kept off paper. What
    /// print and every export take; never what the archive writes.
    public var effectiveMarkups: [MarkupRecord] {
        let set = markupLayerSet
        return drawOrderedMarkups.map { set.effective($0) }
    }

    /// Installs a saved project's layer list and active layer, before or after hydration (not a
    /// command: a reopened project starts with a fresh undo stack). An empty list — a project
    /// written before ADR-0032 — is the default layer alone.
    public func restoreMarkupLayers(_ layers: [MarkupLayer], active: LayerID? = nil) {
        markupLayerSet = layers.isEmpty ? .initial : MarkupLayerSet(layers)
        activeMarkupLayerID = markupLayerSet.resolve(active)
        installMarkupLayerNames()
    }

    /// Publishes the layer names and flags to the name table the summaries and the ledger read.
    func installMarkupLayerNames() {
        names.layers = markupLayerSet.names
        names.hiddenLayers = markupLayerSet.hiddenIDs
        names.lockedLayers = markupLayerSet.lockedIDs
    }

    /// The layer a markup being added is stored on: its own when the project holds it, else the
    /// placement layer for the active choice. The default layer is stored as no id, so a markup on
    /// it is byte-identical to one written before ADR-0032.
    func storedLayerID(forAdded record: MarkupRecord) -> LayerID? {
        let chosen: LayerID
        if let own = record.layerID, markupLayerSet.contains(own) {
            chosen = own
        } else {
            chosen = markupLayerSet.placementLayer(active: activeMarkupLayerID)
        }
        return chosen == MarkupLayer.defaultID ? nil : chosen
    }

    // MARK: Commands

    /// ``DocumentCommand/setMarkupLayers(_:change:)``.
    func applySetMarkupLayers(_ layers: [MarkupLayer], command: DocumentCommand) throws -> DocumentCommandOutcome {
        for layer in layers where layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DocumentCommandError.ledgerFailed(MarkupLayerRefusal.emptyName.description)
        }
        guard layers.count <= MarkupLayerSet.maximumCount else {
            throw DocumentCommandError.ledgerFailed(MarkupLayerRefusal.tooManyLayers.description)
        }
        let previous = markupLayerSet
        let next = MarkupLayerSet(layers)
        guard next != previous else {
            return DocumentCommandOutcome(command: command, inverse: .empty, forward: .empty, changedMarkupIDs: [], changedPageIDs: [])
        }
        // A layer the new list drops takes nobody with it: its markups move to the default layer
        // in this same step, so undo brings layer and markups back together.
        let dropped = Set(previous.layers.map(\.id)).subtracting(next.layers.map(\.id))
        let orphans = orderedMarkups.filter { dropped.contains(previous.resolvedLayerID(of: $0)) }.map(\.id)
        var outcome = try applyFlag(orphans, command: command) { record in
            guard record.layerID != nil else { return false }
            record.layerID = nil
            return true
        }
        markupLayerSet = next
        if !next.contains(activeMarkupLayerID) { activeMarkupLayerID = MarkupLayer.defaultID }
        installMarkupLayerNames()
        var inverse = outcome.inverse
        inverse.markupLayers = previous.layers
        // Every markup whose drawing, lock or paper state the list change moved is "changed" for
        // the canvas; none of them changed a quantity.
        let flagsMoved = previous.hiddenIDs != next.hiddenIDs || previous.lockedIDs != next.lockedIDs
            || previous.offPaperIDs != next.offPaperIDs
        var changed = outcome.changedMarkupIDs
        var pages = outcome.changedPageIDs
        if flagsMoved {
            for record in orderedMarkups {
                let before = previous.layer(of: record)
                let after = next.layer(of: record)
                guard before.visible != after.visible || before.locked != after.locked
                    || before.printable != after.printable else { continue }
                changed.insert(record.id)
                pages.insert(record.pageID)
            }
        }
        outcome = DocumentCommandOutcome(
            command: command, inverse: inverse, forward: .empty,
            changedMarkupIDs: changed, changedPageIDs: pages
        )
        return outcome
    }

    /// ``DocumentCommand/setMarkupLayer(ids:layerID:)``.
    func applySetMarkupLayer(_ ids: [MarkupID], layerID: LayerID, command: DocumentCommand) throws -> DocumentCommandOutcome {
        guard markupLayerSet.contains(layerID) else {
            throw DocumentCommandError.ledgerFailed(MarkupLayerRefusal.unknownLayer(layerID).description)
        }
        let stored: LayerID? = layerID == MarkupLayer.defaultID ? nil : layerID
        let set = markupLayerSet
        return try applyFlag(ids, command: command) { record in
            // Compared as layers, not as ids: a stale id and nil are both the default layer.
            guard set.resolvedLayerID(of: record) != layerID || record.layerID != stored else { return false }
            record.layerID = stored
            return true
        }
    }

    /// ``DocumentCommand/deleteMarkupLayer(_:moveMarkupsTo:)``.
    func applyDeleteMarkupLayer(_ id: LayerID, moveTo target: LayerID, command: DocumentCommand) throws -> DocumentCommandOutcome {
        let previous = markupLayerSet
        let next: MarkupLayerSet
        do {
            next = try previous.removing(id)
        } catch let refusal as MarkupLayerRefusal {
            throw DocumentCommandError.ledgerFailed(refusal.description)
        }
        guard target != id else {
            throw DocumentCommandError.ledgerFailed(MarkupLayerRefusal.moveTargetIsDeletedLayer.description)
        }
        guard next.contains(target) else {
            throw DocumentCommandError.ledgerFailed(MarkupLayerRefusal.unknownLayer(target).description)
        }
        let stored: LayerID? = target == MarkupLayer.defaultID ? nil : target
        let moving = orderedMarkups.filter { previous.resolvedLayerID(of: $0) == id }.map(\.id)
        let moved = try applyFlag(moving, command: command) { record in
            guard record.layerID != stored else { return false }
            record.layerID = stored
            return true
        }
        markupLayerSet = next
        if !next.contains(activeMarkupLayerID) { activeMarkupLayerID = target }
        installMarkupLayerNames()
        var inverse = moved.inverse
        inverse.markupLayers = previous.layers
        // The markups that moved may now draw, lock or print differently.
        var changed = moved.changedMarkupIDs
        var pages = moved.changedPageIDs
        for record in orderedMarkups where moving.contains(record.id) {
            changed.insert(record.id)
            pages.insert(record.pageID)
        }
        return DocumentCommandOutcome(
            command: command, inverse: inverse, forward: .empty,
            changedMarkupIDs: changed, changedPageIDs: pages
        )
    }

    /// Reinstates the layer list an inverse carries, recording the current one for the opposite
    /// direction. Called from ``revert(_:)``.
    func revertMarkupLayers(_ inverse: DocumentCommandInverse, into redo: inout DocumentCommandInverse) {
        guard let layers = inverse.markupLayers else { return }
        redo.markupLayers = markupLayerSet.layers
        markupLayerSet = MarkupLayerSet(layers)
        if !markupLayerSet.contains(activeMarkupLayerID) { activeMarkupLayerID = MarkupLayer.defaultID }
        installMarkupLayerNames()
    }

    // MARK: The locked-layer rule

    /// Whether a command acts on the layer list or on the project's structure rather than on
    /// particular markups, so the locked-layer rule does not apply to it: a rescale re-measures a
    /// locked layer's markups exactly as it re-measures a locked markup, and deleting a layer
    /// moves its markups by definition.
    static func isExemptFromLockedLayers(_ command: DocumentCommand) -> Bool {
        switch command {
        case .changeScale, .recalculateMeasurements, .setScaleRegions, .setProjectZones,
             .reorderPage, .setSheetIdentities, .insertPages, .setPagesExcluded, .setPageViews,
             .addCustomColumns, .setCustomColumns, .addMarkup,
             .setMarkupLayers, .deleteMarkupLayer:
            return true
        default:
            return false
        }
    }

    /// Takes back an applied command that changed a markup on a locked layer, and refuses it.
    ///
    /// Checked on the outcome rather than per command, so every present and future command that
    /// edits markups obeys the rule without remembering to: the inverse names every markup the
    /// command touched and what it looked like before.
    func refuseLockedLayerChanges(_ outcome: DocumentCommandOutcome) throws {
        guard !Self.isExemptFromLockedLayers(outcome.command) else { return }
        let set = markupLayerSet
        guard !set.lockedIDs.isEmpty else { return }
        var offender: MarkupID?
        for (id, before) in outcome.inverse.markups {
            guard let before, set.locksMarkup(before) else { continue }
            guard var after = markup(id) else { offender = id; break }
            var original = before
            after.modifiedAt = .distantPast
            original.modifiedAt = .distantPast
            if after != original { offender = id; break }
        }
        if offender == nil, case .arrangeMarkups = outcome.command {
            offender = outcome.changedMarkupIDs.first { id in markup(id).map(set.locksMarkup) ?? false }
        }
        guard let offender else { return }
        if !outcome.inverse.isEmpty { _ = try? revert(outcome.inverse) }
        throw DocumentCommandError.markupLocked(offender)
    }
}
