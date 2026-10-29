import AppKit
import Foundation
import Observation
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFUIPresentation

/// The review of proposed sheet-reference links (NL-DOCS-10): every link on or off, the
/// references to sheets the set does not hold listed apart, nothing created until accepted.
@MainActor
@Observable
final class SheetLinkReviewModel {
    /// One reference to a sheet the set does not hold, printed `count` times on one sheet.
    struct UnresolvedGroup: Hashable, Identifiable {
        var page: PageID
        var text: String
        var count: Int
        var id: String { "\(page.rawValue.uuidString)-\(text)" }
    }

    let proposals: [SheetReferenceLinker.Proposal]
    let unresolved: [SheetReferenceLinker.Unresolved]
    /// The references to missing sheets, one row per reference per sheet, in reading order
    /// (L-55: the same reference was listed once per time it was printed — six "TR-02" rows).
    let unresolvedGroups: [UnresolvedGroup]
    let sheetNames: [PageID: String]
    /// Every page's name for the rows: its sheet number, else its label, else "Page 3" (L-55:
    /// a reference on an unnamed sheet read "TR-02 on" with nothing after it).
    let pageNames: [PageID: String]
    private(set) var included: Set<String>
    var onAccept: (@MainActor ([SheetReferenceLinker.Proposal]) -> Void)?
    var onCancel: (@MainActor () -> Void)?

    init(result: SheetReferenceLinker.Result, sheetNames: [PageID: String], pageNames: [PageID: String] = [:]) {
        proposals = result.proposals
        unresolved = result.unresolved
        self.sheetNames = sheetNames
        self.pageNames = pageNames.merging(sheetNames) { _, sheet in sheet }
        var groups: [UnresolvedGroup] = []
        var index: [String: Int] = [:]
        for reference in result.unresolved {
            let key = "\(reference.page.rawValue.uuidString)-\(reference.text)"
            if let at = index[key] {
                groups[at].count += 1
            } else {
                index[key] = groups.count
                groups.append(UnresolvedGroup(page: reference.page, text: reference.text, count: 1))
            }
        }
        unresolvedGroups = groups
        included = Set(result.proposals.map(\.id))
    }

    func setIncluded(_ on: Bool, id: String) {
        if on { included.insert(id) } else { included.remove(id) }
    }

    /// The name a row gives the sheet a reference is printed on.
    func pageName(_ page: PageID) -> String {
        pageNames[page] ?? sheetNames[page] ?? NSLocalizedString("an unnamed sheet", comment: "Sheet link review: a sheet with no number, label or position")
    }

    /// "3/A-501 on A-101 → A-501".
    func proposalText(_ proposal: SheetReferenceLinker.Proposal) -> String {
        String(
            format: NSLocalizedString("%1$@ on %2$@ → %3$@", comment: "Sheet link row: the reference, the sheet it is on, the sheet it goes to"),
            proposal.text, pageName(proposal.page), proposal.targetNumber
        )
    }

    /// "TR-02 on Page 1" or "TR-02 on Page 1 · 6 times".
    func unresolvedText(_ group: UnresolvedGroup) -> String {
        let base = String(
            format: NSLocalizedString("%1$@ on %2$@", comment: "Unresolved reference row: the reference, the sheet it is on"),
            group.text, pageName(group.page)
        )
        guard group.count > 1 else { return base }
        return String(
            format: NSLocalizedString("%1$@ · %2$@", comment: "Unresolved reference row with a repeat count: the row, the count as '6 times'"),
            base,
            LocalizedPlural.string(
                "%lld times", count: group.count,
                one: NSLocalizedString("%lld time", comment: "How often a reference is printed on one sheet: once"),
                other: NSLocalizedString("%lld times", comment: "How often a reference is printed on one sheet; the count")
            )
        )
    }

    var summaryText: String {
        String(
            format: NSLocalizedString("%1$@ · %2$@", comment: "Sheet link review summary: the links phrase, the missing-sheets phrase"),
            LocalizedPlural.string(
                "%lld links to create", count: included.count,
                one: NSLocalizedString("%lld link to create", comment: "Sheet link review summary: one link"),
                other: NSLocalizedString("%lld links to create", comment: "Sheet link review summary: links; the count")
            ),
            LocalizedPlural.string(
                "%lld references to sheets not in the set", count: unresolvedGroups.count,
                one: NSLocalizedString("%lld reference to a sheet not in the set", comment: "Sheet link review summary: one missing-sheet reference"),
                other: NSLocalizedString("%lld references to sheets not in the set", comment: "Sheet link review summary: missing-sheet references; the count")
            )
        )
    }

    /// "Create 1 Link" / "Create 4 Links".
    var createTitle: String {
        LocalizedPlural.string(
            "Create %lld Links", count: included.count,
            one: NSLocalizedString("Create %lld Link", comment: "Sheet link review: create the one ticked link"),
            other: NSLocalizedString("Create %lld Links", comment: "Sheet link review: create the ticked links; the count")
        )
    }

    func accept() { onAccept?(proposals.filter { included.contains($0.id) }) }
    func cancel() { onCancel?() }
}

struct SheetLinkReviewView: View {
    @Bindable var model: SheetLinkReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: ZPDFSpacing.m) {
            Text(NSLocalizedString("Link sheet references", comment: "Sheet link review title")).zpdfText(.windowTitle, .textPrimary)
            Text(model.summaryText).zpdfText(.caption, .textSecondary)
            List {
                ForEach(model.proposals) { proposal in
                    Toggle(isOn: Binding(get: { model.included.contains(proposal.id) }, set: { model.setIncluded($0, id: proposal.id) })) {
                        Text(model.proposalText(proposal)).zpdfText(.body, .textPrimary)
                    }
                    .toggleStyle(.checkbox)
                }
                if !model.unresolvedGroups.isEmpty {
                    Section(NSLocalizedString("Sheets cited but not in the set", comment: "Sheet link review: references to missing sheets")) {
                        ForEach(model.unresolvedGroups) { group in
                            Text(model.unresolvedText(group)).zpdfText(.body, .textSecondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Spacer(minLength: 0)
                Button(NSLocalizedString("Cancel", comment: "Alert button")) { model.cancel() }.keyboardShortcut(.cancelAction)
                Button(model.createTitle) { model.accept() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.included.isEmpty)
            }
        }
        .padding(ZPDFSpacing.l)
        .frame(minWidth: 560, minHeight: 380)
        .background(ZPDFColor.background)
    }
}

extension ZenitPDFProjectDocument {

    /// How the review reaches the screen, returning its dismissal. A test injects a capture.
    static var sheetLinkReviewPresenter: (@MainActor (SheetLinkReviewModel, NSWindow?) -> () -> Void) = { model, window in
        guard ZenitModalPresenter.canPresentModally, let window else { return {} }
        let panel = NSWindow(contentViewController: NSHostingController(rootView: SheetLinkReviewView(model: model)))
        panel.styleMask = [.titled, .resizable]
        // Through the one modal door: recorded, and refused on a visible window in a
        // process with no user (R-039).
        ZenitModalPresenter.beginSheet(panel, on: window, identifier: "documents.sheet-link-review") {}
        return { [weak window, weak panel] in
            guard let window, let panel else { return }
            window.endSheet(panel)
        }
    }

    /// Every page's name in the link review: its sheet number, else its printed label, else its
    /// place in the set ("Page 3") — never empty (L-55).
    static func sheetLinkPageNames(pages: [ZPDFContracts.PageDescriptor], sheets: [PageID: String]) -> [PageID: String] {
        var names: [PageID: String] = [:]
        for (position, page) in pages.enumerated() {
            if let sheet = sheets[page.id] {
                names[page.id] = sheet
            } else {
                let label = page.label.trimmingCharacters(in: .whitespacesAndNewlines)
                names[page.id] = String(
                    format: NSLocalizedString("Page %@", comment: "A page named by its label or its one-based place in the set"),
                    label.isEmpty ? String(position + 1) : label
                )
            }
        }
        return names
    }

    /// Link Sheet References…: reads every sheet's text, proposes the links, and on acceptance
    /// creates them as hyperlink markups in one undo step (NL-DOCS-10).
    func linkSheetReferences(window: NSWindow?) async {
        guard let core else { return }
        let pages = await core.session.pageDescriptors
        let identities = await core.session.sheetIdentities
        var sheets: [PageID: String] = [:]
        for page in pages {
            if let number = identities[page.id]?.number {
                sheets[page.id] = number
            } else if !page.label.isEmpty, !page.label.allSatisfy(\.isNumber) {
                sheets[page.id] = page.label
            }
        }
        guard !sheets.isEmpty else {
            core.status.setActiveToolNote(NSLocalizedString(
                "Name the sheets first: links are made to sheet numbers.",
                comment: "Status note: Link Sheet References without sheet numbers"
            ))
            return
        }
        var lines: [PageID: [SheetReferenceLinker.TextLine]] = [:]
        for page in pages {
            guard let drawing = loadedDrawing(forPage: page.id.rawValue) else { continue }
            let read = (try? await drawing.rasterSource.pageTextLines(pageIndex: page.index)) ?? []
            lines[page.id] = read.map { SheetReferenceLinker.TextLine(text: $0.text, bounds: PDFRect(
                x: $0.boundsInPageSpace.origin.x, y: $0.boundsInPageSpace.origin.y,
                width: $0.boundsInPageSpace.width, height: $0.boundsInPageSpace.height
            )) }
        }
        let result = SheetReferenceLinker.scan(sheets: sheets, lines: lines)
        let model = SheetLinkReviewModel(result: result, sheetNames: sheets, pageNames: Self.sheetLinkPageNames(pages: pages, sheets: sheets))
        var dismiss: () -> Void = {}
        model.onCancel = { dismiss() }
        model.onAccept = { [weak self] chosen in
            dismiss()
            guard let self, let core = self.core, !chosen.isEmpty else { return }
            let records = SheetReferenceLinker.markups(for: chosen, documentID: self.drawing?.documentID ?? DocumentID(UUID()), now: Date())
            Task { @MainActor in
                do {
                    _ = try await core.commands.performBatch(
                        records.map { .addMarkup($0) },
                        actionName: NSLocalizedString("Link Sheet References", comment: "Undo action name: sheet reference links created")
                    )
                    await core.refresh()
                    core.status.setActiveToolNote(LocalizedPlural.string(
                        "%lld links created.", count: records.count,
                        one: NSLocalizedString("%lld link created.", comment: "Status note after linking one sheet reference"),
                        other: NSLocalizedString("%lld links created.", comment: "Status note after linking sheet references; the count")
                    ))
                } catch {
                    core.status.setActiveToolNote(String(describing: error))
                }
            }
        }
        dismiss = Self.sheetLinkReviewPresenter(model, window)
    }
}
