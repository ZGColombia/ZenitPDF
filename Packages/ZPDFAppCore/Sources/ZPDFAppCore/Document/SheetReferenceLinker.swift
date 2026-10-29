import Foundation
import ZPDFContracts

/// Finds sheet references in a set's text — "SEE S-201", a detail callout "3/A-501" — and proposes
/// a link for every one whose sheet is in the set; references to sheets that are not are listed
/// apart, a QA finding in their own right (NL-DOCS-10).
public enum SheetReferenceLinker {

    /// A line of a page's text, in page space.
    public struct TextLine: Sendable, Hashable {
        public var text: String
        public var bounds: PDFRect
        public init(text: String, bounds: PDFRect) {
            self.text = text
            self.bounds = bounds
        }
    }

    /// A reference that can be linked.
    public struct Proposal: Sendable, Hashable, Identifiable {
        public var id: String { "\(page.rawValue.uuidString)-\(Int(bounds.minX))-\(Int(bounds.minY))-\(text)" }
        /// The sheet the reference is printed on.
        public var page: PageID
        /// Where it is printed, in page space: the part of the line the reference covers.
        public var bounds: PDFRect
        /// The reference as printed, detail number included ("3/A-501").
        public var text: String
        /// The sheet it names.
        public var target: PageID
        public var targetNumber: String

        public init(page: PageID, bounds: PDFRect, text: String, target: PageID, targetNumber: String) {
            self.page = page
            self.bounds = bounds
            self.text = text
            self.target = target
            self.targetNumber = targetNumber
        }
    }

    /// A reference to a sheet the set does not hold.
    public struct Unresolved: Sendable, Hashable {
        public var page: PageID
        public var text: String
    }

    public struct Result: Sendable, Hashable {
        public var proposals: [Proposal]
        public var unresolved: [Unresolved]
    }

    /// Scans `lines` of each page for the set's sheet numbers.
    ///
    /// - Parameters:
    ///   - sheets: the set's sheet numbers, by page.
    ///   - lines: each page's text lines, by page.
    /// A page's own number (its title block) is never a reference. A reference is a sheet number
    /// standing on its own — not part of a longer word — optionally preceded by a detail number
    /// and a slash. Anything shaped like a sheet number (letters, a separator, digits) that is
    /// not in the set is unresolved.
    public static func scan(sheets: [PageID: String], lines: [PageID: [TextLine]]) -> Result {
        var byNumber: [String: (PageID, String)] = [:]
        for (page, number) in sheets {
            let key = SheetIdentityMatching.normalised(number)
            guard !key.isEmpty else { continue }
            byNumber[key] = byNumber[key] == nil ? (page, number) : (page, number)
        }
        var proposals: [Proposal] = []
        var unresolved: [Unresolved] = []
        let pattern = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])(?:(\d{1,3})\s*/\s*)?([A-Za-z]{1,3}[-. ]?\d{1,4}(?:\.\d{1,3})?)(?![A-Za-z0-9])"#)
        for page in lines.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            let own = sheets[page].map(SheetIdentityMatching.normalised)
            for line in lines[page] ?? [] {
                let text = line.text as NSString
                for match in pattern?.matches(in: line.text, range: NSRange(location: 0, length: text.length)) ?? [] {
                    let numberText = text.substring(with: match.range(at: 2))
                    let key = SheetIdentityMatching.normalised(numberText)
                    guard key != own else { continue }
                    let printed = text.substring(with: match.range)
                    if let (target, targetNumber) = byNumber[key] {
                        proposals.append(Proposal(
                            page: page,
                            bounds: span(of: match.range, in: text.length, line: line.bounds),
                            text: printed,
                            target: target,
                            targetNumber: targetNumber
                        ))
                    } else if numberText.contains(where: { $0 == "-" || $0 == "." }) {
                        // Shaped like a sheet number (A-999), not a word like "ROOM 12".
                        unresolved.append(Unresolved(page: page, text: printed))
                    }
                }
            }
        }
        return Result(proposals: proposals, unresolved: unresolved)
    }

    /// The part of a line a character range covers, by proportion of the characters — text lines
    /// carry no per-glyph boxes, and a link a little wider than its text is still the right link.
    static func span(of range: NSRange, in length: Int, line: PDFRect) -> PDFRect {
        guard length > 0 else { return line }
        let box = line.standardized
        let start = box.minX + box.width * Double(range.location) / Double(length)
        let width = box.width * Double(range.length) / Double(length)
        return PDFRect(x: start, y: box.minY, width: max(width, 1), height: box.height)
    }

    /// The hyperlink markups a set of proposals becomes: a rectangle over each reference,
    /// targeting the sheet by identity, so the link survives a reorder.
    public static func markups(for proposals: [Proposal], documentID: DocumentID, now: Date) -> [MarkupRecord] {
        proposals.map { proposal in
            var record = MarkupRecord(
                id: MarkupID(UUID()),
                documentID: documentID,
                pageID: proposal.page,
                kind: .hyperlink,
                subject: String(format: NSLocalizedString("Link to %@", comment: "Subject of a sheet-reference link; the sheet number"), proposal.targetNumber),
                geometry: MeasurementGeometry(
                    pageID: proposal.page,
                    points: [
                        PDFPoint(x: proposal.bounds.minX, y: proposal.bounds.minY),
                        PDFPoint(x: proposal.bounds.maxX, y: proposal.bounds.maxY)
                    ]
                ),
                createdAt: now,
                modifiedAt: now
            )
            record.link = MarkupLinkTarget(pageID: proposal.target)
            return record
        }
    }
}
