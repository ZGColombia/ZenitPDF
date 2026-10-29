import CoreGraphics
import Foundation
import PDFKit

/// One line of a page's embedded text, with where it sits — the shape the dimension check
/// (feature 13) pairs against a measurement's geometry. Positions are in page space
/// (PDF points, origin bottom-left), the same space markups measure in.
public struct PageTextLine: Sendable, Hashable {
    public let text: String
    public let boundsInPageSpace: CGRect

    public init(text: String, boundsInPageSpace: CGRect) {
        self.text = text
        self.boundsInPageSpace = boundsInPageSpace
    }
}

extension PDFKitDocumentProvider {

    /// The page's embedded text as positioned lines.
    ///
    /// Built from PDFKit's own line selections, so a dimension string drawn as one run of
    /// text is one line with one box. A page with no text layer returns `[]` — the caller
    /// treats that as "nothing to check against", never as an error.
    public func pageTextLines(
        of handle: DocumentHandle,
        pageIndex: Int
    ) async throws -> [PageTextLine] {
        try checkCancellation()
        let open = try entry(handle)
        if open.descriptor.encryption == .locked { return [] }
        defer { withExtendedLifetime(open) {} }
        let page = try page(open, at: pageIndex)
        return try EngineBarrier.guarded("pageTextLines") {
            let characterCount = page.numberOfCharacters
            guard characterCount > 0,
                  let whole = page.selection(for: NSRange(location: 0, length: characterCount)),
                  let pageString = page.string as NSString?
            else { return [] }
            // `characterBounds(at:)` is indexed by the page's *glyph stream*, and line
            // breaks live in `page.string` without a glyph — measured on this OS: after the
            // first newline every box answers for the following character. The map repairs
            // the indexing; a PDF whose breaks do carry glyphs degrades to the unmapped
            // index through the empty-box fallback in `runs`. Shared with characterBoxes so
            // both APIs repair the shift identically (CR-74).
            let glyphIndexByStringIndex = Self.glyphIndexByStringIndex(
                pageString: pageString, characterCount: characterCount
            )

            var lines: [PageTextLine] = []
            for selection in whole.selectionsByLine() {
                // PDFKit's "line" spans the whole baseline — on a printed schedule that is
                // the entire row, cells and all, under one box. Cell-level geometry is what
                // the table import and the dimension check pair against, so a line is split
                // wherever the characters leave a gap wide enough to be a column gutter,
                // measured against the line's own glyph widths.
                let rangeCount = selection.numberOfTextRanges(on: page)
                guard rangeCount > 0 else { continue }
                for rangeIndex in 0..<rangeCount {
                    let range = selection.range(at: rangeIndex, on: page)
                    guard range.location != NSNotFound, range.length > 0 else { continue }
                    lines.append(contentsOf: Self.runs(
                        in: range,
                        of: page,
                        pageString: pageString,
                        glyphIndexByStringIndex: glyphIndexByStringIndex
                    ))
                }
            }
            return lines
        }
    }

    /// One text range broken into runs at column-gutter-sized gaps.
    private static func runs(
        in range: NSRange,
        of page: PDFPage,
        pageString: NSString,
        glyphIndexByStringIndex: [Int]
    ) -> [PageTextLine] {
        var boxes: [(index: Int, bounds: CGRect)] = []
        for index in range.location..<(range.location + range.length) {
            guard glyphIndexByStringIndex.indices.contains(index) else { continue }
            let glyphIndex = glyphIndexByStringIndex[index]
            guard glyphIndex >= 0 else { continue }
            var bounds = page.characterBounds(at: glyphIndex)
            if bounds.isEmpty {
                // A PDF whose breaks carry glyphs is not shifted; try the plain index.
                bounds = page.characterBounds(at: index)
            }
            guard bounds.width.isFinite, !bounds.isEmpty else { continue }
            boxes.append((index, bounds))
        }
        guard !boxes.isEmpty else { return [] }
        let medianWidth = boxes.map(\.bounds.width).sorted()[boxes.count / 2]
        // Three glyphs of daylight is a gutter; one is letter spacing.
        let gutter = max(medianWidth * 3, 6)

        func isSeparator(_ box: (index: Int, bounds: CGRect)) -> Bool {
            // A column gutter arrives two ways: as empty space between boxes, or as one
            // whitespace glyph stretched across the gutter — CoreText writes the latter.
            guard box.bounds.width > gutter else { return false }
            let character = pageString.character(at: box.index)
            return character == 0x20 || character == 0x09 || character == 0xA0
        }

        var result: [PageTextLine] = []
        var run: [(index: Int, bounds: CGRect)] = []
        func flush() {
            defer { run = [] }
            guard let first = run.first, let last = run.last else { return }
            let text = pageString
                .substring(with: NSRange(
                    location: first.index,
                    length: last.index - first.index + 1
                ))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let union = run.dropFirst().reduce(run[0].bounds) { $0.union($1.bounds) }
            result.append(PageTextLine(text: text, boundsInPageSpace: union))
        }
        for box in boxes {
            if isSeparator(box) {
                flush()
                continue
            }
            if let last = run.last, box.bounds.minX - last.bounds.maxX > gutter {
                flush()
            }
            run.append(box)
        }
        flush()
        return result
    }
}
