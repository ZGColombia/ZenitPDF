import Foundation
import ZPDFContracts

/// Which layer-list edit a ``DocumentCommand/setMarkupLayers(_:change:)`` step is, so the Undo
/// menu can name it (ADR-0032).
public enum MarkupLayerChange: String, Sendable, Hashable, CaseIterable {
    case add
    case rename
    case reorder
    case show
    case hide
    case lock
    case unlock
    case print
    case dontPrint
    /// Anything else, several at once — a restore from a file, an import.
    case other

    /// The Undo menu's words for the step.
    public var actionName: String {
        switch self {
        case .add: NSLocalizedString("New Layer", comment: "Undo action name for adding a markup layer")
        case .rename: NSLocalizedString("Rename Layer", comment: "Undo action name for renaming a markup layer")
        case .reorder: NSLocalizedString("Reorder Layers", comment: "Undo action name for moving a markup layer in the list")
        case .show: NSLocalizedString("Show Layer", comment: "Undo action name for showing a markup layer")
        case .hide: NSLocalizedString("Hide Layer", comment: "Undo action name for hiding a markup layer")
        case .lock: NSLocalizedString("Lock Layer", comment: "Undo action name for locking a markup layer")
        case .unlock: NSLocalizedString("Unlock Layer", comment: "Undo action name for unlocking a markup layer")
        case .print: NSLocalizedString("Print Layer", comment: "Undo action name for letting a markup layer print")
        case .dontPrint: NSLocalizedString("Don't Print Layer", comment: "Undo action name for keeping a markup layer off paper")
        case .other: NSLocalizedString("Change Layers", comment: "Undo action name for a general markup layer change")
        }
    }
}

/// Why a layer-list edit was refused, in words a person can act on (ADR-0032).
public enum MarkupLayerRefusal: Error, Hashable, Sendable, CustomStringConvertible {
    /// The default layer cannot be deleted: it is where a markup whose layer is gone belongs.
    case defaultLayerCannotBeDeleted
    /// A layer name must say something.
    case emptyName
    /// The layer named is not in the project.
    case unknownLayer(LayerID)
    /// The target of a move is the layer being deleted.
    case moveTargetIsDeletedLayer
    /// More layers than a project may hold.
    case tooManyLayers

    public var description: String {
        switch self {
        case .defaultLayerCannotBeDeleted:
            NSLocalizedString("The default layer cannot be deleted.", comment: "Layer refusal")
        case .emptyName:
            NSLocalizedString("A layer needs a name.", comment: "Layer refusal")
        case .unknownLayer:
            NSLocalizedString("That layer is no longer in the project.", comment: "Layer refusal")
        case .moveTargetIsDeletedLayer:
            NSLocalizedString("Choose another layer for the markups.", comment: "Layer refusal")
        case .tooManyLayers:
            NSLocalizedString("A project can hold at most 1,000 layers.", comment: "Layer refusal")
        }
    }
}

/// A project's markup layers as one validated value (ADR-0032).
///
/// Always holds the default layer, never two layers with one id, and numbers the layers `0…n-1`
/// in list order, so every consumer — the Navigator, the Inspector popup, the archive — reads the
/// same order. Pure: the session holds one and edits it by replacement, which is what makes an
/// undo of a layer edit a plain state patch.
public struct MarkupLayerSet: Hashable, Sendable {

    /// The most layers a project may hold (mirrors the archive's refusal).
    public static let maximumCount = 1000

    /// The layers, top first, `order` renumbered to the position.
    public private(set) var layers: [MarkupLayer]

    /// A normalised set: duplicate ids dropped (first wins), the default layer added at the
    /// bottom when missing, sorted by `order` (stable), renumbered, blank names replaced.
    public init(_ layers: [MarkupLayer]) {
        var seen: Set<LayerID> = []
        var kept: [MarkupLayer] = []
        for layer in layers where seen.insert(layer.id).inserted {
            kept.append(layer)
        }
        let ordered = kept.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
        var result = ordered
        if !seen.contains(MarkupLayer.defaultID) {
            var fallback = MarkupLayer.makeDefault()
            fallback.order = result.count
            result.append(fallback)
        }
        for index in result.indices {
            result[index].order = index
            if result[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[index].name = result[index].isDefault
                    ? MarkupLayer.defaultName
                    : NSLocalizedString("Layer", comment: "Name of a markup layer whose stored name was blank")
            }
        }
        self.layers = Array(result.prefix(Self.maximumCount))
        if !self.layers.contains(where: \.isDefault), var fallback = result.first(where: \.isDefault) {
            fallback.order = self.layers.count - 1
            self.layers[self.layers.count - 1] = fallback
        }
    }

    /// A new project's list: the default layer alone.
    public static let initial = MarkupLayerSet([MarkupLayer.makeDefault()])

    // MARK: Reading

    /// One layer by identity.
    public func layer(_ id: LayerID) -> MarkupLayer? { layers.first { $0.id == id } }

    /// Whether the project holds the layer.
    public func contains(_ id: LayerID) -> Bool { layers.contains { $0.id == id } }

    /// The layer a markup belongs to, resolved against this list: its own when the list holds it,
    /// else the default layer (a layer id the project does not hold is repaired, never refused).
    public func resolvedLayerID(of record: MarkupRecord) -> LayerID {
        resolve(record.layerID)
    }

    /// `id` when the list holds it, else the default layer.
    public func resolve(_ id: LayerID?) -> LayerID {
        guard let id, contains(id) else { return MarkupLayer.defaultID }
        return id
    }

    /// The layer a markup belongs to.
    public func layer(of record: MarkupRecord) -> MarkupLayer {
        layer(resolvedLayerID(of: record)) ?? MarkupLayer.makeDefault()
    }

    /// Whether a markup is locked by its layer (its own flag not considered).
    public func locksMarkup(_ record: MarkupRecord) -> Bool { layer(of: record).locked }

    /// The record with its layer's flags folded into its own: hidden when either is hidden, locked
    /// when either is locked, printable only when both are. What the canvas and every output
    /// read; never what is stored.
    public func effective(_ record: MarkupRecord) -> MarkupRecord {
        let layer = layer(of: record)
        guard !layer.visible || layer.locked || !layer.printable else { return record }
        var folded = record
        folded.hidden = record.hidden || !layer.visible
        folded.locked = record.locked || layer.locked
        folded.printable = record.printable && layer.printable
        return folded
    }

    /// `records` in draw order (ADR-0036, the ADR-0032 addendum): the bottom layer of the list
    /// first and the top layer last, so an upper layer draws over a lower one; within a layer the
    /// records keep the order they came in — the document's markup order, which Arrange edits.
    /// A stable sort, so a project on one layer draws exactly as before.
    public func drawOrder(_ records: [MarkupRecord]) -> [MarkupRecord] {
        guard layers.count > 1 else { return records }
        var rank: [LayerID: Int] = [:]
        for (index, layer) in layers.enumerated() { rank[layer.id] = layers.count - 1 - index }
        let fallback = rank[MarkupLayer.defaultID] ?? 0
        return records.enumerated()
            .map { (rank: rank[resolvedLayerID(of: $0.element)] ?? fallback, offset: $0.offset, record: $0.element) }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.record)
    }

    /// Names by identity, for the ledger's Layer column and the summaries.
    public var names: [LayerID: String] {
        Dictionary(layers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// The hidden layers.
    public var hiddenIDs: Set<LayerID> { Set(layers.filter { !$0.visible }.map(\.id)) }
    /// The locked layers.
    public var lockedIDs: Set<LayerID> { Set(layers.filter(\.locked).map(\.id)) }
    /// The layers kept off paper.
    public var offPaperIDs: Set<LayerID> { Set(layers.filter { !$0.printable }.map(\.id)) }

    /// Where a new markup goes when the person has `active` chosen: that layer when it is visible
    /// and unlocked, else the topmost layer that is, else `active` itself (the person's choice
    /// stands when nothing better exists). A new markup never lands on a layer that would hide it
    /// or refuse it the moment it is drawn, unless every layer would.
    public func placementLayer(active: LayerID) -> LayerID {
        let resolved = resolve(active)
        if let chosen = layer(resolved), chosen.visible, !chosen.locked { return resolved }
        if let open = layers.first(where: { $0.visible && !$0.locked }) { return open.id }
        return resolved
    }

    /// A name for a new layer no other layer has: "Layer 2", "Layer 3", …
    public func suggestedName() -> String {
        let taken = Set(layers.map { $0.name.lowercased() })
        var number = layers.count + 1
        while true {
            let name = String(format: NSLocalizedString("Layer %d", comment: "Suggested name for a new markup layer; number"), number)
            if !taken.contains(name.lowercased()) { return name }
            number += 1
        }
    }

    // MARK: Editing (pure; each returns the new list)

    /// The list with `layer` added at the top.
    public func adding(_ layer: MarkupLayer) throws -> MarkupLayerSet {
        guard layers.count < Self.maximumCount else { throw MarkupLayerRefusal.tooManyLayers }
        let name = layer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MarkupLayerRefusal.emptyName }
        var added = layer
        added.name = name
        added.order = -1
        return MarkupLayerSet([added] + layers.filter { $0.id != layer.id })
    }

    /// The list with one layer renamed.
    public func renaming(_ id: LayerID, to name: String) throws -> MarkupLayerSet {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MarkupLayerRefusal.emptyName }
        return try updating(id) { $0.name = trimmed }
    }

    /// The list with one layer moved to `index` (clamped), the others keeping their order.
    public func moving(_ id: LayerID, to index: Int) throws -> MarkupLayerSet {
        guard let from = layers.firstIndex(where: { $0.id == id }) else { throw MarkupLayerRefusal.unknownLayer(id) }
        var reordered = layers
        let moved = reordered.remove(at: from)
        reordered.insert(moved, at: max(0, min(reordered.count, index)))
        for position in reordered.indices { reordered[position].order = position }
        return MarkupLayerSet(reordered)
    }

    /// The list with one layer's flags changed.
    public func updating(_ id: LayerID, _ body: (inout MarkupLayer) -> Void) throws -> MarkupLayerSet {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { throw MarkupLayerRefusal.unknownLayer(id) }
        var updated = layers
        body(&updated[index])
        updated[index].id = id
        updated[index].order = index
        return MarkupLayerSet(updated)
    }

    /// The list without one layer. The default layer cannot go.
    public func removing(_ id: LayerID) throws -> MarkupLayerSet {
        guard id != MarkupLayer.defaultID else { throw MarkupLayerRefusal.defaultLayerCannotBeDeleted }
        guard contains(id) else { throw MarkupLayerRefusal.unknownLayer(id) }
        return MarkupLayerSet(layers.filter { $0.id != id })
    }
}
