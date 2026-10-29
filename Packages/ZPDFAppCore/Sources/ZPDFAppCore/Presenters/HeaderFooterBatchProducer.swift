import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// The batch apply's second client (NL-PDF-20): a header, a footer or a sheet number on every
/// sheet in scope, as one action with one undo — the client `StampBatchProducer`'s own
/// documentation named.
///
/// The text is a template. Five fields are filled in per sheet, then frozen, exactly as a
/// stamp's fields are: `{page}` the sheet's label, `{n}` its number (prefix, start and step
/// applied to its position in the set order), `{date}` the batch's one date, `{project}` and
/// `{document}`. What lands on each sheet is an ordinary Text markup, so print, the flattened
/// export and the annotated export carry it like any other.
public struct HeaderFooterBatchProducer: BatchPageItemProducing {

    /// The text, with its fields still unfilled.
    public let template: String
    /// Sheet numbering: `{n}` is `prefix` + `start + step × position`.
    public let numberPrefix: String
    public let numberStart: Int
    public let numberStep: Int
    public let now: Date
    public let author: String
    public let documentName: String
    public let projectName: String
    public let fontSize: Double
    public let localeIdentifier: String
    public let timeZoneIdentifier: String

    /// The subject every placed line carries — what the skip rule and the ledger group by.
    public static let subject = "Header / footer"

    public init(
        template: String,
        numberPrefix: String = "",
        numberStart: Int = 1,
        numberStep: Int = 1,
        now: Date,
        author: String,
        documentName: String = "",
        projectName: String = "",
        fontSize: Double = 10,
        localeIdentifier: String = Locale.current.identifier,
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.template = template
        self.numberPrefix = numberPrefix
        self.numberStart = numberStart
        self.numberStep = numberStep
        self.now = now
        self.author = author
        self.documentName = documentName
        self.projectName = projectName
        self.fontSize = fontSize.isFinite && fontSize > 0 ? fontSize : 10
        self.localeIdentifier = localeIdentifier
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var actionName: String {
        NSLocalizedString("Batch Header or Footer", comment: "Undo action name for a batch header, footer or sheet number")
    }

    public var itemNoun: BatchItemNoun { .lineOfText }

    public var itemName: String { template }

    /// Room for the longest line any sheet could get: the template with every field filled by
    /// a generous stand-in.
    public var placementSize: PDFSizeValue {
        let sample = expanded(pageLabel: "A-000-000", position: 9_999)
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = Double(lines.map(\.count).max() ?? 1)
        return PDFSizeValue(
            width: max(24, longest * fontSize * 0.62),
            height: Double(max(1, lines.count)) * fontSize * 1.5
        )
    }

    /// A sheet already carries this line when a text markup on it came from the same template.
    public func matchesExisting(_ markup: ZPDFUIPresentation.MarkupSummary) -> Bool {
        markup.kind == .text && markup.label == template
    }

    public func record(
        forPage page: ZPDFUIPresentation.PageDescriptor,
        position: Int,
        at point: PDFPointValue,
        documentID: DocumentID,
        identifier: UUID
    ) -> MarkupRecord? {
        let size = placementSize
        // The set position, not `page.index` (W-026): a 10 + 5 sheet two-drawing set stamped
        // 1–10 and then 1–5 again, and a reordered set stamped PDF order.
        let text = expanded(pageLabel: page.label, position: position)
        guard !text.isEmpty else { return nil }
        let pageID = PageID(page.id)
        let corners = [
            PDFPoint(x: point.x - size.width / 2, y: point.y + size.height / 2),
            PDFPoint(x: point.x + size.width / 2, y: point.y - size.height / 2)
        ]
        var record = MarkupRecord(
            id: MarkupID(identifier),
            documentID: documentID,
            pageID: pageID,
            kind: .text,
            subject: Self.subject,
            label: template,
            author: author,
            style: MarkupStyle(color: .opaqueBlack, fontSize: fontSize),
            geometry: MeasurementGeometry(pageID: pageID, points: corners),
            createdAt: now,
            modifiedAt: now
        )
        record.caption = text
        return record
    }

    /// The template with this sheet's fields filled in.
    public func expanded(pageLabel: String, position: Int) -> String {
        let number = numberStart + numberStep * position
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localeIdentifier)
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return template
            .replacingOccurrences(of: "{page}", with: pageLabel)
            .replacingOccurrences(of: "{n}", with: numberPrefix + String(number))
            .replacingOccurrences(of: "{date}", with: formatter.string(from: now))
            .replacingOccurrences(of: "{project}", with: projectName)
            .replacingOccurrences(of: "{document}", with: documentName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AppCoreEnvironment {

    /// A header/footer producer built from the environment's own document facts.
    public func headerFooterBatchProducer(
        template: String,
        numberPrefix: String = "",
        numberStart: Int = 1,
        now: Date = Date(),
        author: String? = nil
    ) -> HeaderFooterBatchProducer? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return HeaderFooterBatchProducer(
            template: trimmed,
            numberPrefix: numberPrefix,
            numberStart: numberStart,
            now: now,
            author: author ?? AuthorIdentity.current(),
            documentName: documentDisplayName,
            projectName: projectDisplayName
        )
    }
}
