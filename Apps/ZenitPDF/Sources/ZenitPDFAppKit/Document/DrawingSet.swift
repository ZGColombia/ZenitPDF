import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// Every drawing of an open project, and which one each page comes from (NL-DOCS-04,
/// ADR-0027 (documents)).
///
/// A project is one set of pages drawn from one or more PDFs. A page keeps its index in its own
/// PDF (ADR-0022), so a page index alone no longer names a picture: the canvas, thumbnails, text,
/// links and vector extraction resolve a page's drawing here, through the page's identity.
/// The first member is the drawing the project was created from; the document's `drawing`
/// property is still that one, so single-drawing code is unchanged.
@MainActor
final class DrawingSet {

    struct Member {
        let drawing: LoadedDrawing
        /// The package's `document.id`, once known; `nil` in Quick PDF Mode.
        var row: String?
        /// The password that unlocked this drawing, memory only (BH-069).
        let password: String?
        let displayName: String
    }

    private(set) var members: [Member]
    /// Page identity → the drawing it comes from.
    private var pageDrawing: [UUID: DocumentID] = [:]
    /// The rows each package this set was written into holds for its drawings, so a Save As
    /// adds the drawings to the new package once and later saves find them.
    var rowsByPackage: [ObjectIdentifier: [DocumentID: String]] = [:]
    /// Automation's page geometry per added drawing; the primary drawing uses the document's.
    var extractionStores: [DocumentID: AutomationExtractionStore] = [:]
    /// Each added drawing's own text index (NL-DOCS-04): a page index is a key within one PDF.
    var searchIndexes: [DocumentID: DocumentSearchIndex] = [:]
    /// Each added drawing's index open still under way — its index, or `nil` when it failed — so
    /// the batch sheet's search scope waits for it rather than leaving the drawing out (V-040).
    var searchIndexOpenings: [DocumentID: Task<DocumentSearchIndex?, Never>] = [:]
    /// The added drawings as search sources of this project's Search panel.
    var searchSources: [ZPDFUIPresentation.ProjectSearchSource] = []

    init(primary: Member) {
        members = [primary]
        register(pages: primary.drawing.pages)
    }

    /// The drawing the project was created from.
    var primary: Member { members[0] }

    /// Whether the project holds more than one drawing.
    var isMultiDrawing: Bool { members.count > 1 }

    /// Adds a drawing and its pages.
    func add(_ member: Member) {
        members.append(member)
        register(pages: member.drawing.pages)
    }

    /// Records which drawing each page comes from.
    func register(pages: [ZPDFContracts.PageDescriptor]) {
        for page in pages { pageDrawing[page.id.rawValue] = page.documentID }
    }

    /// Sets the package rows, keyed by drawing.
    func setRows(_ rows: [DocumentID: String]) {
        for index in members.indices {
            if let row = rows[members[index].drawing.documentID] { members[index].row = row }
        }
    }

    /// Every drawing's package row, keyed by drawing. Complete only when every member has one.
    var rows: [DocumentID: String] {
        var result: [DocumentID: String] = [:]
        for member in members { if let row = member.row { result[member.drawing.documentID] = row } }
        return result
    }

    func member(for documentID: DocumentID) -> Member? {
        members.first { $0.drawing.documentID == documentID }
    }

    /// The member a page comes from; the primary drawing for a page it does not know.
    func member(forPage pageID: UUID) -> Member {
        pageDrawing[pageID].flatMap(member(for:)) ?? primary
    }

    /// The drawing a page comes from.
    func drawing(forPage pageID: UUID) -> LoadedDrawing { member(forPage: pageID).drawing }

    /// The raster source for a page.
    func rasterSource(forPage pageID: UUID) -> PageRasterSource { drawing(forPage: pageID).rasterSource }

    /// A number naming one page's picture across the whole set, for the canvas's raster caches:
    /// the page's own PDF index on the primary drawing — so a single-drawing project keys
    /// exactly as before — and the index offset by the drawing's place in the set otherwise.
    func rasterKey(forPage pageID: UUID, index: Int) -> Int {
        guard let documentID = pageDrawing[pageID],
              let ordinal = members.firstIndex(where: { $0.drawing.documentID == documentID }),
              ordinal > 0 else { return index }
        return ordinal << 24 | index
    }

    /// Closes every drawing but the primary one, which the document closes itself.
    func closeAdded() async {
        for member in members.dropFirst() { await member.drawing.rasterSource.close() }
        let indexes = searchIndexes.values
        searchIndexes = [:]
        searchIndexOpenings = [:]
        searchSources = []
        for index in indexes { await index.shutDown() }
    }
}
