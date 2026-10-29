import CoreGraphics
import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import ZenitQuickLookCore

/// The preview extension's principal class (Info.plist `NSExtensionPrincipalClass`): the
/// Space-bar preview of a project (NL-PLAT-21) — the first sheet with its markups and the
/// ledger's grand totals, as one HTML page with the sheet attached. ``PackagePreview`` builds it
/// from what the application saved in the package; this class only hands it to Quick Look.
@objc(ZenitPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    /// The page's size when Quick Look first shows it; the person can resize the window.
    static let contentSize = CGSize(width: 900, height: 1_100)

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        guard let content = PackagePreview.content(for: request.fileURL) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return QLPreviewReply(dataOfContentType: .html, contentSize: Self.contentSize) { reply in
            reply.stringEncoding = .utf8
            if let image = content.imageData {
                reply.attachments = [
                    PackagePreview.imageAttachmentName: QLPreviewReplyAttachment(data: image, contentType: .png)
                ]
            }
            return Data(content.html.utf8)
        }
    }
}
