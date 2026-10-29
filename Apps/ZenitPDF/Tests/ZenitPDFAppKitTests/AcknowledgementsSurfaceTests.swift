import AppKit
import Foundation
import Testing
@testable import ZenitPDFAppKit

/// The acknowledgements surface, and the licence texts it exists to display.
///
/// Until 2026-08-26 `Zenit PDF.app/Contents/Resources` held two icons, the GRDB resource bundle
/// and `en.lproj`, and the application menu's About item was
/// `orderFrontStandardAboutPanel(_:)` — a panel with a version number and no route to any
/// licence. qpdf's Apache-2.0 §4(d) makes carrying the upstream NOTICE an obligation on a
/// redistributor, and GRDB, Clipper2 and libxlsxwriter carry notices of their own, so that was
/// a compliance failure rather than a missing nicety.
///
/// `Scripts/verify-licence-notices.sh` proves the *files* are in the bundle. These tests prove
/// the *product* can read them: the loader, the ordering, the honest empty state, and — against
/// the assembled bundle when one has been built — that the five notices load through the same
/// code path a person's click takes.
@MainActor
@Suite("Acknowledgements surface", .appTierSerialised)
struct AcknowledgementsSurfaceTests {

    /// The assembled bundle, when `Scripts/build-app.sh` has produced one.
    private static var assembledBundle: Bundle? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZenitPDFAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ZenitPDF
            .deletingLastPathComponent()   // Apps
            .deletingLastPathComponent()   // repository root
        return Bundle(path: root.appendingPathComponent("build/Zenit PDF.app").path)
    }

    /// Writes a throwaway bundle-shaped directory holding the given notices.
    private func makeBundle(
        notices: [String: String],
        named name: String = "Notices"
    ) throws -> (Bundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-ack-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        let licenses = resources.appendingPathComponent(
            ZenitAboutWindowController.resourceDirectoryName, isDirectory: true
        )
        try FileManager.default.createDirectory(at: licenses, withIntermediateDirectories: true)
        for (component, text) in notices {
            try text.write(
                to: licenses.appendingPathComponent("\(component).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        // `Bundle(path:)` needs a plausible bundle; an Info.plist is enough for `resourceURL`.
        try Data("<plist/>".utf8).write(to: root.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(path: root.path), "could not open the fixture bundle \(name)")
        return (bundle, root)
    }

    // MARK: - The loader

    @Test("Every notice in the bundle is loaded, product first, then alphabetically")
    func loadsAndOrdersNotices() throws {
        let (bundle, root) = try makeBundle(notices: [
            "qpdf": "Apache License, Version 2.0 — plus NOTICE.md",
            "GRDB.swift": "MIT — Copyright (C) 2015-2025",
            "Zenit PDF": "MIT — Copyright (c) 2026 ZENIT GROUP S.A.S.",
            "Clipper2": "Boost Software License - Version 1.0"
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = ZenitAboutWindowController(bundle: bundle)
        #expect(controller.unavailableReason == nil)
        #expect(
            controller.notices.map(\.component) == ["Zenit PDF", "Clipper2", "GRDB.swift", "qpdf"],
            "got \(controller.notices.map(\.component))"
        )
        // The text, not the name. "MIT" does not satisfy MIT.
        #expect(controller.notices.first?.text.contains("ZENIT GROUP") == true)
        #expect(controller.componentList.numberOfRows == 4)
        #expect(controller.noticeText.string.contains("ZENIT GROUP"))

        controller.showNotice(at: 3)
        #expect(controller.noticeText.string.contains("Apache License"))
    }

    @Test("An empty notice file is not offered as a notice")
    func emptyNoticesAreRejected() throws {
        let (bundle, root) = try makeBundle(notices: [
            "Real": "Boost Software License - Version 1.0",
            "Hollow": "   \n\n  "
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let controller = ZenitAboutWindowController(bundle: bundle)
        #expect(controller.notices.map(\.component) == ["Real"])
    }

    // MARK: - The honest empty state

    @Test("A bundle with no Licenses directory says so, and names the directory")
    func missingNoticesAreStatedRatherThanShownAsAnEmptyList() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-ack-bare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("<plist/>".utf8).write(to: root.appendingPathComponent("Contents/Info.plist"))
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = try #require(Bundle(path: root.path))
        let controller = ZenitAboutWindowController(bundle: bundle)

        #expect(controller.notices.isEmpty)
        let reason = try #require(
            controller.unavailableReason,
            """
            An acknowledgements window that shows an empty list where notices should be is \
            indistinguishable from a product with no obligations. It must say what is missing.
            """
        )
        #expect(reason.contains(ZenitAboutWindowController.resourceDirectoryName))
        #expect(reason.contains("verify-licence-notices.sh"))
        #expect(controller.noticeText.string == reason)
    }

    // MARK: - The assembled bundle

    @Test("The assembled bundle's notices load through the product's own loader")
    func theShippedNoticesAreReadable() throws {
        let bundle = try #require(
            Self.assembledBundle,
            """
            No bundle at build/Zenit PDF.app. This assertion is about the artefact a person \
            receives, so it cannot be moved to a fixture: run Scripts/build-app.sh.
            """
        )
        let controller = ZenitAboutWindowController(bundle: bundle)
        #expect(controller.unavailableReason == nil)

        let components = controller.notices.map(\.component)
        for expected in ["Zenit PDF", "GRDB.swift", "qpdf", "Clipper2", "libxlsxwriter"] {
            #expect(components.contains(expected), "the bundle carries no notice for \(expected)")
        }
        #expect(components.first == "Zenit PDF")

        // The obligations that are easiest to lose by hand-copying, asserted by content.
        let byComponent = Dictionary(
            uniqueKeysWithValues: controller.notices.map { ($0.component, $0.text) }
        )
        let qpdf = try #require(byComponent["qpdf"])
        #expect(qpdf.contains("Apache License"), "qpdf's licence text is missing")
        #expect(
            qpdf.contains("Artistic"),
            "qpdf's NOTICE.md is missing — Apache-2.0 section 4(d) makes it non-optional"
        )
        // NOTICE.md does not mention it, so the generator copies the licence header of
        // libqpdf/MD5_native.cc into the qpdf notice; the RSA licence asks for it in every copy.
        #expect(
            qpdf.contains("Copyright (C) 1991-2, RSA Data Security, Inc."),
            "qpdf's MD5_native.cc licence header is missing from the qpdf notice"
        )
        let xlsx = try #require(byComponent["libxlsxwriter"])
        #expect(xlsx.lowercased().contains("minizip"), "libxlsxwriter's bundled notices are missing")

        let total = controller.notices.reduce(0) { $0 + $1.text.count }
        #expect(total > 20_000, "only \(total) characters of licence text; that is a truncation")
    }

    // MARK: - The menu reaches it

    @Test("The application menu's About item targets the acknowledgements window")
    func theMenuItemIsWired() throws {
        let bar = ZenitMenuBar.make()
        let applicationMenu = try #require(bar.items.first?.submenu, "no application menu")
        let about = try #require(
            applicationMenu.items.first { $0.title.hasPrefix("About") },
            "the application menu has no About item"
        )
        #expect(about.action == #selector(ZenitAboutWindowController.showAbout(_:)))
        #expect(
            about.target as AnyObject? === ZenitAboutWindowController.shared,
            """
            About is not pointed at the acknowledgements window. If it went back to \
            orderFrontStandardAboutPanel(_:), the licence texts ship and nothing displays them.
            """
        )
        #expect(about.action != #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
    }

    // MARK: - Licences is a tab, and the menu bar names it

    @Test("The window has an About pane and a Licences pane, and opens on About")
    func theWindowHasTwoTabs() throws {
        let (bundle, root) = try makeBundle(notices: ["Zenit PDF": "MIT — Copyright (c) 2026"])
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ZenitAboutWindowController(bundle: bundle)
        _ = controller.window   // force the content view

        #expect(controller.tabView.tabViewItems.count == 2)
        let labels = controller.tabView.tabViewItems.map(\.label)
        #expect(labels.contains("About"))
        #expect(labels.contains("Licences"))
        #expect(controller.selectedTab == .about, "the window should open on About, not mid-list")
    }

    @Test("Selecting the Licences tab puts the licence pane on screen")
    func selectingTheLicencesTabWorks() throws {
        let (bundle, root) = try makeBundle(notices: [
            "Zenit PDF": "MIT — Copyright (c) 2026 ZENIT GROUP S.A.S.",
            "qpdf": "Apache License, Version 2.0 — plus NOTICE.md"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ZenitAboutWindowController(bundle: bundle)
        _ = controller.window

        controller.select(.licences)
        #expect(controller.selectedTab == .licences)

        // The component list must live inside the Licences pane, not somewhere the tab switch
        // leaves behind: a tab that selects a pane the content is not in shows an empty box.
        let pane = try #require(
            controller.tabView.tabViewItems
                .first { ($0.identifier as? String) == "licences" }?.view,
            "no Licences pane"
        )
        #expect(
            Self.contains(controller.componentList, in: pane),
            "the component list is not inside the Licences pane"
        )
        #expect(!controller.notices.isEmpty)

        controller.select(.about)
        #expect(controller.selectedTab == .about, "the tabs must switch both ways")
    }

    @Test("Licences is reachable from the menu bar by name")
    func theHelpMenuReachesLicences() throws {
        let bar = ZenitMenuBar.make()
        let helpMenu = try #require(
            bar.items.compactMap(\.submenu).first { $0.title == "Help" },
            """
            There is no Help menu. Until 2026-08-26 the only route to the licence notices was \
            the About item, which is where people look for a version number, not for the terms \
            they are using software under.
            """
        )
        let licences = try #require(
            helpMenu.items.first { $0.title == "Licences" },
            "the Help menu has no Licences item"
        )
        #expect(licences.action == #selector(ZenitAboutWindowController.showLicences(_:)))
        #expect(licences.target as AnyObject? === ZenitAboutWindowController.shared)
    }

    /// Depth-first search for a view. `NSStackView` nests, so an identity check against the
    /// pane's immediate subviews would pass only by accident.
    private static func contains(_ needle: NSView, in haystack: NSView) -> Bool {
        if haystack === needle { return true }
        return haystack.subviews.contains { contains(needle, in: $0) }
    }
}
