import Foundation

/// How serious an application-level warning is.
public enum AppWarningSeverity: String, Codable, Hashable, Sendable, CaseIterable, Comparable {

    /// Informational; no action required.
    case info
    /// Something needs attention but work can continue.
    case warning
    /// Work is blocked or data is at risk.
    case danger

    /// Orders severities from least to most serious.
    public static func < (lhs: AppWarningSeverity, rhs: AppWarningSeverity) -> Bool {
        let order: [AppWarningSeverity] = [.info, .warning, .danger]
        guard let l = order.firstIndex(of: lhs), let r = order.firstIndex(of: rhs) else { return false }
        return l < r
    }

    /// A localized severity name, spoken by VoiceOver ahead of the message.
    public var displayName: String {
        switch self {
        case .info: return NSLocalizedString("Information", comment: "Warning severity")
        case .warning: return NSLocalizedString("Warning", comment: "Warning severity")
        case .danger: return NSLocalizedString("Problem", comment: "Warning severity")
        }
    }

    /// SF Symbol name so severity is legible without colour.
    public var symbolName: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .danger: return "exclamationmark.octagon"
        }
    }

    /// Redundant colour cue from the palette, dark appearance.
    public var indicatorColor: ColorRGBA {
        switch self {
        case .info: return ColorRGBA.Zenit.Dark.blue
        case .warning: return ColorRGBA.Zenit.Dark.warning
        case .danger: return ColorRGBA.Zenit.Dark.danger
        }
    }
}

/// A non-modal message shown in the warning tray.
///
/// Warnings are how Zenit refuses to be silently wrong: a missing scale, a stale
/// measurement or a failed index becomes a visible, dismissible statement rather than a
/// quietly incorrect number.
public struct AppWarning: Codable, Hashable, Sendable, Identifiable {

    /// Stable identity of the warning.
    public let id: UUID
    /// How serious it is.
    public var severity: AppWarningSeverity
    /// Short localized headline.
    public var title: String
    /// Localized explanation, one or two sentences.
    public var message: String
    /// Localized origin, for example `"Scale"` or `"Geometry Index"`.
    public var source: String
    /// Localized title of the affirmative action, or `nil` when there is none.
    public var actionTitle: String?
    /// Whether the user can dismiss the warning.
    public var isDismissible: Bool
    /// When the warning was raised.
    public var timestamp: Date
    /// Markup the warning is about, if any, so the tray can reveal it.
    public var relatedMarkupID: UUID?
    /// Page the warning is about, if any.
    public var relatedPageID: PageDescriptor.ID?

    /// Creates an application warning.
    public init(
        id: UUID,
        severity: AppWarningSeverity,
        title: String,
        message: String,
        source: String,
        actionTitle: String? = nil,
        isDismissible: Bool = true,
        timestamp: Date,
        relatedMarkupID: UUID? = nil,
        relatedPageID: PageDescriptor.ID? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.message = message
        self.source = source
        self.actionTitle = actionTitle
        self.isDismissible = isDismissible
        self.timestamp = timestamp
        self.relatedMarkupID = relatedMarkupID
        self.relatedPageID = relatedPageID
    }

    /// A localized VoiceOver label: severity, title and message.
    public var accessibilityLabel: String {
        Self.sentences(severity.displayName, title, message)
    }

    /// Headline and detail as the one line a tray row shows, with exactly one full stop
    /// between them however the headline was punctuated.
    ///
    /// Use this instead of interpolating `"\(title). \(message)"`: a caller that composes its
    /// headline from text read off the drawing cannot know whether that text already ended a
    /// sentence, and the template cannot know either. Only the join can. This is finding LT-3
    /// — a scale proposal whose headline was built from the notation `1:50` read "The drawing
    /// says 1:50.." in the warning tray, because the headline's own full stop met the
    /// template's.
    public var trayMessage: String {
        Self.sentences(title, message)
    }

    // MARK: - Sentence composition

    /// Punctuation that already ends a sentence, so no full stop is added after it.
    private static let terminators: Set<Character> = ["?", "!", "…"]

    /// Joins `parts` into one string of sentences, each ended by exactly one full stop.
    ///
    /// Empty and whitespace-only parts drop out entirely rather than leaving a stranded ". "
    /// behind them, so a warning with no detail reads as one sentence and not as two.
    public static func sentences(_ parts: String...) -> String {
        parts
            .map(terminated)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// `text` with surrounding whitespace removed and exactly one sentence terminator at the
    /// end: its own `?`, `!` or `…` if it has one, and otherwise a single full stop, whether
    /// it arrived with none, one or a run of them.
    public static func terminated(_ text: String) -> String {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !body.isEmpty else { return "" }
        // Strip any run of full stops and the whitespace they were hiding FIRST — "1:50 ." and
        // "1:50.." both reduce to "1:50" — and only then ask whether what is left already ends
        // a sentence. Asking first let a stray full stop hide the question mark in front of it:
        // "Replace the scale?." saw a "." at the end, fell through to the strip, and put the
        // full stop straight back on for "Replace the scale?." — LT-3's shape, for the other
        // punctuation (CR-105).
        while let last = body.last, last == "." || last.isWhitespace {
            body = body.dropLast()
        }
        guard !body.isEmpty else { return "" }
        if let last = body.last, terminators.contains(last) { return String(body) }
        return String(body) + "."
    }
}
