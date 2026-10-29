import AppKit
import Foundation
import Testing
import ZPDFContracts
import ZPDFUIShell
import ZPDFUIWorkflows
import UniformTypeIdentifiers
@testable import ZenitPDFAppKit

/// Application-shell regressions (l8-appshell): the About window, the menu bar after a
/// shortcut change, the shortcut reference, the second window's size.
///
/// No test here orders a window on screen: the About window's presenter and the second window's
/// presenter are injected or left to the bundle check, and every menu bar is built and read, never
/// installed.
@MainActor
@Suite("Application shell", .appTierSerialised)
struct Live8AppShellTests {

    // MARK: - Fixtures

    /// A throwaway bundle-shaped directory holding the given licence notices.
    private func makeNoticeBundle(_ notices: [String: String]) throws -> (Bundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-l8-ack-\(UUID().uuidString)", isDirectory: true)
        let licenses = root.appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(ZenitAboutWindowController.resourceDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: licenses, withIntermediateDirectories: true)
        for (component, text) in notices {
            try text.write(to: licenses.appendingPathComponent("\(component).txt"), atomically: true, encoding: .utf8)
        }
        try Data("<plist/>".utf8).write(to: root.appendingPathComponent("Contents/Info.plist"))
        let bundle = try #require(Bundle(path: root.path))
        return (bundle, root)
    }

    /// Records the windows a presenter was handed instead of ordering them front.
    private final class PresentedWindows {
        var windows: [NSWindow] = []
    }

    /// A File menu as AppKit leaves it at launch in a document application whose documents
    /// autosave in place, as measured with a headless AppKit program on this macOS (l8-appshellr,
    /// a File menu built like ours, an autosaving NSDocument class, the menu read after launch):
    /// Open Recent after Open…; Save As stays a primary row with "s" and ⌥⇧⌘; Duplicate follows
    /// it as its alternate with an upper-case "S" and ⌘ alone in its mask (the case carries the
    /// Shift); Rename… and Move To… after Duplicate; Share after the next separator. Answers the
    /// rows AppKit added, Save As and Duplicate.
    private func simulateAppKitFileMenu(in bar: NSMenu) throws -> (added: [NSMenuItem], saveAs: ZenitCommandMenuItem, duplicate: NSMenuItem) {
        let file = try #require(bar.items.first { $0.submenu?.title == ZPDFCommandGroup.file.displayName }?.submenu)
        let open = try #require(ZenitMenuBar.commandItems(in: bar).first { $0.commandID == .openDocument })
        let openRecent = NSMenuItem(title: "Open Recent", action: #selector(NSMenu.submenuAction(_:)), keyEquivalent: "")
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: ""))
        openRecent.submenu = recent
        file.insertItem(openRecent, at: file.index(of: open) + 1)

        let saveAs = try #require(ZenitMenuBar.commandItems(in: bar).first { $0.commandID == .saveAs })
        saveAs.keyEquivalentModifierMask = [.command, .shift, .option]
        let duplicate = NSMenuItem(title: "Duplicate", action: Selector(("duplicateDocument:")), keyEquivalent: "S")
        duplicate.keyEquivalentModifierMask = [.command]
        duplicate.isAlternate = true
        let rename = NSMenuItem(title: "Rename…", action: Selector(("renameDocument:")), keyEquivalent: "")
        let moveTo = NSMenuItem(title: "Move To…", action: Selector(("moveDocument:")), keyEquivalent: "")
        var index = file.index(of: saveAs)
        for row in [duplicate, rename, moveTo] {
            index += 1
            file.insertItem(row, at: index)
        }
        let share = NSMenuItem(title: "Share", action: #selector(NSMenu.submenuAction(_:)), keyEquivalent: "")
        share.submenu = NSMenu(title: "Share")
        let separator = file.items[(index + 1)...].firstIndex(where: \.isSeparatorItem) ?? file.numberOfItems - 1
        file.insertItem(share, at: separator + 1)
        return ([openRecent, duplicate, rename, moveTo, share], saveAs, duplicate)
    }

    // MARK: - L-34 About and Licences

    @Test("L-34: About and Help ▸ Licences build the window on first use and hand it, with content, to the presenter")
    func aboutAndLicencesPresentAWindow() throws {
        let (bundle, root) = try makeNoticeBundle([
            "Zenit PDF": "MIT License\n\nCopyright (c) 2026 ZENIT GROUP S.A.S.",
            "qpdf": "Apache License 2.0 — NOTICE"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let presented = PresentedWindows()
        let previous = ZenitAboutWindowController.windowPresenter
        ZenitAboutWindowController.windowPresenter = { window, _ in presented.windows.append(window) }
        defer { ZenitAboutWindowController.windowPresenter = previous }

        // Lazy exactly as the shipping singleton is: nothing is built at launch.
        let controller = ZenitAboutWindowController(lazilyReadingFrom: bundle)
        #expect(controller.window == nil)

        // The Help menu item's own action.
        controller.showLicences(nil)
        // Old: AppKit never calls `loadWindow()` on a controller with no nib, so `window` stayed
        // nil and `showWindow(_:)` presented nothing — `presented.windows` was empty.
        let window = try #require(presented.windows.first, "Help ▸ Licences presented no window")
        #expect(window === controller.window)
        #expect(window.isReleasedWhenClosed == false)
        #expect(window.isVisible == false, "a test never orders the window on screen")
        #expect(controller.selectedTab == .licences)
        #expect(controller.tabView.numberOfTabViewItems == 2)
        let content = try #require(window.contentView)
        #expect(!content.subviews.isEmpty, "the window has content")
        #expect(controller.notices.map(\.component) == ["Zenit PDF", "qpdf"])
        #expect(controller.noticeText.string.hasPrefix("MIT License"))

        // The application menu's About item reuses the same window.
        controller.showAbout(nil)
        #expect(presented.windows.count == 2)
        #expect(presented.windows.last === window)
        #expect(controller.selectedTab == .about)
    }

    @Test("L-34: the menu bar's target — the shared controller — presents a window too")
    func theSharedControllerPresentsAWindow() throws {
        let presented = PresentedWindows()
        let previous = ZenitAboutWindowController.windowPresenter
        ZenitAboutWindowController.windowPresenter = { window, _ in presented.windows.append(window) }
        defer { ZenitAboutWindowController.windowPresenter = previous }
        let bar = ZenitMenuBar.make()
        let about = try #require(bar.items.first?.submenu?.items.first)
        let target = try #require(about.target as? ZenitAboutWindowController)
        #expect(target === ZenitAboutWindowController.shared)
        // Sent the way the menu sends it.
        #expect(NSApplication.shared.sendAction(try #require(about.action), to: target, from: about))
        // Old: no window — `presented.windows` stayed empty and `shared.window` nil.
        let window = try #require(presented.windows.first)
        #expect(window === ZenitAboutWindowController.shared.window)
        #expect(window.contentView?.subviews.isEmpty == false)
        // A test process has no assembled bundle: the window says why there is no list.
        #expect(ZenitAboutWindowController.shared.noticeText.string.isEmpty == false)
    }

    // MARK: - L-44 shortcut changes keep AppKit's File menu rows

    @Test("L-44: a rebound and restored shortcut edits the installed bar in place, keeping the rows AppKit inserted")
    func shortcutChangeKeepsTheRowsAppKitInserted() throws {
        let bar = ZenitMenuBar.make(table: .standard)
        let file = try #require(bar.items.first { $0.submenu?.title == ZPDFCommandGroup.file.displayName }?.submenu)
        let (added, saveAs, duplicate) = try simulateAppKitFileMenu(in: bar)
        let save = try #require(ZenitMenuBar.commandItems(in: bar).first { $0.commandID == .save })

        let previous = ZPDFCommandTable.effective
        ZPDFCommandTable.effective = .standard
        defer { ZPDFCommandTable.effective = previous }

        // The live sequence: rebind a shortcut in Settings ▸ Keyboard Shortcuts, then restore it.
        let rebound = ZPDFCommandTable.standard.applying(ZPDFShortcutOverrides(bindings: [
            ZPDFCommandID.save.rawValue: .character("s", [.command, .control])
        ]))
        ZenitShortcutSettings.apply(rebound, installedBar: bar)
        #expect(save.keyEquivalent == "s")
        #expect(save.keyEquivalentModifierMask == [.command, .control])
        ZenitShortcutSettings.apply(.standard, installedBar: bar)
        #expect(save.keyEquivalentModifierMask == [.command])

        // Old: `apply` built a new bar and installed it, so Open Recent, Duplicate, Rename…,
        // Move To… and Share were gone and ⇧⌘S did nothing.
        for row in added {
            #expect(row.menu === file, "\(row.title) left the File menu")
        }
        #expect(duplicate.keyEquivalent == "S" && duplicate.keyEquivalentModifierMask == [.command])
        #expect(duplicate.isAlternate)
        #expect(file.index(of: duplicate) == file.index(of: saveAs) + 1, "Duplicate still follows Save As")
        #expect(saveAs.keyEquivalent == "s" && saveAs.keyEquivalentModifierMask == [.command, .shift, .option])
        #expect(!saveAs.isAlternate)

        // Rebinding Save As and restoring it gives back what AppKit made of it — ⌥⇧⌘S — not
        // the table's ⇧⌘S, which AppKit gave to Duplicate.
        let saveAsRebound = ZPDFCommandTable.standard.applying(ZPDFShortcutOverrides(bindings: [
            ZPDFCommandID.saveAs.rawValue: .character("s", [.command, .control, .option])
        ]))
        ZenitShortcutSettings.apply(saveAsRebound, installedBar: bar)
        #expect(saveAs.keyEquivalentModifierMask == [.command, .control, .option])
        #expect(!saveAs.isAlternate)
        ZenitShortcutSettings.apply(.standard, installedBar: bar)
        #expect(saveAs.keyEquivalent == "s" && saveAs.keyEquivalentModifierMask == [.command, .shift, .option])
        #expect(!saveAs.isAlternate)
        #expect(ZenitMenuChord(menuItem: saveAs) != ZenitMenuChord(menuItem: duplicate), "Save As never takes Duplicate's ⇧⌘S")
        #expect(duplicate.keyEquivalent == "S" && duplicate.keyEquivalentModifierMask == [.command] && duplicate.isAlternate)
        #expect(file.index(of: duplicate) == file.index(of: saveAs) + 1)
    }

    @Test("L-44: a table row survives AppKit copying it")
    func commandRowsCopy() throws {
        let bar = ZenitMenuBar.make(table: .standard)
        let save = try #require(ZenitMenuBar.commandItems(in: bar).first { $0.commandID == .save })
        // A Swift subclass without the inherited initialiser traps on AppKit's first copy.
        let copy = try #require(save.copy() as? ZenitCommandMenuItem)
        #expect(copy.commandID == .save)
        #expect(copy.keyEquivalent == save.keyEquivalent)
        #expect(copy.title == save.title)
    }

    // MARK: - L-97 the shortcut reference

    @Test("L-97: Help ▸ Keyboard Shortcuts prints the chords the installed bar carries")
    func shortcutReferenceReadsTheInstalledBar() throws {
        let bar = ZenitMenuBar.make(table: .standard)
        _ = try simulateAppKitFileMenu(in: bar)
        let sections = KeyboardShortcutsReference.sections(table: .standard, menuBar: bar)
        let file = try #require(sections.first { $0.title == ZPDFCommandGroup.file.displayName })
        let saveAsTitle = try #require(ZPDFCommandTable.standard.command(.saveAs)?.title)
        // Old: Save As printed as "⇧⌘S" — the table's spelling, which the menu bar shows on
        // Duplicate — and Duplicate was not listed at all.
        #expect(file.entries.first { $0.title == saveAsTitle }?.shortcut == "⌥⇧⌘S")
        // AppKit's Duplicate is "S" with ⌘ alone in its mask; the upper case is the Shift.
        // Old (checker, on the real menu shape): "⌘S", the same text as Save.
        #expect(file.entries.first { $0.title == "Duplicate" }?.shortcut == "⇧⌘S")
        // An unchanged row keeps the table's spelling.
        let saveTitle = try #require(ZPDFCommandTable.standard.command(.save)?.title)
        #expect(file.entries.first { $0.title == saveTitle }?.shortcut == "⌘S")
        // No two File rows print the same chord.
        let chords = file.entries.filter { $0.context == nil }.map(\.shortcut)
        #expect(Set(chords).count == chords.count, "a chord is printed twice: \(chords)")
    }

    @Test("L-97: a menu row's upper-case key equivalent prints and compares with its implied ⇧")
    func upperCaseKeyEquivalentCarriesShift() {
        let duplicate = NSMenuItem(title: "Duplicate", action: nil, keyEquivalent: "S")
        duplicate.keyEquivalentModifierMask = [.command]
        #expect(KeyboardShortcutsReference.printed(duplicate) == "⇧⌘S")
        #expect(ZenitMenuChord(menuItem: duplicate) == ZenitMenuChord(key: "s", modifiers: [.command, .shift]))
        let alreadyShifted = NSMenuItem(title: "", action: nil, keyEquivalent: "S")
        alreadyShifted.keyEquivalentModifierMask = [.command, .shift]
        #expect(KeyboardShortcutsReference.printed(alreadyShifted) == "⇧⌘S")
        // Lower-case letters, digits, punctuation and control keys carry no implied Shift.
        let save = NSMenuItem(title: "Save", action: nil, keyEquivalent: "s")
        #expect(KeyboardShortcutsReference.printed(save) == "⌘S")
        let zoom = NSMenuItem(title: "Zoom In", action: nil, keyEquivalent: "=")
        #expect(KeyboardShortcutsReference.printed(zoom) == "⌘=")
        let bracket = NSMenuItem(title: "Previous", action: nil, keyEquivalent: "{")
        #expect(KeyboardShortcutsReference.printed(bracket) == "⌘{")
        let tab = NSMenuItem(title: "Next", action: nil, keyEquivalent: "\t")
        tab.keyEquivalentModifierMask = [.control]
        #expect(KeyboardShortcutsReference.printed(tab) == "⌃⇥")
    }

    @Test("L-97: the reference is two aligned columns, never a chord run into its name")
    func shortcutReferenceColumnsAreAligned() throws {
        let sections = KeyboardShortcutsReference.sections(table: .standard)
        let column = KeyboardShortcutsReference.titleColumn(for: sections)
        for entry in sections.flatMap(\.entries) {
            let width = (entry.shortcut as NSString).size(withAttributes: [.font: KeyboardShortcutsReference.font]).width
            #expect(width + KeyboardShortcutsReference.columnGap <= column + 0.5, "\(entry.shortcut) reaches the names")
        }
        let text = KeyboardShortcutsReference.attributedText(for: sections)
        let first = try #require(sections.first?.entries.first)
        let location = (text.string as NSString).range(of: first.title).location
        #expect(location != NSNotFound)
        let style = try #require(text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
        // Old: plain text in a monospaced face with the default 28 pt tab stops, so "⌥⌘N" ran
        // into "Show Navigator".
        #expect(style.tabStops.count == 2)
        #expect(style.tabStops.last?.location == column)
        #expect(style.tabStops.first?.alignment == .right)
        let font = try #require(text.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        #expect(!font.isFixedPitch)

        // The panel shows exactly this text.
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { _ in .dismissed }
        defer { ZenitModalPresenter.reset() }
        KeyboardShortcutsReference.show(menuBar: ZenitMenuBar.make(table: .standard))
        #expect(KeyboardShortcutsReference.textView?.string == text.string)
    }

    // MARK: - L-96 the second window's size

    @Test("L-96: Window ▸ New Window for Project opens at the main window's size, never below the minimum")
    func secondWindowOpensAtTheMainWindowsSize() async throws {
        let harness = try await Fix2Harness.make("L96 Second Window.pdf", calibrate: false)
        let main = try #require(harness.controller.window)
        main.setFrame(NSRect(x: 80, y: 160, width: 1_120, height: 700), display: false)
        let second = try #require(await harness.controller.openNewWindow(for: harness.document))
        defer {
            harness.document.unsavedTakeoffReview = { _, answer in answer(.discard) }
            second.window?.close()
            harness.tearDown()
        }
        #expect(await AppTestSupport.wait { second.canvasController(for: harness.document) != nil })
        let window = try #require(second.window)
        #expect(window.isVisible == false)
        // Old: 1 × 1 here (864 × 526 in the installed build) — the frame the loading
        // placeholder's zero fitting size gave it, because the frame autosave name it would
        // have restored from is held by the first window.
        #expect(window.frame.size == main.frame.size)
        #expect(window.frame.width >= 1_040 && window.frame.height >= 640)
        #expect(window.minSize.width >= 1_040 && window.minSize.height >= 640)
        // Cascaded from the main window, not stacked exactly over it.
        #expect(window.frame.origin != main.frame.origin)
    }

    @Test("L-96: the second window's frame rule, by hand")
    func secondWindowFrameRule() {
        let minimum = NSSize(width: 1_040, height: 640)
        let screen = NSRect(x: 0, y: 25, width: 1_512, height: 920)
        // The source's size, one title bar down and to the right.
        #expect(ProjectWindowController.secondWindowFrame(
            from: NSRect(x: 100, y: 100, width: 1_300, height: 800), minimum: minimum, visible: screen
        ) == NSRect(x: 124, y: 76, width: 1_300, height: 800))
        // A source under the minimum (a window restored small) still opens at the minimum.
        #expect(ProjectWindowController.secondWindowFrame(
            from: NSRect(x: 100, y: 200, width: 864, height: 526), minimum: minimum, visible: screen
        ).size == minimum)
        // Kept inside the visible area: 224 + 1 300 would pass the right edge (1 512), so x is
        // 1 512 − 1 300 = 212; 40 − 24 would pass the bottom (25), so y is 25.
        #expect(ProjectWindowController.secondWindowFrame(
            from: NSRect(x: 200, y: 40, width: 1_300, height: 800), minimum: minimum, visible: screen
        ) == NSRect(x: 212, y: 25, width: 1_300, height: 800))
        // No source window: the default size, centred.
        #expect(ProjectWindowController.secondWindowFrame(from: nil, minimum: minimum, visible: screen)
                == NSRect(x: 76, y: 55, width: 1_360, height: 860))
    }

    // MARK: - L-39 and L-98 the welcome guide

    @Test("L-39: the welcome card names the Help menu item that really brings it back")
    func welcomeCardNamesARealHelpItem() throws {
        let help = try #require(ZenitMenuBar.specialMenu(.help, in: ZenitMenuBar.make()))
        let hint = OnboardingFlow.reopenHint
        let named = try #require(hint.components(separatedBy: "Help ▸ ").last)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // Old: "… from Help ▸ Getting Started." — the Help menu has no item by that name.
        let item = try #require(help.items.first { $0.title == named }, "no Help item is titled “\(named)”")
        #expect(item.action == #selector(ZenitOnboardingController.showWelcome(_:)))
    }

    @Test("L-98: Help ▸ Welcome shows the guide over the front window, even on a drawing that proves every step")
    func welcomeComesBackOverTheFrontWindow() async throws {
        let harness = try await Fix2Harness.make("L98 Welcome.pdf", calibrate: true)
        defer { harness.tearDown() }
        _ = try await harness.addMarkup(tool: .length) { page in
            MeasurementGeometry(pageID: page, points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100)])
        }
        if !harness.shell.isSurfaceVisible(.quantityLedger) { harness.shell.perform(.toggleQuantityLedger) }
        await harness.core.refresh()

        let onboarding = ZenitOnboardingController(store: InMemoryOnboardingProgressStore())
        let previous = ZenitOnboardingController.frontProjectWindow
        ZenitOnboardingController.frontProjectWindow = { (harness.document, harness.controller) }
        defer { ZenitOnboardingController.frontProjectWindow = previous }
        #expect(onboarding.hostWindow == nil, "precondition: never attached, like a guide whose window has closed")
        let proven = try #require(onboarding.provenSteps(of: harness.document))
        #expect(proven == Set(OnboardingStep.allCases), "precondition: the drawing proves every step: \(proven)")

        // The Help menu item's own action.
        onboarding.showWelcome(nil)
        // Old: the card stood on the window the last drawing was attached to (none here, a
        // closed second window live), and the restart completed all four proven steps at once,
        // which puts the card away — `isVisible` was false and nothing appeared.
        #expect(onboarding.hostWindow === harness.controller.window)
        #expect(onboarding.model.isVisible)
        #expect(onboarding.model.completedSteps == Set(OnboardingStep.allCases))
        #expect(onboarding.model.onPerformStep != nil, "the step buttons act in the front window")
        #expect(onboarding.panel == nil, "a test process never draws the card")
    }

    @Test("L-98: restarting the guide ticks what is proven and keeps the card up")
    func restartKeepsTheCardUp() {
        let onboarding = ZenitOnboardingController(store: InMemoryOnboardingProgressStore())
        onboarding.restart(proven: [.openDrawing])
        #expect(onboarding.model.isVisible)
        #expect(onboarding.model.currentStep == .calibrateScale)
        onboarding.restart(proven: Set(OnboardingStep.allCases))
        #expect(onboarding.model.isVisible)
        onboarding.restart(proven: [])
        #expect(onboarding.model.completedSteps.isEmpty)
        #expect(onboarding.model.currentStep == .openDrawing)
    }

    // MARK: - L-35 and L-107 the Settings window

    /// Every visible view under `root`, with its frame in `root`'s coordinates.
    private func descendantFrames(of root: NSView) -> [(view: NSView, frame: NSRect)] {
        var found: [(NSView, NSRect)] = []
        func walk(_ view: NSView) {
            for child in view.subviews where !child.isHidden {
                found.append((child, child.convert(child.bounds, to: root)))
                walk(child)
            }
        }
        walk(root)
        return found
    }

    @Test("L-35 / L-107: every Settings section lies inside the scrolling column, and the window can be resized")
    func settingsContentFitsTheColumn() throws {
        let settings = ZenitSettingsWindowController()
        let window = try #require(settings.window)
        #expect(!window.isVisible)
        // The command as the installed application shows it.
        settings.platformPanel.commandLineField.stringValue =
            PlatformSettingsPanel.installCommand(appURL: URL(fileURLWithPath: "/Applications/Zenit PDF.app"))
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()

        let scroll = try #require(window.contentView as? NSScrollView)
        let document = try #require(scroll.documentView)
        let width = scroll.contentView.bounds.width
        let frames = descendantFrames(of: document)
        let heading = try #require(frames.first { ($0.view as? NSTextField)?.stringValue == "Command-Line Tool" })
        // Old: the command line's single-line width pushed the column past the window, so its
        // stack was shifted left — the heading read "ommand-Line Tool" (minX < 0) and the
        // command ran past the right edge.
        #expect(heading.frame.minX >= 0, "the heading is clipped at the left: \(heading.frame)")
        for (view, frame) in frames where frame.width > 0 {
            #expect(frame.minX >= -0.5 && frame.maxX <= width + 0.5,
                    "\(type(of: view)) \((view as? NSTextField)?.stringValue ?? "") lies outside the column: \(frame) in \(width)")
        }
        let command = try #require(frames.first { $0.view === settings.platformPanel.commandLineField })
        #expect(command.frame.maxX <= width)
        let shown: String = settings.platformPanel.commandLineField.stringValue
        #expect(shown.contains("/Applications/Zenit PDF.app"), "the whole command is shown, never cut short")

        // Old: the last sections stayed below the bottom edge — the column was shorter than its
        // content, so scrolling stopped before them.
        let lowest = frames.map { $0.frame.maxY }.max() ?? 0
        #expect(document.frame.height >= lowest - 0.5, "content below the scrollable height: \(lowest) > \(document.frame.height)")
        // Command-Line Tool is the last section; its Copy Command button is the last control.
        let copyButton = settings.platformPanel.copyCommandButton
        let last = try #require(frames.first { $0.view === copyButton })
        #expect(last.frame.maxY <= document.frame.height + 0.5)
        // Scrolled to the end, the last control is inside the visible part.
        #expect(document.frame.origin == .zero, "the column starts at the clip view's corner: \(document.frame)")
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - clip.bounds.height)))
        scroll.reflectScrolledClipView(clip)
        let lastControl = copyButton.convert(copyButton.bounds, to: clip)
        #expect(clip.bounds.contains(lastControl), "the last control is out of reach at the end of the scroll: \(lastControl) in \(clip.bounds)")

        // Old: titled and closable only — the window could not be made taller to show them.
        #expect(window.styleMask.contains(.resizable))
        #expect(window.contentMinSize.width >= 480)
    }

    // MARK: - L-40 File ▸ New

    @Test("L-40: File ▸ New Project… starts from a drawing, never an empty untitled project")
    func newProjectStartsFromADrawing() async throws {
        let bar = ZenitMenuBar.make()
        let file = try #require(bar.items.first { $0.submenu?.title == ZPDFCommandGroup.file.displayName }?.submenu)
        let new = try #require(file.items.first)
        // Old: "New", ⌘N, `newDocument(_:)` — an untitled Project Mode document with no drawing,
        // which could not be saved, filled or combined into.
        #expect(new.title == "New Project…")
        #expect(new.keyEquivalent == "n" && new.keyEquivalentModifierMask == [.command])
        #expect(new.action == #selector(ZenitDocumentController.newProjectFromDrawing(_:)))
        #expect(new.action != #selector(NSDocumentController.newDocument(_:)))
        #expect(ZenitDocumentController.instancesRespond(to: try #require(new.action)))

        // The chooser offers drawings only: never a project, never a data file.
        let types = NewProjectFromDrawing.drawingContentTypes
        #expect(types.contains(.pdf))
        #expect(!types.contains(ZenitAppInfo.projectType))

        let url = try AppTestSupport.writeFixturePDF(named: "L40 New Project.pdf")
        let document = try AppTestSupport.makeDocument(opening: url)
        defer {
            document.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let previousOpener = NewProjectFromDrawing.drawingOpener
        NewProjectFromDrawing.drawingOpener = { _ in (document, false) }
        defer { NewProjectFromDrawing.drawingOpener = previousOpener }
        ZenitModalPresenter.reset()
        defer { ZenitModalPresenter.reset() }
        ZenitModalPresenter.handler = { request in
            request.identifier == NewProjectFromDrawing.drawingChooserIdentifier ? .urls([url]) : .dismissed
        }

        // The command's whole path: the chooser through the modal door, then the drawing opens
        // and Create Zenit PDF Project asks where to keep the project.
        NewProjectFromDrawing.run(window: nil)
        #expect(ZenitModalPresenter.didRequest(NewProjectFromDrawing.drawingChooserIdentifier))
        #expect(await AppTestSupport.wait {
            ZenitModalPresenter.didRequest(ZenitPDFProjectDocument.appKitSavePanelModalIdentifier)
        }, "Create Zenit PDF Project ran on the chosen drawing")
        #expect(document.drawing != nil, "the project has its drawing")
        #expect(await NewProjectFromDrawing.start(fromDrawingAt: url) == .creatingProject)
    }

    @Test("L-40: the first drawing opened into the start window takes the empty untitled document's place")
    func firstDrawingReplacesTheStartDocument() async throws {
        let previousTabHost = ProjectWindowController.tabHost
        let previousProbe = ProjectWindowController.hostWindowVisibilityForTesting
        defer {
            ProjectWindowController.tabHost = previousTabHost
            ProjectWindowController.hostWindowVisibilityForTesting = previousProbe
        }
        // A launch with nothing to reopen: AppKit's untitled document, in a window of its own.
        ProjectWindowController.hostWindowVisibilityForTesting = { _ in false }
        let start = ZenitPDFProjectDocument()
        start.makeWindowControllers()
        let host = try #require(start.windowControllers.first as? ProjectWindowController)
        #expect(await AppTestSupport.wait { start.core != nil && !start.isLoading })
        #expect(start.isUntouchedStartDocument)
        #expect(host.documents.count == 1)
        // Live the start window is on screen; a test may not put it there, so the visibility
        // half of `canHostAdditionalDocuments` is injected.
        ProjectWindowController.hostWindowVisibilityForTesting = { $0 === host }

        let url = try AppTestSupport.writeFixturePDF(named: "L40 First Drawing.pdf")
        let drawing = ZenitPDFProjectDocument()
        defer {
            host.window?.close()
            drawing.close()
            if !start.isClosed { start.close() }
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        // The document controller's own sequence for ⌘O, Open Recent or a dropped file.
        try drawing.read(from: url, ofType: UTType.pdf.identifier)
        drawing.makeWindowControllers()
        #expect(drawing.hostWindowController === host, "precondition: the drawing joined the start window")
        #expect(await AppTestSupport.wait { drawing.drawing != nil && drawing.shell != nil })

        // Old: the empty "Untitled" stayed beside the drawing as a second tab — Save refused
        // it, nothing could be added to it, and Combine Open Drawings on it posted "Save this
        // takeoff as a project first…", which nobody could do there.
        #expect(await AppTestSupport.wait { host.documents.count == 1 }, "the empty start tab is still there")
        #expect(host.documents.first === drawing)
        #expect(start.isClosed)
        #expect(host.activeDocument === drawing)
        #expect(host.document === drawing, "the window now belongs to the drawing")
        #expect(host.window?.isVisible == false, "a test never orders the window on screen")
        #expect(await AppTestSupport.wait { drawing.core?.document.tabs.count == 1 }, "the tab strip lists only the drawing")
    }

    @Test("L-40: a drawing that fails to open leaves the start window as it was")
    func failedOpenKeepsTheStartDocument() async throws {
        let previousTabHost = ProjectWindowController.tabHost
        let previousProbe = ProjectWindowController.hostWindowVisibilityForTesting
        defer {
            ProjectWindowController.tabHost = previousTabHost
            ProjectWindowController.hostWindowVisibilityForTesting = previousProbe
        }
        ProjectWindowController.hostWindowVisibilityForTesting = { _ in false }
        let start = ZenitPDFProjectDocument()
        start.makeWindowControllers()
        let host = try #require(start.windowControllers.first as? ProjectWindowController)
        #expect(await AppTestSupport.wait { start.core != nil && !start.isLoading })
        ProjectWindowController.hostWindowVisibilityForTesting = { $0 === host }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-l40-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = directory.appendingPathComponent("L40 Not A Drawing.pdf")
        try Data("not a pdf".utf8).write(to: garbage)
        ZenitModalPresenter.reset()
        ZenitModalPresenter.handler = { _ in .dismissed }
        let broken = ZenitPDFProjectDocument()
        defer {
            ZenitModalPresenter.reset()
            host.window?.close()
            if !broken.isClosed { broken.close() }
            if !start.isClosed { start.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        try broken.read(from: garbage, ofType: UTType.pdf.identifier)
        broken.makeWindowControllers()
        #expect(await AppTestSupport.wait { !broken.isLoading && broken.loadFailure != nil })
        #expect(await AppTestSupport.wait { !host.documents.contains { $0 === broken } })
        // The start document is replaced only by a drawing that arrived.
        #expect(!start.isClosed)
        #expect(host.documents.count == 1 && host.documents.first === start)
    }

    @Test("L-40: Combine Open Drawings needs a drawing in front, and on a start tab it says what to do")
    func combineNeedsADrawingInFront() async throws {
        let harness = try await Fix2Harness.make("L40 Combine.pdf", calibrate: false)
        defer { harness.tearDown() }
        // `zenitpdf://new` with a drawing open: the start document joins as a tab after it,
        // and no drawing arrives after it to take its place.
        let start = ZenitPDFProjectDocument()
        harness.controller.attach(document: start)
        start.startLoadingIfNeeded()
        defer { if !start.isClosed { harness.controller.closeReviewedDocumentKeepingWindow(start) } }
        #expect(await AppTestSupport.wait { start.core != nil && !start.isLoading })
        #expect(harness.controller.documents.count == 2)
        #expect(harness.controller.activeDocument === start)

        let state = ZenitAppCommandWindowState(controller: harness.controller)
        // Old rule (`.severalTabs`): enabled here, two tabs.
        #expect(!ZenitAppCommandTable.validate(.combineOpenDrawings, item: nil, state: state),
                "Combine is offered on a tab with no drawing to combine into")
        harness.controller.activateTab(id: harness.document.documentIdentity)
        #expect(ZenitAppCommandTable.validate(.combineOpenDrawings, item: nil, state: state),
                "the drawing's own tab offers it")

        // Reached anyway — the start tab's Navigator ⋯ menu — it names what to do.
        // Old: "Save this takeoff as a project first, then combine…", and Save refuses this tab.
        #expect(await start.combine(openDrawings: [harness.document]) == 0)
        #expect(start.core?.status.snapshot.activeToolNote == ZenitPDFProjectDocument.combineNeedsADrawingNote)
        #expect(ZenitPDFProjectDocument.combineNeedsADrawingNote.contains("Bring forward the drawing"))
    }

    // MARK: - L-33 Open Recent

    @Test("L-33: Open Recent rows read with single spaces")
    func openRecentTitlesAreTidied() throws {
        #expect(OpenRecentTitleTidier.tidied("Plan-A.pdf —  live8") == "Plan-A.pdf — live8")
        #expect(OpenRecentTitleTidier.tidied("Plan-A.pdf  — live8") == "Plan-A.pdf — live8")
        #expect(OpenRecentTitleTidier.tidied("Plan B.pdf") == "Plan B.pdf")

        let bar = ZenitMenuBar.make()
        let file = try #require(bar.items.first { $0.submenu?.title == ZPDFCommandGroup.file.displayName }?.submenu)
        // AppKit's Open Recent, as it inserts it after Open… at launch.
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: ""))
        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecent.submenu = recent
        file.insertItem(openRecent, at: 2)

        let tidier = OpenRecentTitleTidier()
        defer { tidier.stop() }
        tidier.watch(bar)
        #expect(tidier.recentMenu === recent)
        // AppKit fills the submenu as files are opened. Old: the row kept AppKit's
        // "Plan-A.pdf —  live8", two spaces after the dash.
        let row = NSMenuItem(title: "Plan-A.pdf —  live8", action: nil, keyEquivalent: "")
        recent.insertItem(row, at: 0)
        #expect(row.title == "Plan-A.pdf — live8")
        row.title = "Plan-A.pdf —  live8 copy"
        #expect(row.title == "Plan-A.pdf — live8 copy")
        let styled = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        styled.attributedTitle = NSAttributedString(string: "Plan-B.pdf —  live8", attributes: [.font: NSFont.menuFont(ofSize: 0)])
        recent.insertItem(styled, at: 1)
        #expect(styled.attributedTitle?.string == "Plan-B.pdf — live8")
        #expect(recent.items.last?.title == "Clear Menu")
    }

    // MARK: - L-78 the Takeoff Assistant Inbox and the Edit menu

    @Test("L-78: the Takeoff Assistant Inbox never takes the Edit menu from the drawing behind it")
    func inboxLeavesTheEditMenuToTheDrawing() async throws {
        let harness = try await Fix2Harness.make("L78 Inbox.pdf", calibrate: false)
        defer {
            AssistantInboxWindow.forget(harness.controller)
            harness.tearDown()
        }
        let panel = AssistantInboxWindow.present(for: harness.controller, document: harness.document)
        #expect(!panel.isVisible, "a test never orders the panel on screen")
        // Old: a plain NSPanel made key on open — the Edit menu's actions went to it first, and
        // its own empty undo manager and the hosting view disabled Undo, Redo and Copy.
        #expect(panel.becomesKeyOnlyIfNeeded, "pressing Accept or picking a row leaves the project window key")
        #expect(!panel.canBecomeMain)
        let undo = try #require(harness.document.undoManager)
        #expect(panel.undoManager === undo, "when it is key, Undo and Redo still act on the drawing")
        // The same panel comes back for the same drawing, with the same rules.
        #expect(AssistantInboxWindow.present(for: harness.controller, document: harness.document) === panel)
    }

    /// Old: a plain `NSPanel` made key on open, like the Inbox before L-78 — Undo, Redo and Copy
    /// in the Edit menu went to its own empty undo manager while the Review List was in front.
    @Test("L-78: the Review List never takes the Edit menu from the drawing behind it")
    func reviewListLeavesTheEditMenuToTheDrawing() async throws {
        let harness = try await Fix2Harness.make("L78 Review.pdf", calibrate: false)
        defer {
            ReviewListWindow.forget(harness.controller)
            harness.tearDown()
        }
        let panel = try #require(ReviewListWindow.present(for: harness.controller, document: harness.document))
        #expect(!panel.isVisible, "a test never orders the panel on screen")
        #expect(panel is DocumentUtilityPanel)
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.canBecomeMain)
        let undo = try #require(harness.document.undoManager)
        #expect(panel.undoManager === undo, "when it is key, Undo and Redo still act on the drawing")
        #expect(ReviewListWindow.present(for: harness.controller, document: harness.document) === panel)
    }
}
