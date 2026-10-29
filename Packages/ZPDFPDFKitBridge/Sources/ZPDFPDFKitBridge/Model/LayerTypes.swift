import Foundation

// PDF optional content ("layers"), as neutral value types.
//
// ### What honours what — the honest rendering picture
//
// - **The file's default configuration** (`/OCProperties /D`, including its `/OFF`
//   list) is honoured by both PDFKit page drawing and by CoreGraphics'
//   `CGContextDrawPDFPage`. A document whose "Grid" layer ships switched off renders
//   without the grid through either path.
// - **Changing visibility at render time is honoured by neither.** PDFKit exposes no
//   API to toggle an optional-content group, and CoreGraphics has no public way to
//   substitute an alternate OC configuration into `CGContextDrawPDFPage` — both always
//   apply the default `/D` configuration baked into the file. There is no
//   "CGPDFDocument-level OC config" that a caller can flip.
// - Therefore: when a project's effective visibility **differs from the document
//   default**, a truthful raster requires the app tier to re-render via CoreGraphics
//   with content-stream filtering — skipping `BDC /OC` sections (and form XObjects
//   carrying `/OC`) whose group is hidden — which is the ZPDFRenderer path. Use
//   ``PDFLayerTree/effectiveVisibilityMatchesDocumentDefault(overrides:)`` to decide
//   whether the native (PDFKit) render is still telling the truth.

/// Identifies one optional-content group within one document revision.
///
/// The canonical form is `"ocg:<index>"`, where `<index>` is the group's position in
/// the document's `/OCProperties /OCGs` array. That array is part of the file's bytes,
/// so the identifier is deterministic for a given document SHA-256 — which is exactly
/// the stability the `layer_override` table needs — and it distinguishes two layers
/// that share a display name. It is **not** stable across a revision swap that
/// rewrites the catalogue; effective-visibility code must treat an unknown persisted
/// id as "no override", never as an error.
public struct PDFLayerID: Sendable, Hashable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The canonical identifier of the group at `index` in `/OCProperties /OCGs`.
    public static func ocg(atIndex index: Int) -> PDFLayerID {
        PDFLayerID(rawValue: "ocg:\(index)")
    }

    public var description: String { rawValue }
}

/// The `/Usage` application hints of one group, reported and never acted on.
///
/// `nil` means the document does not state the hint. These are advisory: the *default
/// visibility* that matters for rendering and snapping is ``PDFLayer/isVisibleByDefault``,
/// which comes from the `/D` configuration, not from `/Usage`.
public struct PDFLayerUsageHints: Sendable, Hashable, Codable {
    /// `/Usage /View /ViewState` — `true` for `/ON`, `false` for `/OFF`.
    public var view: Bool?
    /// `/Usage /Print /PrintState`.
    public var print: Bool?
    /// `/Usage /Export /ExportState`.
    public var export: Bool?

    public init(view: Bool? = nil, print: Bool? = nil, export: Bool? = nil) {
        self.view = view
        self.print = print
        self.export = export
    }

    public var isEmpty: Bool { view == nil && print == nil && export == nil }
}

/// One optional-content group, in `/OCGs` order.
public struct PDFLayer: Sendable, Hashable, Codable, Identifiable {
    public let id: PDFLayerID
    /// The display name from `/Name`. Duplicate names are legal in a PDF; the ``id``
    /// is what distinguishes two layers called "Walls".
    public let name: String
    /// `true` unless the default configuration switches the group off
    /// (`/D /BaseState /OFF` not overridden by `/ON`, or membership in `/D /OFF`).
    public let isVisibleByDefault: Bool
    /// `true` when the group appears in `/D /Locked`.
    public let isLockedByDefault: Bool
    public let usage: PDFLayerUsageHints

    public init(
        id: PDFLayerID,
        name: String,
        isVisibleByDefault: Bool,
        isLockedByDefault: Bool,
        usage: PDFLayerUsageHints = PDFLayerUsageHints()
    ) {
        self.id = id
        self.name = name
        self.isVisibleByDefault = isVisibleByDefault
        self.isLockedByDefault = isLockedByDefault
        self.usage = usage
    }
}

/// One node of the `/D /Order` presentation tree.
///
/// The nesting is **presentational only**: PDF 32000-1 8.11.4.3's order array controls
/// how a viewer lists layers, and a child's visibility is *not* gated by its parent's.
/// Visibility always resolves per group, which is why
/// ``PDFLayerTree/effectiveVisibility(overrides:)`` works on the flat ``PDFLayerTree/layers``.
public struct PDFLayerNode: Sendable, Hashable, Codable {
    /// `nil` for a label-only grouping node (a bare string in `/Order`).
    public let layerID: PDFLayerID?
    /// The layer's name, or the grouping label.
    public let title: String
    public let children: [PDFLayerNode]

    public init(layerID: PDFLayerID?, title: String, children: [PDFLayerNode] = []) {
        self.layerID = layerID
        self.title = title
        self.children = children
    }
}

/// Which marked-content property names on one page belong to which layer.
///
/// `ZPDFVectorExtraction` tags each primitive with the `/Properties` resource *name*
/// (`"L0"`, `"MC1"`, …) that its enclosing `BDC /OC` section used. Those names are
/// page-scoped, so the mapping back to a ``PDFLayerID`` is recorded per page. An OCMD
/// property that references several groups maps its name to every one of them.
public struct PDFLayerPageBinding: Sendable, Hashable, Codable {
    public let pageIndex: Int
    /// Marked-content property names by the layer they switch, sorted for determinism.
    public let propertyNamesByLayer: [PDFLayerID: [String]]

    public init(pageIndex: Int, propertyNamesByLayer: [PDFLayerID: [String]]) {
        self.pageIndex = pageIndex
        self.propertyNamesByLayer = propertyNamesByLayer
    }
}

/// Everything the `/OCProperties` catalogue of one document declares.
public struct PDFLayerTree: Sendable, Hashable, Codable {
    /// Every group, in `/OCGs` order. This order defines each layer's ``PDFLayerID``.
    public let layers: [PDFLayer]
    /// The presentation tree from `/D /Order`. Layers the order array never mentions
    /// are appended flat at the end, so every layer is reachable from here.
    public let outline: [PDFLayerNode]
    /// The `/RBGroups` radio groups: within one group, viewers keep at most one layer
    /// on at a time. Reported, never enforced here.
    public let radioGroups: [[PDFLayerID]]
    /// Per-page marked-content name bindings, for pages that have any.
    public let pageBindings: [PDFLayerPageBinding]
    /// `true` when a traversal budget stopped the scan early; the tree is then a
    /// truthful prefix rather than the whole catalogue.
    public let scanWasTruncated: Bool

    public init(
        layers: [PDFLayer],
        outline: [PDFLayerNode],
        radioGroups: [[PDFLayerID]],
        pageBindings: [PDFLayerPageBinding],
        scanWasTruncated: Bool
    ) {
        self.layers = layers
        self.outline = outline
        self.radioGroups = radioGroups
        self.pageBindings = pageBindings
        self.scanWasTruncated = scanWasTruncated
    }

    public func layer(_ id: PDFLayerID) -> PDFLayer? {
        layers.first { $0.id == id }
    }

    // MARK: - Effective visibility

    /// The document default overridden by the project's per-layer settings.
    ///
    /// `overrides` maps a persisted `layer_override.layer_id` (``PDFLayerID/rawValue``)
    /// to its `visible` value. Layers without an override keep their document default;
    /// override keys that match no current layer are ignored, because a stale override
    /// from an older document revision must degrade to "no override", not to an error.
    public func effectiveVisibility(overrides: [String: Bool]) -> [PDFLayerID: Bool] {
        var out: [PDFLayerID: Bool] = [:]
        out.reserveCapacity(layers.count)
        for layer in layers {
            out[layer.id] = overrides[layer.id.rawValue] ?? layer.isVisibleByDefault
        }
        return out
    }

    /// `true` when every effective visibility equals the document default — the one
    /// case where a native PDFKit render still tells the truth. Anything else must be
    /// re-rendered via CoreGraphics with content-stream filtering (see the honesty
    /// notes at the top of this file).
    public func effectiveVisibilityMatchesDocumentDefault(overrides: [String: Bool]) -> Bool {
        layers.allSatisfy { layer in
            (overrides[layer.id.rawValue] ?? layer.isVisibleByDefault) == layer.isVisibleByDefault
        }
    }

    /// The marked-content property names on `pageIndex` whose layer is hidden under
    /// the given effective visibility — exactly the set
    /// `ZPDFVectorExtraction.VectorLayerVisibilityFilter` wants as `hiddenLayerIDs`.
    public func hiddenMarkedContentNames(
        onPageIndex pageIndex: Int,
        effectiveVisibility: [PDFLayerID: Bool]
    ) -> Set<String> {
        guard let binding = pageBindings.first(where: { $0.pageIndex == pageIndex }) else {
            return []
        }
        var hidden: Set<String> = []
        for (layerID, names) in binding.propertyNamesByLayer {
            if effectiveVisibility[layerID] == false {
                hidden.formUnion(names)
            }
        }
        return hidden
    }
}
