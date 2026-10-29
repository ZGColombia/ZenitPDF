import CoreGraphics
import Foundation
import PDFKit

extension PDFKitDocumentProvider {

    /// The bookmark tree, walked breadth-limited and depth-limited.
    ///
    /// PDFKit builds `PDFOutline` lazily from the `/Outlines` dictionary, and a malicious
    /// or merely broken file can make that tree deep or wide enough to exhaust the stack.
    /// The walk here is iterative, counted, and reports
    /// ``DocumentOutline/wasTruncated`` rather than stopping silently.
    public func outline(of handle: DocumentHandle) async throws -> DocumentOutline {
        try checkCancellation()
        let open = try unlockedEntry(handle)
        // `PDFPage` holds its `PDFDocument` weakly. Nothing may let the owning document's
        // last strong reference go while a page derived from it is still in use, or the
        // page quietly loses its document and PDFKit starts returning nothing.
        defer { withExtendedLifetime(open) {} }
        guard let root = try EngineBarrier.guarded("outlineRoot", { open.document.outlineRoot })
        else { return .empty }

        var visited = 0
        var truncated = false
        let limits = open.limits

        func node(_ outline: PDFOutline, path: OutlinePath) throws -> OutlineNode? {
            guard visited < limits.maximumOutlineNodes else {
                truncated = true
                return nil
            }
            guard path.depth <= limits.maximumOutlineDepth else {
                truncated = true
                return nil
            }
            visited += 1
            try checkCancellation()

            var children: [OutlineNode] = []
            let childCount = outline.numberOfChildren
            var index = 0
            while index < childCount {
                defer { index += 1 }
                guard let child = outline.child(at: index) else { continue }
                guard let mapped = try node(child, path: path.appending(index)) else {
                    truncated = true
                    break
                }
                children.append(mapped)
            }

            return OutlineNode(
                id: path,
                label: outline.label ?? "",
                destination: destinationTarget(
                    of: outline,
                    document: open.document,
                    labels: open.labels
                ),
                isOpen: outline.isOpen,
                children: children
            )
        }

        var roots: [OutlineNode] = []
        let childCount = root.numberOfChildren
        var index = 0
        while index < childCount {
            defer { index += 1 }
            guard let child = root.child(at: index) else { continue }
            guard let mapped = try node(child, path: OutlinePath([index])) else { break }
            roots.append(mapped)
        }

        return DocumentOutline(roots: roots, wasTruncated: truncated, nodeCount: visited)
    }

    /// Where a bookmark points, or `nil` for a bookmark that is only a heading.
    ///
    /// A bookmark whose action is anything other than "go to a page in this document" —
    /// a URL, a launch, a remote file — is reported as *unresolved* rather than followed.
    private func destinationTarget(
        of outline: PDFOutline,
        document: PDFDocument,
        labels: PageLabelTable
    ) -> DestinationTarget? {
        if let destination = outline.destination {
            return Self.target(for: destination, document: document, labels: labels)
        }
        if let goTo = outline.action as? PDFActionGoTo {
            return Self.target(for: goTo.destination, document: document, labels: labels)
        }
        return nil
    }

    static func target(
        for destination: PDFDestination,
        document: PDFDocument,
        labels: PageLabelTable
    ) -> DestinationTarget {
        var pageIndex: Int?
        if let page = destination.page {
            let index = document.index(for: page)
            if index != NSNotFound, index >= 0 { pageIndex = index }
        }
        let point = destination.point
        let zoom = specified(destination.zoom).flatMap { $0 > 0 ? $0 : nil }
        return DestinationTarget(
            pageIndex: pageIndex,
            pageLabel: pageIndex.flatMap { labels.label(forPageIndex: $0) },
            left: specified(point.x),
            top: specified(point.y),
            zoom: zoom
        )
    }

    /// `value`, or `nil` when PDFKit reports it as unspecified.
    ///
    /// PDFKit's sentinel is `kPDFDestinationUnspecifiedValue`, which is `FLT_MAX` (about
    /// 3.4e38) — finite, and far below the `CGFloat.greatestFiniteMagnitude / 2` (about
    /// 9e307) the old guard compared against, so a `/Fit` or `/XYZ null null null` bookmark
    /// carried the point (3.4e38, 3.4e38) and zoom 3.4e38 as real targets (BH-171).
    static func specified(_ value: CGFloat) -> CGFloat? {
        guard value.isFinite else { return nil }
        let sentinel = CGFloat(kPDFDestinationUnspecifiedValue)
        guard abs(value) < sentinel / 2 else { return nil }
        return value
    }
}
