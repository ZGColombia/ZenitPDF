import CoreGraphics
import Foundation

/// Where a bookmark or a named destination points.
///
/// A destination that names a page the document does not contain is kept, with
/// `pageIndex == nil`, rather than dropped: a broken bookmark tree is information about
/// the file, and silently pruning it makes a damaged set look healthy.
public struct DestinationTarget: Sendable, Hashable, Codable {
    /// Zero-based page index, or `nil` when the destination could not be resolved.
    public let pageIndex: Int?
    /// The page label of `pageIndex`, when resolved.
    public let pageLabel: String?
    /// The point in page space the destination scrolls to, when it specifies at least one
    /// axis. An axis the destination leaves unspecified reads as `0` here, as it always has.
    ///
    /// **Navigate with ``left`` and ``top``, not with this.** A destination may specify one
    /// axis only — `[page /XYZ null 612 0]` means "keep the horizontal position, scroll so 612
    /// is at the top", which is ``left`` `nil` and ``top`` `612`; this property's `(0, 612)`
    /// would jump to the sheet's left edge (BH-586).
    public let point: CGPoint?
    /// The horizontal coordinate the destination asks for, or `nil` to keep the current one.
    public let left: CGFloat?
    /// The vertical coordinate the destination asks for, or `nil` to keep the current one.
    public let top: CGFloat?
    /// The zoom the destination asks for, when it specifies one. `0` in a PDF means
    /// "keep the current zoom" and is reported as `nil`.
    public let zoom: CGFloat?

    public init(pageIndex: Int?, pageLabel: String?, point: CGPoint?, zoom: CGFloat?) {
        self.init(pageIndex: pageIndex, pageLabel: pageLabel, left: point?.x, top: point?.y, zoom: zoom)
    }

    /// A destination with each axis specified independently.
    public init(pageIndex: Int?, pageLabel: String?, left: CGFloat?, top: CGFloat?, zoom: CGFloat?) {
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.left = left
        self.top = top
        if left != nil || top != nil {
            self.point = CGPoint(x: left ?? 0, y: top ?? 0)
        } else {
            self.point = nil
        }
        self.zoom = zoom
    }

    private enum CodingKeys: String, CodingKey {
        case pageIndex, pageLabel, point, left, top, zoom
    }

    /// Decodes both the current form and the form written before ``left`` and ``top``
    /// existed, which carried only `point`: its axes are taken from `point`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let point = try container.decodeIfPresent(CGPoint.self, forKey: .point)
        let hasAxes = container.contains(.left) || container.contains(.top)
        self.init(
            pageIndex: try container.decodeIfPresent(Int.self, forKey: .pageIndex),
            pageLabel: try container.decodeIfPresent(String.self, forKey: .pageLabel),
            left: hasAxes ? try container.decodeIfPresent(CGFloat.self, forKey: .left) : point?.x,
            top: hasAxes ? try container.decodeIfPresent(CGFloat.self, forKey: .top) : point?.y,
            zoom: try container.decodeIfPresent(CGFloat.self, forKey: .zoom)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(pageIndex, forKey: .pageIndex)
        try container.encodeIfPresent(pageLabel, forKey: .pageLabel)
        try container.encodeIfPresent(point, forKey: .point)
        try container.encodeIfPresent(left, forKey: .left)
        try container.encodeIfPresent(top, forKey: .top)
        try container.encodeIfPresent(zoom, forKey: .zoom)
    }

    public var isResolved: Bool { pageIndex != nil }
}

/// One node of the bookmark tree, flattened into a value type.
public struct OutlineNode: Sendable, Hashable, Codable, Identifiable {
    /// A stable path from the root: `[0, 2, 1]` is the second child of the third child of
    /// the first top-level bookmark. Stable for a given document, and derived from
    /// structure rather than from `UUID()`, so tests can name a node.
    public let id: OutlinePath
    public let label: String
    public let destination: DestinationTarget?
    public let isOpen: Bool
    public let children: [OutlineNode]

    public init(
        id: OutlinePath,
        label: String,
        destination: DestinationTarget?,
        isOpen: Bool,
        children: [OutlineNode]
    ) {
        self.id = id
        self.label = label
        self.destination = destination
        self.isOpen = isOpen
        self.children = children
    }

    /// This node and every descendant, depth-first, parents before children.
    public var flattened: [OutlineNode] {
        var out: [OutlineNode] = [self]
        for child in children { out.append(contentsOf: child.flattened) }
        return out
    }
}

/// The index path of an outline node.
public struct OutlinePath: Sendable, Hashable, Codable, CustomStringConvertible {
    public let indices: [Int]
    public init(_ indices: [Int]) { self.indices = indices }
    public func appending(_ index: Int) -> OutlinePath { OutlinePath(indices + [index]) }
    public var depth: Int { indices.count }
    public var description: String { indices.map(String.init).joined(separator: ".") }
}

/// A document's bookmark tree.
public struct DocumentOutline: Sendable, Hashable, Codable {
    public let roots: [OutlineNode]
    /// `true` when traversal stopped at ``DocumentLimits/maximumOutlineNodes`` or
    /// ``DocumentLimits/maximumOutlineDepth``. A cyclic or absurdly deep outline is a
    /// known PDF attack, so traversal is bounded and says so rather than hanging.
    public let wasTruncated: Bool
    public let nodeCount: Int

    public init(roots: [OutlineNode], wasTruncated: Bool, nodeCount: Int) {
        self.roots = roots
        self.wasTruncated = wasTruncated
        self.nodeCount = nodeCount
    }

    public static let empty = DocumentOutline(roots: [], wasTruncated: false, nodeCount: 0)
    public var isEmpty: Bool { roots.isEmpty }

    /// Every node, depth-first.
    public var flattened: [OutlineNode] { roots.flatMap(\.flattened) }
}

/// An entry of the document's `/Dests` name tree.
///
/// Named destinations are how a drawing set cross-references itself: a detail callout on
/// `A-102` points at the name `DETAIL-3-S201`, not at page 7.
public struct NamedDestination: Sendable, Hashable, Codable {
    public let name: String
    public let target: DestinationTarget

    public init(name: String, target: DestinationTarget) {
        self.name = name
        self.target = target
    }
}
