import CoreGraphics
import Foundation

/// How a recognition run behaves.
///
/// Everything here is on-device (spec 17.4). There is no setting that could send a page
/// anywhere, because there is no code in this package that could.
public struct OCRSettings: Sendable, Hashable {

    /// Language hints, most likely first. `Vision` uses them to pick a model and to bias
    /// the language model; an empty list means the recogniser's own default.
    ///
    /// Ask ``OCRService/supportedRecognitionLanguages()`` for what this OS actually has;
    /// an unsupported code is dropped with the rest kept, rather than failing the run,
    /// because a Swedish drawing set opened on a machine without `sv-SE` should still be
    /// searchable in English.
    public var recognitionLanguages: [String]

    /// The recogniser's language model corrects `l00` to `100` and `RCOM` to `ROOM`.
    ///
    /// Off by default, and that is deliberate. A drawing is full of strings that are not
    /// words in any language — `A-102`, `EL-3`, `Ø25`, `C25/30` — and language correction
    /// turns them into words. A takeoff needs the string that is on the sheet.
    public var usesLanguageCorrection: Bool

    /// Accurate recognition, per spec 17.3. `false` selects the fast path, which is for a
    /// live preview and never for an index.
    public var usesAccurateRecognition: Bool

    /// Rasterisation resolution. Spec 17.3 says 200–300 dpi; the initialiser clamps to
    /// that range because below 200 the recogniser loses small title-block type and above
    /// 300 it costs memory for nothing.
    public var renderDPI: Double

    /// Recognised text below this confidence is not written at all.
    ///
    /// Distinct from ``OCRConfidencePolicy/threshold``, which is about *presenting* a hit.
    /// This one is about storing it, and its default is 0 — everything is stored, and the
    /// decision about what to show is made later, by the search, where the user can change
    /// it without a twenty-minute re-recognition.
    public var minimumStoredConfidence: Double

    /// Pages recognised at once.
    ///
    /// The reason this exists: a naive implementation issues one `VNRecognizeTextRequest`
    /// per page, and a 1 000-page set then holds 1 000 rasterised ARCH-D bitmaps — roughly
    /// 25 GB at 300 dpi — in flight simultaneously. The run is a sliding window instead:
    /// at most this many pages are rendered and recognised at a time, and the next page is
    /// only started when one finishes.
    public var maximumConcurrentPages: Int

    /// Skip a page that already has a usable text layer (spec 17.3, "page already has
    /// enough text -> skip by default").
    public var skipsPagesWithTextLayer: Bool

    /// How many characters of extracted text count as "already has enough text".
    ///
    /// A scanned sheet often carries a stamp or a footer added digitally afterwards, so
    /// "has any text at all" is the wrong test — it would skip exactly the pages that need
    /// recognising most.
    public var sufficientTextLayerCharacterCount: Int

    /// Pixels one page's rasterisation may allocate.
    ///
    /// An ARCH-D sheet at 300 dpi is 7 200 x 10 800 — 78 megapixels, 311 MB of RGBA, and
    /// over the bridge's own 64-megapixel render budget. Rather than let the render throw,
    /// the run lowers the scale for that page until it fits and records the resolution it
    /// actually used in ``OCRPageResult``. A sheet recognised at 215 dpi is a usable index;
    /// a sheet that threw is not.
    public var maximumRenderPixels: Int

    /// Words the recogniser should be willing to produce even though they are not in its
    /// vocabulary. Only consulted when ``usesLanguageCorrection`` is on.
    public var customWords: [String]

    /// Recognise a sheet too large for ``maximumRenderPixels`` in tiles at the full
    /// ``renderDPI`` instead of one downscaled image (NL-PDF-13).
    ///
    /// A 2.5 mm title-block digit on an A0 sheet fitted into 40 megapixels is rendered at about
    /// 130 dpi — seven pixels tall, below what the recogniser reads. Tiles keep every page at
    /// the resolution the settings ask for; each tile still fits the budget, so memory per page
    /// does not grow.
    public var tilesLargePages: Bool
    /// Longest side of one tile, in pixels, before the pixel budget caps it further.
    public var tilePixelSize: Int
    /// How much neighbouring tiles overlap, as a fraction of a tile, so a word cut by one tile's
    /// edge is whole in the next. Duplicates are merged by position and text.
    public var tileOverlapFraction: Double
    /// Also read text turned a quarter turn either way — the vertical dimension strings of a
    /// drawing — on any image whose upright pass found fewer than
    /// ``rotatedPassLineThreshold`` lines.
    ///
    /// Off by default: measured on macOS 26, Vision's upright pass already reads a
    /// quarter-turned dimension string, and the two extra passes tripled the time of every
    /// sparse page (a scanned title sheet went from one recognition to three).
    public var recognisesRotatedText: Bool
    /// Below this many upright lines an image is also read rotated. A busy tile is left at one
    /// pass: three passes over every tile of an A0 set would triple the run for the few tiles
    /// that carry vertical strings.
    public var rotatedPassLineThreshold: Int

    public init(
        recognitionLanguages: [String] = ["en-US"],
        usesLanguageCorrection: Bool = false,
        usesAccurateRecognition: Bool = true,
        renderDPI: Double = 300,
        minimumStoredConfidence: Double = 0,
        maximumConcurrentPages: Int = 4,
        maximumRenderPixels: Int = 40_000_000,
        skipsPagesWithTextLayer: Bool = true,
        sufficientTextLayerCharacterCount: Int = 32,
        customWords: [String] = [],
        tilesLargePages: Bool = true,
        tilePixelSize: Int = 2_400,
        tileOverlapFraction: Double = 0.1,
        recognisesRotatedText: Bool = false,
        rotatedPassLineThreshold: Int = 6
    ) {
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.usesAccurateRecognition = usesAccurateRecognition
        self.renderDPI = min(300, max(200, renderDPI.isFinite ? renderDPI : 300))
        self.minimumStoredConfidence = min(1, max(0, minimumStoredConfidence))
        self.maximumConcurrentPages = min(16, max(1, maximumConcurrentPages))
        self.maximumRenderPixels = min(64_000_000, max(1_000_000, maximumRenderPixels))
        self.skipsPagesWithTextLayer = skipsPagesWithTextLayer
        self.sufficientTextLayerCharacterCount = max(0, sufficientTextLayerCharacterCount)
        self.customWords = customWords
        self.tilesLargePages = tilesLargePages
        self.tilePixelSize = min(4_096, max(512, tilePixelSize))
        self.tileOverlapFraction = min(0.4, max(0, tileOverlapFraction.isFinite ? tileOverlapFraction : 0.1))
        self.recognisesRotatedText = recognisesRotatedText
        self.rotatedPassLineThreshold = max(0, rotatedPassLineThreshold)
    }

    public static let standard = OCRSettings()

    /// The render scale that turns PDF points into pixels at ``renderDPI``.
    public var renderScale: CGFloat { CGFloat(renderDPI / 72.0) }
}

/// One recognised word, as stored: its text, the recogniser's confidence, and its page-space box.
public struct OCRRecognisedToken: Sendable, Hashable {
    public let text: String
    public let confidence: Double
    public let bounds: CGRect

    public init(text: String, confidence: Double, bounds: CGRect) {
        self.text = text
        self.confidence = confidence
        self.bounds = bounds
    }
}

/// Why a page produced no recognised text.
public enum OCRSkipReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// The page already carries enough of a text layer.
    case hasTextLayer
    /// The recogniser ran and found nothing above the stored-confidence floor.
    case nothingRecognised
    /// The page could not be rasterised — over the pixel budget, or a degenerate box.
    case notRenderable
}

/// What recognition did to one page.
public struct OCRPageResult: Sendable, Hashable {
    public let pageIndex: Int
    public let pageId: String
    public let tokenCount: Int
    public let lineCount: Int
    /// Lowest confidence among the stored tokens, or `nil` when none were stored.
    public let minimumConfidence: Double?
    /// Mean confidence across the stored tokens, or `nil` when none were stored.
    public let averageConfidence: Double?
    public let skipReason: OCRSkipReason?
    /// Wall-clock seconds spent rendering and recognising this page.
    public let elapsedSeconds: Double
    /// The resolution this page was actually rasterised at, which is
    /// ``OCRSettings/renderDPI`` unless the sheet was too big for the pixel budget.
    public let effectiveDPI: Double

    public init(
        pageIndex: Int,
        pageId: String,
        tokenCount: Int,
        lineCount: Int,
        minimumConfidence: Double?,
        averageConfidence: Double?,
        skipReason: OCRSkipReason?,
        elapsedSeconds: Double,
        effectiveDPI: Double
    ) {
        self.pageIndex = pageIndex
        self.pageId = pageId
        self.tokenCount = tokenCount
        self.lineCount = lineCount
        self.minimumConfidence = minimumConfidence
        self.averageConfidence = averageConfidence
        self.skipReason = skipReason
        self.elapsedSeconds = elapsedSeconds
        self.effectiveDPI = effectiveDPI
    }

    public var wasSkipped: Bool { skipReason != nil }
}

/// What a whole recognition run did.
public struct OCRReport: Sendable, Hashable {
    public let documentId: String
    public let pagesRequested: Int
    /// Pages whose recognised text was stored and is now searchable — every page the
    /// recogniser looked at that produced text, with or without word boxes (S-103).
    public let pagesRecognised: Int
    public let pagesSkipped: Int
    public let tokensWritten: Int
    public let elapsedSeconds: Double
    /// Per-page results in page order.
    public let pages: [OCRPageResult]

    public init(
        documentId: String,
        pagesRequested: Int,
        pagesRecognised: Int,
        pagesSkipped: Int,
        tokensWritten: Int,
        elapsedSeconds: Double,
        pages: [OCRPageResult]
    ) {
        self.documentId = documentId
        self.pagesRequested = pagesRequested
        self.pagesRecognised = pagesRecognised
        self.pagesSkipped = pagesSkipped
        self.tokensWritten = tokensWritten
        self.elapsedSeconds = elapsedSeconds
        self.pages = pages
    }
}

/// How far a recognition run has got.
public struct OCRProgress: Sendable, Hashable {
    public let pagesCompleted: Int
    public let pagesTotal: Int
    /// The page just committed. Every token of this page is in the database by the time
    /// the callback runs, and no token of any later page is.
    public let lastPage: OCRPageResult

    public init(pagesCompleted: Int, pagesTotal: Int, lastPage: OCRPageResult) {
        self.pagesCompleted = pagesCompleted
        self.pagesTotal = pagesTotal
        self.lastPage = lastPage
    }

    public var fraction: Double {
        pagesTotal > 0 ? Double(pagesCompleted) / Double(pagesTotal) : 1
    }
}
