import AppKit
import OSLog
import ZPDFContracts
import ZPDFUIPresentation

/// What a `zenitpdf:` link asks for, decided without side effects so it can be tested.
///
/// Any web page can open a `zenitpdf:` URL, as often as it likes. Until 2026-09-23 an unknown
/// host raised a modal `NSAlert` carrying the page's own URL text: a page
/// could put its words in front of the person, repeatedly. A link is now answered, at most, by a
/// non-modal note in the front project's status tray, and the note never repeats the link's text.
///
/// **A link never opens a file (S17-05).** `zenitpdf://open?path=…` used to hand the path straight
/// to the document controller, with no confirmation. The sandbox limits what the process can read
/// without a user selection, but not to nothing: the app's own container — autosaved copies of the
/// person's takeoffs among it — and world-readable system paths were all one page visit away from
/// being opened unprompted, and any future file entitlement would have widened that to whatever a
/// page could plant. Nothing in the product creates such a link (Shortcuts open drawings through
/// `OpenDrawingIntent`, the command-line tool reads projects itself), so the path form is refused:
/// a link naming a file opens nothing and leaves one quiet note pointing at File ▸ Open….
enum ZenitURLRoute: Equatable {
    /// `zenitpdf://open`: the Open panel, where the person chooses a file themselves.
    case open
    /// `zenitpdf://open?path=…`: a link naming a file. Refused — nothing is opened (S17-05).
    case refusedFileRequest
    /// `zenitpdf://new` or `zenitpdf:` with no host.
    case new
    /// `zenitpdf://reveal?project=…&markup=…` (NL-PLAT-09): bring a markup forward, from a link in
    /// an exported workbook or report.
    case reveal(project: String, markup: UUID)
    /// Anything else. Never a modal.
    case unknown

    init(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            self = .unknown
            return
        }
        switch components.host?.lowercased() {
        case "open":
            let path = components.queryItems?.first { $0.name == "path" }?.value
            self = (path?.isEmpty ?? true) ? .open : .refusedFileRequest
        case "new", .none:
            self = .new
        case "reveal":
            let items = components.queryItems ?? []
            guard let project = items.first(where: { $0.name == "project" })?.value, !project.isEmpty,
                  let markup = items.first(where: { $0.name == "markup" })?.value.flatMap(UUID.init(uuidString:)) else {
                self = .unknown
                return
            }
            self = .reveal(project: project, markup: markup)
        default:
            self = .unknown
        }
    }
}

@MainActor
enum ZenitURLNotes {

    private static let log = Logger(subsystem: ZenitAppInfo.bundleIdentifier, category: "url-scheme")

    /// One id per kind of note, so a page that sends the same link fifty times leaves one note.
    static let unknownLinkNoteID = UUID(uuidString: "6B1C2E0A-5A7F-4C2B-9E7D-0D1A2B3C4D01")!
    static let fileLinkNoteID = UUID(uuidString: "6B1C2E0A-5A7F-4C2B-9E7D-0D1A2B3C4D02")!
    static let revealNoteID = UUID(uuidString: "6B1C2E0A-5A7F-4C2B-9E7D-0D1A2B3C4D03")!

    /// The link a workbook row carries: `zenitpdf://reveal?project=<identity>&markup=` + the id.
    nonisolated static func revealLinkPrefix(project: String) -> String {
        var components = URLComponents()
        components.scheme = ZenitAppInfo.urlScheme
        components.host = "reveal"
        components.queryItems = [URLQueryItem(name: "project", value: project)]
        return (components.string ?? "zenitpdf://reveal?project=") + "&markup="
    }

    /// Finds the open document the link names and brings the markup forward: its page, selected,
    /// zoomed to. A link to a project that is not open, or to a markup that is gone, leaves a note —
    /// never an alert.
    static func reveal(project: String, markup: UUID, in documents: [ZenitPDFProjectDocument]) async -> Bool {
        for document in documents {
            guard await SpreadsheetRoundTrip.identity(of: document) == project, let core = document.core else { continue }
            guard let record = await core.session.markup(MarkupID(markup)) else {
                core.document.post(revealNote(
                    NSLocalizedString("That link's markup is no longer in this project", comment: "Status note for a zenitpdf://reveal link whose markup was deleted"),
                    NSLocalizedString("It may have been deleted since the workbook was exported.", comment: "Status note detail for a reveal link whose markup was deleted")))
                return false
            }
            document.showWindows()
            core.document.goToPage(id: record.pageID.rawValue)
            core.canvas.select(markupIDs: [markup], additive: false)
            core.canvas.zoomTo(markupID: markup)
            return true
        }
        post(revealNote(
            NSLocalizedString("That link belongs to a project that is not open", comment: "Status note for a zenitpdf://reveal link to a closed project"),
            NSLocalizedString("Open the project it was exported from, then click the link again.", comment: "Status note detail for a reveal link to a closed project")),
             to: documents.first)
        return false
    }

    static func revealNote(_ title: String, _ message: String) -> AppWarning {
        AppWarning(id: revealNoteID, severity: .info, title: title, message: message,
                   source: NSLocalizedString("Link", comment: "Status note source for zenitpdf: links"),
                   isDismissible: true, timestamp: Date())
    }

    static func unknownLinkNote(now: Date = Date()) -> AppWarning {
        AppWarning(
            id: unknownLinkNoteID,
            severity: .info,
            title: NSLocalizedString(
                "A link asked Zenit PDF for something it does not do",
                comment: "Status note for an unrecognised zenitpdf: link"
            ),
            message: NSLocalizedString(
                "Nothing was changed.",
                comment: "Status note detail for an unrecognised zenitpdf: link"
            ),
            source: NSLocalizedString("Link", comment: "Status note source for zenitpdf: links"),
            isDismissible: true,
            timestamp: now
        )
    }

    /// The answer to `zenitpdf://open?path=…`. It names neither the path nor the file: the text
    /// of a link is the page's, not ours to repeat.
    static func fileLinkRefusedNote(now: Date = Date()) -> AppWarning {
        AppWarning(
            id: fileLinkNoteID,
            severity: .info,
            title: NSLocalizedString(
                "A link asked Zenit PDF to open a file",
                comment: "Status note when a zenitpdf://open link names a file; links never open files"
            ),
            message: NSLocalizedString(
                "Links cannot open files. Nothing was opened. Choose File ▸ Open… to open it yourself.",
                comment: "Status note detail when a zenitpdf://open link names a file"
            ),
            source: NSLocalizedString("Link", comment: "Status note source for zenitpdf: links"),
            isDismissible: true,
            timestamp: now
        )
    }

    /// Posts `note` to the front project's status tray. With no project open there is nowhere
    /// quiet to say it, so it is only logged — never promoted to a window.
    static func post(_ note: AppWarning, to document: ZenitPDFProjectDocument?) {
        guard let document, let core = document.core else {
            log.info("zenitpdf: link note with no project open: \(note.title, privacy: .public)")
            return
        }
        core.document.post(note)
    }
}
