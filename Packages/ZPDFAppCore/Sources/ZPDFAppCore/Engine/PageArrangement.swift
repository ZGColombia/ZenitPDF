import Foundation
import ZPDFContracts

/// How one sheet is shown, as data over an immutable page (NL-DOCS-07 rotation, NL-DOCS-16
/// crop). Display only: a measurement lives in page space, which neither changes, so every
/// quantity is untouched by construction. Persisted in `page_set_entry` (`view_rotation`,
/// `crop_json`).
public struct PageViewSettings: Codable, Hashable, Sendable {

    /// Degrees clockwise added to the page's own `/Rotate` on screen: 0, 90, 180 or 270.
    public var rotation: Int
    /// The part of the page the view shows, in page space; `nil` shows the whole crop box.
    public var crop: PDFRect?

    public init(rotation: Int = 0, crop: PDFRect? = nil) {
        self.rotation = PageViewSettings.normalised(rotation)
        self.crop = crop
    }

    /// Whether these settings change nothing, so the page needs no entry.
    public var isIdentity: Bool { rotation == 0 && crop == nil }

    /// `degrees` brought to 0, 90, 180 or 270; anything not a quarter turn rounds to one.
    public static func normalised(_ degrees: Int) -> Int {
        let quarter = Int((Double(degrees) / 90).rounded())
        return ((quarter % 4) + 4) % 4 * 90
    }

    /// The crop as the JSON `page_set_entry.crop_json` stores.
    public var cropJSON: String? {
        guard let crop else { return nil }
        let box = crop.standardized
        return "{\"x\":\(box.origin.x),\"y\":\(box.origin.y),\"width\":\(box.size.width),\"height\":\(box.size.height)}"
    }

    /// A crop read back from `crop_json`; `nil` for a missing, malformed or empty rectangle.
    public static func crop(fromJSON json: String?) -> PDFRect? {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = object["x"], let y = object["y"],
              let width = object["width"], let height = object["height"],
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return PDFRect(origin: PDFPoint(x: x, y: y), size: PDFSize(width: width, height: height))
    }
}

/// Page arrangement in the session: pages added from another drawing (NL-DOCS-04), sheets
/// removed from the set and put back (NL-DOCS-07), and each sheet's view (NL-DOCS-07/16).
///
/// A page removed from the set is **kept**: its descriptor stays in the session's known
/// pages and its markups are set aside — out of the canvas and the ledger, still saved — so
/// putting it back, by ⌘Z or by Restore, brings everything back exactly.
extension TakeoffSession {

    /// Every sheet's view, keyed by page. Pages with an identity view have no entry.
    public var pageViews: [PageID: PageViewSettings] { pageViewTable }

    /// The view of one sheet.
    public func pageView(of page: PageID) -> PageViewSettings { pageViewTable[page] ?? PageViewSettings() }

    /// The pages removed from the set, in the order they were held.
    public var excludedPageDescriptors: [ZPDFContracts.PageDescriptor] {
        let live = Set(pageOrderIDs)
        return knownPageOrder.compactMap { id in live.contains(id) ? nil : knownPages[id] }
    }

    /// The drawing a page comes from; the session's own for a page it does not know.
    public func drawing(ofPage page: PageID) -> DocumentID {
        knownPages[page]?.documentID ?? documentID
    }

    /// Installs a stored arrangement after an open: the pages removed from the set and each
    /// sheet's view. No undo step: this is the file, not an edit. Call after ``hydrate`` so the
    /// removed pages' scales and markups were read and are now set aside with them.
    public func restoreArrangement(excluded: Set<PageID>, views: [PageID: PageViewSettings]) {
        let known = Set(knownPages.keys)
        pageViewTable = views.filter { known.contains($0.key) && !$0.value.isIdentity }
        let remaining = pageOrderIDs.filter { !excluded.contains($0) }
        // A set with every page removed shows them all rather than nothing.
        guard !remaining.isEmpty, remaining.count != pageOrderIDs.count else { return }
        replacePageOrder(remaining)
    }

    /// Holds pages of a drawing just attached to the project outside the set (NL-DOCS-04/12):
    /// known, saved as removed from the set, ready for ``DocumentCommand/insertPages(_:at:)``.
    /// No undo step: attaching a file is not an edit of the set.
    public func holdPagesOutsideSet(_ held: [ZPDFContracts.PageDescriptor]) {
        let live = Set(pageOrderIDs)
        for page in held where !live.contains(page.id) { rememberPage(page) }
    }

    func applyInsertPages(
        _ inserted: [ZPDFContracts.PageDescriptor],
        at position: Int,
        command: DocumentCommand
    ) throws -> DocumentCommandOutcome {
        let live = Set(pageOrderIDs)
        guard !inserted.isEmpty else { throw DocumentCommandError.measurementFailed("no pages to insert") }
        for page in inserted where live.contains(page.id) {
            // Words, not the page's identifier: the detail reaches the tray (L-102).
            throw DocumentCommandError.measurementFailed(NSLocalizedString(
                "That sheet is already in the set.",
                comment: "Refusal sentence: inserting a sheet that is already in the drawing set"
            ))
        }
        guard position >= 0, position <= live.count else { throw DocumentCommandError.pageIndexOutOfRange(position) }
        var inverse = DocumentCommandInverse(pageOrder: pageOrderIDs)
        for page in inserted { rememberPage(page) }
        var order = pageOrderIDs
        order.insert(contentsOf: inserted.map(\.id), at: position)
        inverse.recordUnfiledOnReturn(replacePageOrder(order))
        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: [],
            changedPageIDs: Set(pageOrderIDs)
        )
    }

    func applySetPagesExcluded(
        _ pages: [PageID],
        excluded: Bool,
        command: DocumentCommand
    ) throws -> DocumentCommandOutcome {
        for page in pages where knownPages[page] == nil { throw DocumentCommandError.unknownPage(page) }
        let wanted = Set(pages)
        var order = pageOrderIDs
        if excluded {
            order.removeAll { wanted.contains($0) }
            // A set cannot be emptied: there would be no sheet left to show.
            guard !order.isEmpty else {
                throw DocumentCommandError.measurementFailed("the last sheet cannot be removed from the set")
            }
        } else {
            // Restored sheets come back where they were among the known pages.
            let current = Set(order)
            let restoring = knownPageOrder.filter { wanted.contains($0) && !current.contains($0) }
            for page in restoring {
                let knownIndex = knownPageOrder.firstIndex(of: page) ?? knownPageOrder.count
                let before = knownPageOrder[..<knownIndex]
                let anchor = order.lastIndex { before.contains($0) }
                order.insert(page, at: anchor.map { $0 + 1 } ?? 0)
            }
        }
        guard order != pageOrderIDs else {
            return DocumentCommandOutcome(command: command, inverse: .empty, forward: .empty, changedMarkupIDs: [], changedPageIDs: [])
        }
        var inverse = DocumentCommandInverse(pageOrder: pageOrderIDs)
        inverse.recordUnfiledOnReturn(replacePageOrder(order))
        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: [],
            changedPageIDs: wanted
        )
    }

    func applySetPageViews(
        _ requested: [PageID: PageViewSettings?],
        command: DocumentCommand
    ) throws -> DocumentCommandOutcome {
        for page in requested.keys where knownPages[page] == nil { throw DocumentCommandError.unknownPage(page) }
        var previous: [PageID: PageViewSettings?] = [:]
        var changed: Set<PageID> = []
        for (page, view) in requested {
            let existing = pageViewTable[page]
            let next = (view?.isIdentity ?? true) ? nil : view
            guard next != existing else { continue }
            previous.updateValue(existing, forKey: page)
            pageViewTable[page] = next
            changed.insert(page)
        }
        var inverse = DocumentCommandInverse()
        inverse.pageViews = previous.isEmpty ? nil : previous
        return DocumentCommandOutcome(
            command: command,
            inverse: inverse,
            forward: .empty,
            changedMarkupIDs: [],
            changedPageIDs: changed
        )
    }
}
