import AppKit
import UserNotifications
import ZPDFUIPresentation

/// Local notifications for review activity (NL-COLLAB-15): a reply to this person, an @-mention,
/// a status change on their markup — delivered by the system on this Mac, with no push server and
/// no network.
///
/// Off until the person turns it on in the Review List's Activity popover; turning it on is the one
/// moment permission is asked, never at launch. Both the permission request and the posting are
/// injectable, and outside the assembled application neither touches the notification centre, so
/// no test can raise a system prompt.
@MainActor
enum ReviewNotifications {

    static let enabledKey = "zenit.review.notifications"

    /// Test seams: nothing under `Apps/ZenitPDF/Sources` assigns them.
    static var poster: (@MainActor (ReviewActivityItem) -> Void)?
    static var authorizer: (@MainActor (@escaping @MainActor (Bool) -> Void) -> Void)?

    static var isEnabled: Bool {
        (ReviewPreferences.store.object(forKey: enabledKey) as? Bool) ?? false
    }

    /// Turns notifications on (asking the system first) or off.
    static func setEnabled(_ on: Bool) {
        guard on else {
            ReviewPreferences.store.set(false, forKey: enabledKey)
            return
        }
        requestAuthorization { granted in
            ReviewPreferences.store.set(granted, forKey: enabledKey)
        }
    }

    private static func requestAuthorization(_ done: @escaping @MainActor (Bool) -> Void) {
        if let authorizer { authorizer(done); return }
        guard ZenitModalPresenter.canPresentModally else { done(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in done(granted) }
        }
    }

    /// Posts one notification per item, when the person asked for them.
    static func post(_ items: [ReviewActivityItem]) {
        guard isEnabled else { return }
        for item in items {
            if let poster { poster(item); continue }
            guard ZenitModalPresenter.canPresentModally else { continue }
            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("Review activity", comment: "Local notification title for review activity")
            content.body = item.sentence
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
            )
        }
    }
}
