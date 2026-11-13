import CoreGraphics
import Foundation
import PDFKit

/// How a Select Text gesture asks for the page's own text (1.1.0).
///
/// One value per gesture rather than one method per gesture, so the application forwards a
/// single call through its raster source and the provider answers every case behind the same
/// guards: the document open and unlocked, the page in range, PDFKit inside the engine barrier.
/// Points are in page space (PDF points, origin bottom-left, unrotated), the space markups and
/// search highlights already use.
public enum TextSelectionGesture: Sendable, Hashable {
    /// A drag: the text from one point to the other in the page's reading order, as PDFKit
    /// selects it.
    case span(from: CGPoint, to: CGPoint)
    /// A double-click: the word under the point.
    case word(at: CGPoint)
    /// A triple-click: the line under the point.
    case line(at: CGPoint)
    /// Select All: every character on the visible page.
    case wholePage
}

extension PDFKitDocumentProvider {

    /// How far, in page points, a word or line box may lie from the click and still be the one
    /// clicked. PDFKit answers `selectionForWord(at:)` with the *nearest* word, so a
    /// double-click on empty paper would otherwise select a word a sheet-width away.
    static let textHitTolerance: CGFloat = 2

    /// The page's own text for a Select Text gesture, or `nil` when the gesture selects
    /// nothing: no text layer, a click on empty paper, a click outside the visible box.
    ///
    /// - Parameter visibleBox: the part of the page the person can see, in page space — the
    ///   crop box, narrowed by a sheet's own view crop. Text outside it is cropped off the sheet,
    ///   so it is neither selected nor highlighted: Select All selects *by this rectangle*, and a
    ///   drag, a word or a line keeps only what lies inside it. `nil` keeps everything.
    /// - Throws: `PDFBridgeError.documentLocked` for a drawing still behind its password, and the
    ///   provider's errors for a closed document or a page out of range — a failure the caller
    ///   can tell apart from "nothing selected".
    public func textSelection(
        of handle: DocumentHandle,
        pageIndex: Int,
        gesture: TextSelectionGesture,
        within visibleBox: CGRect? = nil
    ) async throws -> TextSelection? {
        try checkCancellation()
        let open = try unlockedEntry(handle)
        // `PDFPage` holds its `PDFDocument` weakly; keep the document alive while the page is
        // in use, as every text read here does.
        defer { withExtendedLifetime(open) {} }
        let page = try page(open, at: pageIndex)
        let box = visibleBox?.standardized
        return try EngineBarrier.guarded("textSelection") { () -> TextSelection? in
            let characterCount = page.numberOfCharacters
            guard characterCount > 0 else { return nil }
            let selection: PDFSelection?
            var probe: CGPoint?
            switch gesture {
            case let .span(from, to):
                guard from != to else { return nil }
                selection = page.selection(from: from, to: to)
            case let .word(point):
                if let box, !box.contains(point) { return nil }
                selection = page.selectionForWord(at: point)
                probe = point
            case let .line(point):
                if let box, !box.contains(point) { return nil }
                selection = page.selectionForLine(at: point)
                probe = point
            case .wholePage:
                selection = box.map { page.selection(for: $0) }
                    ?? page.selection(for: NSRange(location: 0, length: characterCount))
            }
            // The line split below walks every line of the selection — on a whole sheet the
            // costliest step — so a query the canvas has already given up stops here.
            guard !Task.isCancelled, let selection,
                  let neutral = Self.visibleSelection(selection, page: page, pageIndex: pageIndex, box: box),
                  !(neutral.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            else { return nil }
            if let probe {
                let tolerance = Self.textHitTolerance
                let hit = neutral.lineRects.contains { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(probe) }
                guard hit else { return nil }
            }
            return neutral
        }
    }

    /// A selection with the lines outside `box` dropped and a line that straddles its edge cut
    /// back to the characters inside it. Without a box, ``neutralSelection(_:page:pageIndex:)``.
    static func visibleSelection(
        _ selection: PDFSelection,
        page: PDFPage,
        pageIndex: Int,
        box: CGRect?
    ) -> TextSelection? {
        guard let box else { return neutralSelection(selection, page: page, pageIndex: pageIndex) }
        let lines = selection.selectionsByLine()
        var kept: [(string: String, rect: CGRect)] = []
        var changed = false
        for line in lines {
            let bounds = line.bounds(for: page)
            if box.contains(bounds) {
                kept.append((line.string ?? "", bounds))
                continue
            }
            changed = true
            let inside = bounds.intersection(box)
            guard !inside.isNull, inside.width > 0, inside.height > 0,
                  let clipped = page.selection(for: inside) else { continue }
            let string = clipped.string ?? ""
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            kept.append((string, clipped.bounds(for: page).intersection(box)))
        }
        guard !kept.isEmpty else { return nil }
        // Unchanged, PDFKit's own string keeps its own separators; cut, the kept lines are
        // joined one per line.
        let string = changed
            ? kept.map(\.string).joined(separator: "\n")
            : (selection.string ?? kept.map(\.string).joined(separator: "\n"))
        let rects = kept.map(\.rect)
        return TextSelection(
            pageIndex: pageIndex,
            string: string,
            bounds: rects.reduce(CGRect.null) { $0.union($1) },
            lineRects: rects
        )
    }

    /// Whether the page carries a text layer at all — the question Select Text asks once per
    /// page, so it can say so on a scanned sheet instead of selecting nothing in silence.
    ///
    /// - Throws: `PDFBridgeError.documentLocked` for a drawing still behind its password: its
    ///   text cannot be read yet, which is not the same as a scanned sheet having none.
    public func hasTextLayer(of handle: DocumentHandle, pageIndex: Int) async throws -> Bool {
        try checkCancellation()
        let open = try unlockedEntry(handle)
        defer { withExtendedLifetime(open) {} }
        let page = try page(open, at: pageIndex)
        return try EngineBarrier.guarded("hasTextLayer") { page.numberOfCharacters > 0 }
    }
}
