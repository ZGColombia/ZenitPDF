import Foundation
import ZPDFContracts
import ZPDFUIPresentation

/// Turning a stamp template into a placed stamp.
///
/// The one rule this file exists to enforce: **dynamic fields resolve at placement time
/// and are then frozen into the markup.** A stamp that says 2026-08-24 must still say that
/// next year, so there is no function anywhere that takes a `StampInstance` and re-derives
/// its text. The direction is template → instance, once, and the instance is text.
public enum StampBridge {

    /// The contracts spelling of a presentation-layer artwork kind.
    public static func artworkKind(
        _ kind: ZPDFUIPresentation.StampArtworkKind
    ) -> ZPDFContracts.StampArtworkKind {
        switch kind {
        case .vector: .vector
        case .raster: .raster
        case .none: .none
        }
    }

    /// The presentation spelling of a contracts artwork kind.
    public static func artworkKind(
        _ kind: ZPDFContracts.StampArtworkKind
    ) -> ZPDFUIPresentation.StampArtworkKind {
        switch kind {
        case .vector: .vector
        case .raster: .raster
        case .none: .none
        }
    }

    /// The contracts spelling of a presentation-layer field kind.
    public static func fieldKind(
        _ kind: ZPDFUIPresentation.StampFieldKind
    ) -> ZPDFContracts.StampFieldKind {
        switch kind {
        case .date: .date
        case .author: .author
        case .pageLabel: .pageLabel
        case .documentName: .documentName
        case .revision: .revision
        case .projectName: .projectName
        case .freeText: .freeText
        }
    }

    /// Resolves a template's dynamic fields against a placement context and freezes them
    /// into a `StampInstance`.
    ///
    /// Pure and static: the clock, the author, the page label and the prompted text are all
    /// in `context`, so the same template and the same context produce the same stamp on
    /// any machine, in any year, which is what makes the freezing rule testable.
    public static func instance(
        of template: StampTemplate,
        named templateName: String,
        in context: StampResolutionContext
    ) -> StampInstance {
        StampInstance(
            templateID: template.id,
            templateName: templateName,
            templateRevision: template.revision,
            artworkDigest: template.artwork?.digest,
            artworkKind: artworkKind(template.artworkKind),
            widthPoints: template.widthPoints,
            heightPoints: template.heightPoints,
            rotationDegrees: template.rotationDegrees,
            fields: template.resolve(in: context).map {
                StampFieldValue(kind: fieldKind($0.kind), slot: $0.slot, resolvedText: $0.text)
            },
            resolvedAt: context.now
        )
    }

    /// The audit note for a placed stamp: the template it came from and every value that
    /// was resolved into it.
    ///
    /// The trail records **both**. A note that named only the
    /// template would leave "what did the stamp on sheet A-207 actually say in 2026?"
    /// unanswerable once the template was edited, and a note that named only the values
    /// would not say which stamp they came from. Canonical JSON with sorted keys, so two
    /// runs of the same batch write byte-identical notes.
    public static func auditNote(for stamp: StampInstance) -> String? {
        var payload: [String: String] = [
            "stampTemplateID": stamp.templateID.uuidString,
            "stampTemplate": stamp.templateName,
            "stampTemplateRevision": String(stamp.templateRevision),
            "stampArtwork": stamp.artworkKind.rawValue
        ]
        if let digest = stamp.artworkDigest { payload["stampArtworkDigest"] = digest }
        for (key, value) in stamp.resolvedValues { payload["field.\(key)"] = value }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

extension AppCoreEnvironment {

    /// The resolution context for a stamp landing on one page.
    ///
    /// Built from the document snapshot rather than from the environment's ambient state,
    /// so a batch resolves every page against the same document instant — 312 stamps
    /// placed by one action carry one date, not 312 dates a few milliseconds apart.
    public func stampContext(
        pageID: UUID,
        now: Date,
        promptedText: String,
        promptedTexts: [Int: String] = [:],
        author: String? = nil
    ) -> StampResolutionContext {
        StampResolutionContext(
            now: now,
            author: author ?? AuthorIdentity.current(),
            // The sheet's number when it has one, as the batch stamps it (L-58).
            pageLabel: snapshot.pages.first { $0.id == pageID }.map(StampBatchProducer.stampedSheetLabel(of:)) ?? "",
            documentName: documentDisplayName,
            revision: documentRevisionName,
            projectName: projectDisplayName,
            promptedText: promptedText,
            promptedTexts: promptedTexts,
            localeIdentifier: Locale.current.identifier,
            timeZoneIdentifier: TimeZone.current.identifier
        )
    }

    /// Places one stamp preset at a point, with its dynamic fields resolved and frozen.
    ///
    /// The single-click sibling of ``applyBatch(_:request:plan:progress:)``. It goes out
    /// through the same Place door every other Place-mode markup uses — including the
    /// preset's custom column values, which this path used to leave off (BH-452).
    @discardableResult
    public func placeStamp(
        _ preset: ToolPresetSummary,
        at point: PDFPointValue,
        pageID: UUID,
        promptedText: String = "",
        promptedTexts: [Int: String] = [:],
        now: Date = Date()
    ) async -> ToolPresetPlaceReceipt {
        // Every question of the template is answered by slot (`template.placementPrompts`), so
        // a second free-text field no longer resolves empty (BH-796).
        await placePreset(
            preset, at: point, pageID: pageID,
            promptedText: promptedText, promptedTexts: promptedTexts, now: now
        )
    }
}
