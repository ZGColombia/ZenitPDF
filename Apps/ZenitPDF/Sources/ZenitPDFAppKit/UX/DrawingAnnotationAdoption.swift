import AppKit
import Observation
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge

/// Tools ▸ Make Drawing Annotations Editable… (NL-UX-04).
///
/// Drawings often arrive already marked up — clouds, boxes, callouts drawn in another PDF tool.
/// PDFKit paints those into the page image, so they could be seen and never selected: a click
/// on a coloured cloud selected nothing, no colour control appeared, and nothing said the mark
/// was part of the drawing (the third cause of LT3-01).
///
/// This command turns them into Zenit markups, **explicitly and reversibly**:
///
/// 1. It reads the drawing's own annotations with the same reader and mapping the review import
///    uses (`ReviewAnnotationReader`, `AnnotationImportPlanner`, NL-COLLAB-08) — Square →
///    rectangle, Circle → ellipse, Polygon/cloud, PolyLine, Line/arrow, FreeText/callout, Ink,
///    Text notes, text markups — so the two paths can never disagree about a mapping.
/// 2. It shows what it found — how many of each kind, and what it cannot adopt (stamps, links,
///    widgets…) — and does nothing unless the person chooses Make Editable. Never on open.
/// 3. It adds the markups as **one undo step**, with each annotation's colour, width, opacity,
///    text and author.
/// 4. It hides each adopted original rather than deleting anything: the drawing file is never
///    changed. Which originals are hidden is *derived* from the markups present — an original is
///    hidden exactly while a markup with its identity exists — so Undo brings the originals back
///    and Redo hides them again, with no second state to fall out of step.
@MainActor
enum DrawingAnnotationAdoption {

    static let reviewIdentifier = "annotations.adopt.review"
    static let refusalIdentifier = "annotations.adopt.refused"
    /// The synthetic layer adopted originals are bound to, so the existing `shouldDisplay` path
    /// can hide them.
    static let adoptedLayer = PDFLayerID(rawValue: "zenit:adopted-annotations")

    /// What happened, for tests and the status note.
    enum Outcome: Equatable {
        case adopted(markups: Int)
        case cancelled
        case nothingToAdopt(String)
        case refused(String)
    }

    /// Reads, reviews and — on Make Editable — adopts. `confirm` defaults to the review alert;
    /// a test injects its own answer.
    @discardableResult
    static func run(
        document: ZenitPDFProjectDocument,
        window: NSWindow?,
        confirm: (@MainActor (AnnotationImportPlan) async -> Bool)? = nil
    ) async -> Outcome {
        guard let core = document.core, let drawing = document.drawing else { return .refused("no drawing") }
        let reading: ReviewAnnotationReader.Reading
        do {
            reading = try ReviewAnnotationReader.read(url: drawing.url)
        } catch {
            let reason = NSLocalizedString(
                "The drawing's annotations could not be read. A drawing locked with a password keeps them as they are.",
                comment: "Adopt annotations refusal when the file cannot be read"
            )
            refuse(reason, window: window)
            return .refused(reason)
        }
        let plan = await core.planReviewImport(reading)
        guard !plan.newMarkups.isEmpty else {
            let summary = plan.summary
            refuse(String(
                format: NSLocalizedString(
                    "There is nothing new to make editable. %@",
                    comment: "Adopt annotations: nothing to adopt; the placeholder is the scan summary"
                ),
                summary
            ), window: window)
            return .nothingToAdopt(summary)
        }
        let accepted: Bool
        if let confirm {
            accepted = await confirm(plan)
        } else {
            accepted = await review(plan, window: window)
        }
        guard accepted else { return .cancelled }
        do {
            var commands: [DocumentCommand] = plan.newMarkups.map { .addMarkup($0) }
            let byStatus = Dictionary(grouping: plan.statusChanges, by: \.status)
            for status in ZPDFContracts.MarkupStatus.allCases {
                guard let changes = byStatus[status], !changes.isEmpty else { continue }
                commands.append(.batchStatusChange(ids: changes.map(\.markupID), status: status))
            }
            try await core.commands.performBatch(
                commands,
                actionName: NSLocalizedString(
                    "Make Annotations Editable",
                    comment: "Undo action name for turning a drawing's annotations into Zenit markups"
                )
            )
            core.review.recordImportedReplies(plan.replies)
            document.adoptionReading = reading
            document.adoptionTouchedIDs.formUnion(plan.newMarkups.map(\.id.rawValue))
            await core.refresh()
        } catch {
            let reason = String(describing: error)
            refuse(reason, window: window)
            return .refused(reason)
        }
        await applyAdoptedVisibility(document: document)
        observeAdoption(document)
        return .adopted(markups: plan.newMarkups.count)
    }

    // MARK: - Review

    /// The review text: counts per kind, what is left out, and what happens to the originals.
    static func reviewText(_ plan: AnnotationImportPlan) -> (title: String, detail: String) {
        let byKind = Dictionary(grouping: plan.newMarkups, by: \.kind)
            .map { ($0.key.rawValue, $0.value.count) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0): \($0.1)" }
            .joined(separator: ", ")
        var detail = byKind
        if !plan.skipped.isEmpty {
            detail += "\n" + String(
                format: NSLocalizedString("Not adopted: %@", comment: "Adopt annotations review: what cannot be adopted"),
                plan.skipped.prefix(8).joined(separator: "; ")
            )
        }
        detail += "\n" + NSLocalizedString(
            "The originals are hidden, not deleted; the drawing file is not changed. Undo brings them back.",
            comment: "Adopt annotations review: what happens to the originals"
        )
        let title = String(
            format: NSLocalizedString(
                "Make %ld drawing annotations editable?",
                comment: "Adopt annotations review title; the placeholder is how many markups will be made"
            ),
            plan.newMarkups.count
        )
        return (title, detail)
    }

    private static func review(_ plan: AnnotationImportPlan, window: NSWindow?) async -> Bool {
        let text = reviewText(plan)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.detail
        alert.addButton(withTitle: NSLocalizedString("Make Editable", comment: "Adopt annotations review: confirm"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Sheet dismissal by Escape"))
        return await withCheckedContinuation { continuation in
            ZenitModalPresenter.runAlert(alert, identifier: reviewIdentifier, sheetedOn: window, answerWithoutAUser: .dismissed) { answer in
                continuation.resume(returning: answer.buttonIndex == 0)
            }
        }
    }

    private static func refuse(_ reason: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("No annotations were made editable.", comment: "Adopt annotations refusal title")
        alert.informativeText = reason
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert dismissal"))
        ZenitModalPresenter.runAlert(alert, identifier: refusalIdentifier, sheetedOn: window) { _ in }
    }

    // MARK: - Hiding the originals, derived from the markups present

    /// The bindings that hide adopted originals and show again the ones an undo released.
    ///
    /// Only annotations this command ever adopted (`touched`) are bound. An annotation nobody
    /// adopted is left alone entirely, so a drawing layer that hides it keeps it hidden.
    static func adoptedBindings(
        reading: ReviewAnnotationReader.Reading,
        markupIDs: Set<UUID>,
        touched: Set<UUID>
    ) -> [AnnotationLayerBindingReader.Binding] {
        var positionOnPage: [Int: Int] = [:]
        var bindings: [AnnotationLayerBindingReader.Binding] = []
        for annotation in reading.annotations {
            let position = positionOnPage[annotation.pageIndex, default: 0]
            positionOnPage[annotation.pageIndex] = position + 1
            guard annotation.inReplyToIndex == nil else { continue }
            let id = AnnotationImportPlanner.identity(of: annotation, fileDigest: reading.digest).rawValue
            guard touched.contains(id) else { continue }
            bindings.append(AnnotationLayerBindingReader.Binding(
                pageIndex: annotation.pageIndex,
                annotationIndex: position,
                layerID: markupIDs.contains(id) ? adoptedLayer : releasedLayer,
                annotationName: annotation.name,
                subtype: annotation.subtype,
                rect: CGRect(
                    x: annotation.rect.minX, y: annotation.rect.minY,
                    width: annotation.rect.width, height: annotation.rect.height
                ).standardized
            ))
        }
        return bindings
    }

    /// The layer an adopted original whose markup is gone is bound to: never hidden.
    static let releasedLayer = PDFLayerID(rawValue: "zenit:released-annotations")

    /// Hides the adopted originals and shows the rest, then re-renders the canvas.
    static func applyAdoptedVisibility(document: ZenitPDFProjectDocument) async {
        guard let reading = document.adoptionReading, let drawing = document.drawing, let core = document.core else { return }
        let ids = Set(core.snapshot.markups.map(\.id))
        let bindings = adoptedBindings(reading: reading, markupIDs: ids, touched: document.adoptionTouchedIDs)
        let changed = (try? await drawing.rasterSource.applyAnnotationLayerVisibility(
            bindings: bindings,
            hiddenLayerIDs: [adoptedLayer]
        )) ?? 0
        guard changed > 0 else { return }
        document.invalidateThumbnailsAfterLayerChange()
        document.rerenderAfterAnnotationDisplayChange()
    }

    /// Re-derives the originals' visibility whenever the document's markups change — an undo of
    /// the adoption removes the markups, and the originals come back.
    static func observeAdoption(_ document: ZenitPDFProjectDocument) {
        guard let core = document.core else { return }
        let ids = Set(core.snapshot.markups.map(\.id))
        withObservationTracking {
            _ = core.snapshot
        } onChange: { [weak document] in
            Task { @MainActor [weak document] in
                guard let document, let core = document.core else { return }
                if Set(core.snapshot.markups.map(\.id)) != ids {
                    await applyAdoptedVisibility(document: document)
                }
                observeAdoption(document)
            }
        }
    }

    // MARK: - Reopening a project

    /// On open: when the project already holds markups adopted from this drawing's annotations,
    /// hide those originals again — the hiding is view state, never written into the drawing,
    /// so a reopened project would otherwise show every adopted mark twice. The file is read
    /// off the main thread; nothing happens for a drawing without matching annotations.
    static func restoreOnOpen(_ document: ZenitPDFProjectDocument) {
        guard let drawing = document.drawing, let core = document.core, !core.snapshot.markups.isEmpty else { return }
        let url = drawing.url
        Task { @MainActor [weak document] in
            let reading = await Task.detached(priority: .utility) { try? ReviewAnnotationReader.read(url: url) }.value
            guard let document, let core = document.core, let reading, !reading.annotations.isEmpty else { return }
            let present = Set(core.snapshot.markups.map(\.id))
            let adopted = Set(reading.annotations.map {
                AnnotationImportPlanner.identity(of: $0, fileDigest: reading.digest).rawValue
            }).intersection(present)
            guard !adopted.isEmpty else { return }
            document.adoptionReading = reading
            document.adoptionTouchedIDs.formUnion(adopted)
            await applyAdoptedVisibility(document: document)
            observeAdoption(document)
        }
    }
}
