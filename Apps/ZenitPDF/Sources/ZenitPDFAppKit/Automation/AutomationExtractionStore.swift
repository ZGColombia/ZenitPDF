import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFServiceWire
import ZPDFSnapEngine
import ZPDFVectorExtraction

/// One document's page geometry as the automation features read it: auto-trace, symbol
/// counting, title-block reading.
///
/// Two bugs this closes. The symbol schedule re-extracted the current page over XPC although
/// the canvas already held it, and it extracted with the document's *default* optional-content
/// state and no user layer filtering, so a layer the person had switched off still took part in
/// matching. Here every page is extracted **once** with hidden optional content included — so a
/// default-hidden layer the person turned on is present — and each feature filters by the
/// visibility actually in force when it runs. On a drawing without layers the canvas's own
/// extraction is equivalent, and it is used as is: no XPC at all.
@MainActor
final class AutomationExtractionStore {

    /// How a page's geometry is fetched. Injected so tests count requests and never touch the
    /// extraction service.
    typealias Fetcher = @Sendable (_ url: URL, _ pageIndex: Int, _ password: String?) async throws -> VectorPageExtraction

    /// The production fetcher: the geometry service, hidden optional content included.
    static let serviceFetcher: Fetcher = { url, pageIndex, password in
        try await GeometryExtraction.client.extractPageGeometry(
            documentAt: url,
            pageIndex: pageIndex,
            options: GeometryWireOptions(includesHiddenOptionalContent: true, password: password)
        )
    }

    /// Pages kept. A set-wide count walks pages in a window of two, so a handful is plenty;
    /// the store is a convenience over the service, never the only copy.
    static let capacity = 12

    private let fetcher: Fetcher
    private var entries: [Int: VectorPageExtraction] = [:]
    private var order: [Int] = []
    private var inFlight: [Int: Task<VectorPageExtraction, any Error>] = [:]

    /// How many times the fetcher was called. Test affordance for "no re-extraction".
    private(set) var fetchCount = 0

    /// The on-disk store for this drawing (NL-AUTO-15), set once the drawing's digest is known.
    /// Read before the fetcher, written after it.
    var persistent: PersistentExtractionStore?

    init(fetcher: @escaping Fetcher = AutomationExtractionStore.serviceFetcher) {
        self.fetcher = fetcher
    }

    /// Adopts an extraction the application already holds for `pageIndex`.
    ///
    /// Only when it is interchangeable with a layer-aware one: a drawing whose extraction left
    /// hidden optional content out must be fetched again, or a layer the person switched on
    /// would be missing from every automation.
    func adopt(_ extraction: VectorPageExtraction, pageIndex: Int, drawingHasLayers: Bool) {
        guard !drawingHasLayers, entries[pageIndex] == nil else { return }
        store(extraction, pageIndex: pageIndex)
    }

    /// The page's extraction, fetched at most once while it stays in the store.
    func extraction(url: URL, pageIndex: Int, password: String?) async throws -> VectorPageExtraction {
        if let hit = entries[pageIndex] {
            touch(pageIndex)
            return hit
        }
        if let pending = inFlight[pageIndex] { return try await pending.value }
        let fetcher = self.fetcher
        let persistent = self.persistent
        if let persistent,
           let stored = await Task.detached(priority: .userInitiated, operation: { persistent.load(pageIndex: pageIndex) }).value {
            store(stored, pageIndex: pageIndex)
            return stored
        }
        fetchCount += 1
        let task = Task {
            let extraction = try await fetcher(url, pageIndex, password)
            if let persistent {
                Task.detached(priority: .utility) { persistent.save(extraction, pageIndex: pageIndex) }
            }
            return extraction
        }
        inFlight[pageIndex] = task
        defer { inFlight[pageIndex] = nil }
        let extraction = try await task.value
        store(extraction, pageIndex: pageIndex)
        return extraction
    }

    /// The cached extraction, without fetching.
    func cached(pageIndex: Int) -> VectorPageExtraction? { entries[pageIndex] }

    /// Everything dropped — the drawing changed under the store.
    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    private func store(_ extraction: VectorPageExtraction, pageIndex: Int) {
        entries[pageIndex] = extraction
        touch(pageIndex)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
    }

    private func touch(_ pageIndex: Int) {
        order.removeAll { $0 == pageIndex }
        order.append(pageIndex)
    }
}

/// Everything automation keeps per document. One stored property on the document, so the big
/// shared document file carries one line for automation.
@MainActor
final class DocumentAutomationState {
    let extractions: AutomationExtractionStore
    /// The trace choices the person made for this document (NL-AUTO-11). View state, like
    /// layer visibility: never persisted, never marks the document edited.
    var traceChoices = TraceFilter.none
    /// Sheets whose scale proposal was already considered this session (bug
    /// `ZenitPDFProjectDocument.swift:1118`), so an offer is made once per sheet.
    var scaleProposalConsideredPages: Set<UUID> = []

    /// Islands a traced area enclosed, offered as cutouts and waiting for the person (NL-AUTO-10).
    struct IslandOffer {
        let parent: MarkupID
        let pageID: PageID
        let islands: [[PDFPoint]]
    }
    var pendingIslandOffers: [UUID: IslandOffer] = [:]
    /// Subjects read inside traced areas, offered and waiting (NL-AUTO-21).
    var pendingSubjectOffers: [UUID: (markup: MarkupID, subject: String)] = [:]
    /// Project Zones a traced area's drawing layer names, offered and waiting (NL-AUTO-21, r2).
    var pendingZoneOffers: [UUID: (markup: MarkupID, zone: ZoneID)] = [:]
    /// The Takeoff Assistant's inbox (NL-AUTO-16, r2), kept in the project once attached.
    let inbox = AutomationInbox()
    /// Whether Prepare This Set is running on this drawing (L-75), so a second run waits its turn.
    var isPreparingSet = false
    var inboxAttached = false
    var inboxPackageIdentity: ObjectIdentifier?

    init(extractions: AutomationExtractionStore = AutomationExtractionStore()) {
        self.extractions = extractions
    }

    /// Gives the extraction store its on-disk half once the drawing's digest is known.
    func attachPersistentStore(digest: String) {
        guard extractions.persistent?.documentDigest != digest else { return }
        extractions.persistent = PersistentExtractionStore(documentDigest: digest, root: PersistentExtractionStore.defaultRoot)
    }
}
