import AppKit
import ZPDFAppCore
import ZPDFUIPresentation

/// Settings.
///
/// **General ▸ Appearance**: Dark (the default, the 2026-09-23 design's chrome), Light, or
/// Match System. Applied at once to the application and every open window, and remembered.
///
/// **General ▸ Author name**: changing it affects **new** entries
/// only — history is append-only (ADR-0007), so past rows keep the name that made them; the
/// consumers read the preference at record time. The copy says so, together with the
/// local-first privacy promise.
///
/// There is no Updates section: Zenit PDF has no updater and makes no network connection. A
/// newer version is installed by downloading it from the project's releases page.
@MainActor
public final class ZenitSettingsWindowController: NSWindowController, NSWindowDelegate {

    public static let shared = ZenitSettingsWindowController()

    /// The General ▸ Author name field, reachable so tests can drive an edit.
    public let authorField = NSTextField(string: "")

    /// General ▸ Appearance: Dark, Light, Match System, in ``ZenitAppearancePreference`` order.
    public let appearancePopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    /// Where the appearance choice is stored. The process store (scratch outside the assembled
    /// bundle); a test injects its own.
    var appearanceDefaults: any ZPDFDefaultsStoring = ZenitAppearancePreference.processDefaults

    /// What a changed appearance is installed on: the application and its windows. A test
    /// injects a window that is never shown, so choosing Light cannot repaint the user's screen.
    var appearanceTargets: () -> [any NSAppearanceCustomization] = {
        [NSApplication.shared as any NSAppearanceCustomization]
            + NSApplication.shared.windows.map { $0 as any NSAppearanceCustomization }
    }

    /// Canvas ▸ "Mouse wheel zooms" (NL-UX-14), reachable so tests can drive the exact action
    /// it sends. One per controller, like every other control here: a single shared button was
    /// moved into whichever controller built its Canvas section last, so a private controller
    /// (the test seam below) took it out of the shipping Settings window and re-targeted it (K-13).
    let wheelZoomsCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    /// r2-platform: Identity (company, colour), Office library and Command-line tool
    /// (Platform/PlatformSettingsPanel.swift).
    let platformPanel = PlatformSettingsPanel()

    /// ``shared`` for the application; a test makes its own, so it never touches the Settings
    /// window a person might have open.
    init() {
        super.init(window: Self.makeWindow())
        finishSetUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The width of the Settings column: every note, separator and wide control is this wide,
    /// and the window is the column plus its 20 pt margins.
    static let columnWidth: CGFloat = 420

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            // Resizable (L-107): the sections outgrew 620 pt, and a window that could not be made
            // taller left the last sections to a scroll that stopped short of them.
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = NSLocalizedString("Settings", comment: "Settings window title")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: columnWidth + 60, height: 360)
        return window
    }

    private func finishSetUp() {
        window?.delegate = self
        window?.contentView = makeContentView()
        // ⌘Q sends no windowWillClose, and a name typed without Return was lost (BH-876).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        commitAuthorNameIfEdited()
    }

    /// Commits the field when it differs from the stored name — the quit path's commit.
    public func commitAuthorNameIfEdited() {
        let typed = authorField.currentEditor()?.string ?? authorField.stringValue
        guard typed != AuthorIdentity.current() else { return }
        authorField.stringValue = typed
        commitAuthorName()
    }

    /// Whether reopening Settings keeps what is in the name field: only while the window is
    /// already up and the field is being edited (BH-875).
    nonisolated static func keepsTypedName(windowVisible: Bool, isEditing: Bool) -> Bool {
        windowVisible && isEditing
    }

    /// The app-menu action (⌘,).
    @objc public func showSettings(_ sender: Any?) {
        // An open window with a name being typed keeps the typing: ⌘, again used to reset
        // the field to the stored value mid-edit (BH-875).
        if !Self.keepsTypedName(windowVisible: window?.isVisible ?? false,
                                isEditing: authorField.currentEditor() != nil) {
            authorField.stringValue = AuthorIdentity.current()
        }
        authorField.placeholderString = AuthorIdentity.machineDefault
        window?.center()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    /// Writes the field into the preference. An empty field falls back to the machine
    /// default, exactly as ``AuthorIdentity/set(_:)`` documents.
    public func commitAuthorName() {
        AuthorIdentity.set(authorField.stringValue)
        authorField.stringValue = AuthorIdentity.current()
    }

    public func windowWillClose(_ notification: Notification) {
        commitAuthorName()
        platformPanel.companyCommitted(nil)
    }

    // MARK: - Layout

    private func makeContentView() -> NSView {
        // nl-ux: Canvas ("Mouse wheel zooms") and the shortcut and welcome-guide doors, UX/SettingsCanvasSection.swift.
        // nl-markup: Markup tools (tool style memory), Markup/SettingsMarkupSection.swift.
        // r2-measure: Measuring (double-count guard), Measure/SettingsMeasureSection.swift.
        // r2-platform: Identity, Office Library and Command-Line Tool (Platform/PlatformSettingsPanel.swift);
        // the sections outgrew the window, so the stack scrolls.
        let stack = NSStackView(views: [
            generalSection(), separator(),
            section(titled: NSLocalizedString("Identity", comment: "Settings section title"), views: platformPanel.identityViews()), separator(),
            canvasSection(), separator(), measuringSection(), separator(), markupSection(), separator(),
            section(titled: NSLocalizedString("Office Library", comment: "Settings section title"), views: platformPanel.libraryViews()
                + [wrappingNote(NSLocalizedString("Tool sets (.zpdftools) in this folder appear read-only in the Tool Library and update when the files change. Duplicate a tool to edit your own copy. Markups already placed never change.", comment: "Settings note under the office library folder"))]),
            separator(),
            section(titled: NSLocalizedString("Command-Line Tool", comment: "Settings section title"), views: platformPanel.commandLineViews()
                + [wrappingNote(NSLocalizedString("zenit reads projects without opening the app: totals, exports and an integrity check. Run this command once in Terminal to use it by name.", comment: "Settings note under the command-line tool"))])
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = document
        // The column is pinned to the clip view's top and leading edge as well as its width.
        // With only the width tied, the document view's origin was left to whatever the layout
        // pass found, and a section wider than the window (the command line, L-35) pushed the
        // whole column left — "ommand-Line Tool" — and left its height short of its content, so
        // the scroll stopped above the last sections (L-107).
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true
        return line
    }

    private func generalSection() -> NSView {
        let nameLabel = NSTextField(labelWithString: NSLocalizedString(
            "Author name:", comment: "Settings label for the author name field"
        ))
        authorField.stringValue = AuthorIdentity.current()
        authorField.placeholderString = AuthorIdentity.machineDefault
        authorField.target = self
        authorField.action = #selector(authorFieldCommitted(_:))

        let note = wrappingNote(NSLocalizedString(
            "New measurements and history entries are signed with this name. Entries already made keep the name that made them. The name never leaves this Mac except inside project files and exports you share.",
            comment: "Settings note under the author name field"
        ))

        let row = NSStackView(views: [nameLabel, authorField])
        row.orientation = .horizontal
        row.spacing = 8
        authorField.translatesAutoresizingMaskIntoConstraints = false
        authorField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let appearanceLabel = NSTextField(labelWithString: NSLocalizedString(
            "Appearance:", comment: "Settings label for the appearance popup"
        ))
        appearancePopUp.removeAllItems()
        appearancePopUp.addItems(withTitles: ZenitAppearancePreference.allCases.map(\.title))
        appearancePopUp.target = self
        appearancePopUp.action = #selector(appearanceChosen(_:))
        appearancePopUp.setAccessibilityLabel(NSLocalizedString(
            "Appearance", comment: "Accessibility label for the Settings appearance popup"
        ))
        refreshAppearancePopUp()
        let appearanceRow = NSStackView(views: [appearanceLabel, appearancePopUp])
        appearanceRow.orientation = .horizontal
        appearanceRow.spacing = 8

        return section(titled: NSLocalizedString("General", comment: "Settings section title"),
                       views: [row, note, appearanceRow])
    }

    /// Shows the stored appearance choice in the popup.
    public func refreshAppearancePopUp() {
        let stored = ZenitAppearancePreference.load(from: appearanceDefaults)
        if let index = ZenitAppearancePreference.allCases.firstIndex(of: stored) {
            appearancePopUp.selectItem(at: index)
        }
    }

    /// The appearance currently chosen in the popup.
    public var selectedAppearance: ZenitAppearancePreference {
        let index = appearancePopUp.indexOfSelectedItem
        let all = ZenitAppearancePreference.allCases
        return all.indices.contains(index) ? all[index] : ZenitAppearancePreference.defaultValue
    }

    /// Stores the popup's choice and installs it everywhere at once.
    @objc public func appearanceChosen(_ sender: Any?) {
        let choice = selectedAppearance
        choice.save(to: appearanceDefaults)
        for target in appearanceTargets() { choice.apply(to: target) }
    }

    func section(titled title: String, views: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    func wrappingNote(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        note.preferredMaxLayoutWidth = Self.columnWidth
        note.widthAnchor.constraint(equalToConstant: Self.columnWidth).isActive = true
        return note
    }

    @objc private func authorFieldCommitted(_ sender: Any?) {
        commitAuthorName()
    }
}


/// The scrolling Settings content grows downwards from the top.
private final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
