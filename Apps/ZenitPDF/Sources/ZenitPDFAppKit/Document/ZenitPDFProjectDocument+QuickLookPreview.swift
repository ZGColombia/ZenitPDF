import AppKit
import Foundation
import ZPDFAppCore
import ZPDFPersistence
import ZenitQuickLookCore

/// The Space-bar preview's two package members (NL-PLAT-21): `thumbnails/preview.png`, the first
/// sheet with its markups at preview size, and `thumbnails/summary.json`, the project's name, its
/// size and the ledger's grand totals as the ledger shows them. The Quick Look preview extension
/// (`Apps/QuickLookThumbnail`, `ZenitQuickLookPreview`) turns them into the page Finder shows on
/// Space; it computes no quantity and parses no drawing while they are there.
///
/// Written after each save the person makes, under the same switch as the Finder thumbnail
/// (``writesPackageThumbnail``: on in the assembled app, and in a test that asserts it), and never
/// after an autosave — the preview is the project as it was last *saved*.
extension ZenitPDFProjectDocument {

    /// `request` without anything that narrows the rows: no filter, no older-scale view, no
    /// selection scope, no grouping or sort. Only the columns are kept.
    nonisolated static func wholeProjectRequest(from request: LedgerRequest) -> LedgerRequest {
        LedgerRequest(visibleColumns: request.visibleColumns)
    }

    /// The members, as the extension names them.
    nonisolated static let quickLookPreviewImageMember = PackagePreview.imageMember
    nonisolated static let quickLookSummaryMember = PackagePreview.summaryMember

    /// The preview sheet's longest side, in pixels: sharp in Quick Look's default window.
    static let quickLookPreviewLongestSide = 1_600

    /// Gathers the totals and writes them with `image`, the sheet already rendered at preview
    /// size (``writeSavedPicturesAfterSave(at:operation:)`` renders it once for both pictures).
    /// Returns whether the summary was written; the picture is best effort (without it the
    /// extension shows the thumbnail's).
    @discardableResult
    func writeQuickLookPreview(at packageURL: URL, image: CGImage?) async -> Bool {
        guard mode == .project, let summary = await quickLookSummary() else { return false }
        if let image {
            Self.writePNG(image, to: packageURL.appendingPathComponent(Self.quickLookPreviewImageMember))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(summary) else { return false }
        let target = packageURL.appendingPathComponent(Self.quickLookSummaryMember)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The summary of the takeoff as it is now: the ledger's grand totals through the one reading
    /// Shortcuts and AppleScript share (``ZenitShortcutsBridge/totalRows(_:)``).
    ///
    /// The whole project's totals, whatever the ledger shows at save time (S-023): the on-screen
    /// request used to shape them, so a filter or "only values under an older scale" left partial
    /// grand totals in the package beside whole-project sheet and markup counts, unmarked. The
    /// columns stay the person's, so the totals are the ones they chose to see.
    func quickLookSummary() async -> PackagePreviewSummary? {
        guard let core else { return nil }
        let name = displayName ?? fileURL?.deletingPathExtension().lastPathComponent ?? "Takeoff"
        guard let projection = try? await ProjectWindowController.projection(
            core: core, documentName: name,
            scaleDescription: core.snapshot.documentScaleDescription,
            request: Self.wholeProjectRequest(from: core.ledger.request))
        else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return PackagePreviewSummary(
            projectName: name,
            savedAt: formatter.string(from: Date()),
            sheetCount: core.snapshot.pages.count,
            markupCount: core.snapshot.markups.count,
            totals: ZenitShortcutsBridge.totalRows(projection).map { PackagePreviewSummary.Total(title: $0.title, text: $0.text) }
        )
    }
}
