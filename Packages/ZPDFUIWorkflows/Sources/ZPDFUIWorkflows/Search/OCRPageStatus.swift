import Foundation
import ZPDFDesignSystem
import ZPDFUIPresentation

/// Where one page stands with text recognition.
public enum OCRPageStatus: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// Recognition has not been run on this page.
    case notIndexed
    /// Recognition is running on this page right now.
    case indexing
    /// Recognition finished and found text.
    case indexed
    /// Recognition finished and found nothing readable.
    case noTextFound
    /// The page was not read because it already carries real text, and the run was asked to
    /// skip such pages.
    ///
    /// There was no status for this, so the host reported a skipped page as `.noTextFound` and
    /// a vector drawing full of real text came back as page after page of "No text found",
    /// each with a warning glyph. Findings BH-310, IM-150. It counts as done for progress.
    case skippedHasText
    /// The page could not be read this time (1.0.1): macOS text recognition threw in every way
    /// Zenit runs it, or the page could not be rendered for it.
    ///
    /// The host reported it as `.noTextFound`, which told the person the page had been read and
    /// held nothing legible. Words an earlier run recognised on it stay searchable. It counts as
    /// done for progress; a new run reads it again.
    case couldNotBeRead

    /// Stable identity.
    public var id: String { rawValue }

    /// The status of a page a recognition run came back with, from the engine's skip reason:
    /// `OCRSkipReason.rawValue` in ZPDFSearch, carried as text so this tier imports no engine.
    ///
    /// No reason is a page that was read and gave text. A page skipped because it already has
    /// real text is `.skippedHasText` (BH-310, IM-150). A page macOS could not read, or could not
    /// render to read, is `.couldNotBeRead` instead of "No text found" (1.0.1). Only a page the
    /// recogniser read and found nothing on is `.noTextFound`.
    ///
    /// Each engine reason is mapped by name, and ZPDFSearch's tests pin those names and their
    /// number, so a reason the engine adds has to be mapped here on purpose.
    public init(recognitionSkipReason skipReason: String?) {
        guard let skipReason else {
            self = .indexed
            return
        }
        switch skipReason {
        case Self.hasTextLayerSkipReason:
            self = .skippedHasText
        case Self.recognitionFailedSkipReason, Self.notRenderableSkipReason:
            self = .couldNotBeRead
        default:
            // `OCRSkipReason.nothingRecognised`.
            self = .noTextFound
        }
    }

    /// `OCRSkipReason.hasTextLayer.rawValue`. ZPDFSearch's tests pin the engine's raw values.
    static let hasTextLayerSkipReason = "hasTextLayer"
    /// `OCRSkipReason.notRenderable.rawValue`.
    static let notRenderableSkipReason = "notRenderable"
    /// `OCRSkipReason.recognitionFailed.rawValue`.
    static let recognitionFailedSkipReason = "recognitionFailed"

    /// Whether the run is finished with this page, whatever it found.
    public var isDone: Bool {
        self == .indexed || self == .noTextFound || self == .skippedHasText || self == .couldNotBeRead
    }

    /// A localized status name.
    public var displayName: String {
        switch self {
        case .notIndexed:
            return NSLocalizedString("Not read yet", comment: "OCR page status")
        case .indexing:
            return NSLocalizedString("Reading", comment: "OCR page status")
        case .indexed:
            return NSLocalizedString("Text found", comment: "OCR page status")
        case .noTextFound:
            return NSLocalizedString("No text found", comment: "OCR page status")
        case .skippedHasText:
            return NSLocalizedString("Skipped — already has text", comment: "OCR page status")
        case .couldNotBeRead:
            return NSLocalizedString(
                "Could not be read",
                comment: "OCR page status: macOS text recognition failed on the page, or the page could not be rendered for it"
            )
        }
    }

    /// A localized sentence explaining what the status means for search results.
    public var explanation: String {
        switch self {
        case .notIndexed:
            return NSLocalizedString(
                "Searching will not find words on this page until it has been read.",
                comment: "OCR page status explanation"
            )
        case .indexing:
            return NSLocalizedString(
                "This page is being read now. Results from it will appear as soon as it finishes.",
                comment: "OCR page status explanation"
            )
        case .indexed:
            return NSLocalizedString(
                "Words recognised on this page are searchable.",
                comment: "OCR page status explanation"
            )
        case .noTextFound:
            return NSLocalizedString(
                "This page was read and nothing legible was found on it. It may be a pure drawing, or the scan may be too faint.",
                comment: "OCR page status explanation"
            )
        case .skippedHasText:
            return NSLocalizedString(
                "This page already carries real text, so it was not read. Search finds its words through that text.",
                comment: "OCR page status explanation"
            )
        case .couldNotBeRead:
            // True for a recognition failure and a render failure alike, and for a page an
            // earlier run read: its words stay searchable (BH-205).
            return NSLocalizedString(
                "This page could not be read this time, so search finds no new words on it. Any words an earlier reading found on it stay searchable. Try reading it again.",
                comment: "OCR page status explanation: the page could not be read this run"
            )
        }
    }

    /// The design-system severity, so the status is legible without colour.
    public var displaySeverity: ZPDFSeverity {
        switch self {
        case .notIndexed: return .neutral
        case .indexing: return .info
        case .indexed: return .success
        case .noTextFound: return .warning
        case .skippedHasText: return .neutral
        case .couldNotBeRead: return .danger
        }
    }

    /// The glyph shown next to the status.
    public var glyph: ZPDFGlyph {
        switch self {
        case .notIndexed: return .symbol(.hidden)
        case .indexing: return .symbol(.search)
        case .indexed: return .symbol(.success)
        case .noTextFound: return .symbol(.warning)
        case .skippedHasText: return .symbol(.text)
        case .couldNotBeRead: return .symbol(.error)
        }
    }
}

/// What recognition knows about one page.
public struct OCRPageStatusSummary: Hashable, Sendable, Identifiable {

    /// The page this is about.
    public let id: PageDescriptor.ID
    /// The page label the person sees.
    public var pageLabel: String
    /// Zero-based position in the document, for ordering.
    public var pageIndex: Int
    /// Where the page stands.
    public var status: OCRPageStatus
    /// Mean recognition confidence over the page, `0...1`, or `nil` when it has not been read.
    public var confidence: Double?
    /// How many words were recognised.
    public var recognizedWordCount: Int
    /// Which languages were used, as BCP-47 identifiers.
    public var languageIDs: [String]

    /// Creates a page status summary.
    public init(
        id: PageDescriptor.ID,
        pageLabel: String,
        pageIndex: Int,
        status: OCRPageStatus,
        confidence: Double? = nil,
        recognizedWordCount: Int = 0,
        languageIDs: [String] = []
    ) {
        self.id = id
        self.pageLabel = pageLabel
        self.pageIndex = pageIndex
        self.status = status
        self.confidence = confidence.map { min(1, max(0, $0)) }
        self.recognizedWordCount = recognizedWordCount
        self.languageIDs = languageIDs
    }

    /// How much of the page Zenit is prepared to stand behind.
    public var confidenceBand: OCRConfidenceBand? {
        confidence.map(OCRConfidenceBand.init(confidence:))
    }

    /// A localized VoiceOver label: page, status, confidence.
    public var accessibilityLabel: String {
        guard let band = confidenceBand, let confidence else {
            let format = NSLocalizedString(
                "Page %1$@, %2$@",
                comment: "VoiceOver label for a page's OCR status: page label, status"
            )
            return String(format: format, pageLabel, status.displayName)
        }
        let format = NSLocalizedString(
            "Page %1$@, %2$@, %3$@ confidence, %4$d percent",
            comment: "VoiceOver label for a read page: page label, status, confidence band, percentage"
        )
        return String(format: format, pageLabel, status.displayName, band.displayName, Int((confidence * 100).rounded()))
    }
}

/// A confidence band, so a number becomes a judgement a person can act on.
public enum OCRConfidenceBand: String, Hashable, Sendable, CaseIterable, Identifiable {

    /// Recognition was sure.
    case high
    /// Recognition was usable but worth checking.
    case medium
    /// Recognition was poor; read the page yourself.
    case low

    /// Bands a mean confidence falls into.
    public init(confidence: Double) {
        switch confidence {
        case 0.85...: self = .high
        case 0.60..<0.85: self = .medium
        default: self = .low
        }
    }

    /// Stable identity.
    public var id: String { rawValue }

    /// A localized band name.
    public var displayName: String {
        switch self {
        case .high: return NSLocalizedString("High", comment: "OCR confidence band")
        case .medium: return NSLocalizedString("Medium", comment: "OCR confidence band")
        case .low: return NSLocalizedString("Low", comment: "OCR confidence band")
        }
    }

    /// The design-system severity, so the band never rests on colour.
    public var displaySeverity: ZPDFSeverity {
        switch self {
        case .high: return .success
        case .medium: return .warning
        case .low: return .danger
        }
    }
}

/// What a finished recognition run found, for the sheet's closing line (L-20b).
///
/// The sheet used to say "Recognised words are searchable now" after every finished run —
/// including one where every page came back "No text found", so the person went looking for
/// words that were never read. The line now follows what the pages actually returned.
public enum OCRRunOutcome: Hashable, Sendable {

    /// At least one page could not be read (1.0.1). Checked first: whatever the other pages
    /// gave, the person has pages to read again.
    case pagesNotRead
    /// At least one page was read and gave words; they are searchable now.
    case wordsFound
    /// No page gave a word: those that were read found nothing legible.
    case noWordsFound
    /// Every page already carried real text, so none was read.
    case allPagesSkipped

    /// The outcome of a run's page results.
    public init(pageResults: [OCRPageStatusSummary]) {
        if pageResults.contains(where: { $0.status == .couldNotBeRead }) {
            self = .pagesNotRead
        } else if pageResults.contains(where: { $0.status == .indexed }) {
            self = .wordsFound
        } else if !pageResults.isEmpty, pageResults.allSatisfy({ $0.status == .skippedHasText }) {
            self = .allPagesSkipped
        } else {
            self = .noWordsFound
        }
    }

    /// The sentence the sheet shows when the run has finished.
    public var message: String {
        switch self {
        case .pagesNotRead:
            return NSLocalizedString(
                "Finished, but some pages could not be read, so search finds no new words on them. Start reading again to retry them.",
                comment: "OCR sheet: run finished, and one or more pages could not be read"
            )
        case .wordsFound:
            return NSLocalizedString(
                "Finished. Recognised words are searchable now, and are still a search aid rather than a transcription.",
                comment: "OCR sheet: run finished"
            )
        case .noWordsFound:
            return NSLocalizedString(
                "Finished. No words were found on the pages that were read, so nothing new is searchable.",
                comment: "OCR sheet: run finished, and no page gave a recognised word"
            )
        case .allPagesSkipped:
            return NSLocalizedString(
                "Finished. Every page already has real text, so none was read. Search finds their words through that text.",
                comment: "OCR sheet: run finished, and every page was skipped because it already has text"
            )
        }
    }

    /// The design-system severity, so the outcome is legible without colour.
    public var displaySeverity: ZPDFSeverity {
        switch self {
        case .pagesNotRead: return .warning
        case .wordsFound: return .success
        case .noWordsFound: return .warning
        case .allPagesSkipped: return .info
        }
    }
}

/// The statements Zenit always shows alongside recognised text.
///
/// These are not decoration. Recognised text is a *search aid*: it is good enough to find a room
/// number on a scan, and it is not good enough to be quoted in a contract. Saying so, every time,
/// is cheaper than the argument that follows from not saying it.
public enum OCRDisclosure {

    /// Where recognition runs.
    public static let localOnly = NSLocalizedString(
        "Text recognition runs on this Mac. No page and no recognised word is ever uploaded.",
        comment: "Standing note about OCR privacy"
    )

    /// What recognised text is for.
    public static let searchAidOnly = NSLocalizedString(
        "Recognised text is a search aid, not a certified transcription. Check the drawing itself before you rely on a word Zenit read for you.",
        comment: "Standing note about OCR accuracy"
    )
}
