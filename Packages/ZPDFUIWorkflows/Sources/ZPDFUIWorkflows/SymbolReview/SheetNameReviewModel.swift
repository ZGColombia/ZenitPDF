import AppKit
import Foundation
import Observation

/// One page's proposed name in the review (NL-AUTO-04).
public struct SheetNameReviewRow: Identifiable, Hashable, Sendable {
    public let pageIndex: Int
    /// The page as the Navigator names it today.
    public let pageLabel: String
    public var number: String
    public var title: String
    /// Where the reading came from, in words the app tier wrote: "Read in your box",
    /// "Read after “Ritn.nr”", "Judged by shape".
    public let sourceText: String
    /// `0…1`, the reader's own confidence.
    public let confidence: Double
    /// Whether a person must look before this is accepted: low confidence, or nothing read.
    public var needsAttention: Bool { confidence < SheetNameReviewModel.attentionThreshold || number.isEmpty }

    public var id: Int { pageIndex }

    public init(pageIndex: Int, pageLabel: String, number: String, title: String, sourceText: String, confidence: Double) {
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.number = number
        self.title = title
        self.sourceText = sourceText
        self.confidence = confidence
    }
}

/// The accepted names, by page index. A page left out keeps the name it had.
public struct SheetNameReviewOutcome: Hashable, Sendable {
    public struct Name: Hashable, Sendable {
        public let number: String
        public let title: String?
    }
    public let names: [Int: Name]
}

/// Drives the sheet-name review: every proposal editable, duplicates and weak readings flagged,
/// nothing applied until the person accepts — "a name that was not accepted is never shown as the
/// sheet's name, only as a proposal".
@MainActor @Observable
public final class SheetNameReviewModel {

    /// Readings under this confidence are marked for attention and start unticked.
    nonisolated public static let attentionThreshold = 0.5

    public var rows: [SheetNameReviewRow]
    public var includedPageIndexes: Set<Int>

    @ObservationIgnored private let onAccept: (SheetNameReviewOutcome) -> Void
    @ObservationIgnored private let onCancel: () -> Void

    public init(
        rows: [SheetNameReviewRow],
        onAccept: @escaping (SheetNameReviewOutcome) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.rows = rows.sorted { $0.pageIndex < $1.pageIndex }
        self.includedPageIndexes = Set(rows.filter { !$0.needsAttention }.map(\.pageIndex))
        self.onAccept = onAccept
        self.onCancel = onCancel
    }

    /// Page indexes whose number another included row also uses, compared case-insensitively.
    /// Flagged, never renamed: which page really is A-104 is the person's call.
    public var duplicatePageIndexes: Set<Int> {
        var byNumber: [String: [Int]] = [:]
        for row in rows where includedPageIndexes.contains(row.pageIndex) {
            let key = row.number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            byNumber[key, default: []].append(row.pageIndex)
        }
        return Set(byNumber.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    public func setIncluded(_ included: Bool, pageIndex: Int) {
        if included { includedPageIndexes.insert(pageIndex) } else { includedPageIndexes.remove(pageIndex) }
    }

    /// Accepting is refused while two included pages share a number or an included page has
    /// none.
    public var canAccept: Bool {
        !includedPageIndexes.isEmpty && duplicatePageIndexes.isEmpty
            && rows.filter { includedPageIndexes.contains($0.pageIndex) }
                .allSatisfy { !$0.number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var summaryText: String {
        let attention = rows.filter(\.needsAttention).count
        var text = String(
            format: NSLocalizedString(
                "%1$lld of %2$@ named; %3$@",
                comment: "Sheet name review summary: the included count, the total as '12 sheets', the flagged ones as '2 need a look before they are accepted.'"
            ),
            includedPageIndexes.count, WorkflowPlurals.sheets(rows.count), WorkflowPlurals.needALook(attention)
        )
        if !duplicatePageIndexes.isEmpty {
            text += " " + NSLocalizedString(
                "Two or more sheets share a number — fix or untick them to continue.",
                comment: "Sheet name review: duplicate numbers block acceptance"
            )
        }
        return text
    }

    public func accept() {
        guard canAccept else { return }
        var names: [Int: SheetNameReviewOutcome.Name] = [:]
        for row in rows where includedPageIndexes.contains(row.pageIndex) {
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            names[row.pageIndex] = SheetNameReviewOutcome.Name(
                number: row.number.trimmingCharacters(in: .whitespacesAndNewlines),
                title: title.isEmpty ? nil : title
            )
        }
        onAccept(SheetNameReviewOutcome(names: names))
    }

    public func cancel() { onCancel() }

    // MARK: - Showing the whole value (L-54)

    /// The number field's width: the longest number in the review, measured in the field's own
    /// font, so a reading is shown whole rather than cut to "DOKUME…". The field was a fixed
    /// 90 pt, narrower than many sheet numbers, with no way to see the rest.
    public var numberFieldWidth: Double { Self.numberFieldWidth(for: rows.map(\.number)) }

    /// The narrowest the number field gets, in points — the old fixed width.
    public static let numberFieldMinimumWidth = 90.0
    /// The widest the number field gets, in points; a longer reading scrolls inside it.
    public static let numberFieldMaximumWidth = 260.0
    /// The rounded border's insets and the caret, in points.
    public static let numberFieldPadding = 20.0

    /// The width a number field needs to show every one of `numbers` whole.
    public static func numberFieldWidth(for numbers: [String]) -> Double {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = numbers.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(numberFieldMaximumWidth, max(numberFieldMinimumWidth, (Double(widest) + numberFieldPadding).rounded(.up)))
    }
}
