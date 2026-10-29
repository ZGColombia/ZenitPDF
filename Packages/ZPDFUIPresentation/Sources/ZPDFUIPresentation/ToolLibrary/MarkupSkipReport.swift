import Foundation

/// What an Apply-mode action could not write, **per markup**, grouped so a repeated answer is
/// one line with a count.
///
/// # The defect
///
/// Applying one preset across a mixed selection used to report the *union* of everything that
/// had been skipped anywhere: forty markups, one sentence, and no way to tell whether the
/// depth was dropped on all forty or on one. Which markup skipped what was in the audit trail
/// and not in the sentence a person actually reads.
///
/// # Why grouping is part of the fix and not a nicety
///
/// Per-markup honesty taken literally is forty lines saying the same thing, which is a worse
/// report than the one it replaces — nobody reads it, so nobody notices the one line that
/// differs. The grouping is what makes per-markup reporting legible: identical answers
/// collapse into `"12 markups skipped Depth"`, and the markup that skipped something *else*
/// gets its own line instead of disappearing into a union.
///
/// # Why the properties are strings
///
/// The applicability rules and their property enumeration belong to the tier that performs the
/// application. This type takes the localized display names that tier already produces, so the
/// report can be assembled, tested and rendered without the presentation tier growing an
/// opinion about which properties exist.
public struct MarkupSkipReport: Hashable, Sendable {

    /// One markup's answer: which of the preset's properties it could not take.
    public struct Skip: Hashable, Sendable {

        /// The markup that skipped them.
        public let markupID: UUID
        /// Localized display names of the skipped properties.
        public let propertyNames: [String]

        /// Creates one markup's skip record.
        public init(markupID: UUID, propertyNames: [String]) {
            self.markupID = markupID
            self.propertyNames = propertyNames
        }
    }

    /// Every markup that gave the same answer, and what that answer was.
    public struct Group: Hashable, Sendable, Identifiable {

        /// The skipped properties, sorted, so two markups that skipped the same set group
        /// together whatever order their records arrived in.
        public let propertyNames: [String]
        /// The markups that skipped exactly these, in the order they were reported.
        public let markupIDs: [UUID]

        /// Stable identity: the answer itself, which is unique within a report.
        public var id: String { propertyNames.joined(separator: "\u{1F}") }

        /// How many markups gave this answer.
        public var markupCount: Int { markupIDs.count }

        /// Creates a group.
        public init(propertyNames: [String], markupIDs: [UUID]) {
            self.propertyNames = propertyNames
            self.markupIDs = markupIDs
        }

        /// The properties as a localized list: `"Depth"`, `"Depth and Slope"`,
        /// `"Depth, Slope, and Wall height"` — in the app's language, never the system region's.
        public var propertyList: String {
            AppLanguageList.joined(propertyNames)
        }

        /// One line of the report.
        public var line: String {
            guard markupCount != 1 else {
                return String(
                    format: NSLocalizedString(
                        "1 markup skipped %@.",
                        comment: "Apply-mode skip line for a single markup. %@ is a list of property names"
                    ),
                    propertyList
                )
            }
            return String(
                format: NSLocalizedString(
                    "%1$d markups skipped %2$@.",
                    comment: "Apply-mode skip line. %1$d is a markup count, %2$@ a list of property names"
                ),
                markupCount,
                propertyList
            )
        }
    }

    /// The grouped answers, largest group first; ties broken by the property list so the
    /// report is stable between runs and a test can assert it.
    public let groups: [Group]

    /// Builds a report from one record per affected markup.
    ///
    /// Markups that skipped nothing may be passed in and are dropped: "skipped nothing" is not
    /// a line in a report about what was skipped.
    public init(skips: [Skip]) {
        var order: [[String]] = []
        var buckets: [[String]: [UUID]] = [:]
        for skip in skips {
            let key = skip.propertyNames.sorted()
            guard !key.isEmpty else { continue }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(skip.markupID)
        }
        groups = order
            .map { Group(propertyNames: $0, markupIDs: buckets[$0] ?? []) }
            .sorted {
                $0.markupCount == $1.markupCount
                    ? $0.id < $1.id
                    : $0.markupCount > $1.markupCount
            }
    }

    /// Whether nothing was skipped anywhere.
    public var isEmpty: Bool { groups.isEmpty }

    /// The report as lines, one per distinct answer.
    public var lines: [String] { groups.map(\.line) }

    /// The report as one sentence, for a status bar that has room for a sentence and not for
    /// a list. Empty when nothing was skipped.
    public var summarySentence: String { lines.joined(separator: " ") }
}
