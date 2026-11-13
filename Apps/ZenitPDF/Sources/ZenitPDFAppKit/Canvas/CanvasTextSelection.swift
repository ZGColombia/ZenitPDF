import AppKit
import ZPDFAppCore
import ZPDFDesignSystem
import ZPDFPDFKitBridge
import ZPDFUIPresentation

/// Select Text (1.1.0): the drawing's own text, selected on the canvas for copying.
///
/// The toolbar's Text tool places a text *markup*; nothing let a person take the words a
/// drawing already carries — a room schedule, a specification note — without retyping them.
/// This is that: drag across the page's text and it is selected in reading order, as PDFKit
/// selects it; a double-click takes a word, a triple-click a line, any press lets go.
///
/// # Where the work happens
///
/// PDFKit answers every question through the raster source and the bridge's engine barrier,
/// off the main actor, so the canvas never holds a `PDFPage` (the rule `PageRasterSource`
/// exists for). A drag therefore cannot ask once per mouse event and wait: **at most one
/// query runs at a time** — a query the canvas gave up on included, because PDFKit keeps
/// working on it until it returns — and every drag event in between only replaces the one
/// waiting behind it. When the running query returns, the newest wish goes out, so a fast drag
/// costs one query per round trip, not one per event, and the highlight ends on the release.
///
/// # Keyed by its own page
///
/// A selection belongs to the page it was made on (``Selected/pageID``), never to "the current
/// page". Whether a change of the current page lets it go is one rule on the canvas
/// (``PDFCanvasViewController/currentPageChangeClearsTextSelection(selectionPageID:currentPageID:)``),
/// so a canvas that shows several pages at once changes one function.
///
/// # When it is idle
///
/// Unless the tool is armed nothing here runs: the page view routes no event to it, and the
/// canvas's live lane checks one flag (``isEngaged``) and returns.
@MainActor
final class CanvasTextSelection {

    /// The page a gesture selects on: which page, its index in its own drawing, the source that
    /// drawing renders from, and the part of the page the sheet shows.
    struct Target {
        let pageID: UUID
        let pageIndex: Int
        let source: PageRasterSource
        /// The page's visible box in page space — the crop box narrowed by the sheet's view
        /// crop. Text outside it is cropped off the sheet and is never selected.
        let visibleBox: CGRect

        /// What a text-layer answer is remembered under. The raster source and the index are
        /// part of it, so a page id a revision re-points at another drawing is asked afresh.
        var layerKey: LayerKey { LayerKey(pageID: pageID, pageIndex: pageIndex, source: ObjectIdentifier(source)) }
    }

    /// See ``Target/layerKey``.
    struct LayerKey: Hashable {
        let pageID: UUID
        let pageIndex: Int
        let source: ObjectIdentifier
    }

    /// What is selected: the text, one page-space box per selected line, and whether the
    /// drawing lets that text be copied.
    struct Selected: Equatable {
        let pageID: UUID
        let text: String
        let lineRects: [PDFRectValue]
        let allowsCopying: Bool
    }

    /// Asks PDFKit for the text a gesture selects. Throws when PDFKit could not be asked — a
    /// locked or closed drawing — which keeps the previous selection rather than reading as
    /// "nothing selected". Injectable so a test can count, slow down or fail queries.
    typealias Query = @MainActor (Target, TextSelectionGesture) async throws -> ZPDFPDFKitBridge.TextSelection?

    var query: Query = { target, gesture in
        try await target.source.textSelection(pageIndex: target.pageIndex, gesture: gesture, within: target.visibleBox)
    }
    /// Asks whether a page has a text layer at all. A throw is not an answer and is not kept.
    var probe: @MainActor (Target) async throws -> Bool = { target in
        try await target.source.hasTextLayer(pageIndex: target.pageIndex)
    }
    /// The page a press at a page point (`nil`: Select All) selects on. Installed by the canvas.
    var resolveTarget: (@MainActor (PDFPointValue?) -> Target?)?
    /// Called whenever ``selection`` changes, with the new value.
    var onChange: (@MainActor (Selected?) -> Void)?
    /// Called when a page's text layer is known: the page, and whether it has text.
    var onTextLayer: (@MainActor (UUID, Bool) -> Void)?

    /// The selected text, or `nil`.
    private(set) var selection: Selected? {
        didSet { if selection != oldValue { onChange?(selection) } }
    }
    /// Whether the tool is armed.
    private(set) var isEngaged = false
    /// The current page as the canvas last reported it, or `nil` before the first report.
    private(set) var followedPageID: UUID?
    private var hasFollowed = false
    /// Whether a drag is selecting: pressed, not yet released.
    private(set) var isTracking = false

    private var anchor: PDFPointValue?
    /// The page the gesture under way selects on; `nil` once let go.
    private(set) var target: Target?
    /// The newest query wished for and not yet sent.
    private var pending: TextSelectionGesture?
    /// The last query sent since the last clear: the one running, or the one ``selection``
    /// answers. Asking it again would cost a query and change nothing.
    private var lastSent: TextSelectionGesture?
    /// The query PDFKit is working on — current, or given up and still running.
    private var running: Task<Void, Never>?
    /// The generation ``running`` was sent under.
    private var runningGeneration = 0
    /// Bumped by every send and every clear, so an answer to a superseded query is dropped.
    private var generation = 0
    private var probeTask: Task<Void, Never>?
    private var probeGeneration = 0
    private var probingKey: LayerKey?
    /// Each page's text-layer answer, asked once per page.
    private var textLayerByKey: [LayerKey: Bool] = [:]

    /// How many queries reached PDFKit. The coalescing test's seam.
    private(set) var queryCountForTesting = 0

    /// The page the selection, or the gesture still being answered, belongs to.
    var selectionPageID: UUID? { selection?.pageID ?? target?.pageID }

    /// Whether an answer for the gesture under way is still to come.
    var isAnswerOutstanding: Bool {
        pending != nil || (running != nil && runningGeneration == generation)
    }

    /// Whether a page is known to have a text layer; `nil` while that is not yet known.
    func hasTextLayer(for target: Target) -> Bool? { textLayerByKey[target.layerKey] }

    // MARK: - Arming

    /// Arms the tool.
    func engage() {
        isEngaged = true
    }

    /// Records the current page. `true` when it changed since the last report (or this is the
    /// first since arming), so the canvas applies its page-change rule once per change.
    func follow(currentPage pageID: UUID?) -> Bool {
        guard !hasFollowed || pageID != followedPageID else { return false }
        hasFollowed = true
        followedPageID = pageID
        return true
    }

    /// Puts the tool down: the selection is let go and nothing more is asked.
    func disengage() {
        clear()
        probeGeneration &+= 1
        probeTask?.cancel()
        probeTask = nil
        probingKey = nil
        isEngaged = false
        hasFollowed = false
        followedPageID = nil
    }

    /// Lets go of the selection and gives up the query under way. A query PDFKit is already
    /// working on keeps ``running`` until it returns, so the next one waits for it.
    func clear() {
        generation &+= 1
        running?.cancel()
        pending = nil
        lastSent = nil
        anchor = nil
        target = nil
        isTracking = false
        selection = nil
    }

    // MARK: - The gesture

    /// A press at a page point (`nil` off the page) with the system's click count.
    func press(at point: PDFPointValue?, clickCount: Int) {
        clear()
        guard isEngaged, let point, let target = resolveTarget?(point) else { return }
        self.target = target
        switch clickCount {
        case ...1:
            anchor = point
            isTracking = true
        case 2:
            request(.word(at: CGPoint(x: point.x, y: point.y)))
        default:
            request(.line(at: CGPoint(x: point.x, y: point.y)))
        }
    }

    /// The pointer moved with the button down.
    func drag(to point: PDFPointValue) {
        guard isTracking, let anchor else { return }
        request(.span(from: CGPoint(x: anchor.x, y: anchor.y), to: CGPoint(x: point.x, y: point.y)))
    }

    /// The button came up, at `point` (`nil` when it could not be placed). A release where the
    /// press was is a click: it selected nothing and lets the press's clear stand.
    func release(at point: PDFPointValue?) {
        guard isTracking else { return }
        isTracking = false
        defer { anchor = nil }
        guard let anchor, let point, point != anchor else { return }
        request(.span(from: CGPoint(x: anchor.x, y: anchor.y), to: CGPoint(x: point.x, y: point.y)))
    }

    /// The release will never arrive: keep what the drag selected so far.
    func cancelTracking() {
        isTracking = false
        anchor = nil
    }

    /// Selects every character on the visible part of the page in view.
    func selectAll() {
        clear()
        guard isEngaged, let target = resolveTarget?(nil) else { return }
        self.target = target
        request(.wholePage)
    }

    // MARK: - Coalesced queries

    private func request(_ gesture: TextSelectionGesture) {
        // A release where the last drag event was, or a drag event that did not move: the
        // query that answers it is already out or already answered.
        guard gesture != lastSent else {
            pending = nil
            return
        }
        pending = gesture
        if running == nil { send() }
    }

    private func send() {
        guard let gesture = pending, let target else {
            pending = nil
            return
        }
        pending = nil
        lastSent = gesture
        generation &+= 1
        let sent = generation
        runningGeneration = sent
        queryCountForTesting &+= 1
        running = Task { [weak self] in
            guard let self else { return }
            let answer: Result<ZPDFPDFKitBridge.TextSelection?, any Error>
            do {
                answer = .success(try await self.query(target, gesture))
            } catch {
                answer = .failure(error)
            }
            self.land(answer, generation: sent, target: target)
        }
    }

    private func land(
        _ answer: Result<ZPDFPDFKitBridge.TextSelection?, any Error>,
        generation sent: Int,
        target answered: Target
    ) {
        running = nil
        // Applied only while it still answers the gesture under way, on that gesture's page:
        // an answer for a page the canvas has since left is dropped, not drawn.
        if sent == generation, let current = target, current.pageID == answered.pageID,
           case let .success(found) = answer {
            selection = found.map { found in
                Selected(
                    pageID: answered.pageID,
                    text: found.string,
                    lineRects: found.lineRects.map {
                        PDFRectValue(
                            x: Double($0.origin.x), y: Double($0.origin.y),
                            width: Double($0.width), height: Double($0.height)
                        )
                    },
                    allowsCopying: answered.source.allowsCopying
                )
            }
        }
        // A failure keeps the previous selection: PDFKit could not be asked, which is not the
        // same as "nothing there". Either way, the wish that waited goes out now.
        if pending != nil { send() }
    }

    // MARK: - The text layer

    /// Asks once per page whether it has text, and reports the answer.
    func probeTextLayer(for target: Target?) {
        guard let target else { return }
        let key = target.layerKey
        if let known = textLayerByKey[key] {
            onTextLayer?(target.pageID, known)
            return
        }
        guard probingKey != key else { return }
        probeGeneration &+= 1
        let asked = probeGeneration
        probeTask?.cancel()
        probingKey = key
        probeTask = Task { [weak self] in
            guard let self else { return }
            let hasText: Bool?
            do { hasText = try await self.probe(target) } catch { hasText = nil }
            guard asked == self.probeGeneration else { return }
            self.probeTask = nil
            self.probingKey = nil
            // A probe that threw is not remembered: the next arming asks again.
            guard let hasText, !Task.isCancelled else { return }
            self.textLayerByKey[key] = hasText
            if self.isEngaged { self.onTextLayer?(target.pageID, hasText) }
        }
    }

    // MARK: - Waiting

    /// Waits until the answer for the gesture under way has landed (or there is none).
    func settleAnswer() async {
        while isAnswerOutstanding, let task = running {
            await task.value
        }
    }

    /// Waits until every query and probe sent so far has returned. For tests.
    func settle() async {
        while true {
            if let task = running {
                await task.value
            } else if let task = probeTask {
                await task.value
            } else {
                return
            }
        }
    }
}

// MARK: - The canvas

extension PDFCanvasViewController {

    /// The status bar's note on a page with no text to select, pointing at the command that
    /// reads a scanned sheet.
    static var noTextLayerNote: String {
        NSLocalizedString(
            "This page has no text to select. Tools ▸ Read Text from Scanned Pages… reads a scanned sheet for Search.",
            comment: "Status bar note: Select Text is armed on a page without a text layer"
        )
    }

    /// The status bar's note when Copy is refused because the drawing forbids copying its text.
    static var copyingNotAllowedNote: String {
        NSLocalizedString(
            "This PDF does not allow copying its text.",
            comment: "Status bar note: Copy refused because the drawing's security settings forbid copying text"
        )
    }

    /// Whether Select Text is the armed tool.
    var isSelectTextArmed: Bool { armedMode == .selectText }

    // MARK: Page rules — the three a multi-page canvas changes

    /// Whether a change of the current page lets go of a selection made on another page.
    ///
    /// The canvas shows one page, so a selection on any page but the current one is on no page
    /// the person can see: it goes. A canvas that keeps neighbouring pages on screen answers
    /// `false` while the selection's page is still shown — this function, and nothing else.
    static func currentPageChangeClearsTextSelection(selectionPageID: UUID, currentPageID: UUID?) -> Bool {
        selectionPageID != currentPageID
    }

    /// The page the page view draws: the one page whose text-selection boxes it may show.
    var textSelectionViewPageID: UUID? { core.document.currentPageID }

    /// The page a press at `point` selects on (`nil` point: the page Select All selects). One
    /// page is shown, so it is that page; a multi-page canvas resolves the page under the point
    /// here, and adopts it first.
    func textSelectionTarget(at point: PDFPointValue?) -> CanvasTextSelection.Target? {
        guard let page = core.document.currentPage, let source = rasterSource(for: page) else { return nil }
        let box = page.viewBox
        return CanvasTextSelection.Target(
            pageID: page.id,
            pageIndex: page.index,
            source: source,
            visibleBox: CGRect(x: box.minX, y: box.minY, width: box.size.width, height: box.size.height)
        )
    }

    // MARK: The live lane

    /// The live lane's hook: arms the text selection, applies the page-change rule when the
    /// current page moves, or lets the selection go when another tool is armed. Cheap when the
    /// tool is not armed: one flag is read.
    func reconcileTextSelection(mode: ZenitToolMode) {
        guard mode == .selectText else {
            guard textSelection.isEngaged else { return }
            textSelection.disengage()
            pageView.textSelection = nil
            pageView.textSelectionHighlights = []
            withdrawNoTextLayerNote()
            return
        }
        if !textSelection.isEngaged {
            if textSelection.resolveTarget == nil { installTextSelectionHooks() }
            textSelection.engage()
            // A markup selected under Select is not what this tool's Cut, Delete or arrows mean:
            // it is let go, so none of them can reach it.
            if !core.canvas.selectedMarkupIDs.isEmpty { core.canvas.clearSelection() }
        }
        if pageView.textSelection !== textSelection { pageView.textSelection = textSelection }
        let current = core.document.currentPageID
        guard textSelection.follow(currentPage: current) else { return }
        if let page = textSelection.selectionPageID,
           Self.currentPageChangeClearsTextSelection(selectionPageID: page, currentPageID: current) {
            textSelection.clear()
        }
        applyTextSelectionHighlights()
        textSelection.probeTextLayer(for: textSelectionTarget(at: nil))
    }

    private func installTextSelectionHooks() {
        textSelection.resolveTarget = { [weak self] point in self?.textSelectionTarget(at: point) }
        textSelection.onChange = { [weak self] _ in self?.applyTextSelectionHighlights() }
        textSelection.onTextLayer = { [weak self] pageID, hasText in
            self?.textLayerKnown(pageID: pageID, hasText: hasText)
        }
    }

    /// Hands the page view the selection's boxes when the selection is on the page it draws.
    private func applyTextSelectionHighlights() {
        guard let selected = textSelection.selection, selected.pageID == textSelectionViewPageID else {
            pageView.textSelectionHighlights = []
            return
        }
        pageView.textSelectionHighlights = selected.lineRects
    }

    /// Says so in the status bar when the page in view has nothing to select, and takes the
    /// note back when it does — only ever its own note.
    private func textLayerKnown(pageID: UUID, hasText: Bool) {
        guard isSelectTextArmed, core.document.currentPageID == pageID else { return }
        if hasText {
            withdrawNoTextLayerNote()
        } else {
            core.status.setActiveToolNote(Self.noTextLayerNote)
        }
    }

    private func withdrawNoTextLayerNote() {
        guard core.status.snapshot.activeToolNote == Self.noTextLayerNote else { return }
        core.status.setActiveToolNote(nil)
    }

    // MARK: Copy, Select All, Escape

    /// The selected drawing text, when it is on the page in view.
    private var visibleSelectedText: CanvasTextSelection.Selected? {
        guard let selected = textSelection.selection, !selected.text.isEmpty,
              selected.pageID == textSelectionViewPageID else { return nil }
        return selected
    }

    /// Whether drawing text is selected on the page in view.
    var hasSelectedText: Bool { visibleSelectedText != nil }

    /// Copies the selected drawing text as plain text — unless the drawing forbids copying its
    /// text, when the status bar says so and nothing is written. `false` when no text is
    /// selected, so Copy goes on to the selected markups.
    @discardableResult
    func copySelectedText() -> Bool {
        guard let selected = visibleSelectedText else { return false }
        guard selected.allowsCopying else {
            core.status.setActiveToolNote(Self.copyingNotAllowedNote)
            return true
        }
        markupPasteboard.writePlainText(selected.text)
        return true
    }

    /// Edit ▸ Copy's text half: copies the selection now, or — when the answer for the drag
    /// just made is still on its way — waits for it and copies that, so ⌘C straight after a
    /// release never copies the previous, shorter answer. `false` when there is no text to copy.
    func copySelectedTextWhenAnswered() -> Bool {
        guard isSelectTextArmed, textSelection.isAnswerOutstanding else { return copySelectedText() }
        Task { @MainActor [weak self] in
            await self?.textSelection.settleAnswer()
            self?.copySelectedText()
        }
        return true
    }

    /// Copy's enablement from the text selection, or `nil` when text does not decide it.
    func validateTextCopy() -> Bool? {
        if isSelectTextArmed, textSelection.isAnswerOutstanding {
            return textSelection.target?.source.allowsCopying ?? true
        }
        guard let selected = visibleSelectedText else { return nil }
        return selected.allowsCopying
    }

    /// Edit ▸ Select All with Select Text armed: the page's text. `false` otherwise, so Select
    /// All selects markups as before.
    func selectAllTextIfArmed() -> Bool {
        guard isSelectTextArmed else { return false }
        applyArmedTool()
        textSelection.selectAll()
        return true
    }

    /// Select All's enablement with Select Text armed, or `nil` when the tool is not armed.
    func validateSelectAllText() -> Bool? {
        guard isSelectTextArmed else { return nil }
        guard let target = textSelectionTarget(at: nil) else { return false }
        return textSelection.hasTextLayer(for: target) ?? true
    }

    /// Escape lets go of selected drawing text first, keeping the tool; the next Escape puts the
    /// tool down. `true` when there was a selection to let go.
    func clearTextSelectionForEscape() -> Bool {
        guard textSelection.selection != nil || textSelection.isAnswerOutstanding else { return false }
        textSelection.clear()
        return true
    }

    // MARK: Markups stay still

    /// Whether Cut, Delete and the arrow keys are kept off markups: Select Text selects the
    /// drawing's words, and a markup that happens to be selected is not what those keys mean.
    var holdsMarkupEdits: Bool { isSelectTextArmed }

    // MARK: Context menu

    /// Whether a right-click answers with the text selection's own menu.
    var showsTextSelectionMenu: Bool {
        isSelectTextArmed && hasSelectedText
    }

    /// The right-click menu over selected drawing text: Copy and Select All.
    func textSelectionContextMenu() -> NSMenu? {
        guard showsTextSelectionMenu else { return nil }
        let menu = NSMenu(title: NSLocalizedString("Selected Text", comment: "Canvas context menu title over selected drawing text"))
        menu.autoenablesItems = false
        menu.addItem(ContextMenuItem(
            title: NSLocalizedString("Copy", comment: "Canvas context menu: copy the selected drawing text"),
            enabled: validateTextCopy() ?? false
        ) { [weak self] in self?.copySelectedText() })
        menu.addItem(ContextMenuItem(
            title: NSLocalizedString("Select All", comment: "Canvas context menu: select all the text on the page")
        ) { [weak self] in _ = self?.selectAllTextIfArmed() })
        return menu
    }

    // MARK: Testing

    /// The selected drawing text, for tests.
    var textSelectionForTesting: CanvasTextSelection.Selected? { textSelection.selection }

    /// Waits for the text selection's queries and probes to return. For tests.
    func settleTextSelection() async {
        await textSelection.settle()
    }
}

// MARK: - The page view

extension CanvasPageView {

    /// The selected-text fill: the selection tint, translucent so the drawing's own words stay
    /// legible under it. Made once — the overlay repaints at pointer rate.
    static let textSelectionFill = CanvasMarkupStyle.selectionInk.withAlphaComponent(0.28)

    /// Draws the selected lines that reach `dirtyRect` as one translucent path, through the
    /// current transform — so the highlight stays on its words through every zoom and pan —
    /// and never past the sheet's edge.
    func drawTextSelection(transform: PageDisplayTransform, dirtyRect: NSRect) {
        guard !textSelectionHighlights.isEmpty else { return }
        let area = dirtyRect.intersection(transform.pageFrame)
        guard !area.isNull, !area.isEmpty else { return }
        let path = NSBezierPath()
        var any = false
        for rect in textSelectionHighlights {
            let box = transform.viewRect(from: rect).intersection(area)
            guard !box.isNull, !box.isEmpty else { continue }
            path.appendRect(box)
            any = true
        }
        guard any else { return }
        Self.textSelectionFill.setFill()
        path.fill()
    }

    /// Repaints only the overlay under the old and the new highlight.
    func textSelectionHighlightsChanged(from old: [PDFRectValue]) {
        guard let transform else {
            liveOverlay.needsDisplay = true
            return
        }
        let dirty = (old + textSelectionHighlights)
            .map { transform.viewRect(from: $0) }
            .reduce(CGRect.null) { $0.union($1) }
        guard !dirty.isNull else { return }
        liveOverlay.setNeedsDisplay(dirty.insetBy(dx: -2, dy: -2))
    }
}
