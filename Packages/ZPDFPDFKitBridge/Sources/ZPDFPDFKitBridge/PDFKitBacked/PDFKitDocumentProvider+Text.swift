import CoreGraphics
import Foundation
import PDFKit

extension PDFKitDocumentProvider {

    // MARK: - Page text

    public func pageText(of handle: DocumentHandle, pageIndex: Int) async throws -> PageText {
        try checkCancellation()
        let open = try entry(handle)
        if open.descriptor.encryption == .locked {
            return PageText(
                pageIndex: pageIndex,
                availability: .notPermitted,
                string: "",
                characterCount: 0,
                wasTruncated: false
            )
        }
        // `PDFPage` holds its `PDFDocument` weakly. Nothing may let the owning document's
        // last strong reference go while a page derived from it is still in use, or the
        // page quietly loses its document and PDFKit starts returning nothing.
        defer { withExtendedLifetime(open) {} }
        let page = try page(open, at: pageIndex)
        // PDFKit builds the page layout lazily here, and that path raises on a malformed
        // `/Info` dictionary. See `EngineBarrier`.
        let scanned = try EngineBarrier.guarded("pageText") {
            (count: page.numberOfCharacters, string: page.string)
        }
        let characterCount = scanned.count
        guard characterCount > 0, let string = scanned.string, !string.isEmpty else {
            // The scanned-sheet case, and it is a first-class answer rather than "".
            return PageText(
                pageIndex: pageIndex,
                availability: .noTextLayer,
                string: "",
                characterCount: 0,
                wasTruncated: false
            )
        }
        let limit = open.limits.maximumPageCharacters
        let truncated = string.count > limit
        return PageText(
            pageIndex: pageIndex,
            availability: .available,
            string: truncated ? String(string.prefix(limit)) : string,
            characterCount: characterCount,
            wasTruncated: truncated
        )
    }

    // MARK: - Character boxes

    public func characterBoxes(
        of handle: DocumentHandle,
        pageIndex: Int,
        range: CharacterRange?
    ) async throws -> [CharacterBox] {
        try checkCancellation()
        let open = try unlockedEntry(handle)
        // `PDFPage` holds its `PDFDocument` weakly. Nothing may let the owning document's
        // last strong reference go while a page derived from it is still in use, or the
        // page quietly loses its document and PDFKit starts returning nothing.
        defer { withExtendedLifetime(open) {} }
        let page = try page(open, at: pageIndex)
        let characterCount = try EngineBarrier.guarded("characterBoxes.count") { page.numberOfCharacters }
        guard characterCount > 0 else { return [] }

        let requested = range ?? CharacterRange(location: 0, length: characterCount)
        guard requested.location <= characterCount, requested.upperBound <= characterCount else {
            throw PDFBridgeError.characterRangeOutOfRange(
                location: requested.location,
                length: requested.length,
                characterCount: characterCount
            )
        }
        let count = min(requested.length, open.limits.maximumCharacterBoxes)
        // `characterBounds(at:)` is indexed by the page's *glyph stream*, in which line breaks
        // carry no glyph; indexing it with a raw string index shifts every box after the first
        // newline and returns an empty rect for the last real character (measured on this OS:
        // "ABC\nDEF" → string index 3 = D's box). +TextLines already repairs this with a glyph
        // map; characterBoxes must share it so box i answers for character i (CR-74).
        let pageString = try EngineBarrier.guarded("characterBoxes.string") { page.string as NSString? }
        let glyphMap = pageString.map {
            Self.glyphIndexByStringIndex(pageString: $0, characterCount: characterCount)
        }
        var boxes: [CharacterBox] = []
        boxes.reserveCapacity(count)
        var offset = 0
        while offset < count {
            if offset % 4096 == 0 { try checkCancellation() }
            let index = requested.location + offset
            let bounds = try EngineBarrier.guarded("characterBoxes.bounds") {
                Self.characterBounds(of: page, stringIndex: index, glyphMap: glyphMap)
            }
            boxes.append(CharacterBox(characterIndex: index, bounds: bounds))
            offset += 1
        }
        return boxes
    }

    /// Maps each string index to its glyph-stream index, or `-1` for a character with no glyph
    /// (a line break). Shared by ``characterBoxes(of:pageIndex:range:)`` and
    /// ``pageTextLines(of:pageIndex:)`` so both repair PDFKit's glyph-vs-string indexing the same
    /// way (CR-74). `characterCount` is `PDFPage.numberOfCharacters`.
    static func glyphIndexByStringIndex(pageString: NSString, characterCount: Int) -> [Int] {
        var map = [Int](repeating: -1, count: max(0, characterCount))
        var newlineCount = 0
        for stringIndex in 0..<min(characterCount, pageString.length) {
            let character = pageString.character(at: stringIndex)
            if character == 0x0A || character == 0x0D {
                newlineCount += 1
            } else {
                map[stringIndex] = stringIndex - newlineCount
            }
        }
        return map
    }

    /// The page-space box for the character at `stringIndex`, using the glyph map to undo the
    /// glyph-stream/string-index shift. Falls back to the raw index for a PDF whose breaks do
    /// carry glyphs, and to `.zero` for a character with no glyph at all (a line break).
    static func characterBounds(of page: PDFPage, stringIndex: Int, glyphMap: [Int]?) -> CGRect {
        if let glyphMap, glyphMap.indices.contains(stringIndex) {
            let glyphIndex = glyphMap[stringIndex]
            if glyphIndex >= 0 {
                let bounds = page.characterBounds(at: glyphIndex)
                if !bounds.isEmpty { return bounds }
            } else {
                // A line break has no glyph; report an empty box rather than a shifted one.
                return .zero
            }
        }
        let raw = page.characterBounds(at: stringIndex)
        return raw.isEmpty ? .zero : raw
    }

    // MARK: - Selection

    public func selection(
        of handle: DocumentHandle,
        pageIndex: Int,
        from start: CGPoint,
        to end: CGPoint
    ) async throws -> TextSelection? {
        try checkCancellation()
        let open = try unlockedEntry(handle)
        // `PDFPage` holds its `PDFDocument` weakly. Nothing may let the owning document's
        // last strong reference go while a page derived from it is still in use, or the
        // page quietly loses its document and PDFKit starts returning nothing.
        defer { withExtendedLifetime(open) {} }
        let page = try page(open, at: pageIndex)
        return try EngineBarrier.guarded("selection") { () -> TextSelection? in
            guard page.numberOfCharacters > 0 else { return nil }
            guard let selection = page.selection(from: start, to: end) else { return nil }
            return Self.neutralSelection(selection, page: page, pageIndex: pageIndex)
        }
    }

    static func neutralSelection(
        _ selection: PDFSelection,
        page: PDFPage,
        pageIndex: Int
    ) -> TextSelection? {
        let string = selection.string ?? ""
        let lineRects = selection.selectionsByLine().map { $0.bounds(for: page) }
        let bounds = lineRects.reduce(CGRect.null) { $0.union($1) }
        guard !string.isEmpty || !bounds.isNull else { return nil }
        return TextSelection(
            pageIndex: pageIndex,
            string: string,
            bounds: bounds.isNull ? selection.bounds(for: page) : bounds,
            lineRects: lineRects
        )
    }

    // MARK: - Search

    /// Searches page by page over the extracted text rather than through
    /// `PDFDocument.findString`.
    ///
    /// Two reasons. It yields an exact ``CharacterRange`` per hit, which PDFKit's
    /// selection objects do not expose and which the FTS5 index in spec 17.2 needs; and
    /// it is bounded and cancellable at page granularity, so searching a 1 000-sheet set
    /// cannot become an uninterruptible call into PDFKit.
    public func search(
        in handle: DocumentHandle,
        query: String,
        options: TextSearchOptions
    ) async throws -> TextSearchResults {
        try checkCancellation()
        let open = try unlockedEntry(handle)
        // `PDFPage` holds its `PDFDocument` weakly. Nothing may let the owning document's
        // last strong reference go while a page derived from it is still in use, or the
        // page quietly loses its document and PDFKit starts returning nothing.
        defer { withExtendedLifetime(open) {} }
        let limits = open.limits

        guard !query.isEmpty else { throw PDFBridgeError.emptySearchQuery }
        guard query.count <= limits.maximumQueryLength else {
            throw PDFBridgeError.searchQueryTooLong(length: query.count, limit: limits.maximumQueryLength)
        }

        let pageIndices: [Int]
        if options.pageIndices.isEmpty {
            pageIndices = Array(0..<open.descriptor.pageCount)
        } else {
            for index in options.pageIndices where index < 0 || index >= open.descriptor.pageCount {
                throw PDFBridgeError.pageIndexOutOfRange(index: index, pageCount: open.descriptor.pageCount)
            }
            // Each page once, in the caller's order: a repeated index scanned the page twice,
            // listed every hit twice against the hit budget and counted the page twice in
            // `pagesSearched` (BH-573).
            var seen: Set<Int> = []
            pageIndices = options.pageIndices.filter { seen.insert($0).inserted }
        }

        var compareOptions: NSString.CompareOptions = [.literal]
        if options.isCaseInsensitive { compareOptions.insert(.caseInsensitive) }
        if options.isDiacriticInsensitive { compareOptions.insert(.diacriticInsensitive) }

        var hits: [TextSearchHit] = []
        var withoutText: [Int] = []
        var truncated = false

        pageLoop: for pageIndex in pageIndices {
            try checkCancellation()
            guard let page = open.document.page(at: pageIndex) else { continue }
            let scanned = try EngineBarrier.guarded("search.pageText") {
                (count: page.numberOfCharacters, string: page.string)
            }
            guard scanned.count > 0, let text = scanned.string, !text.isEmpty else {
                withoutText.append(pageIndex)
                continue
            }
            let haystack = text as NSString
            let label = open.labels.label(forPageIndex: pageIndex) ?? String(pageIndex + 1)
            var searchStart = 0
            // Bounded: `searchStart` strictly increases every iteration.
            while searchStart < haystack.length {
                let remaining = NSRange(location: searchStart, length: haystack.length - searchStart)
                let found = haystack.range(of: query, options: compareOptions, range: remaining)
                guard found.location != NSNotFound, found.length > 0 else { break }
                searchStart = found.location + max(1, found.length)

                if options.matchesWholeWordsOnly,
                   !Self.isWholeWord(range: found, in: haystack) { continue }

                guard hits.count < limits.maximumSearchHits else {
                    truncated = true
                    break pageLoop
                }

                let geometry = try EngineBarrier.guarded("search.hitGeometry") {
                    () -> (lineRects: [CGRect], selectionBounds: CGRect) in
                    let selection = page.selection(for: found)
                    let rects = selection?.selectionsByLine().map { $0.bounds(for: page) } ?? []
                    return (rects, selection?.bounds(for: page) ?? .null)
                }
                let lineRects = geometry.lineRects
                let bounds = lineRects.reduce(CGRect.null) { $0.union($1) }
                hits.append(
                    TextSearchHit(
                        pageIndex: pageIndex,
                        pageLabel: label,
                        range: CharacterRange(found),
                        matchedText: haystack.substring(with: found),
                        bounds: bounds.isNull ? geometry.selectionBounds : bounds,
                        lineRects: lineRects,
                        excerpt: Self.excerpt(
                            around: found,
                            in: haystack,
                            context: options.excerptContextLength
                        )
                    )
                )
            }
        }

        return TextSearchResults(
            query: query,
            hits: hits,
            wasTruncated: truncated,
            pagesWithoutTextLayer: withoutText,
            pagesSearched: pageIndices.count
        )
    }

    static func isWholeWord(range: NSRange, in haystack: NSString) -> Bool {
        func isWordCharacter(_ scalar: unichar) -> Bool {
            guard let unicode = Unicode.Scalar(scalar) else { return false }
            return CharacterSet.alphanumerics.contains(unicode)
        }
        if range.location > 0, isWordCharacter(haystack.character(at: range.location - 1)) {
            return false
        }
        let after = range.location + range.length
        if after < haystack.length, isWordCharacter(haystack.character(at: after)) {
            return false
        }
        return true
    }

    static func excerpt(around range: NSRange, in haystack: NSString, context: Int) -> String {
        guard context > 0 else { return haystack.substring(with: range) }
        let start = max(0, range.location - context)
        let end = min(haystack.length, range.location + range.length + context)
        return haystack.substring(with: NSRange(location: start, length: end - start))
    }
}
