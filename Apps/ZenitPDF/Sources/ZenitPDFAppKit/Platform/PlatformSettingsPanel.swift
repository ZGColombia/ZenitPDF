import AppKit
import ZPDFAppCore
import ZPDFUIPresentation

/// Settings ▸ Identity, Office library and Command-line tool (NL-COLLAB-05, NL-PLAT-15,
/// NL-PLAT-13). Built here and placed by ``ZenitSettingsWindowController``.
///
/// - **Identity**: the company that goes with the author name, and the author colour. Both are
///   app-level preferences like the name, and both travel only inside projects and exports the
///   person shares. The author id behind them is random and made once.
/// - **Office library**: the folder whose `.zpdftools` sets are listed read-only in the Tool
///   Library and kept up to date (``SubscribedToolLibrary``).
/// - **Command-line tool**: where `zenit` is inside the application and the one line that makes
///   it a command. A sandboxed application cannot write into `/usr/local/bin` itself, so it
///   says what to type instead of pretending to install.
@MainActor
final class PlatformSettingsPanel: NSObject {

    /// Identity ▸ Company.
    let companyField = NSTextField(string: "")
    /// Identity ▸ Colour.
    let colorPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Office library ▸ the folder in use, or "None".
    let libraryFolderLabel = NSTextField(labelWithString: "")
    let chooseLibraryButton = NSButton(title: "", target: nil, action: nil)
    let stopLibraryButton = NSButton(title: "", target: nil, action: nil)
    /// Command-line tool ▸ the install command.
    let commandLineField = NSTextField(labelWithString: "")
    let copyCommandButton = NSButton(title: "", target: nil, action: nil)

    /// Where the subscription is kept; the shared one in the app, an isolated one in a test.
    var library: SubscribedToolLibrary = .shared

    /// The folder chooser. Injectable so a test answers it; the shipping value is an open panel
    /// through ``ZenitModalPresenter``.
    var chooseFolder: @MainActor (NSWindow?) async -> URL? = { window in
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.message = NSLocalizedString("Choose the folder that holds your office's tool sets (.zpdftools).", comment: "Office library folder chooser message")
            ZenitModalPresenter.runOpenPanel(panel, identifier: PlatformSettingsPanel.chooseFolderIdentifier, sheetedOn: window) { answer in
                continuation.resume(returning: answer.firstURL)
            }
        }
    }

    static let chooseFolderIdentifier = "settings.officeLibraryFolder"

    /// The palette the colour popup offers after "Automatic": the named markup palette, stored as
    /// `#RRGGBBAA` so the preference is plain text.
    static var colorChoices: [(name: String, hex: String)] {
        ZenitNamedPalette.entries.map { ($0.name, hex($0.color)) }
    }

    nonisolated static func hex(_ color: ColorRGBA) -> String {
        func byte(_ value: Double) -> String { String(format: "%02X", Int((max(0, min(1, value)) * 255).rounded())) }
        return "#" + byte(color.red) + byte(color.green) + byte(color.blue) + byte(color.alpha)
    }

    // MARK: - Sections

    func identityViews() -> [NSView] {
        let companyLabel = NSTextField(labelWithString: NSLocalizedString("Company:", comment: "Settings label for the company field"))
        companyField.stringValue = AuthorIdentity.company() ?? ""
        companyField.placeholderString = NSLocalizedString("Optional", comment: "Placeholder of an optional Settings field")
        companyField.target = self
        companyField.action = #selector(companyCommitted(_:))
        companyField.setAccessibilityLabel(NSLocalizedString("Company", comment: "Accessibility label of the company field"))
        companyField.translatesAutoresizingMaskIntoConstraints = false
        companyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        let companyRow = NSStackView(views: [companyLabel, companyField])
        companyRow.orientation = .horizontal
        companyRow.spacing = 8

        let colorLabel = NSTextField(labelWithString: NSLocalizedString("Author colour:", comment: "Settings label for the author colour popup"))
        colorPopUp.removeAllItems()
        colorPopUp.addItem(withTitle: NSLocalizedString("Automatic", comment: "Author colour: the palette's choice"))
        for choice in Self.colorChoices { colorPopUp.addItem(withTitle: choice.name) }
        colorPopUp.target = self
        colorPopUp.action = #selector(colorChosen(_:))
        colorPopUp.setAccessibilityLabel(NSLocalizedString("Author colour", comment: "Accessibility label of the author colour popup"))
        refreshColorPopUp()
        let colorRow = NSStackView(views: [colorLabel, colorPopUp])
        colorRow.orientation = .horizontal
        colorRow.spacing = 8
        return [companyRow, colorRow]
    }

    func libraryViews() -> [NSView] {
        chooseLibraryButton.title = NSLocalizedString("Choose Folder…", comment: "Settings: choose the office library folder")
        chooseLibraryButton.bezelStyle = .rounded
        chooseLibraryButton.target = self
        chooseLibraryButton.action = #selector(chooseLibrary(_:))
        stopLibraryButton.title = NSLocalizedString("Stop Using", comment: "Settings: stop the office library subscription")
        stopLibraryButton.bezelStyle = .rounded
        stopLibraryButton.target = self
        stopLibraryButton.action = #selector(stopLibrary(_:))
        refreshLibrary()
        let buttons = NSStackView(views: [chooseLibraryButton, stopLibraryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        return [libraryFolderLabel, buttons]
    }

    func commandLineViews() -> [NSView] {
        commandLineField.stringValue = Self.installCommand(appURL: Bundle.main.bundleURL)
        commandLineField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        commandLineField.isSelectable = true
        // Wrapped inside the Settings column, whole (L-35). On one line the command was wider
        // than the window: it ran past the right edge and pushed the section left until its
        // heading read "ommand-Line Tool". Truncating it would hide the path it links.
        commandLineField.usesSingleLineMode = false
        commandLineField.cell?.wraps = true
        commandLineField.cell?.isScrollable = false
        commandLineField.maximumNumberOfLines = 0
        commandLineField.lineBreakMode = .byCharWrapping
        commandLineField.preferredMaxLayoutWidth = ZenitSettingsWindowController.columnWidth
        commandLineField.translatesAutoresizingMaskIntoConstraints = false
        commandLineField.widthAnchor.constraint(equalToConstant: ZenitSettingsWindowController.columnWidth).isActive = true
        commandLineField.setAccessibilityLabel(NSLocalizedString("Command that installs the command-line tool", comment: "Accessibility label of the CLI install command"))
        copyCommandButton.title = NSLocalizedString("Copy Command", comment: "Settings: copy the CLI install command")
        copyCommandButton.bezelStyle = .rounded
        copyCommandButton.target = self
        copyCommandButton.action = #selector(copyCommand(_:))
        return [commandLineField, copyCommandButton]
    }

    // MARK: - State

    func refreshColorPopUp() {
        let stored = AuthorIdentity.colorHex()
        let index = Self.colorChoices.firstIndex { $0.hex == stored }.map { $0 + 1 } ?? 0
        colorPopUp.selectItem(at: index)
    }

    func refreshLibrary() {
        if let folder = library.folder {
            libraryFolderLabel.stringValue = String(format: NSLocalizedString("Folder: %@", comment: "Settings: the office library folder in use"), folder.path)
            stopLibraryButton.isEnabled = true
        } else {
            libraryFolderLabel.stringValue = NSLocalizedString("No office library folder.", comment: "Settings: no office library folder")
            stopLibraryButton.isEnabled = false
        }
    }

    /// The line that links the bundled tool into the person's PATH.
    nonisolated static func installCommand(appURL: URL) -> String {
        let tool = appURL.appendingPathComponent("Contents/Helpers/zenit").path
        return "sudo ln -sf '\(tool.replacingOccurrences(of: "'", with: "'\\''"))' /usr/local/bin/zenit"
    }

    // MARK: - Actions

    @objc func companyCommitted(_ sender: Any?) {
        AuthorIdentity.setCompany(companyField.stringValue)
        companyField.stringValue = AuthorIdentity.company() ?? ""
    }

    @objc func colorChosen(_ sender: Any?) {
        let index = colorPopUp.indexOfSelectedItem
        AuthorIdentity.setColorHex(index > 0 && index <= Self.colorChoices.count ? Self.colorChoices[index - 1].hex : nil)
    }

    @objc func chooseLibrary(_ sender: Any?) {
        let window = chooseLibraryButton.window
        Task { @MainActor in
            guard let url = await chooseFolder(window) else { return }
            library.subscribe(to: url)
            refreshLibrary()
            library.refreshOpenDocuments()
        }
    }

    @objc func stopLibrary(_ sender: Any?) {
        library.unsubscribe()
        refreshLibrary()
        library.refreshOpenDocuments()
    }

    @objc func copyCommand(_ sender: Any?) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(commandLineField.stringValue, forType: .string)
    }
}
