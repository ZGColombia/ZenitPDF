import AppKit
import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell

/// Arranging the set without touching the PDF (NL-DOCS-07 rotate and remove, NL-DOCS-16 crop):
/// every change is data, one undo step, persisted with the project, and changes no quantity.
extension ZenitPDFProjectDocument {

    /// The alert's identifier, for tests that answer it.
    static let removeMeasuredSheetsAlertIdentifier = "documents.remove-measured-sheets"

    /// Turns sheets by a quarter turn on screen: +90 clockwise, -90 anticlockwise.
    func rotatePages(_ ids: [PageID], by degrees: Int) async {
        guard let core, !ids.isEmpty else { return }
        let shown = Dictionary(core.document.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var views: [PageID: PageViewSettings?] = [:]
        for id in ids {
            let current = await core.session.pageView(of: id)
            let rotation = (shown[id.rawValue]?.viewRotation ?? current.rotation) + degrees
            views[id] = PageViewSettings(rotation: rotation, crop: current.crop)
        }
        await performArrangement(.setPageViews(views))
    }

    /// Shows only `rect` (page space) of a sheet; a turn it has is kept.
    func cropPage(_ id: PageID, to rect: PDFRectValue) async {
        guard let core, rect.size.width > 1, rect.size.height > 1 else { return }
        let current = await core.session.pageView(of: id)
        let crop = PDFRect(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height).standardized
        await performArrangement(.setPageViews([id: PageViewSettings(rotation: current.rotation, crop: crop)]))
    }

    /// Returns sheets to their whole page; a turn they have is kept.
    func clearCrop(_ ids: [PageID]) async {
        guard let core else { return }
        var views: [PageID: PageViewSettings?] = [:]
        for id in ids {
            let current = await core.session.pageView(of: id)
            views[id] = PageViewSettings(rotation: current.rotation, crop: nil)
        }
        await performArrangement(.setPageViews(views))
    }

    /// Removes sheets from the set, or puts removed ones back. Removing sheets that carry
    /// measurements asks first, because their rows leave the Quantity Ledger (they come back
    /// with the sheet, by ⌘Z or Restore, also after a save).
    func setPagesRemoved(_ ids: [PageID], removed: Bool, window: NSWindow?) async {
        guard let core, !ids.isEmpty else { return }
        if removed {
            let wanted = Set(ids)
            let measured = await core.session.orderedMarkups.filter { wanted.contains($0.pageID) && $0.measurement != nil }.count
            if measured > 0, !(await confirmRemovingMeasuredSheets(measurements: measured, sheets: ids.count, window: window)) {
                return
            }
        }
        await performArrangement(.setPagesExcluded(ids, excluded: removed))
    }

    /// Asks before measured sheets leave the set. A test answers through `ZenitModalPresenter`.
    private func confirmRemovingMeasuredSheets(measurements: Int, sheets: Int, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString(
                "Remove %d sheets with %d measurements from the set?",
                comment: "Alert title: remove sheets that carry measurements; sheet count, measurement count"
            ),
            sheets, measurements
        )
        alert.informativeText = NSLocalizedString(
            "Their measurements leave the Quantity Ledger. Nothing is deleted: Undo or Restore brings the sheets and their measurements back, also after saving.",
            comment: "Alert detail: removing measured sheets from the set is reversible"
        )
        alert.addButton(withTitle: NSLocalizedString("Remove from Set", comment: "Alert button: remove the sheets from the set"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
        return await withCheckedContinuation { continuation in
            ZenitModalPresenter.runAlert(
                alert,
                identifier: Self.removeMeasuredSheetsAlertIdentifier,
                sheetedOn: window,
                answerWithoutAUser: .button(1)
            ) { answer in
                continuation.resume(returning: answer.buttonIndex == 0)
            }
        }
    }

    /// One arrangement command through the bus: one undo step, and the tray hears a refusal.
    private func performArrangement(_ command: DocumentCommand) async {
        guard let core else { return }
        do {
            _ = try await core.commands.perform(command)
            await core.refresh()
        } catch {
            core.status.setActiveToolNote(String(
                format: NSLocalizedString("The sheets were not changed: %@", comment: "Status note: an arrangement was refused; the reason"),
                String(describing: error)
            ))
        }
    }

    /// Pushes what the Navigator shows beside the cards: the removed sheets, the sheets with no
    /// scale, and whether there is a revision to compare with. Called after every refresh.
    func refreshArrangementState(shell: ProjectShellEnvironment, snapshot: DocumentSnapshot) {
        let scaled = Set(snapshot.pageScales.keys)
        let unscaled = Set(snapshot.pages.map(\.id)).subtracting(scaled)
        if shell.unscaledPageIDs != unscaled { shell.unscaledPageIDs = unscaled }
        let hasRevision = newestRevision != nil
        if shell.hasPreviousRevision != hasRevision { shell.hasPreviousRevision = hasRevision }
        guard let core else { return }
        Task { @MainActor [weak shell] in
            let removed = await core.session.excludedPageDescriptors
            let identities = await core.session.sheetIdentities
            let sheets = removed.map { page in
                NavigatorRemovedSheet(
                    id: page.id.rawValue,
                    title: identities[page.id].flatMap { ZPDFUIPresentation.PageDescriptor.composedSheetName(number: $0.number, title: $0.title) }
                        ?? page.label
                )
            }
            if shell?.removedSheets != sheets { shell?.removedSheets = sheets }
        }
    }
}
