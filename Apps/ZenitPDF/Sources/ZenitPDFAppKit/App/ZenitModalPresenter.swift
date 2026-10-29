import AppKit
import Foundation

/// What a modal presentation is asking, recorded in a form a test can assert on.
///
/// The identifier is the stable half — a test matches on it, so rewording a button or a
/// title cannot silently retarget an assertion at a different dialogue.
public struct ZenitModalRequest: Sendable, Equatable {

    /// The kind of thing being put in front of a person.
    public enum Kind: String, Sendable {
        case alert
        case savePanel
        case openPanel
    }

    public let kind: Kind
    public let identifier: String
    public let title: String
    public let detail: String
    public let buttons: [String]
    /// Whether the call site asked for it to hang from a window rather than block the app.
    public let sheeted: Bool

    public init(
        kind: Kind,
        identifier: String,
        title: String = "",
        detail: String = "",
        buttons: [String] = [],
        sheeted: Bool = false
    ) {
        self.kind = kind
        self.identifier = identifier
        self.title = title
        self.detail = detail
        self.buttons = buttons
        self.sheeted = sheeted
    }
}

/// What came back from a modal presentation.
public enum ZenitModalAnswer: Sendable, Equatable {

    /// The button at this index was pressed, counting from the first one added.
    case button(Int)

    /// Nobody answered: the sheet was cancelled, or this process has no user.
    case dismissed

    /// A file panel returned these locations. Empty is the same as ``dismissed``.
    case urls([URL])

    /// The chosen button index, or `nil` when no button was chosen.
    public var buttonIndex: Int? {
        if case .button(let index) = self { return index }
        return nil
    }

    /// The first location a file panel returned, or `nil`.
    public var firstURL: URL? {
        if case .urls(let urls) = self { return urls.first }
        return nil
    }
}

/// The one door every blocking presentation in the application tier is shown through.
///
/// ### Why this exists
///
/// A test must never present a dialogue. A dialogue that a person answers makes a test pass
/// that would otherwise hang or fail, so the suite's result depends on who was watching —
/// the same class of defect as a skipped test reported as green. A test that leaves a crash
/// marker armed, for example, makes the next reopen run `NSAlert.runModal()` in a process
/// with no user: the fixture is in the right place, and the modal is the leak.
///
/// ### The rule, enforced by construction rather than by care
///
/// This is ``ZenitErrorPresenter``'s design applied to every other dialogue, and for the same
/// reason: an opt-in seam is a rule somebody has to remember, and this is the same rule
/// enforced by construction. A modal is only ever really presented from the
/// assembled application bundle. A `swift test` process is never the assembled bundle —
/// `Bundle.main.bundleIdentifier` is the test runner's, never ``ZenitAppInfo/bundleIdentifier``
/// — so **no test can put a dialogue on screen even if it injects nothing**.
/// Instead the request is recorded in ``recorded`` and the call site is handed the answer it
/// declared a process with no user should get.
///
/// A test that wants to *decide* an answer installs ``handler``; the handler is consulted
/// first, in the app as well, which is what makes the paths injectable. Nothing under
/// `Apps/ZenitPDF/Sources` may assign it — `ModalInjectionTests.theModalSeamsAreTestOnly`
/// fails the build if anything does, the same scan the recovery seam already gets.
///
/// ### What this covers and what it does not
///
/// Covered: `NSAlert`, `NSSavePanel`, `NSOpenPanel`, and every `runModal` form. Those either
/// draw on the screen or spin a modal run loop with no exit.
///
/// **Not covered: `NSWindow.beginSheet` of a workflow sheet.** A sheet hangs from a window,
/// and no window in the app test target is ever ordered front, so it draws nothing and blocks
/// nothing — the app-tier tests present and end workflow sheets deliberately
/// (`ProjectWindowController.presentToolLibrary` is driven by four suites). The edge of the
/// exemption is exact: a sheet whose *content* is an `NSAlert` or a file panel goes through
/// this door like everything else, because those are presented by AppKit and can escalate to
/// an application-modal window when the parent is not visible.
@MainActor
public enum ZenitModalPresenter {

    /// How one request is answered. Injected by a test; `nil` uses the built-in behaviour.
    public typealias Handler = @MainActor (ZenitModalRequest) -> ZenitModalAnswer

    /// The injected decider, or `nil` for the built-in behaviour.
    public static var handler: Handler?

    /// Every request the presenter has been handed since ``reset()``, oldest first.
    public private(set) static var recorded: [ZenitModalRequest] = []

    /// Every request that was actually drawn on a screen since ``reset()``.
    ///
    /// This is the gate's evidence rather than the app's bookkeeping: in a test process it
    /// must stay empty, and `ModalInjectionTests` asserts exactly that.
    public private(set) static var presentedForReal: [ZenitModalRequest] = []

    /// Whether this process is allowed to draw a modal at all.
    ///
    /// True only when the code is running from the shipping application bundle. Everything
    /// else — `swift test`, `swift run`, a command-line tool linking the framework — answers
    /// without drawing.
    public static var canPresentModally: Bool {
        Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier
    }

    /// The most recent request, or `nil`.
    public static var lastRecorded: ZenitModalRequest? { recorded.last }

    /// Whether a request with this identifier has been made since ``reset()``.
    public static func didRequest(_ identifier: String) -> Bool {
        recorded.contains { $0.identifier == identifier }
    }

    /// Forgets every recorded request and removes any injected handler. A test calls this in
    /// its setup **and** in a `defer`, because this is process-wide state.
    public static func reset() {
        recorded = []
        presentedForReal = []
        handler = nil
    }

    /// Runs `body` with `answer` installed as the decision for every request, then restores
    /// whatever was there before — including the recorded requests.
    ///
    /// The restoration is the point. Gate unreliability of this kind comes from one shared
    /// process-wide resource left changed by a test that had finished with it.
    @discardableResult
    public static func answering(
        _ answer: @escaping @MainActor (ZenitModalRequest) -> ZenitModalAnswer,
        perform body: () throws -> Void
    ) rethrows -> [ZenitModalRequest] {
        let previousHandler = handler
        let previousRecorded = recorded
        let previousPresented = presentedForReal
        recorded = []
        handler = answer
        defer {
            handler = previousHandler
            recorded = previousRecorded
            presentedForReal = previousPresented
        }
        try body()
        return recorded
    }

    // MARK: - Alerts

    /// Presents an alert and delivers the answer.
    ///
    /// - Parameters:
    ///   - alert: the configured alert. Its text and button titles become the request, so a
    ///     test asserts on what the person would have read.
    ///   - identifier: the stable name of this dialogue.
    ///   - window: the window to sheet it on, when there is a visible one.
    ///   - answerWithoutAUser: what a process with no user gets. Every call site must state
    ///     this, because "what happens when nobody is there" is a product decision and not a
    ///     default — for the recovery prompt it is *open read-only*, for the unsaved-takeoff
    ///     review it is *discard the scratch*, and the two are not interchangeable.
    ///   - completion: receives the answer, always on the main actor, always exactly once.
    public static func runAlert(
        _ alert: NSAlert,
        identifier: String,
        sheetedOn window: NSWindow? = nil,
        answerWithoutAUser: ZenitModalAnswer = .dismissed,
        completion: @escaping @MainActor (ZenitModalAnswer) -> Void
    ) {
        let sheeted = window?.isVisible == true
        let request = ZenitModalRequest(
            kind: .alert,
            identifier: identifier,
            title: alert.messageText,
            detail: alert.informativeText,
            buttons: alert.buttons.map(\.title),
            sheeted: sheeted
        )
        recorded.append(request)
        if let handler {
            completion(handler(request))
            return
        }
        guard canPresentModally else {
            NSLog("ZENIT-MODAL (not presented, no bundle): %@", identifier)
            completion(answerWithoutAUser)
            return
        }
        presentedForReal.append(request)
        if sheeted, let window {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { completion(answer(for: response)) }
            }
        } else {
            completion(answer(for: alert.runModal()))
        }
    }

    /// The blocking form, for the call sites whose caller must return a value.
    ///
    /// Still incapable of drawing outside the assembled bundle, so it is a modal loop only
    /// where there is a person to end it.
    @discardableResult
    public static func runAlert(
        _ alert: NSAlert,
        identifier: String,
        answerWithoutAUser: ZenitModalAnswer = .dismissed
    ) -> ZenitModalAnswer {
        var outcome = answerWithoutAUser
        runAlert(
            alert,
            identifier: identifier,
            sheetedOn: nil,
            answerWithoutAUser: answerWithoutAUser
        ) { outcome = $0 }
        return outcome
    }

    // MARK: - File panels

    /// Presents a save panel and delivers the chosen location.
    public static func runSavePanel(
        _ panel: NSSavePanel,
        identifier: String,
        sheetedOn window: NSWindow?,
        completion: @escaping @MainActor (ZenitModalAnswer) -> Void
    ) {
        runPanel(
            panel,
            kind: .savePanel,
            identifier: identifier,
            window: window,
            urls: { [$0.url].compactMap { $0 } },
            completion: completion
        )
    }

    /// Presents an open panel and delivers the chosen locations.
    public static func runOpenPanel(
        _ panel: NSOpenPanel,
        identifier: String,
        sheetedOn window: NSWindow?,
        completion: @escaping @MainActor (ZenitModalAnswer) -> Void
    ) {
        runPanel(
            panel,
            kind: .openPanel,
            identifier: identifier,
            window: window,
            urls: { ($0 as? NSOpenPanel)?.urls ?? [] },
            completion: completion
        )
    }

    private static func runPanel(
        _ panel: NSSavePanel,
        kind: ZenitModalRequest.Kind,
        identifier: String,
        window: NSWindow?,
        urls: @escaping @MainActor (NSSavePanel) -> [URL],
        completion: @escaping @MainActor (ZenitModalAnswer) -> Void
    ) {
        let sheeted = window?.isVisible == true
        let request = ZenitModalRequest(
            kind: kind,
            identifier: identifier,
            title: panel.message ?? "",
            detail: panel.nameFieldStringValue,
            buttons: [panel.prompt ?? ""],
            sheeted: sheeted
        )
        recorded.append(request)
        if let handler {
            completion(handler(request))
            return
        }
        guard canPresentModally else {
            NSLog("ZENIT-MODAL (not presented, no bundle): %@", identifier)
            completion(.dismissed)
            return
        }
        presentedForReal.append(request)
        let deliver: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else {
                completion(.dismissed)
                return
            }
            let chosen = urls(panel)
            completion(chosen.isEmpty ? .dismissed : .urls(chosen))
        }
        if sheeted, let window {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { deliver(response) }
            }
        } else {
            deliver(panel.runModal())
        }
    }

    /// Records a panel that AppKit itself would have run and that we refused to let it run.
    ///
    /// `-[NSDocument runModalSavePanel:...]`, `-[NSDocument runModalPrintOperation:...]` and
    /// `-[NSDocumentController runModalOpenPanel:forTypes:]` are AppKit's, not ours: they are
    /// reached from ⌘S, from `saveDocumentAs:`, from File ▸ Open and from the autosave
    /// machinery, so there is no call site to route. The overrides that divert them report
    /// here instead, so the request is still visible to a test and to this presenter's ledger.
    public static func recordDivertedAppKitPanel(_ identifier: String) {
        let request = ZenitModalRequest(kind: .savePanel, identifier: identifier)
        recorded.append(request)
        if let handler {
            _ = handler(request)
            return
        }
        NSLog("ZENIT-MODAL (AppKit panel diverted, no bundle): %@", identifier)
    }

    // MARK: - Workflow sheets

    /// Hangs a workflow sheet from its window, through the one modal door (BH-923).
    ///
    /// The request is recorded like every other, so a test sees which sheet was asked for. A
    /// process with no user may attach a sheet only to a window nobody can see — an app-tier
    /// test's windows are never ordered front, so such a sheet draws nothing and blocks
    /// nothing — and is refused against a visible one, which in a test process would be a
    /// sheet on the user's screen.
    ///
    /// - Returns: whether the sheet was attached.
    @discardableResult
    public static func beginSheet(
        _ sheet: NSWindow,
        on parent: NSWindow,
        identifier: String,
        completion: @escaping @MainActor () -> Void
    ) -> Bool {
        let request = ZenitModalRequest(kind: .alert, identifier: identifier, title: sheet.title)
        recorded.append(request)
        if !canPresentModally, parent.isVisible {
            NSLog("ZENIT-MODAL (sheet refused on a visible window, no bundle): %@", identifier)
            return false
        }
        if canPresentModally { presentedForReal.append(request) }
        parent.beginSheet(sheet) { _ in
            MainActor.assumeIsolated { completion() }
        }
        return true
    }

    // MARK: - Free-standing panels

    /// Orders a panel of our own onto the screen, in a process that has one.
    ///
    /// The quit progress affordance is the only such panel in the application, and
    /// `orderFrontRegardless()` is exactly what its name says: a window on whatever screen is
    /// in front, which in a test process is the user's. Routing it here keeps
    /// `verify-no-uninjected-modals.sh` able to say that no call site anywhere reaches that
    /// method directly.
    ///
    /// - Returns: whether the panel was really put on a screen.
    @discardableResult
    public static func presentPanel(_ panel: NSPanel, identifier: String) -> Bool {
        let request = ZenitModalRequest(kind: .alert, identifier: identifier, title: panel.title)
        recorded.append(request)
        if let handler {
            _ = handler(request)
            return false
        }
        guard canPresentModally else {
            NSLog("ZENIT-MODAL (not presented, no bundle): %@", identifier)
            return false
        }
        presentedForReal.append(request)
        panel.orderFrontRegardless()
        return true
    }

    // MARK: - Translation

    private static func answer(for response: NSApplication.ModalResponse) -> ZenitModalAnswer {
        switch response {
        case .alertFirstButtonReturn: return .button(0)
        case .alertSecondButtonReturn: return .button(1)
        case .alertThirdButtonReturn: return .button(2)
        case .OK: return .button(0)
        default:
            // Buttons past the third come back as `alertThirdButtonReturn + n`. Nothing in
            // this application has four, but decoding it is one line and guessing is not.
            let offset = response.rawValue - NSApplication.ModalResponse.alertThirdButtonReturn.rawValue
            if offset > 0 { return .button(2 + offset) }
            return .dismissed
        }
    }
}
