import Foundation
import ZPDFContracts
import ZPDFPersistence

extension AppCoreEnvironment {

    /// Plans a review import against the document as it stands (NL-COLLAB-08).
    ///
    /// The file is the document's own drawing — every import flow reads that PDF or an XFDF made
    /// on it — so its annotations land on that drawing's sheets in the set, matched by PDF page
    /// index (S-030). Each page keeps its real drawing identity, so another drawing of a
    /// multi-drawing set never receives them.
    public func planReviewImport(_ reading: ReviewAnnotationReader.Reading) async -> AnnotationImportPlan {
        let drawing = DocumentID(snapshot.documentID)
        let pages = await session.pageDescriptors.filter { $0.documentID == drawing }.sorted { $0.index < $1.index }
        let existing = Set(await session.orderedMarkups.map(\.id.rawValue))
        let replies = Set(review.entries.compactMap { UUID(uuidString: $0.id) })
        let plan = AnnotationImportPlanner.plan(
            annotations: reading.annotations,
            pages: pages,
            documentID: drawing,
            existingMarkupIDs: existing,
            existingReplyIDs: replies,
            fileDigest: reading.digest,
            annotationsOverBudget: reading.annotationsOverBudget
        )
        // NL-MEASURE-16: measurement annotations become live measurements on
        // calibrated pages (Measure/MeasuredAnnotationImport.swift).
        var converted = MeasuredAnnotationImport.converting(
            plan,
            annotations: reading.annotations,
            fileDigest: reading.digest,
            calibratedPages: Set(await session.pageScales.keys)
        )
        // Each measured at the scale of where it lies, through the decision paste and drawing
        // take (T-025). They were measured at the page scale whatever region they lay in: a
        // PolyLineDimension inside a 1:20 detail on a 1:100 sheet read five times too long.
        let placed = await placingByScaleRegions(
            converted.newMarkups,
            unmeasured: Dictionary(plan.newMarkups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
        converted.newMarkups = placed.records
        converted.measurementsAcrossScaleRegions = placed.acrossRegions
        return converted
    }

    /// `records` with every measurement placed by ``scaleRegionPlacement(of:)``: inside one region
    /// its scale, outside every region the page default. One lying across regions is replaced by
    /// its `unmeasured` markup, or left out when there is none, and counted.
    func placingByScaleRegions(
        _ records: [ZPDFContracts.MarkupRecord],
        unmeasured: [MarkupID: ZPDFContracts.MarkupRecord] = [:]
    ) async -> (records: [ZPDFContracts.MarkupRecord], acrossRegions: Int) {
        var placed: [ZPDFContracts.MarkupRecord] = []
        var across = 0
        for original in records {
            var record = original
            guard record.tool != nil, record.parentMarkupID == nil else {
                placed.append(record)
                continue
            }
            switch await scaleRegionPlacement(of: record) {
            case let .region(regionID, scaleID):
                record.scaleRegionID = regionID
                record.scaleID = scaleID
            case .pageDefault:
                record.scaleRegionID = nil
                record.scaleID = nil
            case .held:
                across += 1
                if let plain = unmeasured[record.id] { placed.append(plain) }
                continue
            }
            record.scaleVersion = nil
            placed.append(record)
        }
        return (placed, across)
    }

    /// How many pages the document's own drawing has — its PDF's, removed sheets included — which
    /// is what a review file made on that drawing must match. The set's sheet count is not: it
    /// drops removed sheets and adds the other drawings of a multi-drawing set (S-030).
    public func reviewDrawingPageCount() async -> Int {
        await session.knownPages(ofDrawing: DocumentID(snapshot.documentID)).count
    }

    /// Applies an accepted plan: every new markup and every status change as **one** undoable
    /// step, then the replies into their threads.
    ///
    /// Replies are records of what the reviewer wrote, keyed by stable ids, so they are not on
    /// the undo stack: undoing the import removes the markups, their threads wait under the same
    /// ids, and a redo — or a second import of the same file — finds them again without doubling.
    @discardableResult
    public func acceptReviewImport(_ plan: AnnotationImportPlan) async throws -> DocumentBatchOutcome? {
        // Placed again against the regions as they stand now, so no add path reaches the document
        // with a scale nobody resolved (T-025); the plan did it for the preview.
        let markups = await placingByScaleRegions(plan.newMarkups).records
        var commands: [DocumentCommand] = markups.map { .addMarkup($0) }
        let byStatus = Dictionary(grouping: plan.statusChanges, by: \.status)
        for status in ZPDFContracts.MarkupStatus.allCases {
            guard let changes = byStatus[status], !changes.isEmpty else { continue }
            commands.append(.batchStatusChange(ids: changes.map(\.markupID), status: status))
        }
        let outcome = try await commands.isEmpty ? nil : self.commands.performBatch(
            commands,
            actionName: NSLocalizedString("Import Review Annotations", comment: "Undo action name for importing a reviewer's PDF annotations")
        )
        review.recordImportedReplies(plan.replies)
        review.markChangedElsewhere(
            markups.map(\.id.rawValue) + plan.statusChanges.map(\.markupID.rawValue) + plan.replies.map(\.markupID.rawValue)
        )
        await refresh()
        return outcome
    }
}

extension AppReviewPresenter {

    /// Stores replies read from a reviewer's file, under their stable ids, without an undo step
    /// (see ``AppCoreEnvironment/acceptReviewImport(_:)``). A reply already present is left as is.
    public func recordImportedReplies(_ replies: [AnnotationImportPlan.Reply], origin: String = "pdf-import") {
        let known = Set(entries.map(\.id))
        let records = replies
            .filter { !known.contains($0.id.uuidString) }
            .map { reply in
                ReviewEntryRecord(
                    id: reply.id.uuidString,
                    projectId: currentProjectID,
                    markupId: reply.markupID.rawValue.uuidString,
                    authorName: reply.author.isEmpty
                        ? NSLocalizedString("Reviewer", comment: "Author of an imported reply whose file named nobody")
                        : reply.author,
                    body: reply.body,
                    createdAt: PersistenceTimestamp.string(from: reply.createdAt),
                    origin: origin
                )
            }
        recordWithoutUndo(records)
    }
}
