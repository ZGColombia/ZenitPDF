import AppKit
import ZPDFPersistence

/// Finder previews of a project (NL-UX-17, the no-extension slice).
///
/// A `.zpdfproj` is a package; macOS shows a package's `QuickLook/Thumbnail.png` as its Finder
/// icon and in Quick Look when no preview extension claims the type. After every save the person
/// makes the first sheet is written there, so a folder of projects reads as drawings rather than
/// as a row of identical document icons. Local only; the drawing file itself is never touched.
///
/// Written by ``ZenitPDFProjectDocument/writeSavedPicturesAfterSave(at:operation:)``, from the
/// one render that also makes `thumbnails/package.png` (U-020): a second writer used to render
/// the bare drawing again after every save — autosaves included — so the two pictures disagreed
/// about the markups and a save rendered the sheet twice.
extension ZenitPDFProjectDocument {

    /// Where the thumbnail goes inside a package.
    nonisolated static let finderThumbnailPath = ProjectPackageLayout.finderQuickLook + "/Thumbnail.png"

    /// PNG-encodes an image into a package's `QuickLook/` folder, staged and moved into place so
    /// Finder never meets a half-written file. Returns whether it was written.
    @discardableResult
    nonisolated static func writeThumbnail(_ image: CGImage, into packageURL: URL) -> Bool {
        writePNG(image, to: packageURL.appendingPathComponent(finderThumbnailPath))
    }
}
