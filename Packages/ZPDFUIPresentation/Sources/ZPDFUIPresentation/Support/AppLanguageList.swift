import Foundation

/// Joins names into one list in the application's language: "A", "A and B", "A, B and C".
///
/// `ListFormatter.localizedString(byJoining:)` follows the system region, not the language the
/// application's strings are in, so on a Swedish Mac it put "och" inside an English sentence
/// (live test 8: Prepare This Set's passed-over sheets, Find Repeated Sheets). Every list that
/// goes into a localized sentence is joined here, in the language the sentence itself is in.
public enum AppLanguageList {

    /// `items` as one list in `bundle`'s first localization (the app ships English only).
    public static func joined(_ items: [String], bundle: Bundle = .main) -> String {
        let formatter = ListFormatter()
        formatter.locale = Locale(identifier: bundle.preferredLocalizations.first ?? "en")
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }
}
