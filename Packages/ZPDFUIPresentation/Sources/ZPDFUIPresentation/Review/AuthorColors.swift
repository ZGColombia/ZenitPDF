import Foundation

/// A colour per author, for avatars and for "who drew what" on a busy sheet (NL-COLLAB-05/06).
///
/// Deterministic for a document: the document's authors, sorted, take the named palette in turn,
/// so the same set of people always gets the same colours and the first five are always distinct.
/// Every colour has a spoken name, so a legend reads "Ada — Cyan", and an avatar always carries
/// the person's initials: colour is never the only cue.
public enum AuthorColors {

    /// One colour per non-empty author name. Names that belong to one person (`aliases`, the
    /// names this person signed with before a rename) share that person's colour.
    public static func assignments(
        for authors: [String],
        aliases: Set<String> = []
    ) -> [String: ZenitNamedPalette.Entry] {
        let names = Array(Set(authors.filter { !$0.isEmpty }))
        // One slot per person: every alias counts as the first alias, in sorted order.
        let canonicalAlias = aliases.sorted().first
        func person(_ name: String) -> String { aliases.contains(name) ? (canonicalAlias ?? name) : name }
        let people = Array(Set(names.map(person))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var slot: [String: ZenitNamedPalette.Entry] = [:]
        for (index, name) in people.enumerated() {
            slot[name] = ZenitNamedPalette.entries[index % ZenitNamedPalette.entries.count]
        }
        var result: [String: ZenitNamedPalette.Entry] = [:]
        for name in names { result[name] = slot[person(name)] }
        return result
    }

    /// "Ada — Cyan, Bo — Blue", in author order.
    public static func legend(_ assignments: [String: ZenitNamedPalette.Entry]) -> String {
        assignments
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { String(format: NSLocalizedString("%1$@ — %2$@", comment: "Author colour legend entry: author, colour name"), $0.key, $0.value.name) }
            .joined(separator: ", ")
    }

    /// The initials' colour on an author's avatar: whichever of near-black or near-white reads
    /// better against it, by WCAG contrast.
    public static func initialsColor(on background: ColorRGBA) -> ColorRGBA {
        let dark = ColorRGBA.Zenit.Dark.background
        let light = ColorRGBA.Zenit.Dark.text
        return contrast(background, dark) >= contrast(background, light) ? dark : light
    }

    /// The WCAG 2 contrast ratio of two opaque colours.
    public static func contrast(_ a: ColorRGBA, _ b: ColorRGBA) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ color: ColorRGBA) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }
}

/// Up to two initials for a person — the one rule the top bar's author badge, the Inspector's
/// avatar and the review author directory all use (S-053, iteration 2). Four rules used to
/// disagree: "a.berg@site.example" read "AE" in the top bar and "AB" in the Inspector.
public enum AuthorInitials {

    /// The first letters of the first and last words, uppercased in `locale`: "John Doe" → "JD",
    /// "Test-Exempel Person" → "TP", "test" → "T", "ärt ört" → "ÄÖ".
    ///
    /// An e-mail-shaped name uses its local part ("a.berg@site.example" → "AB"). Words split
    /// on whitespace, `.`, `-`, `_` and `,`; a word led by punctuation or a digit is skipped
    /// ("(Team) Studio" → "S"). Empty when nothing is left — each surface decides what to draw
    /// then (a person glyph, a question mark).
    public static func initials(for name: String, locale: Locale = .current) -> String {
        let local = name.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        let letters = local
            .split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "-" || $0 == "_" || $0 == "," })
            .compactMap { word in word.first.flatMap { $0.isLetter ? $0 : nil } }
        guard let first = letters.first else { return "" }
        let picked = letters.count > 1 ? [first, letters[letters.count - 1]] : [first]
        return String(picked).uppercased(with: locale)
    }
}
