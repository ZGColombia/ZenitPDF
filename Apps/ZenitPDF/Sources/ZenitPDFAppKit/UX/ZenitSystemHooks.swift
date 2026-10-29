import AppKit
import UniformTypeIdentifiers

/// NL-UX-18: Services, and a Spotlight / Dock presence for open projects. All local; nothing
/// here needs an account or the network.
///
/// **Finder ▸ Services ▸ "Open as Quick Takeoff in Zenit PDF".** Declared in `Info.plist.in`
/// (`NSServices`, `NSMessage` = `openAsQuickTakeoff`); this object answers it: every PDF in the
/// pasteboard opens as a document, the same way File ▸ Open would open it.
@MainActor
final class ZenitServicesProvider: NSObject {

    static let shared = ZenitServicesProvider()

    /// How a service request opens files. Injectable so a test observes the open without
    /// driving the shared document controller.
    var openURLs: @MainActor ([URL]) -> Void = { urls in
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    /// The PDFs a service pasteboard carries: file URLs whose type conforms to PDF.
    static func pdfURLs(in pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension)
            return type?.conforms(to: .pdf) == true
        }
    }

    /// The service entry point. The selector's name is the plist's `NSMessage` plus the
    /// standard `userData:error:` tail.
    @objc func openAsQuickTakeoff(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let urls = Self.pdfURLs(in: pasteboard)
        guard !urls.isEmpty else {
            error?.pointee = NSLocalizedString(
                "Zenit PDF can open PDF drawings only.",
                comment: "Services refusal when the selection holds no PDF"
            ) as NSString
            return
        }
        openURLs(urls)
    }
}

extension ZenitPDFProjectDocument {

    /// The activity type Zenit publishes for an open project (Spotlight's recent items and the
    /// Dock menu list documents through it).
    static let viewingActivityType = "com.zenitgroup.zenitpdf.viewing"

    /// An `NSUserActivity` naming this document's file, or `nil` before it has one.
    func makeViewingActivity() -> NSUserActivity? {
        guard let url = fileURL else { return nil }
        let activity = NSUserActivity(activityType: Self.viewingActivityType)
        activity.title = displayName
        activity.isEligibleForSearch = true
        activity.isEligibleForHandoff = false
        activity.isEligibleForPublicIndexing = false
        activity.userInfo = ["path": url.path]
        activity.requiredUserInfoKeys = ["path"]
        return activity
    }
}
