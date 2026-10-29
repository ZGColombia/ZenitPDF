import AppKit
import ImageIO
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFExport
import ZPDFPersistence

/// The picture the Quick Look thumbnail extension reads first (K-05, NL-PLAT-21).
///
/// `Apps/QuickLookThumbnail` looks for `thumbnails/package.png` inside a project — "the first
/// sheet as the person last saw it, markups included" — and only when it is missing parses the
/// drawing itself in its own process. Nothing in the application ever wrote that member, so every
/// Finder thumbnail of a project was the bare drawing. It is written after each save the person
/// makes, painted through the one flatten sequence print and the flattened export use, so the
/// thumbnail cannot show markups the printout would not.
extension ZenitPDFProjectDocument {

    /// Where the thumbnail lives inside a package: the layout's own `thumbnails/` folder. The
    /// extension's reader (`PackageThumbnail.storedImageMember`) names the same member, and a
    /// test holds the two together.
    nonisolated static let packageThumbnailMember = ProjectPackageLayout.thumbnails + "/package.png"

    /// The thumbnail's longest side, in pixels: what Finder asks for at its largest icon size.
    static let packageThumbnailLongestSide = 512

    /// Whether saves write the thumbnail. On in the assembled application; package-format tests
    /// assert a package's exact members, so a test process turns it on only where it asserts it.
    static var writesPackageThumbnail = ZenitProcessDefaults.isAssembledApplication

    /// Writes the saved pictures after a save of `operation` into the package at `packageURL`,
    /// when saves write them: the Quick Look thumbnail, the package's Finder icon
    /// (`QuickLook/Thumbnail.png`) and the Space-bar preview's sheet and summary (NL-PLAT-21). An autosave does not: it runs on a timer while the person works, and the
    /// pictures are the sheet as it was last *saved*.
    ///
    /// One task, one scene build of the first sheet and one render (T-014): the thumbnail and
    /// the preview each built the flatten job of the *whole* drawing on the main actor — a scene
    /// per sheet — to keep its first page, and rendered it again at their own size.
    func writeSavedPicturesAfterSave(at packageURL: URL, operation: NSDocument.SaveOperationType) {
        guard Self.writesPackageThumbnail, !Self.isAutosave(operation) else { return }
        Task { @MainActor in
            let pictures = await renderSavedPictures()
            if mode == .project, let thumbnail = pictures?.thumbnail {
                Self.writePNG(thumbnail, to: packageURL.appendingPathComponent(Self.packageThumbnailMember))
                // The same picture as the package's Finder icon (NL-UX-17): one render, one
                // picture, none on an autosave (U-020).
                Self.writeThumbnail(thumbnail, into: packageURL)
            }
            _ = await writeQuickLookPreview(at: packageURL, image: pictures?.preview)
        }
    }

    /// Both saved pictures of the first sheet with its markups, from one job and one render: the
    /// preview at ``quickLookPreviewLongestSide``, and the thumbnail scaled down from it to
    /// ``packageThumbnailLongestSide``. A missing thumbnail is never an error: the extension
    /// then draws the sheet itself.
    func renderSavedPictures() async -> (thumbnail: CGImage?, preview: CGImage)? {
        guard let picture = await packagePicture(),
              let preview = await renderPackagePicture(picture.job, sheets: picture.sheets, longestSide: Self.quickLookPreviewLongestSide)
        else { return nil }
        return (Self.scaledDown(preview, longestSide: Self.packageThumbnailLongestSide), preview)
    }

    /// The flatten job of the set's first sheet alone — its scene only, never every sheet's
    /// (T-014). The set's first sheet, as the Navigator shows it (U-013): the primary drawing's
    /// lowest page index was taken, which is a removed sheet when the first was set aside and
    /// never an added drawing's sheet placed first. A sheet of an added drawing is read from its
    /// own file (`sheets` is then set).
    func packagePicture() async -> (job: FlattenedDrawingExport.Job, sheets: DrawingSetOutput?)? {
        let setFirst = await core?.session.pageDescriptors.first
        guard let firstSheet = setFirst ?? drawing?.pages.min(by: { $0.index < $1.index }) else { return nil }
        var sheets: DrawingSetOutput?
        if !isPrimaryDrawingPage(firstSheet), let own = loadedDrawing(forPage: firstSheet.id.rawValue),
           let page = own.pages.first(where: { $0.id == firstSheet.id }) {
            sheets = DrawingSetOutput.sheets(of: own, [page])
        }
        guard let job = try? await FlattenedDrawingExport.job(
            for: self,
            artwork: { [weak self] digest in
                guard let package = self?.projectPackage else { return nil }
                return try? await ProjectArtworkStore.geometry(forDigest: digest, in: package)
            },
            set: sheets,
            only: [firstSheet.id]
        ) else { return nil }
        return (job, sheets)
    }

    private func renderPackagePicture(_ job: FlattenedDrawingExport.Job, sheets: DrawingSetOutput?, longestSide: Int) async -> CGImage? {
        guard let page = job.pages.first else { return nil }
        let content: (any FlattenPageContentDrawing)? = if let sheets { await sheets.contentSource(for: self) } else {
            await FlattenedDrawingExport.contentSource(for: self, rasterFallbackPages: [page.page])
        }
        return PDFReportSheetImages.render(
            pages: [page], content: content, longestSide: longestSide
        ).pages.first?.image
    }

    /// `image` with its longest side `longestSide`, the aspect kept and each side rounded as the
    /// sheet renderer rounds it; `image` itself when it is no larger.
    nonisolated static func scaledDown(_ image: CGImage, longestSide: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > longestSide, longest > 0 else { return image }
        let factor = Double(longestSide) / Double(longest)
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: (image.colorSpace?.model == .rgb ? image.colorSpace : nil)
                ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// PNG-encodes `image` beside `target` and moves it into place, so a reader never meets a
    /// half-written file.
    @discardableResult
    nonisolated static func writePNG(_ image: CGImage, to target: URL) -> Bool {
        let manager = FileManager.default
        let folder = target.deletingLastPathComponent()
        guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return false }
        let staging = folder.appendingPathComponent(".\(target.lastPathComponent)-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? manager.removeItem(at: staging)
            return false
        }
        do {
            if manager.fileExists(atPath: target.path) {
                _ = try manager.replaceItemAt(target, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: target)
            }
            return true
        } catch {
            try? manager.removeItem(at: staging)
            return false
        }
    }
}
