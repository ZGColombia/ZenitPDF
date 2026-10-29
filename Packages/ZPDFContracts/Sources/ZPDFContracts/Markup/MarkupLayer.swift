import Foundation

/// One markup layer of a project (ADR-0032).
///
/// A project owns an ordered list of layers. Every markup belongs to exactly one of them:
/// ``MarkupRecord/layerID`` names it, and a record whose `layerID` is `nil` belongs to the
/// project's **default layer** — which is how every markup written before ADR-0032 keeps its
/// meaning with no migration pass over the markups.
///
/// The three flags act on the markups of the layer as a whole and combine with each markup's own
/// flags: a markup is drawn only when neither it nor its layer is hidden, is editable only when
/// neither is locked, and reaches paper only when both are printable. None of them touches a
/// quantity: a hidden layer's rows stay in the Quantity Ledger and in every total, because hiding
/// is a view decision and a total that moves when a checkbox is unticked is a silent change.
public struct MarkupLayer: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity, minted once. The default layer's is ``defaultID`` in every project.
    public var id: LayerID
    /// The name a person sees and types. Not an identity: two layers may share a name.
    public var name: String
    /// The layer's place in the list, `0` at the top. Consumers sort by it and never by name.
    public var order: Int
    /// Whether the layer's markups are drawn and can be hit-tested on the canvas.
    public var visible: Bool
    /// Whether the layer's markups refuse selection and every edit.
    public var locked: Bool
    /// Whether the layer's markups reach print and flattened export.
    public var printable: Bool

    public init(
        id: LayerID,
        name: String,
        order: Int,
        visible: Bool = true,
        locked: Bool = false,
        printable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.order = order
        self.visible = visible
        self.locked = locked
        self.printable = printable
    }

    /// The default layer's identity, the same constant in every project.
    ///
    /// A constant rather than a minted id, so "the markup with no layer id" and "the markup on
    /// the default layer" are one statement in every file, old or new, without a lookup.
    public static let defaultID = LayerID(UUID(uuidString: "5A1E0000-0000-4000-8000-00000000DEF0")!)

    /// The name the default layer is created with. A person may rename it.
    public static let defaultName = "Default"

    /// The default layer as a new project starts with it: first, visible, unlocked, printable.
    public static func makeDefault(name: String = MarkupLayer.defaultName) -> MarkupLayer {
        MarkupLayer(id: defaultID, name: name, order: 0)
    }

    /// Whether this is the project's default layer, which can be renamed, hidden and locked but
    /// never deleted: it is where a markup whose layer is gone belongs.
    public var isDefault: Bool { id == Self.defaultID }
}

extension MarkupRecord {

    /// The layer this markup belongs to: its ``layerID``, or the default layer when it has none
    /// (ADR-0032). Whether that layer still exists is the project's question, not the record's —
    /// a caller holding the layer list resolves an unknown id to the default layer as well.
    public var effectiveLayerID: LayerID { layerID ?? MarkupLayer.defaultID }
}
