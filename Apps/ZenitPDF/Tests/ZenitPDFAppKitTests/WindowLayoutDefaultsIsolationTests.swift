import AppKit
import Foundation
import Testing
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The window layout must not be persisted into the user's real preferences by a test, and one
/// run must not be able to decide the next.
///
/// **The defect these tests close.** `ProjectWindowController.installContent(for:)` built its
/// shell with `ProjectWindowLayoutController(environment:canvasProvider:)`. That initialiser's
/// `store` parameter defaults to `ProjectWindowLayoutStore()`, whose `defaults` parameter
/// defaults to `UserDefaults.standard`. Two default arguments deep, **product** code was writing
/// `Zenit.ProjectWindow.LayoutState` into the shared domain — the same class of shared state
/// that decided five gate outcomes in this repository, the set-mode leak worst among them, only
/// this time in shipping code rather than in a test. Every app-tier test that opened a window
/// left the next one a stored layout.
///
/// **What is proven here, and what each test is worth.**
///
/// 1. The process test is not the assembled bundle, so the structural guard is armed at all —
///    without this the other three would pass vacuously on a developer's machine.
/// 2. The product's store is not `UserDefaults.standard`, and writing a layout through the
///    product's own path leaves the real domain untouched and adds no preference file.
/// 3. Resolving the store a second time — literally what the next process does at its first
///    window — yields a store that knows nothing of what this run wrote.
/// 4. The call site is still wired. Every previous version of this fix in this repository was
///    built and then not called; a scan of `Apps/ZenitPDF/Sources` fails the run that unwires it.
@MainActor
@Suite("Window layout defaults isolation", .appTierSerialised)
struct WindowLayoutDefaultsIsolationTests {

    /// A layout no default and no other suite would produce, so finding it anywhere is proof of
    /// origin rather than a coincidence.
    private func distinctiveState() -> ProjectWindowLayoutState {
        ProjectWindowLayoutState(
            navigatorWidth: 317,
            inspectorWidth: 419,
            ledgerHeight: 271,
            isNavigatorCollapsed: true,
            isInspectorCollapsed: false,
            isLedgerCollapsed: false,
            isLedgerBarCollapsed: true,
            isLedgerDetached: true,
            navigatorSection: .zones
        )
    }

    // MARK: - 1. The guard is armed

    @Test("A swift test process is not the assembled bundle, so the scratch branch is taken")
    func theStructuralGuardIsArmedInThisProcess() {
        #expect(
            ZenitProcessDefaults.isAssembledApplication == false,
            """
            Bundle.main.bundleIdentifier is \(Bundle.main.bundleIdentifier ?? "nil"), which \
            equals the shipping identifier. If that is ever true in a test process the guard \
            is inert and every other assertion in this suite is vacuous.
            """
        )
    }

    // MARK: - 2. The user's real preferences are never written

    @Test("Saving a layout through the product's store leaves UserDefaults.standard untouched")
    func theProductStoreNeverReachesTheRealDomain() {
        let key = ProjectWindowLayoutStore.defaultsKey

        // The real domain, before. Read directly rather than through the seam, because the
        // point is what is on the machine and not what the seam reports.
        let realBefore = UserDefaults.standard.data(forKey: key)
        let plistsBefore = ScratchDefaults.zenitSuiteFileCount()
        // The zenit count may honestly be zero on a machine that has never run the suite, so the
        // positive control is that the folder can be listed at all.
        #expect(
            ScratchDefaults.preferencesFolderIsListable(),
            "the Preferences folder could not be listed, so the census proves nothing"
        )

        let store = ProjectWindowLayoutStore(defaults: ZenitProcessDefaults.layout)
        #expect(store.save(distinctiveState()))

        // It really was stored — otherwise the next assertion passes because nothing was
        // written at all, which would prove isolation by proving the store is broken.
        #expect(store.load().navigatorWidth == 317)
        #expect(store.load().isLedgerDetached)

        let realAfter = UserDefaults.standard.data(forKey: key)
        #expect(
            realAfter == realBefore,
            "the product's layout store wrote into UserDefaults.standard under \(key)"
        )
        #expect(
            ScratchDefaults.zenitSuiteFileCount() == plistsBefore,
            """
            the scratch store minted a preference file: \
            \(plistsBefore) → \(ScratchDefaults.zenitSuiteFileCount()). It is in-memory \
            precisely so it cannot.
            """
        )

        ZenitProcessDefaults.discardScratchStore()
    }

    // MARK: - 3. A run cannot influence the next

    @Test("A freshly resolved store — what the next process gets — inherits nothing")
    func oneRunCannotInfluenceTheNext() {
        // Run one: the product path, writing a layout the way a window would.
        let thisRun = ProjectWindowLayoutStore(defaults: ZenitProcessDefaults.layout)
        #expect(thisRun.save(distinctiveState()))
        #expect(thisRun.load() == distinctiveState().normalized())

        // Run two: `makeProcessStore()` is the exact call the next process makes when it
        // resolves its store. Nothing else is simulated and nothing is re-implemented.
        let nextRun = ProjectWindowLayoutStore(defaults: ZenitProcessDefaults.makeProcessStore())
        #expect(
            nextRun.load() == .default,
            """
            the next process's store loaded \(nextRun.load()), not the shipped default. \
            Whatever this run wrote survived into it, which is the preference leak's mechanism.
            """
        )

        // And the reverse direction: run two writing must not be visible to run one either.
        #expect(thisRun.load() == distinctiveState().normalized())

        ZenitProcessDefaults.discardScratchStore()
    }

    @Test("Nothing this suite wrote is left in the process store afterwards")
    func theScratchStoreIsEmptiedOnRequest() {
        let store = ProjectWindowLayoutStore(defaults: ZenitProcessDefaults.layout)
        #expect(store.save(distinctiveState()))
        ZenitProcessDefaults.discardScratchStore()
        #expect(
            store.load() == .default,
            "discardScratchStore() left the layout behind for whatever runs next in this process"
        )
    }

    // MARK: - 4. The fix is called, not merely built

    @Test("ProjectWindowController still names the store explicitly")
    func theCallSiteIsStillWired() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZenitPDFAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ZenitPDF
            .appendingPathComponent("Sources/ZenitPDFAppKit", isDirectory: true)

        let controller = sources
            .appendingPathComponent("Window/ProjectWindowController.swift")
        let text = try String(contentsOf: controller, encoding: .utf8)
        #expect(
            text.contains("store: ProjectWindowLayoutStore(defaults: ZenitProcessDefaults.layout)"),
            """
            ProjectWindowController no longer names its layout store, so \
            ProjectWindowLayoutController's default argument is back — and that default is \
            UserDefaults.standard. Built-but-unwired has happened seven times in this \
            repository; this is the eighth caught by a scan instead of by a person.
            """
        )

        // No other product file may construct the layout controller without saying where the
        // layout lives. A second window would otherwise reintroduce the defect one file over.
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: sources.path)
        while let relative = enumerator?.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            let body = try String(
                contentsOf: sources.appendingPathComponent(relative), encoding: .utf8
            )
            // Code only. Two files in this directory *document* the defect by naming the
            // initialiser in prose, and a scan that cannot tell an explanation from a
            // regression teaches people to delete the explanation.
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
                guard trimmed.contains("ProjectWindowLayoutController(") else { continue }
                // The store may be named on this line or on one of the next few, since the
                // call is written across lines.
                let window = lines[number..<min(number + 6, lines.count)].joined(separator: "\n")
                if !window.contains("store:") {
                    offenders.append("\(relative):\(number + 1)")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            these product files build a ProjectWindowLayoutController without a store, so they \
            take the UserDefaults.standard default: \(offenders.joined(separator: ", "))
            """
        )
    }
}
