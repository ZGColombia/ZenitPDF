import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFUIPresentation
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Platform fixes: the platform bugs that live in the app target.
@MainActor
@Suite("Platform fixes", .appTierSerialised)
struct PlatformLaneFixTests {

    private static let bundleDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Bundle")

    private static func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: bundleDirectory.appendingPathComponent(name))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private static func exportedType(_ identifier: String) throws -> [String: Any]? {
        let types = try #require(try plist("Info.plist.in")["UTExportedTypeDeclarations"] as? [[String: Any]])
        return types.first { $0["UTTypeIdentifier"] as? String == identifier }
    }

    // MARK: - zenitpdf: links never raise a modal

    @Test("zenitpdf: links route without side effects")
    func linksRoute() throws {
        // S17-05: a link naming a file is refused, in every spelling; only the bare form asks the
        // person, through the Open panel.
        #expect(ZenitURLRoute(try #require(URL(string: "zenitpdf://open?path=/tmp/a.pdf"))) == .refusedFileRequest)
        #expect(ZenitURLRoute(try #require(URL(string: "zenitpdf://OPEN?path=%7E%2FLibrary%2Fx.zpdfproj"))) == .refusedFileRequest)
        #expect(ZenitURLRoute(try #require(URL(string: "zenitpdf://open?mode=view&path=file:///etc/hosts"))) == .refusedFileRequest)
        #expect(ZenitURLRoute(try #require(URL(string: "zenitpdf://open"))) == .open)
        #expect(ZenitURLRoute(try #require(URL(string: "zenitpdf://open?path="))) == .open)
        #expect(ZenitURLRoute(try #require(URL(string: "zenitpdf://NEW"))) == .new)
        #expect(ZenitURLRoute(try #require(URL(string: "zenitpdf:"))) == .new)
        #expect(ZenitURLRoute(try #require(URL(string: "zenitpdf://pay-now?text=Your%20Mac%20is%20infected"))) == .unknown)
    }

    @Test("An unknown link raises no modal, and fifty of them leave one quiet note that quotes nothing")
    func unknownLinkIsANoteNotAnAlert() async throws {
        // Old code: `default:` built an NSAlert whose informative text was the page's URL and ran
        // it through ZenitModalPresenter (identifier "app.unknownLink") — once per link.
        ZenitModalPresenter.reset()
        let delegate = ZenitApplicationDelegate()
        let hostile = try #require(URL(string: "zenitpdf://pay-now?text=Your%20Mac%20is%20infected"))
        for _ in 0..<5 { delegate.handleZenitURL(hostile) }
        #expect(ZenitModalPresenter.recorded.isEmpty, "a link must never put a modal in front of the person")

        let url = try AppTestSupport.writeFixturePDF(named: "Link \(UUID().uuidString).pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        defer { document.close() }
        #expect(await AppTestSupport.wait { document.core != nil })
        let core = try #require(document.core)
        for _ in 0..<50 { ZenitURLNotes.post(ZenitURLNotes.unknownLinkNote(), to: document) }
        let notes = core.document.warnings.filter { $0.id == ZenitURLNotes.unknownLinkNoteID }
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(note.severity == .info)
        #expect(!note.title.contains("infected") && !note.message.contains("infected"))
        #expect(!ZenitModalPresenter.recorded.contains { $0.identifier == "app.unknownLink" || $0.detail.contains("infected") },
                "\(ZenitModalPresenter.recorded.map(\.identifier))")
    }

    @Test("S17-05: a link naming a file opens nothing, asks nothing, and leaves one note that names nothing")
    func aLinkNeverOpensAFile() async throws {
        // Old code: `handleZenitURL` expanded the tilde and called
        // `openDocument(withContentsOf:display:)` with no confirmation, so any web page could make
        // the app open an autosaved copy of the person's own work from its container. The paths
        // below do not exist, so even a regression of that code could not put a window up here:
        // it would fail to open and post a different note, which the assertions catch.
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }
        let marker = "Planted\(UUID().uuidString.prefix(8))"
        let container = "~/Library/Containers/\(ZenitAppInfo.bundleIdentifier)/Data/Library/Application Support/Zenit PDF/Autosave/\(marker).zpdfproj"
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("\(marker).pdf").path
        var links: [URL] = []
        for path in [container, temporary, "/etc/\(marker)"] {
            var components = URLComponents()
            components.scheme = ZenitAppInfo.urlScheme
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            links.append(try #require(components.url))
        }
        let delegate = ZenitApplicationDelegate()
        var notes: [AppWarning] = []
        delegate.postLinkNote = { note, _ in notes.append(note) }
        let before = NSDocumentController.shared.documents.map(\.fileURL)

        for link in links { delegate.handleZenitURL(link) }
        // Room for an asynchronous open to land, so "none did" is a measurement, not a race.
        try await Task.sleep(for: .milliseconds(300))

        #expect(NSDocumentController.shared.documents.map(\.fileURL) == before, "a link opened a document")
        #expect(ZenitModalPresenter.recorded.isEmpty, "a link must never put a modal in front of the person")
        #expect(notes.count == links.count)
        #expect(notes.allSatisfy { $0.id == ZenitURLNotes.fileLinkNoteID && $0.severity == .info })
        for note in notes {
            #expect(!note.title.contains(marker) && !note.message.contains(marker), "the note repeats the link's text")
            #expect(note.message.contains("File ▸ Open…"), "the note says how to open a file instead")
        }
    }

    // MARK: - No network, no updater

    @Test("The app asks for no network access, ships no updater keys, and has no Check for Updates item")
    func noNetworkEntitlementOrUpdater() throws {
        // Old: com.apple.security.network.client and two mach-lookup temporary exceptions for the
        // updater's installer, disable-library-validation for its framework, six SU* keys in
        // Info.plist and Zenit PDF ▸ Check for Updates…. The updater was removed (2026-10-27).
        let entitlements = try Self.plist("ZenitPDF.entitlements")
        #expect(entitlements["com.apple.security.network.client"] == nil)
        #expect(entitlements["com.apple.security.network.server"] == nil)
        #expect(!entitlements.keys.contains { $0.hasPrefix("com.apple.security.temporary-exception.") })
        #expect(entitlements["com.apple.security.cs.disable-library-validation"] == nil)
        let info = try Self.plist("Info.plist.in")
        #expect(!info.keys.contains { $0.hasPrefix("SU") }, "\(info.keys.filter { $0.hasPrefix("SU") })")
        let bar = ZenitMenuBar.make()
        let applicationMenu = try #require(bar.items.first?.submenu, "no application menu")
        let appTitles = applicationMenu.items.map(\.title)
        #expect(appTitles.contains("Settings…"), "\(appTitles)")
        #expect(!appTitles.contains { $0.localizedCaseInsensitiveContains("update") }, "\(appTitles)")
        let allTitles = bar.items.compactMap(\.submenu).flatMap(\.items).map(\.title)
        #expect(!allTitles.contains("Check for Updates…"))
    }

    // MARK: - File types

    @Test(".zpdftools and .zpdfoverlay are declared types conforming to JSON")
    func toolSetAndOverlayAreDeclared() throws {
        // Old code: Info.plist.in exported only the project, ledger-json and jobtemplate types,
        // so both extensions resolved to a session-local dyn.* type.
        for (identifier, fileExtension) in [
            (ToolSetDocument.typeIdentifier, ToolSetDocument.fileExtension),
            (ZenitAppInfo.overlayTypeIdentifier, ZenitAppInfo.overlayExtension),
        ] {
            let declaration = try #require(try Self.exportedType(identifier), "\(identifier) is not exported")
            #expect((declaration["UTTypeConformsTo"] as? [String]) == ["public.json"])
            let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
            #expect((tags["public.filename-extension"] as? [String]) == [fileExtension])
        }
    }

    // MARK: - Entitlements

    @Test("The unused app-group entitlement is gone")
    func noApplicationGroup() throws {
        // Old code: com.apple.security.application-groups = [group.com.zenitgroup.zenitpdf], used
        // by nothing, and on macOS 15+ an unprovisioned group container prompts on first access.
        let entitlements = try Self.plist("ZenitPDF.entitlements")
        #expect(entitlements["com.apple.security.application-groups"] == nil)
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
    }

    // MARK: - VoiceOver reaches every markup

    private static func shape(x: Double, y: Double, caption: String) -> CanvasMarkupShape {
        CanvasMarkupShape(
            id: UUID(),
            pageID: UUID(),
            color: ColorRGBA(red: 1, green: 0, blue: 0, alpha: 1),
            strokes: [CanvasStroke(points: [PDFPointValue(x: x, y: y), PDFPointValue(x: x + 10, y: y)], closed: false, filled: false)],
            counts: [],
            bounds: PDFRectValue(x: x, y: y, width: 10, height: 0),
            hidden: false,
            caption: caption
        )
    }

    @Test("Markups scrolled out of view stay in the accessibility tree, in reading order")
    func offscreenMarkupsAreReachable() {
        // Old code: `guard frame.intersects(visible)` dropped every markup outside the visible
        // rectangle, so with the view scrolled to its top-left corner only "top-left" was listed.
        let view = CanvasPageView(frame: CGRect(x: 0, y: 0, width: 2000, height: 2000))
        view.transform = PageDisplayTransform(
            pageBox: PDFRectValue(x: 0, y: 0, width: 2000, height: 2000),
            rotation: 0,
            zoom: 1,
            origin: .zero
        )
        view.shapes = [
            Self.shape(x: 1800, y: 100, caption: "bottom-right"),
            Self.shape(x: 50, y: 1900, caption: "top-left"),
            Self.shape(x: 1800, y: 1900, caption: "top-right"),
        ]
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        scroll.documentView = view
        #expect(view.visibleRect.width <= 200, "the fixture must actually hide most of the page")
        let labels = view.markupAccessibilityElements().compactMap { $0.accessibilityLabel() }
        #expect(labels.count == 3)
        #expect(labels.map { $0.components(separatedBy: ", ").last ?? "" } == ["top-left", "top-right", "bottom-right"])
    }

    @Test("The canvas reads its sheet label, not its page index, when the sheet has one")
    func canvasReadsTheSheetLabel() {
        // Old code: always "Drawing, page %ld", even on sheet A-101.
        #expect(CanvasPageView.canvasAccessibilityLabel(sheetLabel: "A-101", pageNumber: 3) == "Drawing, sheet A-101")
        #expect(CanvasPageView.canvasAccessibilityLabel(sheetLabel: nil, pageNumber: 3) == "Drawing, page 3")
        #expect(CanvasPageView.canvasAccessibilityLabel(sheetLabel: "3", pageNumber: 3) == "Drawing, page 3")
        #expect(CanvasPageView.canvasAccessibilityLabel(sheetLabel: "  ", pageNumber: 2) == "Drawing, page 2")
    }

    // MARK: - Release toolchain pin

    @Test("The release job fails, rather than warns, when the pinned Xcode is missing")
    func releaseToolchainIsPinned() throws {
        // Old code: the "Select Xcode" step printed ::warning title=Xcode … and carried on, so a
        // release could be built on an unpinned toolchain with a green job; the header also still
        // said build-app.sh "does not exist".
        let workflow = try String(
            contentsOf: Self.bundleDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8)
        #expect(!workflow.contains("::warning title=Xcode"))
        #expect(workflow.contains("::error title=Xcode ${XCODE_VERSION} not on this runner"))
        #expect(workflow.contains("::error title=Wrong Xcode"))
        #expect(!workflow.contains("Scripts/build-app.sh does not exist"))
        #expect(workflow.contains("actions/attest-build-provenance"))
    }
}
