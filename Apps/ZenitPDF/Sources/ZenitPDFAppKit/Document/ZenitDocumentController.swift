import AppKit
import UniformTypeIdentifiers

/// The document controller.
///
/// One document class serves both document modes, so the routing this subclass performs
/// is about *types*, not classes: an Info.plist `NSDocumentClass` entry names an Objective-C class,
/// and a Swift class in a SwiftPM module has a mangled Objective-C name that the plist cannot spell
/// stably across module renames. Answering `documentClass(forType:)` in code removes that coupling
/// entirely.
@MainActor
public final class ZenitDocumentController: NSDocumentController {

    /// Types this application can open, in the order the Open panel offers them.
    public nonisolated static let readableTypeIdentifiers: [String] = [
        ZenitAppInfo.projectTypeIdentifier,
        UTType.pdf.identifier
    ]

    public override var documentClassNames: [String] {
        [NSStringFromClass(ZenitPDFProjectDocument.self)]
    }

    public override var defaultType: String? {
        ZenitAppInfo.projectTypeIdentifier
    }

    public override func documentClass(forType typeName: String) -> AnyClass? {
        ZenitPDFProjectDocument.self
    }

    /// Resolves a URL to one of the two supported type identifiers.
    ///
    /// `super` consults the bundle's declared document types, which is right when the application
    /// is running from a bundle and empty when it is running from `swift run`. The extension check
    /// below is the fallback that keeps a development build openable.
    public override func typeForContents(of url: URL) throws -> String {
        if let type = try? super.typeForContents(of: url),
           Self.readableTypeIdentifiers.contains(type) {
            return type
        }
        switch url.pathExtension.lowercased() {
        case ZenitAppInfo.projectExtension:
            return ZenitAppInfo.projectTypeIdentifier
        case "pdf":
            return UTType.pdf.identifier
        default:
            throw ZenitDocumentError.unsupportedFileType(url.lastPathComponent)
        }
    }

    /// Opens a document, resolving a stored drag-and-drop bookmark first when plain access
    /// has lapsed.
    ///
    /// A file that arrived by drop in an earlier session is readable only through the
    /// security-scoped bookmark taken at drop time; without this
    /// resolution the file would silently fail to reopen from Open Recent after a relaunch.
    public override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        let (target, release) = Self.resolvedAccess(for: url)
        // A scan or photo of a sheet becomes a PDF drawing first (NL-PLAT-04).
        if Self.isImageDrawing(target) {
            openImageDrawing(target, release: release, display: displayDocument, completionHandler: completionHandler)
            return
        }
        // A DXF becomes a scaled vector sheet; a DWG gets a sentence (NL-PLAT-05).
        if CADDrawingIntake.canOpen(target) {
            openCADDrawing(target, release: release, display: displayDocument, completionHandler: completionHandler)
            return
        }
        // A measurement overlay or an export profile acts on the document in front (NL-PLAT-03).
        if Self.isDataFile(target) {
            openDataFile(target, release: release, completionHandler: completionHandler)
            return
        }
        super.openDocument(withContentsOf: target, display: displayDocument) { document, alreadyOpen, error in
            Self.handOver(release, to: document, alreadyOpen: alreadyOpen)
            completionHandler(document, alreadyOpen, error)
        }
    }

    /// Window restoration's door. AppKit reopens a document that was open at a crash (or with
    /// "Close windows when quitting" off) through this, not ``openDocument(withContentsOf:display:completionHandler:)``,
    /// so a dropped file restored here never consulted its bookmark and failed with "cannot
    /// open" (BH-892).
    public override func reopenDocument(
        for urlOrNil: URL?,
        withContentsOf contentsURL: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        let (target, release) = Self.resolvedAccess(for: contentsURL)
        super.reopenDocument(for: urlOrNil, withContentsOf: target, display: displayDocument) { document, alreadyOpen, error in
            Self.handOver(release, to: document, alreadyOpen: alreadyOpen)
            completionHandler(document, alreadyOpen, error)
        }
    }

    /// The URL to read and, when a stored drop bookmark had to be resolved, the call that
    /// ends its security-scoped access.
    static func resolvedAccess(
        for url: URL,
        isReadable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) },
        resolve: (String) -> URL? = { DroppedFileBookmarks.beginAccess(forPath: $0, defaults: ZenitProcessDefaults.bookmarks) }
    ) -> (URL, (() -> Void)?) {
        guard !isReadable(url.path), let resolved = resolve(url.path) else { return (url, nil) }
        return (resolved, { resolved.stopAccessingSecurityScopedResource() })
    }

    /// Balanced when the document closes, or right here if it never opens; the access used
    /// to be started and never stopped (CR-163).
    private static func handOver(_ release: (() -> Void)?, to document: NSDocument?, alreadyOpen: Bool) {
        guard let release else { return }
        if let document = document as? ZenitPDFProjectDocument, !alreadyOpen {
            document.scopedAccessRelease = release
        } else {
            release()
        }
    }

    public override func runModalOpenPanel(
        _ openPanel: NSOpenPanel,
        forTypes types: [String]?
    ) -> Int {
        openPanel.allowedContentTypes = Self.openPanelContentTypes
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.treatsFilePackagesAsDirectories = false
        openPanel.message = NSLocalizedString(
            "Choose a drawing or a Zenit PDF project.",
            comment: "Open panel message"
        )
        // File ▸ Open is one of the modal paths that must be injectable, and AppKit runs it,
        // not us. A process with no user chooses nothing, so this answers Cancel rather than
        // putting an open panel on screen.
        guard ZenitModalPresenter.canPresentModally, ZenitModalPresenter.handler == nil else {
            ZenitModalPresenter.recordDivertedAppKitPanel(Self.openPanelModalIdentifier)
            return NSApplication.ModalResponse.cancel.rawValue
        }
        return super.runModalOpenPanel(openPanel, forTypes: Self.openPanelContentTypes.map(\.identifier))
    }

    /// The stable name of AppKit's File ▸ Open panel.
    public static let openPanelModalIdentifier = "appkit.openPanel"
}
