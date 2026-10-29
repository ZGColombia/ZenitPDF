import Foundation

/// The one wording for an exclusion the text index could not run (U-081).
///
/// The query compiler drops a `NOT` it cannot express — a leading `NOT`, or `NOT` after `OR` —
/// rather than searching for the word the person wanted left out. Every surface that shows a
/// count from such a query has to say so, or the count reads as if the word had been excluded:
/// the Search panel's status line and the batch sheet's search-term scope, which is the number
/// a person checks before placing a stamp on every page it counts. One sentence, one place, so
/// the two surfaces cannot drift apart.
public enum SearchExclusionNote {

    /// "“corridor” was not excluded: put NOT between two words, as in room NOT corridor".
    ///
    /// - Parameter terms: the dropped words as the person typed them.
    /// - Returns: the note without closing punctuation; the Search panel appends it to its
    ///   result count after a dash, the batch sheet closes it as a sentence.
    public static func text(for terms: [String]) -> String {
        // One form per count: two words read "“a”, “b” were not excluded". The one sentence
        // said "was" for any number of words (V-075).
        let format = terms.count == 1
            ? NSLocalizedString(
                "%@ was not excluded: put NOT between two words, as in room NOT corridor",
                comment: "Search status note: the one quoted word after NOT could not be excluded"
            )
            : NSLocalizedString(
                "%@ were not excluded: put NOT between two words, as in room NOT corridor",
                comment: "Search status note: the quoted words after NOT (two or more) could not be excluded"
            )
        return String(format: format, terms.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "))
    }
}
