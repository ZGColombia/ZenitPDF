import Foundation
import ZPDFUIPresentation

/// A defaults store that lives and dies with the process.
///
/// Deliberately **not** `UserDefaults(suiteName:)`. A named suite is a file in
/// `~/Library/Preferences` that `cfprefsd` creates on first write and leaves behind after
/// `removePersistentDomain(forName:)`, which is how a development machine's Preferences folder
/// reached 2 662 plists and what `Scripts/verify-test-tier-hygiene.sh` now counts
/// before and after every suite run. A store that never touches the disk cannot be counted
/// wrong, cannot be inherited by the next run, and cannot survive a watchdog kill.
///
/// One instance per process, so two `ProjectWindowLayoutStore`s built at different moments in
/// one test still agree with each other — which is what makes "the layout is remembered"
/// testable at this tier without a file.
final class ZenitScratchDefaults: ZPDFDefaultsStoring {

    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func persistedData(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func setPersistedData(_ data: Data?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = data
    }

    /// Whether anything has been written. A test asserts on this rather than on a file.
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.isEmpty
    }

    /// Forgets everything.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

/// Where this **process** is allowed to persist preferences.
///
/// ## Why a type exists for one `if`
///
/// `UserDefaults.standard` is the most expensive piece of shared state in this repository.
/// Five gate outcomes have been decided by it rather than by the code under test, and the
/// mechanism is always the same: one run writes a key into the user's real preference domain,
/// and every later run in that process — and on that machine — reads it back as though the
/// product had produced it. The worst of them:
/// `PresetApplySkipReportTests` put `{"myTools":"apply"}` into the `swiftpm-testing-helper`
/// domain, where it stayed, and `build-app-package.sh` was deterministically red three times
/// for a preference file rather than for a line of code.
///
/// ``ZenitPDFProjectDocument/processToolSetModeDefaults`` closed that hole for tool-set modes,
/// and it closed it **structurally** rather than by asking every test to remember an injection:
/// a `swift test` process is not the assembled bundle, so it is handed a private store whether
/// or not anybody opted in. That is the rule this type generalises, because the same hole was
/// still open one window over.
///
/// ## What was still open
///
/// `ProjectWindowController.installContent(for:)` built its shell composition with
/// `ProjectWindowLayoutController(environment:canvasProvider:)`, whose `store` parameter
/// defaults to `ProjectWindowLayoutStore()`, whose `defaults` parameter in turn defaults to
/// `UserDefaults.standard`. Two default arguments, neither overridden, and therefore
/// **product** code writing `Zenit.ProjectWindow.LayoutState` into the user's real domain from
/// inside every app-tier test that opened a window. Split proportions, which pane was
/// collapsed, which inspector sections were expanded and whether the ledger was detached all
/// persisted out of one test run and into the next — one run decided by the previous one, in
/// exactly 27.1's shape, in shipping code rather than in a test.
///
/// ## The rule
///
/// The real domain is reachable only from the assembled application bundle. Anywhere else —
/// `swift test`, `swift run`, a preview, a script — this process gets a ``ZenitScratchDefaults``
/// that exists only in memory. There is nothing on disk for the next run to inherit and nothing
/// for the preference-file census to count, which is a stronger guarantee than emptying a named
/// suite and does not depend on any cleanup step running.
@MainActor
public enum ZenitProcessDefaults {

    /// The defaults store this process may persist window layout to.
    ///
    /// `UserDefaults.standard` in the shipping bundle; a per-process in-memory store anywhere
    /// else.
    public static var layout: any ZPDFDefaultsStoring { override ?? processStore }

    /// The defaults store dropped-file bookmarks persist to: the same rule and the same store as
    /// ``layout``. An app-tier test that drops a file onto a window used to write
    /// `zenit.droppedFileBookmarks` into the test process's real domain.
    public static var bookmarks: any ZPDFDefaultsStoring { layout }

    /// Points this process at a store of its own rather than the process one. Set by a test;
    /// `nil` in the product, which has no way to set it.
    static var override: (any ZPDFDefaultsStoring)?

    /// Whether this process is the assembled application.
    ///
    /// The same structural test ``ZenitPDFProjectDocument/processToolSetModeDefaults`` and
    /// ``ZenitErrorPresenter`` use. A `swift test` process cannot forge it: the identifier comes
    /// from the bundle's `Info.plist`, and a test runner has a different one or none at all.
    public static var isAssembledApplication: Bool {
        Bundle.main.bundleIdentifier == ZenitAppInfo.bundleIdentifier
    }

    /// Resolved once per process.
    private static let processStore: any ZPDFDefaultsStoring = makeProcessStore()

    /// The resolution itself, factored out of the `static let` so a test can run it twice.
    ///
    /// Calling this is precisely what the *next* process does at its first window. A test that
    /// writes through one result and then reads through a second is therefore not a
    /// re-implementation of the rule — it is the rule, executed twice, which is the only way to
    /// prove inside one process that a run cannot influence the next.
    static func makeProcessStore() -> any ZPDFDefaultsStoring {
        isAssembledApplication ? UserDefaults.standard : ZenitScratchDefaults()
    }

    /// Forgets everything this process has written, when this process is using a scratch store.
    ///
    /// In the shipping bundle there is no scratch store and this does nothing — it can never
    /// reach the user's real preferences.
    public static func discardScratchStore() {
        (processStore as? ZenitScratchDefaults)?.removeAll()
        (override as? ZenitScratchDefaults)?.removeAll()
    }
}
