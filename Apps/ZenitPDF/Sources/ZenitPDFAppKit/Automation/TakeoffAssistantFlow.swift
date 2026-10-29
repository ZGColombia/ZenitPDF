import AppKit
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFDesignSystem
import ZPDFSnapEngine
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// Measure ▸ Prepare This Set… and Measure ▸ Takeoff Assistant Inbox (NL-AUTO-16).
///
/// Prepare walks every sheet of the drawing and files what the detectors propose — the sheet's
/// name from its title block, its scale, its rooms — in the project's inbox. The inbox lists the
/// proposals sheet by sheet; Accept runs the ordinary command (name the sheet, set the preset
/// scale, add the room as an area recording that the detector found it), Reject records the
/// decision so a rerun does not offer it again. Nothing is committed without a click, and
/// nothing leaves this Mac.
extension ProjectWindowController {

    func prepareSet(for document: ZenitPDFProjectDocument) {
        // One run per drawing at a time: two would interleave their progress notes and file
        // the same sheets twice.
        guard !document.automation.isPreparingSet else {
            document.core?.status.setActiveToolNote(NSLocalizedString(
                "Prepare This Set is already running on this drawing.",
                comment: "Takeoff Assistant: a second Prepare while one runs"))
            return
        }
        Task { @MainActor in _ = await self.runTakeoffAssistant(for: document) }
    }

    /// What the assistant read of one sheet before its detectors run.
    struct AssistantSheetRead: Sendable {
        var lines: [RecognisedTextLine]
        /// The sheet's linework, or `nil` when it could not be read (then no rooms or symbols).
        var extraction: VectorPageExtraction?
    }

    /// How one sheet is read: its text and its linework. Injectable so a test can stand in a
    /// reader that never answers; the shipping value is the two readers every automation uses.
    static var assistantSheetReader: (@MainActor (ProjectWindowController, ZenitPDFProjectDocument, ZPDFContracts.PageDescriptor) async -> AssistantSheetRead) = { controller, document, page in
        let lines = await PageTextLoader.lines(document: document, page: page, region: nil, allowRegionOCR: false).map(\.recognisedTextLine)
        let extraction = try? await controller.automationExtraction(for: document, page: page)
        return AssistantSheetRead(lines: lines, extraction: extraction)
    }

    /// The longest one sheet's reading may take before the run goes on without it (L-75):
    /// four times the geometry service's own 30 s request deadline, so a sheet the service
    /// answers slowly, even after one restart, is never cut short, and a reader that never
    /// answers costs two minutes instead of the whole run. Injectable for tests.
    static var assistantSheetReadDeadline: Duration = .seconds(120)

    /// Waits for `body` at most `deadline`; `nil` when the deadline came first. A body that
    /// never resumes is left suspended — the run it belonged to has already gone on.
    static func assistantRead<T: Sendable>(within deadline: Duration, _ body: @escaping @MainActor () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = AssistantReadOnce(continuation)
            // Both tasks start after this closure returns, on the main actor, so each finds the
            // other's handle in place: a finished read stops the clock, an expired clock cancels
            // the read.
            once.clock = Task { @MainActor in
                do { try await Task.sleep(for: deadline) } catch { return }
                once.resume(nil)
                once.work?.cancel()
            }
            once.work = Task { @MainActor in
                let value = await body()
                once.clock?.cancel()
                once.resume(value)
            }
        }
    }

    /// The whole run. Returns how many proposals were filed, for tests.
    ///
    /// Every sheet of the set, each read from its own drawing (T-005): the primary PDF's pages
    /// used to be walked, so a sheet removed from the set got proposals and the sheets of added
    /// drawings got none. A proposal's `pageIndex` is the sheet's place in the set, which is the
    /// order the Inbox lists them in — a PDF page index repeats across the drawings.
    ///
    /// The run always ends with its result in the status note (L-75). It used to report only
    /// through a notice in the warnings tray and leave the note at "Preparing sheet 3 of 3…",
    /// so on a three-sheet set the run looked stalled for good; and a sheet whose
    /// linework could not be read was dropped from the search without a word. A sheet whose
    /// reading does not finish within ``assistantSheetReadDeadline`` is now passed over and named.
    @discardableResult
    func runTakeoffAssistant(for document: ZenitPDFProjectDocument) async -> Int {
        guard let core = document.core, document.drawing != nil else { return 0 }
        document.automation.isPreparingSet = true
        defer { document.automation.isPreparingSet = false }
        let inbox = document.automation.inbox
        await document.attachInboxIfNeeded()
        var filed = 0
        var unreadLinework = 0
        var timedOut: [String] = []
        let pages = await core.session.pageDescriptors
        // The person's library symbols are searched on every sheet (NL-AUTO-13); an unreadable
        // library is searched as empty rather than stopping the run.
        let library = (try? Self.symbolLibrary.entries()) ?? []
        for (position, page) in pages.enumerated() {
            core.status.setActiveToolNote(String(format: NSLocalizedString("Preparing sheet %1$d of %2$d…", comment: "Takeoff Assistant progress; sheet, total"), position + 1, pages.count))
            let reader = Self.assistantSheetReader
            guard let read = await Self.assistantRead(within: Self.assistantSheetReadDeadline, { [weak self] () -> AssistantSheetRead in
                guard let self else { return AssistantSheetRead(lines: [], extraction: nil) }
                return await reader(self, document, page)
            }) else {
                timedOut.append(AssistantInboxWindow.pageLabel(for: page.id.rawValue, in: document).nonEmpty ?? String(position + 1))
                continue
            }
            if read.extraction == nil { unreadLinework += 1 }
            let lines = read.lines
            let extraction = read.extraction
            let scale = await core.session.scale(onPage: page.id)
            var metresPerPoint: Double?
            if let scale {
                let value = scale.matrix.map(PDFPoint(x: 0, y: 0)).distance(to: scale.matrix.map(PDFPoint(x: 1, y: 0)))
                if value.isFinite, value > 0 { metresPerPoint = value }
            }
            let summary = core.snapshot.pages.first { $0.id == page.id.rawValue }
            var filter = document.automation.traceChoices
            // The layer panel is the primary drawing's; it hides nothing on another drawing's sheet.
            filter.hiddenLayerIDs = document.hiddenLayerNames(for: page, snap: true)
            let input = AssistantPageInput(
                pageID: page.id.rawValue, pageIndex: position,
                pageBox: PDFRectValue(x: page.boxes.crop.origin.x, y: page.boxes.crop.origin.y, width: page.boxes.crop.size.width, height: page.boxes.crop.size.height),
                lines: lines, primitives: extraction?.primitives, metresPerPoint: metresPerPoint,
                isNamed: summary?.sheetNumber != nil, hasScale: scale != nil)
            let options = Self.roomOptions(metresPerPoint: metresPerPoint)
            let chosen = filter
            let proposals = await Task.detached(priority: .userInitiated) {
                TakeoffAssistant.proposals(for: input, roomOptions: options, filter: chosen, library: library)
            }.value
            filed += await inbox.file(proposals, forPage: page.id.rawValue).count
        }
        let result = Self.assistantResult(sheets: pages.count, filed: filed, open: inbox.openProposals.count,
                                          unreadLinework: unreadLinework, timedOut: timedOut)
        // The note is where the run said "Preparing sheet n of n…"; the result replaces it.
        core.status.setActiveToolNote(result)
        core.document.post(AppWarning(
            id: Self.assistantNoteID, severity: .info,
            title: result,
            message: String(format: NSLocalizedString("Nothing was changed. Accept or reject each proposal in %@.", comment: "Takeoff Assistant result detail; the Inbox command's path in the menu bar"),
                            ZenitAppCommandTable.menuPath(for: .assistantInbox)),
            source: NSLocalizedString("Takeoff Assistant", comment: "Warning source: the Takeoff Assistant"),
            isDismissible: true, timestamp: Date()))
        return filed
    }

    /// The run's result, as the status note and the notice say it (L-75): how many sheets were
    /// prepared, what is waiting in the Inbox, and every sheet that was not fully read.
    static func assistantResult(sheets: Int, filed: Int, open: Int, unreadLinework: Int, timedOut: [String]) -> String {
        var parts: [String] = []
        let prepared = sheets - timedOut.count
        if filed == 0 {
            parts.append(String(format: NSLocalizedString(
                "Prepared %1$d of %2$d sheets. Nothing to review: the assistant found no names, scales, rooms or library symbols to propose.",
                comment: "Takeoff Assistant result: nothing found; sheets prepared, sheets in the set"), prepared, sheets))
        } else {
            parts.append(String(format: NSLocalizedString(
                "Prepared %1$d of %2$d sheets. %3$d to review in the Takeoff Assistant Inbox.",
                comment: "Takeoff Assistant result; sheets prepared, sheets in the set, open proposals"), prepared, sheets, open))
        }
        if unreadLinework == 1 {
            parts.append(NSLocalizedString(
                "The linework of 1 sheet could not be read, so its rooms and symbols were not searched.",
                comment: "Takeoff Assistant result: one sheet's vector geometry could not be read"))
        } else if unreadLinework > 1 {
            parts.append(String(format: NSLocalizedString(
                "The linework of %d sheets could not be read, so their rooms and symbols were not searched.",
                comment: "Takeoff Assistant result: several sheets' vector geometry could not be read; count"), unreadLinework))
        }
        if !timedOut.isEmpty {
            parts.append(String(format: NSLocalizedString(
                "Not read in time, so passed over: %@. Run Prepare This Set again to retry.",
                comment: "Takeoff Assistant result: sheets whose reading did not finish; the sheet names"),
                AppLanguageList.joined(timedOut)))
        }
        return parts.joined(separator: " ")
    }

    static let assistantNoteID = UUID(uuidString: "4A9B8C7D-6E5F-4A3B-9C2D-1E0F2A3B4C5D")!

    func showAssistantInbox(for document: ZenitPDFProjectDocument) {
        Task { @MainActor in
            await document.attachInboxIfNeeded()
            AssistantInboxWindow.present(for: self, document: document)
        }
    }

    /// Carries out one accepted proposal through the command bus and records the decision.
    /// Returns whether it was applied.
    @discardableResult
    func acceptAssistantProposal(_ proposal: AssistantProposal, document: ZenitPDFProjectDocument) async -> Bool {
        guard let core = document.core else { return false }
        let page = PageID(proposal.pageID)
        do {
            switch proposal.kind {
            case .sheetName:
                try await core.commands.perform(.setSheetIdentities(
                    [page: SheetIdentity(number: proposal.sheetNumber, title: proposal.sheetTitle, source: .titleBlockText)],
                    overwriteManual: false))
            case .scale:
                // Never over a scale a person set since the proposal was filed.
                guard await core.session.scale(onPage: page) == nil,
                      let numerator = proposal.ratioNumerator.flatMap({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }),
                      let denominator = proposal.ratioDenominator.flatMap({ Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) })
                else {
                    await document.automation.inbox.decide(proposal.id, .rejected)
                    return false
                }
                _ = try await core.commands.setPresetScale(page: page, ratioNumerator: numerator, ratioDenominator: denominator,
                                                           label: proposal.scaleDisplay ?? "")
            case .room:
                guard let ring = proposal.roomRing, ring.count >= 3 else { return false }
                let documentID = await core.session.documentID
                let now = Date()
                let record = CaptureStamp.stamped(MarkupRecord(
                    id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: .area,
                    subject: proposal.roomName ?? NSLocalizedString("Area", comment: "Nameless area in the printed-area check"),
                    geometry: MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: ring, isClosed: true))]),
                    createdAt: now, modifiedAt: now), method: CaptureMethod(kind: .roomDetected))
                try await core.commands.perform(.addMarkup(record))
            case .symbols:
                guard let positions = proposal.symbolPositions, !positions.isEmpty else { return false }
                let documentID = await core.session.documentID
                let now = Date()
                // One count of every hit, as a symbol review would land it, marked as matched.
                let record = CaptureStamp.stamped(MarkupRecord(
                    id: MarkupID(UUID()), documentID: documentID, pageID: page, kind: .measurement, tool: .count,
                    subject: proposal.symbolDesignation ?? "",
                    geometry: Self.scheduleCountGeometry(pageID: page, positions: positions),
                    createdAt: now, modifiedAt: now), method: CaptureMethod(kind: .symbolMatched))
                try await core.commands.perform(.addMarkup(record))
            }
        } catch {
            core.status.setActiveToolNote(String(describing: error))
            return false
        }
        await document.automation.inbox.decide(proposal.id, .accepted)
        await core.commands.settle()
        await core.refresh()
        return true
    }
}

/// Resumes an ``ProjectWindowController/assistantRead(within:_:)`` wait exactly once: with the
/// sheet's reading, or with `nil` when the deadline came first.
@MainActor
private final class AssistantReadOnce<T: Sendable> {
    private var continuation: CheckedContinuation<T?, Never>?
    var clock: Task<Void, Never>?
    var work: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension ZenitPDFProjectDocument {
    /// Points the inbox at the project, once; a Quick PDF keeps it in memory until saved.
    func attachInboxIfNeeded() async {
        guard !automation.inboxAttached || automation.inboxPackageIdentity != projectPackage.map(ObjectIdentifier.init) else { return }
        automation.inboxAttached = true
        automation.inboxPackageIdentity = projectPackage.map(ObjectIdentifier.init)
        await automation.inbox.attach(package: projectPackage)
    }
}

/// The inbox as a list, sheet by sheet, with Accept and Reject on every proposal.
struct AssistantInboxView: View {
    let inbox: AutomationInbox
    let pageLabel: (UUID) -> String
    let onAccept: (AssistantProposal) -> Void
    let onReject: (AssistantProposal) -> Void

    var body: some View {
        let open = inbox.openProposals
        let pages = Array(Set(open.map(\.pageID))).sorted { lhs, rhs in
            (open.first { $0.pageID == lhs }?.pageIndex ?? 0) < (open.first { $0.pageID == rhs }?.pageIndex ?? 0)
        }
        VStack(alignment: .leading, spacing: 0) {
            ZPDFPanelHeader(title: String(format: NSLocalizedString("%d to review", comment: "Takeoff Assistant Inbox header; count"), open.count))
            if open.isEmpty {
                Text(String(format: NSLocalizedString("Nothing to review. %@ fills the inbox.", comment: "Empty Takeoff Assistant Inbox; the Prepare command's path in the menu bar"),
                            ZenitAppCommandTable.menuPath(for: .prepareSet)))
                    .foregroundStyle(ZPDFColor.textSecondary)
                    .padding(ZPDFSpacing.m)
            } else {
                List {
                    ForEach(pages, id: \.self) { page in
                        Section(pageLabel(page)) {
                            ForEach(open.filter { $0.pageID == page }) { proposal in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(proposal.summary)
                                        Text(String(format: NSLocalizedString("%d %% sure", comment: "Proposal confidence"), Int((proposal.confidence * 100).rounded())))
                                            .font(.caption)
                                            .foregroundStyle(ZPDFColor.textSecondary)
                                    }
                                    Spacer()
                                    Button(NSLocalizedString("Accept", comment: "Accept a Takeoff Assistant proposal")) { onAccept(proposal) }
                                        .accessibilityLabel(String(format: NSLocalizedString("Accept: %@", comment: "Accessibility: accept a proposal"), proposal.summary))
                                    Button(NSLocalizedString("Reject", comment: "Reject a Takeoff Assistant proposal")) { onReject(proposal) }
                                        .accessibilityLabel(String(format: NSLocalizedString("Reject: %@", comment: "Accessibility: reject a proposal"), proposal.summary))
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .background(ZPDFColor.background)
    }
}

/// The inbox's utility panel, one per drawing per window, shown only in the assembled
/// application. Per drawing since S-010: one panel per window was bound to the first drawing's
/// inbox, and its Accept changed that drawing whatever tab was in front.
@MainActor
enum AssistantInboxWindow {
    private static var panels = DocumentPanelRegistry()

    @discardableResult
    static func present(for controller: ProjectWindowController, document: ZenitPDFProjectDocument) -> NSPanel {
        if let panel = panels.panel(for: controller, document: document) {
            (panel as? DocumentUtilityPanel)?.presentWithoutTakingKey()
            return panel
        }
        // Never the Edit menu's target in place of the drawing behind it (L-78).
        let panel = DocumentUtilityPanel(document: document, contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                                         styleMask: [.titled, .closable, .resizable, .utilityWindow])
        panel.title = NSLocalizedString("Takeoff Assistant Inbox", comment: "Takeoff Assistant Inbox window title")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.contentViewController = NSHostingController(rootView: AssistantInboxView(
            inbox: document.automation.inbox,
            // Read when the list draws, not when the panel was made (T-019): the panel lives as
            // long as the drawing, and a sheet named from this very Inbox kept its old header.
            pageLabel: { [weak document] id in document.map { pageLabel(for: id, in: $0) } ?? "" },
            onAccept: { [weak controller, weak document] proposal in
                guard let controller, let document else { return }
                Task { @MainActor in await controller.acceptAssistantProposal(proposal, document: document) }
            },
            onReject: { [weak document] proposal in
                guard let document else { return }
                Task { @MainActor in await document.automation.inbox.decide(proposal.id, .rejected) }
            }))
        panel.setAccessibilityLabel(NSLocalizedString("Takeoff Assistant Inbox", comment: "Takeoff Assistant Inbox window title"))
        panels.store(panel, for: controller, document: document)
        panel.presentWithoutTakingKey()
        return panel
    }

    /// A sheet's header in the Inbox, as the Navigator names it now: its number, else its label,
    /// else its place in the set. Empty for a sheet the takeoff no longer has.
    static func pageLabel(for pageID: UUID, in document: ZenitPDFProjectDocument) -> String {
        guard let page = document.core?.snapshot.pages.first(where: { $0.id == pageID }) else { return "" }
        return page.sheetNumber ?? page.label ?? String(page.index + 1)
    }

    /// Closes and forgets the panels of a window that is closing, or of one drawing leaving it.
    static func forget(_ controller: ProjectWindowController, document: ZenitPDFProjectDocument? = nil) {
        panels.forget(controller, document: document)
    }

    /// The panel open for a window's drawing, if any. Test affordance.
    static func openPanel(for controller: ProjectWindowController, document: ZenitPDFProjectDocument) -> NSPanel? {
        panels.panel(for: controller, document: document)
    }
}
