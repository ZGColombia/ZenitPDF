import Foundation
import Observation
import ZPDFPDFKitBridge

/// One PDF optional-content layer as the Navigator shows it: identity, name, and the
/// *effective* visibility (document default overridden by the project's setting).
public struct DocumentLayerItem: Identifiable, Hashable, Sendable {

    /// `PDFLayerID.rawValue` — stable for one document revision, never the display name,
    /// because two layers called "Walls" are two layers.
    public let id: String
    /// The display name from `/Name`.
    public let name: String
    /// What the document's `/D` configuration says.
    public let isVisibleByDefault: Bool
    /// The visibility in force: the default unless the project overrides it.
    public let isVisible: Bool
    /// Whether the document's default configuration locks the layer (`/D /Locked`).
    public let isLocked: Bool

    /// Creates a layer row.
    public init(id: String, name: String, isVisibleByDefault: Bool, isVisible: Bool, isLocked: Bool = false) {
        self.id = id
        self.name = name
        self.isVisibleByDefault = isVisibleByDefault
        self.isVisible = isVisible
        self.isLocked = isLocked
    }
}

/// The per-document layer visibility state: the one place a layer toggle
/// lands, and the one place the snap index, the canvas render and the Navigator read from.
///
/// The model owns the override dictionary in the same shape the `layer_override` table
/// persists (`PDFLayerID.rawValue` → visible); ``attach(archive:)`` restores it from the
/// project and keeps it there (R-205). It knows nothing about views: the Navigator's rows are derived through ``items``,
/// and every consequence of a toggle — rebuilding the snap index, re-rendering the canvas —
/// runs through ``onVisibilityChange``.
@MainActor
@Observable
public final class DocumentLayerVisibility {

    /// The document's layer catalogue, or `nil` when the drawing has no `/OCProperties`.
    public private(set) var tree: PDFLayerTree?

    /// Project overrides, keyed by `PDFLayerID.rawValue`. Only differences from the
    /// document default are kept, so an empty dictionary always means "native render
    /// still tells the truth".
    public private(set) var overrides: [String: Bool] = [:]

    /// Raised after a toggle changed the effective visibility. The app tier rebuilds the
    /// snap index and re-renders the canvas here.
    @ObservationIgnored
    public var onVisibilityChange: (@MainActor () -> Void)?

    /// Feature 30: the one layer measuring and snapping are locked to, by
    /// `PDFLayerID.rawValue` — or `nil`, the default, for no lock. Render visibility never
    /// reads this; only the snap index does, through
    /// ``snapHiddenMarkedContentNames(onPageIndex:)``.
    public private(set) var measureLockLayerID: String?

    /// Where the project keeps ``overrides`` (R-205), or `nil` — Quick PDF Mode, and every
    /// test that does not attach one.
    @ObservationIgnored
    public private(set) var archive: LayerOverrideArchive?

    /// Creates an empty model; ``adopt(tree:)`` installs the catalogue once it is read.
    public init() {}

    /// Restores the project's stored layer visibility and keeps every later toggle there.
    ///
    /// Call after ``adopt(tree:)``: an override naming a layer the drawing no longer has, or
    /// equal to the document default, is dropped, like any stale override. A restored state
    /// that differs from what is shown raises ``onVisibilityChange``, so the canvas and the
    /// snap index follow it exactly as they follow a toggle.
    ///
    /// `restoringStored: false` is the Save As case: the state in force moves into the new
    /// project instead of being replaced by what that project stores (nothing, yet).
    public func attach(archive: LayerOverrideArchive, restoringStored: Bool = true) async {
        self.archive = archive
        guard restoringStored else {
            archive.save(overrides)
            return
        }
        let stored = await archive.load()
        guard let tree else { return }
        let restored = stored.filter { layerID, visible in
            tree.layers.first { $0.id.rawValue == layerID }.map { $0.isVisibleByDefault != visible } ?? false
        }
        guard restored != overrides else { return }
        overrides = restored
        onVisibilityChange?()
    }

    /// Installs the document's layer catalogue. Overrides that no longer match a layer are
    /// dropped, because a stale override from another revision must degrade to "no
    /// override", never to an error — and so is a measure lock on a layer that no longer
    /// exists, because a lock on nothing would silently snap to nothing.
    public func adopt(tree: PDFLayerTree?) {
        self.tree = tree
        guard let tree else {
            overrides = [:]
            measureLockLayerID = nil
            return
        }
        let known = Set(tree.layers.map(\.id.rawValue))
        overrides = overrides.filter { known.contains($0.key) }
        if let lock = measureLockLayerID, !known.contains(lock) { measureLockLayerID = nil }
    }

    /// Locks measuring and snapping to one layer, or lifts the lock with `nil`.
    public func setMeasureLock(_ layerID: String?) {
        guard measureLockLayerID != layerID else { return }
        if let layerID {
            guard tree?.layers.contains(where: { $0.id.rawValue == layerID }) == true else { return }
        }
        measureLockLayerID = layerID
        onVisibilityChange?()
    }

    /// The locked layer's display name, for the status bar. Invariant: a tool locked to a
    /// layer says so wherever the tool is named, or a snap that found nothing looks like a
    /// broken snap.
    public var measureLockLayerName: String? {
        guard let lock = measureLockLayerID else { return nil }
        return tree?.layers.first { $0.id.rawValue == lock }?.name
    }

    /// The layer rows in `/OCGs` order, with effective visibility resolved.
    public var items: [DocumentLayerItem] {
        guard let tree else { return [] }
        let effective = tree.effectiveVisibility(overrides: overrides)
        return tree.layers.map { layer in
            DocumentLayerItem(
                id: layer.id.rawValue,
                name: layer.name,
                isVisibleByDefault: layer.isVisibleByDefault,
                isVisible: effective[layer.id] ?? layer.isVisibleByDefault,
                isLocked: layer.isLockedByDefault
            )
        }
    }

    /// Whether the document has any layers to toggle.
    public var hasLayers: Bool { !(tree?.layers.isEmpty ?? true) }

    /// Sets one layer's effective visibility.
    ///
    /// An override equal to the document default is removed rather than stored, so
    /// ``matchesDocumentDefault`` — the "is the native render still truthful" question —
    /// stays exactly the emptiness of the difference.
    public func setVisible(_ visible: Bool, layerID: String) {
        guard let tree, let layer = tree.layers.first(where: { $0.id.rawValue == layerID }) else {
            return
        }
        let before = matchesDocumentDefault
        let effectiveBefore = overrides[layerID] ?? layer.isVisibleByDefault
        if visible == layer.isVisibleByDefault {
            overrides.removeValue(forKey: layerID)
        } else {
            overrides[layerID] = visible
        }
        let effectiveAfter = overrides[layerID] ?? layer.isVisibleByDefault
        if effectiveBefore != effectiveAfter || before != matchesDocumentDefault {
            archive?.save(overrides)
            onVisibilityChange?()
        }
    }

    /// `true` when every effective visibility equals the document default — the one case
    /// where PDFKit/CoreGraphics page drawing is still truthful. Anything else must be
    /// re-rendered via the content-stream path (see `ZPDFPDFKitBridge.LayerTypes`).
    public var matchesDocumentDefault: Bool {
        guard let tree else { return true }
        return tree.effectiveVisibilityMatchesDocumentDefault(overrides: overrides)
    }

    /// The marked-content property names on one page whose layer is effectively hidden —
    /// exactly the set ``TakeoffSession/buildSnapIndex(page:extraction:hiddenLayerIDs:)``
    /// and `VectorLayerVisibilityFilter` take.
    /// The layers effectively hidden right now, by identity.
    ///
    /// The typed complement of ``hiddenMarkedContentNames(onPageIndex:)``, needed because a
    /// drawing can attach layer membership to **annotations**, which have no marked-content
    /// name at all — some elevation sets do it exclusively that way. Content hiding
    /// filters by name; annotation hiding filters by this.
    public var hiddenLayerIDs: Set<PDFLayerID> {
        guard let tree else { return [] }
        let effective = tree.effectiveVisibility(overrides: overrides)
        return Set(tree.layers.map(\.id).filter { effective[$0] == false })
    }

    public func hiddenMarkedContentNames(onPageIndex pageIndex: Int) -> Set<String> {
        guard let tree else { return [] }
        return tree.hiddenMarkedContentNames(
            onPageIndex: pageIndex,
            effectiveVisibility: tree.effectiveVisibility(overrides: overrides)
        )
    }

    /// The marked-content names the **snap index** must exclude: the effectively hidden
    /// layers — and, under a measure lock, every layer that is not the locked one.
    ///
    /// Feature 30 lives entirely in this set. The render keeps reading
    /// ``hiddenMarkedContentNames(onPageIndex:)``, so a lock changes what snaps and never
    /// what the person sees — a sheet that visibly lost its other layers would read as a
    /// display bug, not as a measuring aid.
    public func snapHiddenMarkedContentNames(onPageIndex pageIndex: Int) -> Set<String> {
        guard let tree else { return [] }
        guard let lock = measureLockLayerID else {
            return hiddenMarkedContentNames(onPageIndex: pageIndex)
        }
        let effective = tree.effectiveVisibility(overrides: overrides)
        var visibility = effective
        for layer in tree.layers {
            // The locked layer stays as visible as the person made it. Forcing it on built the
            // snap index from linework the render still hid, so snaps landed on lines nobody
            // could see (BH-425). A lock on a hidden layer snaps to nothing, which is what the
            // sheet shows.
            visibility[layer.id] = layer.id.rawValue == lock && effective[layer.id] != false
        }
        return tree.hiddenMarkedContentNames(
            onPageIndex: pageIndex,
            effectiveVisibility: visibility
        )
    }
}
