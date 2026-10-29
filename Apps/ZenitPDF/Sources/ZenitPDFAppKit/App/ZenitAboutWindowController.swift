import AppKit

/// About Zenit PDF — identity, version, and the acknowledgements the licences require.
///
/// ## Why this replaced `orderFrontStandardAboutPanel(_:)`
///
/// The application menu's About item used to be one line:
/// `#selector(NSApplication.orderFrontStandardAboutPanel(_:))`. AppKit's standard panel shows
/// the icon, the name, the version and whatever `NSHumanReadableCopyright` says, and nothing
/// else — no licence text, and no way to reach any.
///
/// That is not a tidiness problem, it is a **compliance failure**. Zenit PDF links qpdf, whose
/// Apache-2.0 §4(d) obliges a redistributor to carry the upstream `NOTICE` — qpdf's is
/// substantive, offering a pre-v7 Artistic-2.0 alternative and crediting the Rijndael and sphlib
/// implementations behind its AES and SHA-2 support — and whose `MD5_native.cc` carries an RSA
/// Data Security notice that must be retained in every copy. libxlsxwriter's FreeBSD notice
/// arrives with minizip and the FreeBSD `queue.h`/`tree.h` macros, Clipper2 is Boost-1.0 and
/// GRDB is MIT. `Contents/Resources` held icons, a GRDB resource bundle and `en.lproj`, and not
/// one line of any of it.
///
/// Two rules from `Docs/Licences/LICENSE_EVIDENCE.md` shape what this window does:
///
///   * **the full text, not the name.** "MIT" is not the MIT licence, and an SPDX identifier
///     discharges no obligation;
///   * **offline.** A local-first application cannot satisfy attribution with a hyperlink to a
///     page it would need the network to fetch — and this application makes no network
///     connection at all (`Scripts/verify-no-network.sh`).
///
/// So the notices are files inside the bundle, this window reads them from there, and
/// `Scripts/verify-licence-notices.sh` fails the build if a component named in the evidence
/// manifest has no text in `Contents/Resources/Licenses`.
///
/// ## When the notices cannot be found
///
/// Running from `swift run` or a test process, there is no assembled bundle and therefore no
/// `Licenses` directory. The window says exactly that, names the directory it looked in, and
/// points at the gate — it never shows an empty list, because an empty acknowledgements list
/// is indistinguishable from a product that has no obligations.
@MainActor
public final class ZenitAboutWindowController: NSWindowController, NSWindowDelegate {

    /// The shared window. One About window, reopened rather than stacked.
    public static let shared = ZenitAboutWindowController(lazilyReadingFrom: .main)

    /// The directory inside the bundle the notices are read from.
    public static let resourceDirectoryName = "Licenses"

    /// One component's notice, as loaded from the bundle.
    public struct Notice: Sendable, Hashable {
        /// The component name, taken from the file name.
        public let component: String
        /// The verbatim notice text.
        public let text: String
    }

    /// Everything found in the bundle, product first and the rest alphabetical.
    public private(set) var notices: [Notice] = []

    /// Why the list is empty, when it is. `nil` when notices were found.
    public private(set) var unavailableReason: String?

    /// The two panes of this window.
    ///
    /// The licences are a tab rather than a section further down the About pane because a
    /// person needs a route they can *name*: "the Licences tab", reachable from the menu
    /// bar without knowing that licence text lives behind an About item. A pane a reader has to
    /// scroll to discover is, for compliance purposes, a pane they were never offered.
    public enum Tab: Int, Sendable, CaseIterable {
        case about
        case licences

        var identifier: String {
            switch self {
            case .about: return "about"
            case .licences: return "licences"
            }
        }

        var title: String {
            switch self {
            case .about:
                return NSLocalizedString("About", comment: "About window tab")
            case .licences:
                return NSLocalizedString("Licences", comment: "About window tab")
            }
        }
    }

    /// The tab container. `public` so a test can assert which pane is selected without
    /// re-implementing the lookup.
    public let tabView = NSTabView()

    /// The pane currently on screen.
    public var selectedTab: Tab {
        guard let identifier = tabView.selectedTabViewItem?.identifier as? String,
              let tab = Tab.allCases.first(where: { $0.identifier == identifier })
        else { return .about }
        return tab
    }

    /// Brings one pane to the front.
    public func select(_ tab: Tab) {
        tabView.selectTabViewItem(withIdentifier: tab.identifier)
    }

    /// The component list.
    public let componentList = NSTableView()

    /// The notice text for the selected component.
    public let noticeText = NSTextView()

    private let scrollHost = NSScrollView()

    /// The bundle the notices are read from: the application's own for ``shared``, a fixture
    /// bundle for a test.
    private let noticesBundle: Bundle

    /// A controller that builds nothing until it is first presented — the shipping singleton.
    ///
    /// `ZenitMenuBar` sets `about.target` and `licences.target` to ``shared`` while it builds
    /// the menu bar, which happens during launch, on the main thread, before the first drawing
    /// appears. So this initialiser does nothing: no window, no reading licence files off disk,
    /// no content view. `makeContentView()` builds both panes up front, and the About pane alone
    /// rasterises the application icon into an `NSImageView` and lays out a wrapping paragraph;
    /// doing that at launch cost main-thread time in `Scripts/verify-app-launches.sh`.
    ///
    /// ``loadWindowIfNeeded()`` builds the window the first time it is presented. It used to be
    /// left to an override of `loadWindow()`, on the belief that `NSWindowController` calls it
    /// the first time anything asks for `window`. It does not: AppKit calls `loadWindow()` only
    /// for a controller that names a nib, and this one names none, so `window` stayed `nil`,
    /// `showWindow(_:)` ordered nothing front, and About and Help ▸ Licences opened no window at
    /// all in the installed build (L-34) — the licence notices that qpdf's
    /// Apache-2.0 §4(d) obliges us to carry were unreachable.
    init(lazilyReadingFrom bundle: Bundle) {
        self.noticesBundle = bundle
        super.init(window: nil)
    }

    /// Test seam: a controller reading notices from a bundle of the test's choosing, so the
    /// loading, the ordering and the empty-state message can all be asserted without an
    /// assembled application.
    ///
    /// Eager, unlike ``shared``: a test wants the loaded, laid-out state, and there is no launch
    /// to keep out of the way of.
    init(bundle: Bundle) {
        self.noticesBundle = bundle
        super.init(window: nil)
        loadWindowIfNeeded()
    }

    /// The window, built on first use from ``noticesBundle``. See ``init(lazilyReadingFrom:)``.
    @discardableResult
    func loadWindowIfNeeded() -> NSWindow {
        if let window { return window }
        let window = Self.makeWindow()
        self.window = window
        reload(from: noticesBundle)
        finishSetUp()
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = String(
            format: NSLocalizedString("About %@", comment: "Application menu item"),
            ZenitAppInfo.displayName
        )
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 380)
        return window
    }

    // MARK: - Loading

    /// Reads every `*.txt` in the bundle's `Licenses` directory.
    ///
    /// The product's own licence sorts first — a reader wants to know what they are running
    /// before they read what it is built on — and the rest alphabetically, so the order does not
    /// depend on the file system.
    public func reload(from bundle: Bundle) {
        let directory = bundle.resourceURL?
            .appendingPathComponent(Self.resourceDirectoryName, isDirectory: true)
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else {
            notices = []
            unavailableReason = String(
                format: NSLocalizedString(
                    """
                    The licence notices are missing from this build.

                    Zenit PDF ships the full licence text of every component it is built on \
                    inside %@. This copy has no such directory, which means it was assembled \
                    without them — a build in that state must not be distributed.

                    Scripts/verify-licence-notices.sh checks for exactly this and fails the \
                    build. If you are running from a development build rather than an \
                    assembled application, that is the expected reason.
                    """,
                    comment: "Acknowledgements: the bundle carries no licence notices"
                ),
                directory?.path ?? "Contents/Resources/\(Self.resourceDirectoryName)"
            )
            return
        }

        let loaded: [Notice] = names
            .filter { $0.hasSuffix(".txt") }
            .compactMap { name in
                let url = directory.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return Notice(component: String(name.dropLast(4)), text: text)
            }
            .sorted { left, right in
                if left.component == ZenitAppInfo.displayName { return true }
                if right.component == ZenitAppInfo.displayName { return false }
                return left.component.localizedStandardCompare(right.component) == .orderedAscending
            }

        notices = loaded
        unavailableReason = loaded.isEmpty
            ? String(
                format: NSLocalizedString(
                    """
                    %@ exists but holds no readable licence notice.

                    A build in this state must not be distributed; \
                    Scripts/verify-licence-notices.sh fails on it.
                    """,
                    comment: "Acknowledgements: the notices directory is present but empty"
                ),
                directory.path
            )
            : nil
    }

    // MARK: - Layout

    private func finishSetUp() {
        window?.delegate = self
        window?.contentView = makeContentView()
        selectFirstComponent()
        select(.about)
    }

    private func makeContentView() -> NSView {
        let root = NSView()

        tabView.translatesAutoresizingMaskIntoConstraints = false
        for tab in Tab.allCases {
            let item = NSTabViewItem(identifier: tab.identifier)
            item.label = tab.title
            item.view = tab == .about ? makeAboutPane() : makeLicencesPane()
            tabView.addTabViewItem(item)
        }
        root.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
        return root
    }

    /// Identity, version, and the one paragraph that answers "what am I allowed to do with this".
    private func makeAboutPane() -> NSView {
        let pane = NSView()

        let icon = NSImageView(image: NSApplication.shared.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel(ZenitAppInfo.displayName)

        let name = NSTextField(labelWithString: ZenitAppInfo.displayName)
        name.font = .systemFont(ofSize: 20, weight: .semibold)

        let version = NSTextField(
            labelWithString: String(
                format: NSLocalizedString(
                    "Version %1$@ (%2$@)", comment: "About: marketing version and build number"
                ),
                ZenitAppInfo.shortVersion,
                ZenitAppInfo.buildVersion
            )
        )
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor

        let copyright = NSTextField(
            labelWithString: Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright")
                as? String ?? "Copyright © 2026 ZENIT GROUP S.A.S."
        )
        copyright.font = .systemFont(ofSize: 11)
        copyright.textColor = .secondaryLabelColor

        // The wording here is the plain-language half of `Docs/Legal/LICENSING_STATEMENT.md`.
        // It says what the licence permits without asking the reader to parse a licence, and it
        // is careful about one distinction that statement makes at length: this application is
        // MIT, and the components it is built on are permissively licensed but not all MIT.
        let summary = NSTextField(
            wrappingLabelWithString: NSLocalizedString(
                """
                Zenit PDF is free and open source software, released under the MIT \
                licence. You may use it commercially, study it, change it and \
                redistribute it, including in closed-source products, provided the \
                copyright notice and the licence text travel with it.

                The application is built on several third-party components. All of them \
                are permissively licensed — MIT, Apache-2.0, BSD, Boost, zlib and the \
                RSA MD5 licence — and each carries its own conditions, chiefly that its \
                notice is reproduced. Every one of those notices is in the Licences tab, \
                in full, and ships inside the application so that it can be read without \
                a network connection.

                Measurements produced by this application are the user's responsibility \
                to verify against the source drawing.
                """,
                comment: "About: plain-language summary of the licensing position"
            )
        )
        summary.font = .systemFont(ofSize: 12)

        let openLicences = NSButton(
            title: NSLocalizedString("Show Licences", comment: "About: button to the Licences tab"),
            target: self,
            action: #selector(showLicences(_:))
        )
        openLicences.bezelStyle = .rounded

        let identity = NSStackView(views: [name, version, copyright])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 2

        let header = NSStackView(views: [icon, identity])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        let stack = NSStackView(views: [header, summary, openLicences])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)

        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor),
            summary.widthAnchor.constraint(lessThanOrEqualToConstant: 640)
        ])
        return pane
    }

    /// The component list and the verbatim notice for the selected component.
    private func makeLicencesPane() -> NSView {
        let pane = NSView()

        let heading = NSTextField(
            labelWithString: NSLocalizedString(
                "Acknowledgements", comment: "About: heading over the third-party licence list"
            )
        )
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        let subheading = NSTextField(
            wrappingLabelWithString: NSLocalizedString(
                """
                Zenit PDF is open source and is built on the components below. Their full \
                licence texts ship inside the application and are reproduced here in full, \
                offline, as those licences require.
                """,
                comment: "About: explanation over the third-party licence list"
            )
        )
        subheading.font = .systemFont(ofSize: 11)
        subheading.textColor = .secondaryLabelColor

        // The component list.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("component"))
        column.title = NSLocalizedString("Component", comment: "Acknowledgements list column")
        column.width = 180
        componentList.addTableColumn(column)
        componentList.headerView = nil
        componentList.rowSizeStyle = .default
        componentList.dataSource = self
        componentList.delegate = self
        componentList.setAccessibilityLabel(
            NSLocalizedString("Components", comment: "Acknowledgements list accessibility label")
        )

        let listScroll = NSScrollView()
        listScroll.documentView = componentList
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder

        // The notice itself. Selectable so a reader can copy a notice out, never editable.
        noticeText.isEditable = false
        noticeText.isSelectable = true
        noticeText.drawsBackground = true
        noticeText.backgroundColor = .textBackgroundColor
        noticeText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        noticeText.textContainerInset = NSSize(width: 8, height: 8)
        noticeText.isVerticallyResizable = true
        noticeText.isHorizontallyResizable = false
        noticeText.autoresizingMask = [.width]
        noticeText.textContainer?.widthTracksTextView = true
        noticeText.setAccessibilityLabel(
            NSLocalizedString("Licence text", comment: "Acknowledgements text accessibility label")
        )

        scrollHost.documentView = noticeText
        scrollHost.hasVerticalScroller = true
        scrollHost.borderType = .bezelBorder

        let split = NSStackView(views: [listScroll, scrollHost])
        split.orientation = .horizontal
        split.distribution = .fill
        split.spacing = 12

        let stack = NSStackView(views: [heading, subheading, split])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            subheading.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            listScroll.widthAnchor.constraint(equalToConstant: 190)
        ])
        return pane
    }

    // MARK: - Selection

    /// Puts the first component's notice on screen, or the reason there is none.
    public func selectFirstComponent() {
        if notices.isEmpty {
            noticeText.string = unavailableReason ?? ""
            return
        }
        componentList.reloadData()
        componentList.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showNotice(at: 0)
    }

    /// Shows one component's notice. `public` so a test can drive the exact selection the table
    /// drives, rather than a private re-implementation of it.
    public func showNotice(at index: Int) {
        guard notices.indices.contains(index) else { return }
        noticeText.string = notices[index].text
        noticeText.scroll(.zero)
    }

    // MARK: - The menu action

    /// The application menu's About item.
    @objc public func showAbout(_ sender: Any?) {
        present(.about, sender: sender)
    }

    /// The Help menu's Licences item, and the About pane's button.
    ///
    /// Separate from `showAbout(_:)` because the obligation is separate: a reader looking for
    /// the licence of a component must reach the text without first knowing that it lives
    /// behind an About item.
    @objc public func showLicences(_ sender: Any?) {
        present(.licences, sender: sender)
    }

    /// How the window reaches the screen: ordered front in the assembled application, never in
    /// any other process. A test replaces it to see which window would have been shown; nothing
    /// under `Apps/ZenitPDF/Sources` reassigns it.
    static var windowPresenter: @MainActor (NSWindow, Any?) -> Void = { window, sender in
        guard ZenitModalPresenter.canPresentModally else { return }
        window.makeKeyAndOrderFront(sender)
    }

    private func present(_ tab: Tab, sender: Any?) {
        // The window is built here, on first use, because AppKit never builds it for a
        // controller with no nib (L-34): `showWindow(_:)` on an unbuilt controller showed nothing.
        let window = loadWindowIfNeeded()
        // Centre only the first time. Re-centring a window the reader has already moved is the
        // kind of small rudeness that makes a window feel like a dialog.
        if !window.isVisible { window.center() }
        select(tab)
        Self.windowPresenter(window, sender)
    }
}

extension ZenitAboutWindowController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int { notices.count }

    public func tableView(
        _ tableView: NSTableView,
        objectValueFor tableColumn: NSTableColumn?,
        row: Int
    ) -> Any? {
        notices.indices.contains(row) ? notices[row].component : nil
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        showNotice(at: componentList.selectedRow)
    }
}
