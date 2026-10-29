import Foundation

/// Count phrases that read correctly for every count — "1 page", "2 pages" — and stay
/// localisation-ready.
///
/// Every UI package resolves its strings against `Bundle.main` (the app's `en.lproj` is copied to
/// the top of `Contents/Resources` by `Scripts/build-app.sh`). Plural rules live in a dedicated
/// catalogue table, **`Plurals.stringsdict`**, whose source is kept in this package at
/// `Localization/<lang>.lproj/Plurals.stringsdict` and which `Scripts/build-app.sh` copies next to `Localizable.strings` (it fails the build when a shipped language lacks one). A
/// language with more than two plural categories (Polish, Arabic, …) gets them there, keyed by
/// the same `key` the call site passes.
///
/// When the bundle carries no rule for `key` — a unit test, whose main bundle is the test runner,
/// or a catalogue that has not been updated yet — the English one/other choice is made here, from
/// the two already-localised formats the caller passes. That fallback is what fixes the
/// "1 items" family of findings (BH-503, BH-786, BH-788, BH-790, BH-810, BH-821, BH-822, IM-137)
/// independently of whether the catalogue has shipped.
public enum LocalizedPlural {

    /// The catalogue table that holds the plural rules.
    public static let tableName = "Plurals"

    /// Formats `count` with the plural form the current language requires.
    ///
    /// - Parameters:
    ///   - key: The `Plurals.stringsdict` key, conventionally the plural English format, for
    ///     example `"%lld pages"`. Its `NSStringLocalizedFormatKey` must take one integer.
    ///   - count: The number the phrase is about.
    ///   - one: The localised singular format, e.g. `NSLocalizedString("%lld page", …)`. Must
    ///     contain exactly one `%lld` (or `%ld`/`%d`) conversion.
    ///   - other: The localised plural format, e.g. `NSLocalizedString("%lld pages", …)`.
    ///   - bundle: The catalogue bundle; `.main` in the product, injectable for tests.
    public static func string(
        _ key: String,
        count: Int,
        one: String,
        other: String,
        bundle: Bundle = .main
    ) -> String {
        let sentinel = "\u{1}zpdf.plural.missing"
        let format = bundle.localizedString(forKey: key, value: sentinel, table: tableName)
        if format != sentinel {
            return String.localizedStringWithFormat(format, count)
        }
        return String.localizedStringWithFormat(count == 1 ? one : other, count)
    }

    /// Formats `count` and more arguments with the plural form the current language requires:
    /// "1 page already carries “Reviewed”", "5 pages already carry “Reviewed”".
    ///
    /// The count is argument 1 and is always shown. `one` and `other` take it as `%1$lld` and
    /// the rest positionally (`%2$@`, …); the catalogue rule for `key` selects on it with
    /// `%1$#@variable@` and names the rest the same way.
    public static func string(
        _ key: String,
        count: Int,
        one: String,
        other: String,
        arguments: [CVarArg],
        bundle: Bundle = .main
    ) -> String {
        let sentinel = "\u{1}zpdf.plural.missing"
        let format = bundle.localizedString(forKey: key, value: sentinel, table: tableName)
        let chosen = format != sentinel ? format : (count == 1 ? one : other)
        return String(format: chosen, locale: Locale.current, arguments: [count] + arguments)
    }
}
