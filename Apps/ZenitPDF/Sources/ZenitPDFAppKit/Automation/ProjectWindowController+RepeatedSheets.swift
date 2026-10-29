import AppKit
import CoreGraphics
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// Measure ▸ Find Repeated Sheets… (NL-AUTO-21): sheets whose linework is the same drawing — the
/// typical floor of a block, drawn once per storey — found by comparing their geometry, so the
/// person measures one and applies it ×N through the ledger's Repeat × column instead of measuring
/// every storey again. The multiplier is shown before it is applied, applied only on a click, and
/// one ⌘Z takes it back.
extension ProjectWindowController {

    static let repeatedSheetsIdentifier = "automation.repeatedSheets"

    /// One group as the prompt shows it: the sheet to measure, and the sheets like it.
    struct RepeatedSheetGroup: Equatable {
        let firstPageID: PageID
        let pageIDs: [PageID]
        let labels: [String]
        var multiplier: Int { pageIDs.count }
    }

    /// What the prompt for one group has to say (X-014): the measurements ×N would apply to,
    /// the ones already on the group's other sheets — which ×N would count a second time — and
    /// the ones on the first sheet that already repeat, whose count ×N multiplies.
    struct RepeatedSheetsPrompt: Equatable {
        let group: RepeatedSheetGroup
        /// Measurements on the group's first sheet.
        let measurementCount: Int
        /// Measurements on the group's other sheets.
        var measuredElsewhere: Int = 0
        /// First-sheet measurements whose Repeat × is already above once.
        var alreadyRepeated: Int = 0

        /// Whether applying could count a sheet twice or change a repetition someone set: the
        /// prompt then says so and Not Now is its default button.
        var needsCare: Bool { measuredElsewhere > 0 || alreadyRepeated > 0 }
    }

    /// How a group is decided: `true` applies ×N. Injectable; the shipping value is an alert.
    static var repeatedSheetsDecision: (@MainActor (RepeatedSheetsPrompt, NSWindow?) async -> Bool) = { prompt, window in
        await withCheckedContinuation { continuation in
            ZenitModalPresenter.runAlert(repeatedSheetsAlert(prompt), identifier: repeatedSheetsIdentifier, sheetedOn: window) { answer in
                continuation.resume(returning: answer.buttonIndex == 0)
            }
        }
    }

    /// The prompt for one group; its first button applies ×N. Return answers it, except when the
    /// prompt needs care (X-014): then Return is Not Now, so a reflex keypress cannot count the
    /// other sheets' measurements twice or replace a repetition already set.
    static func repeatedSheetsAlert(_ prompt: RepeatedSheetsPrompt) -> NSAlert {
        let group = prompt.group
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Measure once, apply ×%d?", comment: "Repeated sheets prompt title; multiplier"), group.multiplier)
        alert.informativeText = repeatedSheetsMessage(
            group, measurementCount: prompt.measurementCount,
            measuredElsewhere: prompt.measuredElsewhere, alreadyRepeated: prompt.alreadyRepeated
        )
        let apply = alert.addButton(withTitle: String(format: NSLocalizedString("Apply ×%d", comment: "Repeated sheets: apply the multiplier"), group.multiplier))
        let notNow = alert.addButton(withTitle: NSLocalizedString("Not Now", comment: "Repeated sheets: decline"))
        if prompt.needsCare {
            apply.keyEquivalent = ""
            notNow.keyEquivalent = "\r"
        }
        return alert
    }

    /// The prompt's body. It states the bound the sheets matched within rather than calling them
    /// "the same drawing" (S-099): the check is geometric, and the person decides whether the
    /// floors really repeat. Measurements already on the other sheets, and first-sheet ones that
    /// already repeat, are named (X-014): the prompt used to assume neither existed.
    static func repeatedSheetsMessage(
        _ group: RepeatedSheetGroup, measurementCount: Int, measuredElsewhere: Int = 0, alreadyRepeated: Int = 0
    ) -> String {
        let bound = String(format: "%.2f", RepeatedSheetDetector.defaultTolerancePoints * 25.4 / 72)
        var message = String(
            format: NSLocalizedString("Sheets %1$@ have the same linework: every line lies within %2$@ mm of a line on the other sheet. The %3$d measurements on %4$@ can count ×%5$d in the Quantity Ledger (Repeat ×), instead of measuring the other sheets again. Nothing changes unless you apply it.", comment: "Repeated sheets prompt body; sheet list, match bound in millimetres on paper, measurement count, first sheet, multiplier"),
            AppLanguageList.joined(group.labels), bound, measurementCount, group.labels.first ?? "", group.multiplier)
        if measuredElsewhere > 0 {
            message += " " + String(
                format: NSLocalizedString("Already measured on the other sheets: %1$d. Applying ×%2$d would count those sheets twice.", comment: "Repeated sheets prompt: measurements already on the other sheets of the group; count, multiplier"),
                measuredElsewhere, group.multiplier)
        }
        if alreadyRepeated > 0 {
            message += " " + String(
                format: NSLocalizedString("Already repeating on %2$@: %1$d. Applying multiplies their Repeat × by %3$d.", comment: "Repeated sheets prompt: first-sheet measurements that already carry a repetition; count, first sheet, multiplier"),
                alreadyRepeated, group.labels.first ?? "", group.multiplier)
        }
        return message
    }

    func findRepeatedSheets(for document: ZenitPDFProjectDocument) {
        Task { @MainActor in _ = await self.runRepeatedSheets(for: document) }
    }

    /// The whole command. Returns the groups found, for tests.
    ///
    /// Every sheet of the set, each read from its own drawing (T-005): the primary PDF's pages
    /// used to be walked, so a sheet removed from the set was still fingerprinted and counted in
    /// the Repeat × multiplier, and the sheets of added drawings were never compared. Sheets are
    /// keyed by their place in the set, since a PDF page index repeats across the drawings.
    @discardableResult
    func runRepeatedSheets(for document: ZenitPDFProjectDocument) async -> [RepeatedSheetGroup] {
        guard let core = document.core, document.drawing != nil else { return [] }
        core.status.setActiveToolNote(NSLocalizedString("Comparing the sheets…", comment: "Repeated sheets: running"))
        let setPages = await core.session.pageDescriptors
        var signatures: [(page: Int, signature: RepeatedSheetDetector.Signature)] = []
        for (position, page) in setPages.enumerated() {
            guard let extraction = try? await automationExtraction(for: document, page: page) else { continue }
            let size = CGSize(width: page.boxes.crop.size.width, height: page.boxes.crop.size.height)
            // The layer panel is the primary drawing's: its hidden layers name nothing on a sheet
            // of another drawing (U-012, the one rule).
            let hidden = document.hiddenLayerNames(for: page, snap: false)
            let signature = await Task.detached(priority: .userInitiated) {
                RepeatedSheetDetector.signature(page: extraction, pageSize: size, layerFilter: VectorLayerVisibilityFilter(hiddenLayerIDs: hidden))
            }.value
            signatures.append((position, signature))
        }
        let found = await Task.detached(priority: .userInitiated) { RepeatedSheetDetector.groups(signatures) }.value
        let labels = Dictionary(core.snapshot.pages.map { ($0.id, $0.label ?? String($0.index + 1)) }, uniquingKeysWith: { first, _ in first })
        let groups: [RepeatedSheetGroup] = found.compactMap { positions in
            let members = positions.filter(setPages.indices.contains)
            guard let first = members.first else { return nil }
            return RepeatedSheetGroup(firstPageID: setPages[first].id, pageIDs: members.map { setPages[$0].id },
                                      labels: members.map { labels[setPages[$0].id.rawValue] ?? String($0 + 1) })
        }
        guard !groups.isEmpty else {
            core.status.setActiveToolNote(NSLocalizedString("No two sheets of this drawing have the same linework.", comment: "Repeated sheets: none found"))
            return []
        }
        core.status.setActiveToolNote(String(format: NSLocalizedString("%d groups of repeated sheets found.", comment: "Repeated sheets: groups found"), groups.count))
        for group in groups {
            let markups = await core.session.orderedMarkups.filter { $0.kind == .measurement }
            let measurements = markups.filter { $0.pageID == group.firstPageID }
            let others = Set(group.pageIDs.dropFirst())
            let prompt = RepeatedSheetsPrompt(
                group: group,
                measurementCount: measurements.count,
                measuredElsewhere: markups.filter { others.contains($0.pageID) }.count,
                alreadyRepeated: measurements.filter(RepetitionColumn.isRepeated).count
            )
            guard await Self.repeatedSheetsDecision(prompt, window) else { continue }
            guard !measurements.isEmpty else {
                core.status.setActiveToolNote(String(format: NSLocalizedString("Measure %@ first, then apply it to the sheets like it.", comment: "Repeated sheets: nothing measured on the first sheet"), group.labels.first ?? ""))
                continue
            }
            // A repetition already set is multiplied, never replaced (X-014): a mirrored unit at
            // ×2 on a floor that repeats on N sheets counts ×2N. It used to become ×N.
            let commands = measurements.map {
                RepetitionColumn.edit(markupID: $0.id, count: Self.repeatedCount(RepetitionColumn.count(of: $0), times: group.multiplier))
            }
            do {
                try await core.commands.performBatch(commands, actionName: String(format: NSLocalizedString("Apply ×%d", comment: "Undo action name: apply a repetition multiplier"), group.multiplier))
                await core.commands.settle()
                await core.refresh()
            } catch {
                core.status.setActiveToolNote(String(describing: error))
            }
        }
        return groups
    }

    /// A measurement's Repeat × after a group of `multiplier` sheets is applied to it: its own
    /// count times the group's, held to the column's maximum (X-014).
    static func repeatedCount(_ current: Int, times multiplier: Int) -> Int {
        let (product, overflow) = Swift.max(RepetitionColumn.defaultCount, current).multipliedReportingOverflow(by: Swift.max(1, multiplier))
        return overflow ? RepetitionColumn.maximumCount : Swift.min(product, RepetitionColumn.maximumCount)
    }
}
