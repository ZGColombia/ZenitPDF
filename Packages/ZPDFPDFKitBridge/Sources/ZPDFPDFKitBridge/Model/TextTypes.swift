import CoreGraphics
import Foundation

/// Whether a page has an extractable text layer at all.
///
/// The scanned-drawing case is the normal case in construction, not an edge case: half
/// the sheets in a set are photocopies. Every text API in this package answers it
/// explicitly rather than returning an empty string that a caller might read as "no
/// match found".
public enum TextAvailability: String, Sendable, Hashable, Codable, CaseIterable {
    /// The page has characters.
    case available
    /// The page has no text layer. OCR is the only route to text here.
    case noTextLayer
    /// The document is encrypted, still locked, or forbids copying, so text was not read.
    case notPermitted
}

/// One page's text.
public struct PageText: Sendable, Hashable, Codable {
    public let pageIndex: Int
    public let availability: TextAvailability
    /// The extracted string, empty unless `availability == .available`.
    public let string: String
    /// The number of characters PDFKit reports for the page, which is the domain of
    /// ``CharacterBox`` indices. It can exceed `string.count`, because a Swift `Character`
    /// may be several PDF characters.
    public let characterCount: Int
    /// `true` when extraction stopped at ``DocumentLimits/maximumPageCharacters``.
    public let wasTruncated: Bool

    public init(
        pageIndex: Int,
        availability: TextAvailability,
        string: String,
        characterCount: Int,
        wasTruncated: Bool
    ) {
        self.pageIndex = pageIndex
        self.availability = availability
        self.string = string
        self.characterCount = characterCount
        self.wasTruncated = wasTruncated
    }

    public var isEmpty: Bool { characterCount == 0 }
}

/// A half-open range in a page's UTF-16 character space.
///
/// Not `NSRange`: this package must not add a retroactive `Codable` conformance to a
/// Foundation type, and a value type of its own costs two integers.
public struct CharacterRange: Sendable, Hashable, Codable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    public init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    public var upperBound: Int { location + length }
    public var isEmpty: Bool { length == 0 }
}

/// The bounding box of one character, in page space.
public struct CharacterBox: Sendable, Hashable, Codable {
    public let characterIndex: Int
    public let bounds: CGRect

    public init(characterIndex: Int, bounds: CGRect) {
        self.characterIndex = characterIndex
        self.bounds = bounds
    }
}

/// A text selection between two points on one page.
public struct TextSelection: Sendable, Hashable, Codable {
    public let pageIndex: Int
    public let string: String
    /// The union of the selection's rectangles on the page, in page space.
    public let bounds: CGRect
    /// The per-line rectangles, in page space, for drawing a highlight.
    public let lineRects: [CGRect]

    public init(pageIndex: Int, string: String, bounds: CGRect, lineRects: [CGRect]) {
        self.pageIndex = pageIndex
        self.string = string
        self.bounds = bounds
        self.lineRects = lineRects
    }

    public var isEmpty: Bool { string.isEmpty }
}

/// How a document search compares.
public struct TextSearchOptions: Sendable, Hashable, Codable {
    public var isCaseInsensitive: Bool
    public var isDiacriticInsensitive: Bool
    /// Only match when both ends of the hit sit on a word boundary. A boundary is any
    /// position next to a character that is neither a letter nor a digit.
    public var matchesWholeWordsOnly: Bool
    /// Characters of surrounding text returned with each hit, on each side.
    public var excerptContextLength: Int
    /// Restrict the search to these page indices. Empty means the whole document.
    public var pageIndices: [Int]

    public init(
        isCaseInsensitive: Bool = true,
        isDiacriticInsensitive: Bool = false,
        matchesWholeWordsOnly: Bool = false,
        excerptContextLength: Int = 40,
        pageIndices: [Int] = []
    ) {
        self.isCaseInsensitive = isCaseInsensitive
        self.isDiacriticInsensitive = isDiacriticInsensitive
        self.matchesWholeWordsOnly = matchesWholeWordsOnly
        self.excerptContextLength = max(0, min(excerptContextLength, 4096))
        self.pageIndices = pageIndices
    }

    public static let standard = TextSearchOptions()
}

/// One search hit.
///
/// `pageLabel` is carried alongside `pageIndex` because a search result list is a
/// user-facing surface, and a user looking for `ROOM 101` needs to be told it is on sheet
/// `A-102`, not on "page 3".
public struct TextSearchHit: Sendable, Hashable, Codable {
    public let pageIndex: Int
    public let pageLabel: String
    /// The matched range in the page's UTF-16 character space, which is the space
    /// PDFKit's own character indices live in.
    public let range: CharacterRange
    public let matchedText: String
    /// The union of the hit's rectangles in page space.
    public let bounds: CGRect
    /// Per-line rectangles of the hit, for highlighting a wrapped match.
    public let lineRects: [CGRect]
    /// `matchedText` with up to ``TextSearchOptions/excerptContextLength`` characters of
    /// surrounding text on each side.
    public let excerpt: String

    public init(
        pageIndex: Int,
        pageLabel: String,
        range: CharacterRange,
        matchedText: String,
        bounds: CGRect,
        lineRects: [CGRect],
        excerpt: String
    ) {
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.range = range
        self.matchedText = matchedText
        self.bounds = bounds
        self.lineRects = lineRects
        self.excerpt = excerpt
    }
}

/// The outcome of a document search.
public struct TextSearchResults: Sendable, Hashable, Codable {
    public let query: String
    public let hits: [TextSearchHit]
    /// `true` when the search stopped at ``DocumentLimits/maximumSearchHits``.
    public let wasTruncated: Bool
    /// Pages that were searched and had no text layer at all. A search that returns no
    /// hits over 40 scanned sheets is a different answer from one that returns no hits
    /// over 40 vector sheets, and the caller is told which it got.
    public let pagesWithoutTextLayer: [Int]
    public let pagesSearched: Int

    public init(
        query: String,
        hits: [TextSearchHit],
        wasTruncated: Bool,
        pagesWithoutTextLayer: [Int],
        pagesSearched: Int
    ) {
        self.query = query
        self.hits = hits
        self.wasTruncated = wasTruncated
        self.pagesWithoutTextLayer = pagesWithoutTextLayer
        self.pagesSearched = pagesSearched
    }

    public var isEmpty: Bool { hits.isEmpty }
}
