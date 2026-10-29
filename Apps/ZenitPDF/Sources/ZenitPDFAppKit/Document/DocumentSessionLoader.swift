import CoreGraphics
import Foundation
import ZPDFUIShell
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFServiceClient
import ZPDFServiceWire
import ZPDFSnapEngine
import ZPDFVectorExtraction

/// The one geometry-extraction door the app uses (S15).
///
/// `automatic()` connects to `GeometryService.xpc` when the running bundle embeds it —
/// the assembled app — and falls back to the identical in-process extractor under
/// `swift run`/`swift test`, where no `.xpc` bundle can launch. A crash of the service
/// mid-extraction is retried once against the relaunched service before the error
/// reaches the caller, so a hostile drawing kills a worker process, never the app.
enum GeometryExtraction {
    static let client = ZPDFGeometryServiceClient.automatic()
}

/// One opened drawing: the pages the engine measures against, and the source the canvas draws.
public struct LoadedDrawing: Sendable {
    /// Identity every markup on this drawing is stamped with.
    public let documentID: DocumentID
    /// Page geometry, read out of the file by PDFKit behind the exception barrier.
    public let pages: [ZPDFContracts.PageDescriptor]
    /// The rasteriser the canvas pulls page images from.
    public let rasterSource: PageRasterSource
    /// SHA-256 of the file as opened. Goes into the project manifest verbatim.
    public let digest: FileDigest
    /// Where the bytes came from.
    public let url: URL
}

/// Turns a PDF on disk into an engine session.
///
/// The whole path runs off the main actor. `NSDocument.read(from:ofType:)` is synchronous and runs
/// on the main thread, so nothing here is called from it: the document records the URL and this
/// loader runs afterwards, which is why a 400-page set does not freeze the window it is opening
/// into.
public enum DocumentSessionLoader {

    /// Opens a PDF and reads its page geometry.
    ///
    /// - Parameter password: the password for an encrypted drawing, when the person has
    ///   given one (LT-38). Without it an encrypted drawing loads in its locked state,
    ///   which the caller must check through `LoadedDrawing.rasterSource.isLocked`.
    public static func load(
        pdfAt url: URL,
        documentID: DocumentID = DocumentID(UUID()),
        password: String? = nil,
        knownDigest: FileDigest? = nil
    ) async throws -> LoadedDrawing {
        let (source, descriptors) = try await PageRasterSource.open(
            url: url, password: password, knownDigest: knownDigest
        )
        // BH-068: the bridge's page descriptor carries no user unit, so it is read from the page
        // dictionaries — by the one reader `zenit` uses too (X-051).
        let userUnits = PageUserUnits.read(at: url, password: password)
        let pages = try descriptors.map {
            try contractPage(from: $0, documentID: documentID, userUnit: userUnits[$0.index] ?? 1)
        }
        return LoadedDrawing(
            documentID: documentID,
            pages: pages,
            rasterSource: source,
            digest: await source.digest,
            url: url
        )
    }

    /// Maps a PDFKit page descriptor onto the frozen contract type.
    ///
    /// The two are deliberately different types — `ZPDFPDFKitBridge` knows nothing about
    /// `ZPDFContracts` — so this mapping is the seam, and it is here rather than in either package.
    public static func contractPage(
        from descriptor: PDFPageDescriptor,
        documentID: DocumentID,
        id: PageID = PageID(UUID()),
        userUnit: Double = 1
    ) throws -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: id,
            documentID: documentID,
            index: descriptor.index,
            label: descriptor.label,
            boxes: ZPDFContracts.PageBoxes(
                media: rect(descriptor.boxes.media),
                crop: rect(descriptor.boxes.crop)
            ),
            rotation: try PageRotation.normalizing(degrees: descriptor.rotation),
            userUnit: PageUserUnits.sanitised(userUnit)
        )
    }

    /// The drawing's outline (bookmark) titles, keyed by zero-based page index — the sheet
    /// names the Navigator's page cards show ("A1.01 - Floor Plan").
    ///
    /// Read with CoreGraphics, the parser `PageUserUnits` uses. A drawing with no outline, a
    /// locked drawing, or an entry that points at a URL rather than a page gives no title for
    /// that page; the card then falls back to the page's own label.
    static func readOutlineTitles(at url: URL, password: String?) -> [Int: String] {
        guard let document = CGPDFDocument(url as CFURL) else { return [:] }
        if document.isEncrypted, !document.isUnlocked, let password {
            _ = document.unlockWithPassword(password)
        }
        guard !document.isEncrypted || document.isUnlocked,
              let outline = document.outline as? [String: Any] else { return [:] }
        return outlineTitles(from: outline, pageCount: document.numberOfPages)
    }

    /// Walks a CoreGraphics outline dictionary (`Title`, `Destination` as a 1-based page
    /// number, `Children`) into titles by zero-based page index.
    ///
    /// When several entries point at one page, the **shallowest entry that is not a grouping
    /// node** wins. A grouping node is one with a descendant pointing at another page: a set's
    /// outline typically reads "Architectural" → "A1.01 - Floor Plan", both pointing at the first
    /// sheet, and "Architectural" also holds sheets 2..n, so it is a section, not a name. A sheet
    /// entry "A-101 Floor Plan" whose children are its own details ("Detail 3", same page) is not
    /// a grouping node, so the sheet keeps its name rather than taking the last detail's
    /// (the old rule, "the deepest wins", named it after a detail).
    /// A page reached only by grouping nodes takes the deepest of them. Ties keep the first in
    /// reading order. Bounded in depth and entry count so a hostile outline cannot run the open
    /// away.
    static func outlineTitles(from outline: [String: Any], pageCount: Int) -> [Int: String] {
        struct Candidate { var depth: Int; var title: String; var grouping: Bool }
        var candidates: [Int: [Candidate]] = [:]
        var visited = 0
        /// Returns the set of pages the subtree points at (its own destination included).
        @discardableResult
        func walk(_ node: [String: Any], depth: Int) -> Set<Int> {
            guard depth <= 32, visited < 20_000 else { return [] }
            visited += 1
            var ownIndex: Int?
            if depth > 0,
               let number = (node[kCGPDFOutlineDestination as String] as? NSNumber)?.intValue,
               number >= 1, number <= pageCount {
                ownIndex = number - 1
            }
            var subtree: Set<Int> = []
            for child in node[kCGPDFOutlineChildren as String] as? [[String: Any]] ?? [] {
                subtree.formUnion(walk(child, depth: depth + 1))
            }
            if let index = ownIndex {
                if let title = (node[kCGPDFOutlineTitle as String] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !title.isEmpty {
                    let grouping = subtree.contains { $0 != index }
                    candidates[index, default: []].append(
                        Candidate(depth: depth, title: title, grouping: grouping)
                    )
                }
                subtree.insert(index)
            }
            return subtree
        }
        walk(outline, depth: 0)
        // Appended in post-order, which keeps reading order among entries of equal depth (two
        // entries of one depth are never ancestor and descendant), so `first` is the tie-break.
        var titles: [Int: String] = [:]
        for (index, entries) in candidates {
            let names = entries.filter { !$0.grouping }
            if let minDepth = names.map(\.depth).min() {
                titles[index] = names.first { $0.depth == minDepth }?.title
            } else if let maxDepth = entries.map(\.depth).max() {
                titles[index] = entries.first { $0.depth == maxDepth }?.title
            }
        }
        return titles
    }

    /// The drawing's bookmark tree for the Pages Index (NL-DOCS-06), each entry resolved to a
    /// page identity of this drawing; an entry pointing nowhere in it keeps its title and no
    /// page. Bounded in depth and entries, like ``outlineTitles(from:pageCount:)``.
    static func navigatorBookmarks(for drawing: LoadedDrawing, password: String?) -> [NavigatorBookmark] {
        guard let document = CGPDFDocument(drawing.url as CFURL) else { return [] }
        if document.isEncrypted, !document.isUnlocked, let password { _ = document.unlockWithPassword(password) }
        guard !document.isEncrypted || document.isUnlocked,
              let outline = document.outline as? [String: Any] else { return [] }
        var pageIDs: [Int: UUID] = [:]
        for page in drawing.pages { pageIDs[page.index] = page.id.rawValue }
        return bookmarks(from: outline, pageIDs: pageIDs)
    }

    /// The pure half of ``navigatorBookmarks(for:password:)``: a CoreGraphics outline dictionary
    /// into bookmarks, with 1-based destinations mapped through `pageIDs` (zero-based index →
    /// identity).
    static func bookmarks(from outline: [String: Any], pageIDs: [Int: UUID]) -> [NavigatorBookmark] {
        var visited = 0
        func walk(_ node: [String: Any], path: String, depth: Int) -> [NavigatorBookmark] {
            guard depth <= 32 else { return [] }
            var result: [NavigatorBookmark] = []
            for (offset, child) in (node[kCGPDFOutlineChildren as String] as? [[String: Any]] ?? []).enumerated() {
                guard visited < 20_000 else { break }
                visited += 1
                let title = (child[kCGPDFOutlineTitle as String] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let number = (child[kCGPDFOutlineDestination as String] as? NSNumber)?.intValue
                let pageID = number.flatMap { pageIDs[$0 - 1] }
                let id = path.isEmpty ? "\(offset)" : "\(path).\(offset)"
                let children = walk(child, path: id, depth: depth + 1)
                guard !title.isEmpty || !children.isEmpty else { continue }
                result.append(NavigatorBookmark(id: id, title: title, pageID: pageID, children: children))
            }
            return result
        }
        return walk(outline, path: "", depth: 0)
    }

    /// Outline titles keyed by the drawing's page identities, for
    /// `AppDocumentPresenter.sheetOutlineTitles`. Keyed by identity rather than position so a
    /// later reorder cannot hand one sheet another's name.
    static func sheetOutlineTitles(for drawing: LoadedDrawing, password: String?) -> [UUID: String] {
        let byIndex = readOutlineTitles(at: drawing.url, password: password)
        guard !byIndex.isEmpty else { return [:] }
        var titles: [UUID: String] = [:]
        for page in drawing.pages {
            if let title = byIndex[page.index] { titles[page.id.rawValue] = title }
        }
        return titles
    }

    private static func rect(_ value: CGRect) -> PDFRect {
        PDFRect(
            x: Double(value.origin.x),
            y: Double(value.origin.y),
            width: Double(value.size.width),
            height: Double(value.size.height)
        )
    }

    /// Builds the snap index for one page, extracting its vector geometry first.
    ///
    /// A scanned sheet has no vector content; that is not an error, and the index still carries
    /// the markup and page-boundary layers so Markup Snap keeps working while Vector Snap
    /// correctly reports itself unavailable.
    public static func buildSnapIndex(
        for page: ZPDFContracts.PageDescriptor,
        documentURL: URL,
        session: TakeoffSession,
        password: String? = nil
    ) async -> SnapIndexResult {
        var failureReason: String?
        let extraction: VectorPageExtraction?
        do {
            // An unlocked drawing's password travels with the request, so Vector Snap works on a
            // protected drawing too (BH-069); the service never logs, stores or caches it.
            extraction = try await GeometryExtraction.client.extractPageGeometry(
                documentAt: documentURL,
                pageIndex: page.index,
                options: GeometryWireOptions(password: password)
            )
        } catch {
            // A failure is not "no vector content": say what happened (BH-353). The index is
            // still built, markup-only, below, so Markup Snap keeps working.
            extraction = nil
            failureReason = extractionFailureReason(error)
        }
        do {
            let availability = try await session.buildSnapIndex(page: page, extraction: extraction)
            return SnapIndexResult(availability: availability, extraction: extraction, failureReason: failureReason)
        } catch {
            // No index stored means every later snap resolve fails with `unknownPage`. Fall
            // back to a markup-and-boundary index so snapping to markups still works, and
            // report the vector half as failed rather than absent.
            let fallback = extraction == nil
                ? nil
                : try? await session.buildSnapIndex(page: page, extraction: nil)
            return SnapIndexResult(
                availability: fallback,
                extraction: extraction,
                failureReason: failureReason ?? indexFailureReason(error)
            )
        }
    }

    /// The status-bar words for an extraction that failed.
    static func extractionFailureReason(_ error: any Error) -> String {
        if case VectorExtractionError.documentEncrypted = error {
            return NSLocalizedString(
                "Vector Snap is not available on a password-protected drawing",
                comment: "Geometry index status when the drawing's vector geometry cannot be read because it is encrypted"
            )
        }
        return String(
            format: NSLocalizedString(
                "Vector Snap could not read this page: %@",
                comment: "Geometry index status when vector extraction failed; the argument is the reason"
            ),
            error.localizedDescription
        )
    }

    /// The reason alone, for callers that phrase their own sentence.
    static func extractionFailureDetail(_ error: any Error) -> String {
        if case VectorExtractionError.documentEncrypted = error {
            return NSLocalizedString(
                "the drawing is password-protected",
                comment: "Reason vector geometry could not be read: encrypted drawing"
            )
        }
        return error.localizedDescription
    }

    /// The status-bar words for a snap index that could not be built.
    static func indexFailureReason(_ error: any Error) -> String {
        String(
            format: NSLocalizedString(
                "Vector Snap could not index this page: %@",
                comment: "Geometry index status when building the snap index failed; the argument is the reason"
            ),
            error.localizedDescription
        )
    }

    /// What one page's indexing pass produced.
    ///
    /// The extraction travels back with the availability because two features need the same
    /// geometry and extracting it twice would cost 13 ms and a second scan of the content
    /// stream for nothing: Vector Snap indexes it, and the canvas's vector underlay draws it.
    public struct SnapIndexResult: Sendable {
        public let availability: SnapIndexAvailability?
        public let extraction: VectorPageExtraction?
        /// Set when extraction or indexing *failed*, as opposed to finding no vector content.
        /// Already localized; the status bar shows it as `GeometryIndexStatus.failed`.
        public let failureReason: String?

        public init(
            availability: SnapIndexAvailability?,
            extraction: VectorPageExtraction?,
            failureReason: String? = nil
        ) {
            self.availability = availability
            self.extraction = extraction
            self.failureReason = failureReason
        }
    }
}
