import Foundation

/// A query-time visibility filter over ``VectorPrimitive/layerID``.
///
/// The snap engine holds one extraction per page and must not rebuild anything when
/// the user toggles a layer. This filter is that contract: it is applied at query
/// time, over the already-extracted primitives, and costs one set lookup per
/// primitive — no re-extraction, no index rebuild.
///
/// `hiddenLayerIDs` holds marked-content **property names** (`"L0"`, `"MC1"`, …) —
/// the page-scoped identifiers ``VectorPrimitive/layerID`` carries. The bridge's
/// `PDFLayerTree.hiddenMarkedContentNames(onPageIndex:effectiveVisibility:)` produces
/// exactly this set from a project's effective layer visibility.
///
/// To let a filter also *show* a layer the document hides by default, extract with
/// ``VectorExtractionOptions/includesHiddenOptionalContent`` on: every layer's
/// geometry is then present once, and this filter alone decides what the snap engine
/// sees.
public struct VectorLayerVisibilityFilter: Sendable, Hashable {
    /// Marked-content property names whose primitives are excluded.
    public var hiddenLayerIDs: Set<String>
    /// Whether primitives outside any marked-content layer pass. `true` by default:
    /// unlayered linework has no layer to hide.
    public var includesUnlayeredContent: Bool

    public init(hiddenLayerIDs: Set<String>, includesUnlayeredContent: Bool = true) {
        self.hiddenLayerIDs = hiddenLayerIDs
        self.includesUnlayeredContent = includesUnlayeredContent
    }

    /// The filter that hides nothing.
    public static let everythingVisible = VectorLayerVisibilityFilter(hiddenLayerIDs: [])

    /// `true` when the primitive is visible under this filter.
    public func admits(_ primitive: VectorPrimitive) -> Bool {
        guard let layerID = primitive.layerID else { return includesUnlayeredContent }
        return !hiddenLayerIDs.contains(layerID)
    }
}

public extension VectorPageExtraction {

    /// The primitives visible under `filter`, in the original deterministic order.
    func primitives(visibleUnder filter: VectorLayerVisibilityFilter) -> [VectorPrimitive] {
        guard !filter.hiddenLayerIDs.isEmpty || !filter.includesUnlayeredContent else {
            return primitives
        }
        return primitives.filter(filter.admits)
    }

    /// Shorthand: everything except the primitives on the named hidden layers.
    func primitives(excludingLayerIDs hiddenLayerIDs: Set<String>) -> [VectorPrimitive] {
        primitives(visibleUnder: VectorLayerVisibilityFilter(hiddenLayerIDs: hiddenLayerIDs))
    }

    /// Every distinct ``VectorPrimitive/layerID`` in this extraction, sorted.
    var layerIDs: [String] {
        var seen: Set<String> = []
        for primitive in primitives {
            if let layerID = primitive.layerID { seen.insert(layerID) }
        }
        return seen.sorted()
    }
}
