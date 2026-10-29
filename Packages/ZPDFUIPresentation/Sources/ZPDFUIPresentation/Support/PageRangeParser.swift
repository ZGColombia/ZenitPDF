import Foundation

/// The one reading of a typed page list — "1, 3-5; 8" — shared by every sheet that asks for
/// pages (IM-148: OCR, Bulk Scale, batch fields).
///
/// Pages are 1-based as typed and 0-based as returned. Commas and semicolons separate
/// fragments; a fragment is one page or a range `a-b`, and a reversed range (`5-3`) is the
/// same range. A fragment is *rejected* if its page or either range endpoint is outside the
/// document, and named back to the person rather than silently dropped.
public enum PageRangeParser {

    /// The zero-based page indices named by fragments wholly within `1...pageCount`.
    public static func indices(in text: String, pageCount: Int) -> IndexSet {
        var result = IndexSet()
        for fragment in fragments(of: text) {
            result.formUnion(indices(ofFragment: fragment, pageCount: pageCount))
        }
        return result
    }

    /// Invalid or out-of-document fragments, trimmed and in typed order.
    public static func rejectedFragments(in text: String, pageCount: Int) -> [String] {
        fragments(of: text).filter { indices(ofFragment: $0, pageCount: pageCount).isEmpty }
    }

    /// Whether fragments exist and every page and both range endpoints are inside the document.
    public static func isValid(_ text: String, pageCount: Int) -> Bool {
        let parts = fragments(of: text)
        return !parts.isEmpty && rejectedFragments(in: text, pageCount: pageCount).isEmpty
    }

    /// The zero-based indices of an inclusive 1-based range, either order; empty when any
    /// end falls outside the document.
    public static func indices(from low: Int, to high: Int, pageCount: Int) -> IndexSet {
        guard pageCount > 0 else { return IndexSet() }
        let lower = min(low, high)
        let upper = max(low, high)
        guard lower >= 1, upper <= pageCount else { return IndexSet() }
        return IndexSet((lower - 1)...(upper - 1))
    }

    private static func fragments(of text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func indices(ofFragment fragment: String, pageCount: Int) -> IndexSet {
        let bounds = fragment.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if bounds.count == 2, let low = Int(bounds[0]), let high = Int(bounds[1]) {
            return indices(from: low, to: high, pageCount: pageCount)
        }
        if bounds.count == 1, let single = Int(bounds[0]), pageCount > 0, (1...pageCount).contains(single) {
            return IndexSet(integer: single - 1)
        }
        return IndexSet()
    }
}
