import AppKit

/// Keeps the titles of AppKit's File ▸ Open Recent rows to single spaces (L-33).
///
/// Open Recent is AppKit's own submenu — `ZenitMenuBar` deliberately builds none (LT-20) — and
/// when two recent files share a name AppKit tells them apart by their folder, composing the row
/// from its own strings: the separator `" — "` (spaces included, AppKit's `Document` table) joined
/// to the folder by a further `"%@ %@"`. The row read "Plan-A.pdf —  live8", two spaces after the
/// dash, in the installed build. There is no API for those titles, so this watches the submenu
/// and collapses every run of white space in a row's title to one space as AppKit adds or
/// changes it. It changes nothing else: not the order, not the action, not the file a row opens.
@MainActor
final class OpenRecentTitleTidier: NSObject {

    /// The shipping instance, watching the installed menu bar from launch.
    static let shared = OpenRecentTitleTidier()

    /// The menu bar watched, and the Open Recent submenu found in it.
    private weak var bar: NSMenu?
    private(set) weak var recentMenu: NSMenu?

    /// `title` with every run of white space collapsed to a single space, and none at the ends.
    nonisolated static func tidied(_ title: String) -> String {
        title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The Open Recent submenu of `bar`: the one holding AppKit's Clear Menu row.
    static func openRecentMenu(in bar: NSMenu) -> NSMenu? {
        for item in bar.items {
            guard let submenu = item.submenu else { continue }
            if submenu.items.contains(where: { $0.action == #selector(NSDocumentController.clearRecentDocuments(_:)) }) {
                return submenu
            }
            if let nested = openRecentMenu(in: submenu) { return nested }
        }
        return nil
    }

    /// Starts watching `bar`: its Open Recent submenu now, and again whenever menu tracking
    /// begins, in case AppKit inserted or replaced the submenu after launch.
    func watch(_ bar: NSMenu) {
        let center = NotificationCenter.default
        if let previous = self.bar {
            center.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: previous)
        }
        self.bar = bar
        center.addObserver(self, selector: #selector(trackingBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: bar)
        attachToOpenRecent()
    }

    /// Stops watching. The shipping instance never does; a test does.
    func stop() {
        NotificationCenter.default.removeObserver(self)
        bar = nil
        recentMenu = nil
    }

    @objc private func trackingBegan(_ notification: Notification) {
        attachToOpenRecent()
    }

    @objc private func recentMenuChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        tidy(menu)
    }

    /// Finds the Open Recent submenu, watches it if it is new, and tidies what it holds.
    private func attachToOpenRecent() {
        guard let bar, let menu = Self.openRecentMenu(in: bar) else { return }
        if menu !== recentMenu {
            let center = NotificationCenter.default
            if let old = recentMenu {
                center.removeObserver(self, name: NSMenu.didAddItemNotification, object: old)
                center.removeObserver(self, name: NSMenu.didChangeItemNotification, object: old)
            }
            recentMenu = menu
            center.addObserver(self, selector: #selector(recentMenuChanged(_:)), name: NSMenu.didAddItemNotification, object: menu)
            center.addObserver(self, selector: #selector(recentMenuChanged(_:)), name: NSMenu.didChangeItemNotification, object: menu)
        }
        tidy(menu)
    }

    /// Collapses the white space in every row's title. Setting a title posts another change
    /// notification, which finds the title already tidy and sets nothing.
    func tidy(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem {
            if let attributed = item.attributedTitle {
                let tidy = Self.tidied(attributed.string)
                guard tidy != attributed.string else { continue }
                item.attributedTitle = Self.tidied(attributed)
            } else {
                let tidy = Self.tidied(item.title)
                if tidy != item.title { item.title = tidy }
            }
        }
    }

    /// An attributed title with its white-space runs collapsed, the attributes of the first
    /// character of each run kept.
    private static func tidied(_ attributed: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        let text = result.string as NSString
        var index = text.length
        // Back to front, so earlier ranges stay valid while later ones are edited.
        while index > 0 {
            index -= 1
            guard let scalar = Unicode.Scalar(text.character(at: index)), Character(scalar).isWhitespace else { continue }
            var start = index
            while start > 0, let previous = Unicode.Scalar(text.character(at: start - 1)), Character(previous).isWhitespace {
                start -= 1
            }
            let run = NSRange(location: start, length: index - start + 1)
            let atEnd = run.location == 0 || NSMaxRange(run) == text.length
            result.replaceCharacters(in: run, with: atEnd ? "" : " ")
            index = start
        }
        return result
    }
}
