import CoreGraphics
import Foundation

/// Where a search looks. Spec 17.5's first three scopes.
public enum SearchScope: Sendable, Hashable {
    /// One page of one document.
    case page(projectId: String, pageId: String)
    /// Every page of one document.
    case document(projectId: String, documentId: String)
    /// Every document in the project.
    case project(projectId: String)

    public var projectId: String {
        switch self {
        case let .page(projectId, _): return projectId
        case let .document(projectId, _): return projectId
        case let .project(projectId): return projectId
        }
    }
}

/// What to do with a recognised hit whose confidence is below the bar.
public enum LowConfidenceHandling: String, Sendable, Hashable, Codable, CaseIterable {
    /// Return it, flagged. The default, and the honest one: the estimator decides whether
    /// a 0.4-confidence `RCOM 1O1` is the `ROOM 101` they were looking for.
    case mark
    /// Drop it. For an automated consumer that must not act on a guess.
    case exclude
}

/// When a recognised hit counts as trustworthy.
///
/// ### Why this is a policy and not a constant
///
/// A recognised hit and a real text hit are not the same kind of fact, and a takeoff is
/// billed against the second kind. A search that silently mixes them tells the estimator
/// that the drawing says `ROOM 101` when what actually happened is that a recogniser
/// thought a smudge probably said that. Every hit this package returns therefore carries
/// ``SearchHit/sourceType``, and every recognised hit carries its
/// ``SearchHit/ocrConfidence`` and an explicit ``SearchHit/isLowConfidenceOCR`` flag.
/// Nothing is ever silently mixed.
public struct OCRConfidencePolicy: Sendable, Hashable {
    /// Recognised hits at or above this confidence are treated as ordinary hits. Below it
    /// they are marked, or excluded, per ``handling``.
    public var threshold: Double
    public var handling: LowConfidenceHandling

    public init(threshold: Double = 0.5, handling: LowConfidenceHandling = .mark) {
        self.threshold = min(1, max(0, threshold.isFinite ? threshold : 0.5))
        self.handling = handling
    }

    public static let standard = OCRConfidencePolicy()
    /// Everything recognised is returned, and nothing is marked. For a diagnostic view.
    public static let permissive = OCRConfidencePolicy(threshold: 0, handling: .mark)
    /// Only confident recognition survives.
    public static let strict = OCRConfidencePolicy(threshold: 0.8, handling: .exclude)
}

/// Where a hit's highlight rectangles came from.
public enum SearchBoundsSource: String, Sendable, Hashable, Codable, CaseIterable {
    /// The `ocr_token` rows whose normalised token matched a query term. Exact.
    case recognisedTokens
    /// The markup's own `geometry_blob`, as one bounding rectangle.
    case markupGeometry
    /// The PDF engine's own page search, resolved on demand.
    case pageText
    /// No rectangles: the hit has no geometry, or bounds resolution was not asked for.
    case none
}

/// One ranked hit.
public struct SearchHit: Sendable, Hashable {
    public let sourceType: SearchSourceType
    public let projectId: String
    public let documentId: String?
    public let pageId: String?
    /// The `source_id` of the row: a page id, a markup id, `markupId/columnId`, a zone id.
    public let sourceId: String
    /// Zero-based position in the page tree, when the hit is on a page.
    public let pageIndex: Int?
    /// What the sheet is called — `A-102`, not "page 3". A hit list is a user-facing
    /// surface and spec 9 forbids formatting an index as if it were a label.
    public let pageLabel: String?
    /// FTS5's own snippet, with the matched terms bracketed.
    public let snippet: String
    /// `bm25`. Lower is a better match; the list is already sorted by it.
    public let rank: Double
    /// Page-space rectangles for highlighting, possibly empty.
    public let bounds: [CGRect]
    public let boundsSource: SearchBoundsSource
    /// The lowest confidence among the recognised tokens that matched, for an `ocr` hit.
    /// `nil` for every other source type — a real text layer has no confidence, and
    /// reporting `1.0` for it would invite exactly the conflation this package refuses.
    public let ocrConfidence: Double?
    /// `true` when this is a recognised hit below ``OCRConfidencePolicy/threshold``.
    public let isLowConfidenceOCR: Bool
    /// `true` when this is a recognised hit whose confidence could not be established
    /// at all — the FTS row matched, but no `ocr_token` row on the page did (CR-125).
    ///
    /// Unknown is not zero. The old code spelled it `(confidence ?? 0) < threshold`,
    /// which made "we could not find the token" indistinguishable from "the recogniser
    /// was certain it was wrong", and under
    /// ``LowConfidenceHandling/exclude`` that silently deleted good hits whenever the
    /// token lookup and the FTS tokeniser disagreed — a folding difference, or an
    /// `ocr_token` table that had been cleared while the FTS rows survived. Such a hit
    /// is now kept, is not counted as low confidence, and says so.
    public let hasUnknownOCRConfidence: Bool

    public init(
        sourceType: SearchSourceType,
        projectId: String,
        documentId: String?,
        pageId: String?,
        sourceId: String,
        pageIndex: Int?,
        pageLabel: String?,
        snippet: String,
        rank: Double,
        bounds: [CGRect],
        boundsSource: SearchBoundsSource,
        ocrConfidence: Double?,
        isLowConfidenceOCR: Bool,
        hasUnknownOCRConfidence: Bool = false
    ) {
        self.sourceType = sourceType
        self.projectId = projectId
        self.documentId = documentId
        self.pageId = pageId
        self.sourceId = sourceId
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.snippet = snippet
        self.rank = rank
        self.bounds = bounds
        self.boundsSource = boundsSource
        self.ocrConfidence = ocrConfidence
        self.isLowConfidenceOCR = isLowConfidenceOCR
        self.hasUnknownOCRConfidence = hasUnknownOCRConfidence
    }
}

/// Highlight rectangles resolved for one hit after the result list was shown (IM-085).
public struct SearchHitBounds: Sendable, Hashable {
    /// Page-space rectangles, possibly empty.
    public let rects: [CGRect]
    public let source: SearchBoundsSource

    public init(rects: [CGRect], source: SearchBoundsSource) {
        self.rects = rects
        self.source = source
    }
}

/// One search.
public struct SearchRequest: Sendable, Hashable {
    /// Exactly what the user typed.
    public var text: String
    public var scope: SearchScope
    public var sources: SearchSourceFilter
    public var queryOptions: SearchQueryOptions
    public var confidence: OCRConfidencePolicy
    public var maximumHits: Int
    /// Resolve highlight rectangles. Off makes a project-wide count query cheap, and is
    /// the first phase of an interactive search: show the list, then resolve rectangles
    /// for the hits the user reveals with ``SearchService/bounds(for:query:)-(SearchHit,_)``
    /// (IM-085). Defaults to `true` so existing callers are unchanged.
    public var resolvesBounds: Bool

    public init(
        text: String,
        scope: SearchScope,
        sources: SearchSourceFilter = .all,
        queryOptions: SearchQueryOptions = .standard,
        confidence: OCRConfidencePolicy = .standard,
        maximumHits: Int = 200,
        resolvesBounds: Bool = true
    ) {
        self.text = text
        self.scope = scope
        self.sources = sources
        self.queryOptions = queryOptions
        self.confidence = confidence
        self.maximumHits = max(1, maximumHits)
        self.resolvesBounds = resolvesBounds
    }
}

/// The outcome of one search.
public struct SearchResults: Sendable, Hashable {
    public let query: SearchQuery
    /// Ranked best first.
    public let hits: [SearchHit]
    /// `true` when the search stopped at the hit limit.
    public let wasTruncated: Bool
    /// How many hits each source produced, before the confidence policy excluded any.
    public let hitCountsBySource: [SearchSourceType: Int]
    /// Recognised hits below the threshold. Non-zero means the list the user is looking at
    /// contains guesses, and the UI is expected to say so.
    public let lowConfidenceOCRHitCount: Int
    /// Recognised hits dropped by ``LowConfidenceHandling/exclude``.
    public let excludedLowConfidenceOCRHitCount: Int
    /// Recognised hits whose confidence could not be established (CR-125). Non-zero
    /// means the index and the token table disagree about this page, which is worth
    /// saying out loud — it is never a reason to drop the hit.
    public let unknownConfidenceOCRHitCount: Int
    public let elapsedSeconds: Double

    public init(
        query: SearchQuery,
        hits: [SearchHit],
        wasTruncated: Bool,
        hitCountsBySource: [SearchSourceType: Int],
        lowConfidenceOCRHitCount: Int,
        excludedLowConfidenceOCRHitCount: Int,
        unknownConfidenceOCRHitCount: Int = 0,
        elapsedSeconds: Double
    ) {
        self.query = query
        self.hits = hits
        self.wasTruncated = wasTruncated
        self.hitCountsBySource = hitCountsBySource
        self.lowConfidenceOCRHitCount = lowConfidenceOCRHitCount
        self.excludedLowConfidenceOCRHitCount = excludedLowConfidenceOCRHitCount
        self.unknownConfidenceOCRHitCount = unknownConfidenceOCRHitCount
        self.elapsedSeconds = elapsedSeconds
    }

    public var isEmpty: Bool { hits.isEmpty }
}

/// What is in the index right now. Internal with ``SearchService/statistics(projectId:)``.
struct SearchIndexStatistics: Sendable, Hashable {
    let projectId: String
    let rowCountsBySource: [SearchSourceType: Int]
    let recognisedTokenCount: Int
    let indexedDocumentCount: Int

    init(
        projectId: String,
        rowCountsBySource: [SearchSourceType: Int],
        recognisedTokenCount: Int,
        indexedDocumentCount: Int
    ) {
        self.projectId = projectId
        self.rowCountsBySource = rowCountsBySource
        self.recognisedTokenCount = recognisedTokenCount
        self.indexedDocumentCount = indexedDocumentCount
    }

    var totalRowCount: Int { rowCountsBySource.values.reduce(0, +) }
}

/// Resolves highlight rectangles for a hit in a PDF text layer.
///
/// The FTS index stores a page's text but not where any of it is, so a `pdf-text` hit's
/// rectangles have to come from the engine. That is an optional dependency: a caller that
/// only wants a result list — a count, an export, a jump-to-page — should not have to open
/// every document in the project to get one.
public protocol SearchTextBoundsResolving: Sendable {
    /// Page-space rectangles for `terms` on one page, or an empty array when the page or
    /// the document is not available.
    func textBounds(
        documentId: String,
        pageIndex: Int,
        terms: [SearchBoundsTerm]
    ) async -> [CGRect]
}

/// One term as a highlight has to see it.
///
/// Not a bare `String`, for two reasons the finding review found the hard way:
///
/// - the literal must be what the user typed (`A-102`), not the tokens the index split
///   it into (`A 102`), which appear in that order nowhere on a drawing (CR-123);
/// - a prefix term is a *word* the user has not finished typing, so the highlight belongs
///   on the whole word, not on the three glyphs typed so far (CR-140).
public struct SearchBoundsTerm: Sendable, Hashable {
    /// The literal to look for, exactly as it was typed.
    public let text: String
    /// `true` when `text` is the beginning of a word rather than the whole of it.
    public let isPrefix: Bool
    /// `true` when the hit was found case-sensitively, so only text in the typed case is the
    /// match and only it gets a rectangle (W-081).
    public let isCaseSensitive: Bool

    public init(text: String, isPrefix: Bool, isCaseSensitive: Bool = false) {
        self.text = text
        self.isPrefix = isPrefix
        self.isCaseSensitive = isCaseSensitive
    }
}
