import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// The scoped batch apply's first client: the same stamp on every sheet, one action.
///
/// Everything stamp-shaped about a batch lives here, and nothing stamp-shaped lives in
/// ``AppCoreEnvironment/runBatchApply(_:plan:progress:)``. That split is the whole point:
/// the next client — batch headers, footers, page numbers, revision clouds — writes one of
/// these and gets the scope preview, the per-page anchoring, the single undo, the single
/// audit group, the progress, the cancellation and the skip rule for free.
///
/// # The one date
///
/// `now` is fixed when the producer is built, not read per page. A batch of 312 stamps is
/// one action by one person at one instant, and 312 stamps carrying 312 timestamps a few
/// milliseconds apart would be a record of the machine rather than of the decision. Each
/// page's *label*, by contrast, is resolved per page — that is the field that legitimately
/// differs across the batch.
public struct StampBatchProducer: BatchPageItemProducing {

    /// The preset being placed.
    public let preset: ToolPresetSummary
    /// Its stamp template.
    public let template: StampTemplate
    /// The instant the whole batch resolves its dates against.
    public let now: Date
    /// The author every stamp in the batch is signed with.
    public let author: String
    /// The document's display name, for the `documentName` field.
    public let documentName: String
    /// The document's active revision, for the `revision` field.
    public let revisionName: String
    /// The project's name, for the `projectName` field.
    public let projectName: String
    /// The text the person supplied at the placement prompt, for the free-text field.
    public let promptedText: String
    /// Answers to every further placement question, keyed by field slot (BH-796).
    public let promptedTexts: [Int: String]
    /// The locale dates are formatted in.
    public let localeIdentifier: String
    /// The time zone dates are formatted in.
    public let timeZoneIdentifier: String
    /// The preset's custom column defaults, resolved against the document's columns.
    ///
    /// A single Place click has always stored these; the batch left them off, so one preset
    /// produced two record shapes and 312 stamps landed with empty ledger cells (BH-117).
    public let customValues: [ColumnID: Domain.CellValue]

    /// Creates a producer.
    public init(
        preset: ToolPresetSummary,
        template: StampTemplate,
        now: Date,
        author: String,
        documentName: String = "",
        revisionName: String = "",
        projectName: String = "",
        promptedText: String = "",
        promptedTexts: [Int: String] = [:],
        localeIdentifier: String = Locale.current.identifier,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        customValues: [ColumnID: Domain.CellValue] = [:]
    ) {
        self.customValues = customValues
        self.promptedTexts = promptedTexts
        self.preset = preset
        self.template = template
        self.now = now
        self.author = author
        self.documentName = documentName
        self.revisionName = revisionName
        self.projectName = projectName
        self.promptedText = promptedText
        self.localeIdentifier = localeIdentifier
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var actionName: String {
        NSLocalizedString("Batch Stamp", comment: "Undo action name for a scoped batch stamp")
    }

    public var itemNoun: BatchItemNoun { .stamp }

    public var itemName: String { preset.name }

    public var placementSize: PDFSizeValue {
        PDFSizeValue(width: template.widthPoints, height: template.heightPoints)
    }

    /// A page already carries this stamp when any markup on it came from this template.
    ///
    /// Template identity, not appearance: a stamp whose free text differs is still the same
    /// stamp for the purpose of "do not put a second approval seal on this sheet", and that
    /// is the mistake the skip rule exists to stop.
    public func matchesExisting(_ markup: ZPDFUIPresentation.MarkupSummary) -> Bool {
        markup.stampTemplateID == template.id
    }

    public func record(
        forPage page: ZPDFUIPresentation.PageDescriptor,
        position: Int,
        at point: PDFPointValue,
        documentID: DocumentID,
        identifier: UUID
    ) -> MarkupRecord? {
        let context = StampResolutionContext(
            now: now,
            author: author,
            // A named sheet is stamped with its number (L-58: "Sheet 1" on the sheet named
            // A-00-0-002); the page's own label only when it has none.
            pageLabel: Self.stampedSheetLabel(of: page),
            documentName: documentName,
            revision: revisionName,
            projectName: projectName,
            promptedText: promptedText,
            promptedTexts: promptedTexts,
            localeIdentifier: localeIdentifier,
            timeZoneIdentifier: timeZoneIdentifier
        )
        guard var record = AppCoreEnvironment.placementRecord(
            for: preset,
            at: point,
            pageID: PageID(page.id),
            documentID: documentID,
            author: author,
            customValues: customValues,
            now: now,
            identifier: identifier
        ) else { return nil }
        record.stamp = StampBridge.instance(of: template, named: preset.name, in: context)
        return record
    }

    /// The sheet as a stamp names it: its sheet number when it has been named, otherwise the
    /// page's own label.
    public static func stampedSheetLabel(of page: ZPDFUIPresentation.PageDescriptor) -> String {
        let number = page.sheetNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return number.isEmpty ? page.label : number
    }
}

extension AppCoreEnvironment {

    /// A producer for one stamp preset, built from the environment's own document facts.
    ///
    /// Returns `nil` when the preset is not a stamp preset, which is the honest answer: a
    /// batch of a Polygon Area preset is a different feature and pretending otherwise would
    /// place 312 empty rectangles.
    public func stampBatchProducer(
        for preset: ToolPresetSummary,
        promptedText: String = "",
        promptedTexts: [Int: String] = [:],
        now: Date = Date(),
        author: String? = nil
    ) -> StampBatchProducer? {
        guard let template = preset.stamp else { return nil }
        return StampBatchProducer(
            preset: preset,
            template: template,
            now: now,
            author: author ?? AuthorIdentity.current(),
            documentName: documentDisplayName,
            revisionName: documentRevisionName,
            projectName: projectDisplayName,
            promptedText: promptedText,
            promptedTexts: promptedTexts,
            customValues: ledgerColumnsCache.map {
                Self.resolvedCustomValues(preset.customDefaults, columns: $0, currencyCode: ledger.defaultCurrencyCode).values
            } ?? [:]
        )
    }
}
