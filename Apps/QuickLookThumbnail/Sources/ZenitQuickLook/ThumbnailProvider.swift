import CoreGraphics
import Foundation
import QuickLookThumbnailing
import ZenitQuickLookCore

/// The extension's principal class (Info.plist `NSExtensionPrincipalClass`): Finder asks for a
/// project's thumbnail, and gets the one ``PackageThumbnail`` draws — or an error, and then the
/// document icon.
@objc(ZenitThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void) {
        // Opened once (R-210): the reply draws the same decoded picture or open page it was sized by.
        // A stored picture that does not open falls through to the drawing (S-125).
        guard let resolved = PackageThumbnail.resolve(package: request.fileURL),
              let natural = resolved.naturalSize else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }
        let size = PackageThumbnail.fitted(natural, into: request.maximumSize)
        guard size.width >= 1, size.height >= 1 else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }
        handler(QLThumbnailReply(contextSize: size) { context -> Bool in
            resolved.draw(in: context, size: size)
            return true
        }, nil)
    }
}
