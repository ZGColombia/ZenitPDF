import Foundation

/// The display name measurements and audit entries are signed with.
///
/// Two rules, both binding:
///
/// 1. **The name comes from the machine or from the user — never from source.** The
///    default is the macOS account's full name (`NSFullUserName()`), falling back to the
///    short account name when that is empty. No literal person's name exists anywhere in
///    this repository; a CI grep gate (`Scripts/verify-author-scrub.sh`) enforces it.
/// 2. **Changing the name affects new entries only.** History is append-only (ADR-0007);
///    past rows keep the name that made them. Consumers therefore read the name through
///    a provider at record time, never by capturing it once.
///
/// The setting is an app-level preference, not project data: a shared project shows each
/// contributor's own name. It never leaves the machine except inside project files and
/// exports the user shares themselves.
@MainActor
public enum AuthorIdentity {

    /// Where the chosen name is stored. Absent means "use the machine default".
    public static let defaultsKey = "com.zenitgroup.zenitpdf.author.name"

    /// Whether the first-run prompt has been shown (asked once, ever — skipping counts).
    public static let promptedKey = "com.zenitgroup.zenitpdf.author.prompted"

    /// The defaults store. Injectable so tests never touch the real preferences.
    public static var defaults: UserDefaults = .standard

    /// The machine's own answer: the account full name, or the short name when the full
    /// name is empty.
    public static var machineDefault: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }

    /// The name new entries are signed with, right now.
    public static func current() -> String {
        if let stored = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        return machineDefault
    }

    /// The names this person signed with before a rename (NL-COLLAB-05), so a rename does not
    /// split one person into two: "my" filters and colours group them under one identity.
    public static let aliasesKey = "com.zenitgroup.zenitpdf.author.aliases"

    /// Every name this person has signed with on this machine, the current one first.
    public static func names() -> [String] {
        var result = [current()]
        for alias in defaults.stringArray(forKey: aliasesKey) ?? [] where !result.contains(alias) {
            result.append(alias)
        }
        return result
    }

    /// Records the user's choice. An empty name, or one equal to the machine default,
    /// clears the override so the preference tracks the account name again.
    public static func set(_ name: String) {
        let previous = current()
        defer {
            // The name being left keeps belonging to this person.
            if current() != previous {
                var aliases = defaults.stringArray(forKey: aliasesKey) ?? []
                if !aliases.contains(previous) { aliases.append(previous) }
                defaults.set(aliases.filter { $0 != current() }, forKey: aliasesKey)
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == machineDefault {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(trimmed, forKey: defaultsKey)
        }
    }

    // MARK: - Identity beyond the name (NL-COLLAB-05)

    /// This installation's stable author id: a random UUID made once and kept. Never derived
    /// from the machine or the account, so it says nothing about who or where the person is.
    public static let authorIDKey = "com.zenitgroup.zenitpdf.author.id"
    /// The company shown next to the name in the Review List and the review report. Optional.
    public static let companyKey = "com.zenitgroup.zenitpdf.author.company"
    /// The avatar colour chosen in Settings, `#RRGGBBAA`; absent means the palette's.
    public static let colorKey = "com.zenitgroup.zenitpdf.author.color"

    /// The stable id, created on first use.
    public static func authorID() -> String {
        if let stored = defaults.string(forKey: authorIDKey), UUID(uuidString: stored) != nil { return stored }
        let made = UUID().uuidString
        defaults.set(made, forKey: authorIDKey)
        return made
    }

    /// The company, or `nil` when none is set.
    public static func company() -> String? {
        let stored = defaults.string(forKey: companyKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? nil : stored
    }

    /// Sets or clears the company (an empty string clears it). At most 200 characters are kept.
    public static func setCompany(_ company: String) {
        let trimmed = company.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { defaults.removeObject(forKey: companyKey) } else { defaults.set(String(trimmed.prefix(200)), forKey: companyKey) }
    }

    /// The chosen avatar colour, `#RRGGBBAA`, or `nil` for the palette's.
    public static func colorHex() -> String? {
        guard let stored = defaults.string(forKey: colorKey), isColorHex(stored) else { return nil }
        return stored
    }

    /// Sets or clears the avatar colour. Anything but `#RRGGBBAA` clears it.
    public static func setColorHex(_ hex: String?) {
        if let hex, isColorHex(hex) { defaults.set(hex.uppercased(), forKey: colorKey) } else { defaults.removeObject(forKey: colorKey) }
    }

    static func isColorHex(_ text: String) -> Bool {
        text.count == 9 && text.hasPrefix("#") && text.dropFirst().allSatisfy(\.isHexDigit)
    }

    /// Whether the first-run prompt is still owed.
    public static var needsFirstRunPrompt: Bool {
        !defaults.bool(forKey: promptedKey)
    }

    /// Marks the prompt as shown — accepted or skipped alike; skipping keeps the
    /// default silently, and the question is never asked twice.
    public static func markPrompted() {
        defaults.set(true, forKey: promptedKey)
    }
}
