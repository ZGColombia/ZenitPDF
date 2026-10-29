import Foundation
import Observation
import ZPDFUIPresentation

/// Which pages a recognition run should cover.
public enum OCRPageRangeSelection: Hashable, Sendable {

    /// Only the page on screen.
    case currentPage
    /// Every page in the document.
    case allPages
    /// A contiguous run of pages, one-based and inclusive.
    case range(lowerBound: Int, upperBound: Int)
    /// A typed list such as `"1-4, 7, 12-14"`.
    case custom(String)

    /// A localized name for the range picker.
    public var displayName: String {
        switch self {
        case .currentPage: return NSLocalizedString("This page", comment: "OCR page range choice")
        case .allPages: return NSLocalizedString("All pages", comment: "OCR page range choice")
        case .range: return NSLocalizedString("Page range", comment: "OCR page range choice")
        case .custom: return NSLocalizedString("Specific pages", comment: "OCR page range choice")
        }
    }

    /// Resolves to zero-based page indices inside a document of `pageCount` pages.
    ///
    /// Anything out of range is dropped rather than clamped, so a typo cannot silently read a
    /// page the person did not ask for (CR-185). A range and a typed list are read by
    /// ``PageRangeParser``, the one page-list grammar every sheet shares: this type kept its own
    /// copy until R-140, and the copy had drifted — `3-` and `-3` read as page 3, and a single
    /// page in a document of no pages trapped on `1...0`.
    public func resolvedIndices(pageCount: Int, currentPageIndex: Int) -> IndexSet {
        guard pageCount > 0 else { return IndexSet() }
        switch self {
        case .currentPage:
            guard (0..<pageCount).contains(currentPageIndex) else { return IndexSet() }
            return IndexSet(integer: currentPageIndex)
        case .allPages:
            return IndexSet(0..<pageCount)
        case let .range(lower, upper):
            return PageRangeParser.indices(from: lower, to: upper, pageCount: pageCount)
        case let .custom(text):
            return PageRangeParser.indices(in: text, pageCount: pageCount)
        }
    }
}

/// A language recognition should look for.
public struct OCRLanguage: Hashable, Sendable, Identifiable {

    /// BCP-47 identifier, for example `"sv-SE"`.
    public let id: String

    /// Creates a language.
    public init(id: String) {
        self.id = id
    }

    /// The language's name in the person's own locale, falling back to the identifier.
    public var displayName: String {
        Self.displayName(forIdentifier: id, in: .current)
    }

    /// A language name for a recognition identifier: the full name ("Swedish (Sweden)"), else
    /// the language alone ("Vietnamese"), else the identifier itself.
    ///
    /// The middle step is L-27. Recognition reports Vietnamese as `vi-VT`, whose region is not
    /// a region, so the locale has no name for the whole identifier and the sheet listed the
    /// raw code. The language part still has a name, and the person picks a language, not a
    /// region.
    public static func displayName(forIdentifier id: String, in locale: Locale) -> String {
        if let full = locale.localizedString(forIdentifier: id), !full.isEmpty, full != id {
            return full
        }
        if let code = Locale.Language(identifier: id).languageCode?.identifier,
           let language = locale.localizedString(forLanguageCode: code), !language.isEmpty, language != code {
            return language
        }
        return id
    }

    /// The languages Zenit offers by default. The host may hand it a different list once the
    /// recognition engine reports what this Mac actually supports.
    public static let commonLanguages: [OCRLanguage] = [
        "en-US", "sv-SE", "nb-NO", "da-DK", "fi-FI",
        "de-DE", "nl-NL", "fr-FR", "es-ES", "it-IT", "pt-PT", "pl-PL"
    ].map(OCRLanguage.init(id:))
}

/// What the host is asked to run.
public struct OCRRunRequest: Hashable, Sendable {

    /// Pages to read, in document order.
    public var pageIDs: [PageDescriptor.ID]
    /// Languages to look for, in priority order.
    public var languageIDs: [String]
    /// Whether pages that already carry real text should be skipped.
    public var skipsPagesWithText: Bool

    /// Creates a run request.
    public init(pageIDs: [PageDescriptor.ID], languageIDs: [String], skipsPagesWithText: Bool) {
        self.pageIDs = pageIDs
        self.languageIDs = languageIDs
        self.skipsPagesWithText = skipsPagesWithText
    }
}

/// Where a recognition run stands.
public enum OCRRunPhase: Hashable, Sendable {

    /// Nothing has been started.
    case idle
    /// Pages are being read.
    case running
    /// Cancel was pressed and the current page is being finished off.
    case cancelling
    /// Every requested page was read.
    case finished
    /// The run stopped early because the person asked it to.
    case cancelled
    /// The run could not continue.
    case failed(ZPDFUserFacingError)

    /// Whether a Cancel button should be offered.
    public var isCancellable: Bool { self == .running }

    /// Whether the Start button should be offered.
    public var canStart: Bool {
        switch self {
        case .idle, .finished, .cancelled, .failed: return true
        case .running, .cancelling: return false
        }
    }
}

/// Drives the recognition sheet: what to read, how far it has got, and how well it went.
///
/// The model never recognises anything itself. It describes a request, hands it to the host
/// through ``onStart``, and collects per-page results as the host reports them. That keeps the
/// Vision work off the main actor and keeps this type testable without an engine.
@MainActor
@Observable
public final class OCRRunModel {

    /// The pages available to read.
    public private(set) var pages: [PageDescriptor]
    /// Zero-based index of the page on screen.
    public var currentPageIndex: Int
    /// Which pages to read.
    public var rangeSelection: OCRPageRangeSelection = .allPages
    /// The text behind ``OCRPageRangeSelection/custom(_:)``.
    public var customRangeText: String = ""
    /// Bounds behind ``OCRPageRangeSelection/range(lowerBound:upperBound:)``.
    public var rangeLowerBound: Int = 1
    /// Bounds behind ``OCRPageRangeSelection/range(lowerBound:upperBound:)``.
    public var rangeUpperBound: Int = 1
    /// The languages offered.
    public private(set) var availableLanguages: [OCRLanguage]
    /// The languages chosen, in priority order.
    public var selectedLanguageIDs: [String]
    /// Whether pages that already carry embedded text are skipped.
    public var skipsPagesWithText: Bool = true

    /// Where the run stands.
    public private(set) var phase: OCRRunPhase = .idle
    /// What each page came back with, in document order.
    public private(set) var pageResults: [OCRPageStatusSummary] = []

    /// Runs when the person presses Start.
    public var onStart: (@MainActor (OCRRunRequest) -> Void)?
    /// Runs when the person presses Cancel.
    public var onCancel: (@MainActor () -> Void)?

    /// Runs when the person asks the run to continue with the sheet closed (IM-152). `nil`
    /// when the host cannot show progress anywhere else, and the sheet then offers no such
    /// button rather than one that does nothing.
    public var onContinueInBackground: (@MainActor () -> Void)?
    /// Whether the run was sent to the background and the sheet closed without cancelling it.
    public private(set) var isInBackground = false
    /// When the run in flight started, for the time-left estimate.
    private(set) var runStartedAt: Date?
    /// The clock, injectable so the estimate is testable.
    var now: @MainActor () -> Date = { Date() }

    /// Creates the model.
    ///
    /// - Parameters:
    ///   - selectedLanguageIDs: the languages to start with — the host passes the last run's
    ///     choice. When `nil`, the person's own preferred languages that recognition offers are
    ///     chosen, in their order, falling back to US English (IM-149).
    ///   - preferredLanguages: the person's languages, as BCP-47 identifiers.
    public init(
        pages: [PageDescriptor],
        currentPageIndex: Int = 0,
        availableLanguages: [OCRLanguage] = OCRLanguage.commonLanguages,
        selectedLanguageIDs: [String]? = nil,
        existingResults: [OCRPageStatusSummary] = [],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.pages = pages
        self.currentPageIndex = currentPageIndex
        self.availableLanguages = availableLanguages
        self.selectedLanguageIDs = selectedLanguageIDs
            ?? Self.defaultLanguageIDs(available: availableLanguages, preferred: preferredLanguages)
        self.pageResults = existingResults.sorted { $0.pageIndex < $1.pageIndex }
        self.rangeUpperBound = max(1, pages.count)
    }

    /// The person's preferred languages that recognition offers, matched on the full
    /// identifier first and then on the language code, in preference order; US English (or the
    /// first offered language) when none match.
    ///
    /// Everybody used to start on the first offered language, so a Swedish estimator had to
    /// find sv-SE in the grid on every run. IM-149.
    public static func defaultLanguageIDs(available: [OCRLanguage], preferred: [String]) -> [String] {
        func code(_ id: String) -> String {
            String(id.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
        }
        var chosen: [String] = []
        for identifier in preferred {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            let match = available.first { $0.id.caseInsensitiveCompare(normalized) == .orderedSame }
                ?? available.first { code($0.id) == code(normalized) }
            if let match, !chosen.contains(match.id) { chosen.append(match.id) }
        }
        if !chosen.isEmpty { return chosen }
        if available.contains(where: { $0.id == "en-US" }) { return ["en-US"] }
        return [available.first?.id].compactMap { $0 }
    }

    // MARK: - Derived state

    /// The zero-based page indices the current selection resolves to.
    public var resolvedPageIndices: IndexSet {
        effectiveSelection.resolvedIndices(pageCount: pages.count, currentPageIndex: currentPageIndex)
    }

    /// The pages the current selection resolves to, in document order.
    public var resolvedPages: [PageDescriptor] {
        resolvedPageIndices.compactMap { index in
            pages.indices.contains(index) ? pages[index] : nil
        }
    }

    /// A localized description of what will be read, for the sheet and for VoiceOver.
    public var rangeSummary: String {
        let count = resolvedPageIndices.count
        guard count > 0 else {
            return NSLocalizedString(
                "No pages selected",
                comment: "OCR range summary when the selection resolves to nothing"
            )
        }
        // V-068: "1 of 1 page", not "1 of 1 pages".
        let format = NSLocalizedString(
            "%1$lld of %2$@",
            comment: "OCR range summary: selected page count, the total as '12 pages'"
        )
        return String(format: format, count, WorkflowPlurals.pages(pages.count))
    }

    /// How many pages the run in flight was started with, or `nil` when nothing is running.
    ///
    /// The denominator has to be the number of pages the run was *asked* for, fixed at the
    /// moment Start was pressed. Recomputing it from the live selection meant that widening the
    /// scope mid-run collapsed the bar and narrowing it completed the bar over a run that was
    /// still going. Finding CR-181.
    public private(set) var requestedPageCount: Int?

    /// How many of the requested pages have come back, `0...1`.
    public var progressFraction: Double {
        let total = requestedPageCount ?? resolvedPageIndices.count
        guard total > 0 else { return 0 }
        return min(1, Double(completedPageCount) / Double(total))
    }

    /// How many requested pages the run is finished with, skipped pages included.
    public var completedPageCount: Int {
        pageResults.reduce(0) { $0 + ($1.status.isDone ? 1 : 0) }
    }

    /// Pages skipped because they already carry text (IM-150).
    public var pagesSkippedForText: [OCRPageStatusSummary] {
        pageResults.filter { $0.status == .skippedHasText }
    }

    /// The typed page-list fragments that name no page in the document (IM-148).
    public var rejectedRangeFragments: [String] {
        guard case .custom = rangeSelection else { return [] }
        return PageRangeParser.rejectedFragments(in: customRangeText, pageCount: pages.count)
    }

    /// "Page 12 of 40 · about 2 min left", from the time per completed page so far, or `nil`
    /// before anything has come back (IM-152).
    public var progressEstimate: String? {
        guard let total = requestedPageCount, total > 0, let runStartedAt else { return nil }
        let done = completedPageCount
        guard done > 0 else { return nil }
        let current = min(total, done + 1)
        let elapsed = now().timeIntervalSince(runStartedAt)
        let remaining = max(0, elapsed / Double(done) * Double(total - done))
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = remaining >= 60 ? [.hour, .minute] : [.second]
        let left = formatter.string(from: remaining.rounded(.up)) ?? ""
        return String(
            format: NSLocalizedString(
                "Page %1$d of %2$d · about %3$@ left",
                comment: "OCR progress estimate. 1: current page, 2: requested pages, 3: time left"
            ),
            current, total, left
        )
    }

    /// Whether the sheet's scope controls should be locked.
    ///
    /// They are, for as long as anything is in flight. A control that changes what a running
    /// batch is doing — or, worse, only changes what the progress bar claims it is doing — is
    /// not a control the person can use truthfully.
    public var isScopeEditable: Bool { phase.canStart }

    /// The page being read right now, or `nil`.
    public var pageBeingRead: OCRPageStatusSummary? {
        pageResults.first { $0.status == .indexing }
    }

    /// Mean confidence across every page that produced text, or `nil`.
    public var averageConfidence: Double? {
        let values = pageResults.compactMap(\.confidence)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// How many read pages fall into each confidence band.
    public var confidenceBandCounts: [OCRConfidenceBand: Int] {
        var counts: [OCRConfidenceBand: Int] = [:]
        for result in pageResults {
            guard let band = result.confidenceBand else { continue }
            counts[band, default: 0] += 1
        }
        return counts
    }

    /// Pages that were read and produced nothing, worth showing separately.
    public var pagesWithoutText: [OCRPageStatusSummary] {
        pageResults.filter { $0.status == .noTextFound }
    }

    /// What the pages of the last run returned, for the sheet's "Finished" line (L-20b).
    public var finishedOutcome: OCRRunOutcome {
        OCRRunOutcome(pageResults: pageResults)
    }

    /// Whether Start should be offered.
    public var canStart: Bool {
        phase.canStart && !resolvedPageIndices.isEmpty && !selectedLanguageIDs.isEmpty
    }

    // MARK: - Actions

    /// Builds the request and hands it to the host.
    public func start() {
        guard canStart else { return }
        let requestedPages = resolvedPages
        pageResults = requestedPages.map {
            OCRPageStatusSummary(
                id: $0.id,
                pageLabel: $0.label,
                pageIndex: $0.index,
                status: .notIndexed
            )
        }
        requestedPageCount = requestedPages.count
        runStartedAt = now()
        isInBackground = false
        phase = .running
        onStart?(OCRRunRequest(
            pageIDs: requestedPages.map(\.id),
            languageIDs: selectedLanguageIDs,
            skipsPagesWithText: skipsPagesWithText
        ))
    }

    /// Asks the host to stop. The page in flight is allowed to finish so its partial result is
    /// not left half-written.
    public func cancel() {
        guard phase == .running else { return }
        phase = .cancelling
        onCancel?()
    }

    /// Lets the run go on with the sheet closed. Only offered when the host installed
    /// ``onContinueInBackground``; nothing is cancelled (IM-152).
    public func continueInBackground() {
        guard phase == .running, let onContinueInBackground else { return }
        isInBackground = true
        onContinueInBackground()
    }

    /// Records what one page came back with.
    ///
    /// The results stay sorted by page, and a new one is inserted at its place by binary
    /// search instead of appending and re-sorting the whole list for every page reported —
    /// on a 500-page run that re-sort ran 500 times on the main actor. IM-151.
    public func record(_ summary: OCRPageStatusSummary) {
        var low = 0
        var high = pageResults.count
        while low < high {
            let mid = (low + high) / 2
            if pageResults[mid].pageIndex < summary.pageIndex { low = mid + 1 } else { high = mid }
        }
        var probe = low
        while probe < pageResults.count, pageResults[probe].pageIndex == summary.pageIndex {
            if pageResults[probe].id == summary.id {
                pageResults[probe] = summary
                return
            }
            probe += 1
        }
        if let index = pageResults.firstIndex(where: { $0.id == summary.id }) {
            // Reported again under a different position: move it.
            pageResults.remove(at: index)
            record(summary)
            return
        }
        pageResults.insert(summary, at: low)
    }

    /// Marks the run as finished, or as cancelled when Cancel had already been pressed.
    public func finish() {
        phase = (phase == .cancelling) ? .cancelled : .finished
        requestedPageCount = nil
        runStartedAt = nil
        for index in pageResults.indices where pageResults[index].status == .indexing {
            pageResults[index].status = .notIndexed
        }
    }

    /// Stops the run with a failure the person can act on.
    public func fail(_ error: ZPDFUserFacingError) {
        phase = .failed(error)
        requestedPageCount = nil
        for index in pageResults.indices where pageResults[index].status == .indexing {
            pageResults[index].status = .notIndexed
        }
    }

    /// Puts the sheet back to its starting state, keeping what was already read.
    public func reset() {
        phase = .idle
        requestedPageCount = nil
    }

    // MARK: - Private

    private var effectiveSelection: OCRPageRangeSelection {
        switch rangeSelection {
        case .custom:
            return .custom(customRangeText)
        case .range:
            return .range(lowerBound: rangeLowerBound, upperBound: rangeUpperBound)
        default:
            return rangeSelection
        }
    }
}
