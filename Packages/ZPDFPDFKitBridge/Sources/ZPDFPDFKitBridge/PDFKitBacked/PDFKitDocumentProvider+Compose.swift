import CoreGraphics
import Foundation
import PDFKit

/// One page of a composed document (NL-DOCS-08): a page of an open drawing, turned by a view
/// rotation on top of its own `/Rotate`, and optionally relabelled — with its sheet number.
public struct ComposedPage: Sendable, Hashable {
    public var document: DocumentHandle
    public var pageIndex: Int
    /// 0, 90, 180 or 270, added to the page's own `/Rotate` in the result.
    public var viewRotation: Int
    /// The page label the result gives this page; `nil` keeps the source's own label.
    public var label: String?

    public init(document: DocumentHandle, pageIndex: Int, viewRotation: Int = 0, label: String? = nil) {
        self.document = document
        self.pageIndex = pageIndex
        self.viewRotation = viewRotation
        self.label = label
    }
}

/// A bookmark of a composed document, pointing at a result page (NL-DOCS-06 "Create Bookmarks
/// from Sheet Names"). A group has no page of its own.
public struct ComposedBookmark: Sendable, Hashable {
    public var title: String
    public var resultPageIndex: Int?
    public var children: [ComposedBookmark]

    public init(title: String, resultPageIndex: Int?, children: [ComposedBookmark] = []) {
        self.title = title
        self.resultPageIndex = resultPageIndex
        self.children = children
    }
}

extension PDFKitDocumentProvider {

    /// Writes a new PDF from pages of one or more open drawings, in the given order — the
    /// arranged set of a project (NL-DOCS-08). Links between the carried pages are re-pointed,
    /// bookmarks carried (or replaced by `bookmarks`), page labels written by incremental
    /// update (sheet numbers where given). No source file is ever written: the one write path
    /// hashes each before and after.
    public func composeDocument(
        _ pages: [ComposedPage],
        bookmarks: [ComposedBookmark]? = nil,
        to destination: DocumentDestination
    ) async throws -> DocumentWriteReceipt {
        try checkCancellation()
        guard let first = pages.first else { throw PDFBridgeError.pageOperation(.resultWouldBeEmpty) }
        let primary = try unlockedEntry(first.document)
        var contributors: [DocumentHandle: OpenDocument] = [first.document: primary]
        for page in pages where contributors[page.document] == nil {
            contributors[page.document] = try unlockedEntry(page.document)
        }
        for page in pages {
            guard let open = contributors[page.document], page.pageIndex >= 0,
                  page.pageIndex < open.descriptor.pageCount else {
                throw PDFBridgeError.pageOperation(.pageIndexOutOfRange(
                    index: page.pageIndex, count: contributors[page.document]?.descriptor.pageCount ?? 0
                ))
            }
        }
        let protectedURLs = contributors.values.compactMap { $0.origin.fileURL }
        var carried: CarriedStructure = ([], nil)
        return try performWrite(
            primary: primary,
            alsoProtecting: protectedURLs,
            destination: destination,
            finish: { url in try Self.appendCarriedPageLabels(&carried, toFileAt: url) },
            notCarried: { carried.notCarried }
        ) {
            let (pristine, carriers) = try Self.pristineContributors(contributors)
            let result = PDFDocument()
            for (position, page) in pages.enumerated() {
                guard let source = pristine[page.document]?.page(at: page.pageIndex),
                      let copy = source.copy() as? PDFPage else {
                    // The real page count, as the page-operations path reports it (W-059: this
                    // copy said `count: 0`).
                    throw PDFBridgeError.pageOperation(.pageIndexOutOfRange(
                        index: page.pageIndex, count: pristine[page.document]?.pageCount ?? 0
                    ))
                }
                result.insert(copy, at: position)
                result.page(at: position)?.rotation = PageRotationMath.normalised(source.rotation + page.viewRotation)
            }
            carried = PageStructureCarrier.carry(
                into: result,
                sources: pages.map { ($0.document, $0.pageIndex) },
                contributors: carriers,
                primary: first.document
            )
            // Sheet numbers win over the carried labels, page by page.
            if pages.contains(where: { $0.label != nil }) {
                carried.labels = pages.enumerated().map { position, page in
                    page.label ?? carried.labels?[position]
                        ?? contributors[page.document]?.labels.label(forPageIndex: page.pageIndex)
                        ?? String(page.pageIndex + 1)
                }
            }
            if let bookmarks {
                let root = PDFOutline()
                for bookmark in bookmarks {
                    if let node = Self.outline(bookmark, in: result, depth: 1) {
                        root.insertChild(node, at: root.numberOfChildren)
                    }
                }
                result.outlineRoot = root.numberOfChildren > 0 ? root : nil
            }
            return result
        }
    }

    private static func outline(_ bookmark: ComposedBookmark, in document: PDFDocument, depth: Int) -> PDFOutline? {
        guard depth <= 32 else { return nil }
        let node = PDFOutline()
        node.label = bookmark.title
        if let index = bookmark.resultPageIndex, let page = document.page(at: index) {
            let box = page.bounds(for: .cropBox)
            node.destination = PDFDestination(page: page, at: CGPoint(x: box.minX, y: box.maxY))
        }
        for child in bookmark.children {
            if let rebuilt = outline(child, in: document, depth: depth + 1) {
                node.insertChild(rebuilt, at: node.numberOfChildren)
            }
        }
        return (node.destination != nil || node.numberOfChildren > 0) ? node : nil
    }
}
