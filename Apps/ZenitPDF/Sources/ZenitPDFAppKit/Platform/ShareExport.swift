import AppKit
import ZPDFUIPresentation

/// File ▸ Share Last Export… (NL-PLAT-10): the file the last export wrote, handed to the system's
/// share picker — Mail, Messages, AirDrop, Notes — which needs no entitlement and no server. It is
/// always the person's own action; nothing is shared automatically, and nothing but that one file
/// goes. "Send Project…" remains the way to hand over the whole project.
@MainActor
enum ShareExport {

    static let noteID = UUID(uuidString: "9A4C2E1B-7D3F-4B5A-8C6E-0F1A2B3C4D5E")!

    /// Where the file is handed to the picker. A test injects its own; outside the assembled
    /// application nothing is shown.
    static var sharingPresenter: (@MainActor (URL, NSWindow?) -> Void)?

    /// What sharing would hand over, or why it cannot: the last export must exist on disk.
    enum Target: Equatable {
        case file(URL)
        case nothingExported
        case fileGone(String)
    }

    static func target(for document: ZenitPDFProjectDocument) -> Target {
        guard let url = document.lastExportURL else { return .nothingExported }
        guard FileManager.default.fileExists(atPath: url.path) else { return .fileGone(url.lastPathComponent) }
        return .file(url)
    }

    static func share(document: ZenitPDFProjectDocument, window: NSWindow?) {
        switch target(for: document) {
        case let .file(url):
            if let sharingPresenter { sharingPresenter(url, window); return }
            guard ZenitModalPresenter.canPresentModally, let view = window?.contentView else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1), of: view, preferredEdge: .minY)
        case .nothingExported:
            note(document, NSLocalizedString("Nothing exported yet", comment: "Share Last Export with no export: title"),
                 NSLocalizedString("Export the ledger or a drawing first (File ▸ Export…), then share the file it wrote.", comment: "Share Last Export with no export: detail"))
        case let .fileGone(name):
            note(document, NSLocalizedString("The exported file is no longer there", comment: "Share Last Export after the file moved: title"),
                 String(format: NSLocalizedString("“%@” was moved or deleted after it was exported. Export again to share it.", comment: "Share Last Export after the file moved: detail; file name"), name))
        }
    }

    private static func note(_ document: ZenitPDFProjectDocument, _ title: String, _ message: String) {
        document.core?.document.post(AppWarning(
            id: noteID, severity: .info, title: title, message: message,
            source: NSLocalizedString("Share", comment: "Status note source for sharing"),
            isDismissible: true, timestamp: Date()))
    }
}
