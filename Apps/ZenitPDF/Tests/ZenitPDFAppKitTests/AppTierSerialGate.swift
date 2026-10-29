import Foundation
import Testing

/// One process-wide serial gate for the whole application test target.
///
/// ### Why this exists
///
/// `build-app-package.sh` was green one run in six. The recorded failures were always the same
/// shape — `await wait { … }` never becoming true — and always in the suites that drive a
/// document: Select's drag trio, `TabbedWindowTests`, `QuickPDFLifecycleTests`, the search and
/// ledger wiring tests. The gap named shared mutable global state as the cause. It is half the
/// cause; the other half is bigger and simpler.
///
/// **Every suite in this target is `@MainActor`, because the tier under test is.** Swift Testing
/// runs suites concurrently, so thirty-odd main-actor tests interleave on the *one* main actor.
/// `AppTestSupport.wait` polls that actor every 20 ms, and a poll that cannot get a turn is
/// indistinguishable from a condition that never became true. Measured on this machine
/// (2026-08-25, `ZENIT_WAIT_TRACE=1`, 210 tests):
///
/// | | wall clock | slowest single `wait` |
/// |---|---|---|
/// | parallel | 23.5 s | **11.0 s** |
/// | serial | 18.5 s | **1.03 s** |
///
/// The old default budget was 10 s. That is the whole flake: a wait that needs 11 s against a
/// budget of 10 is a coin toss, and the coin was landing badly one run in six. Raising the
/// default to 60 s hid it without removing it, and turned a correctness suite into a timing
/// suite that anyone's `xcodebuild` in another window could tip over.
///
/// **Parallelism was buying nothing.** The suite is bound on `await`s and asynchronous document
/// loads, not on cores; serialised it is *faster* as well as deterministic. So this is not
/// serialisation as the honest second-best over isolation — there is nothing to isolate. There
/// is one main actor, one `NSDocumentController.shared`, one `ProjectWindowController.tabHost`,
/// one `quickPDFAutosaveRootOverride`, one `searchIndexRootOverride`, one
/// `DamagedDrawingRepair.repairedCopiesRootOverride` and one `ZenitErrorPresenter.handler`.
/// A test tier that pretends there are thirty of each is the defect. Running one test at a time
/// makes every one of those a per-test resource by construction, which is the isolation the gap
/// asked for, obtained at negative cost.
///
/// `.serialized` alone cannot do this: it orders tests *within* a suite, and every failure in
/// 15.15 was across suites.
actor AppTierSerialGate {

    static let shared = AppTierSerialGate()

    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// FIFO, so a test cannot be starved by later arrivals — the failure mode this replaces.
    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    func release() {
        if waiting.isEmpty {
            held = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Applies ``AppTierSerialGate`` to a suite and everything inside it.
///
/// Attached to every suite in this target. A suite that is added without it re-opens 15.15 for
/// itself and for whichever suite it interleaves with, which is why `AppTierSerialisationTests`
/// fails the build if one is missing.
struct AppTierSerialisation: SuiteTrait, TestTrait, TestScoping {

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // The suite's own scope must not hold the gate: the tests inside it run within that
        // scope, and a suite holding the one permit while its tests queue for it is a deadlock.
        guard testCase != nil else {
            try await function()
            return
        }
        await AppTierSerialGate.shared.acquire()
        do {
            try await function()
        } catch {
            await AppTierSerialGate.shared.release()
            throw error
        }
        await AppTierSerialGate.shared.release()
    }
}

extension Trait where Self == AppTierSerialisation {
    /// One test at a time, across every suite in the application test target.
    static var appTierSerialised: Self { Self() }
}

/// The gate on the gate: a suite added to this target without ``AppTierSerialisation`` re-opens
/// the one-run-in-six flake the moment it interleaves with a document suite, and nothing else in the
/// build would notice — a flake does not fail on the run that introduces it.
@Suite(.appTierSerialised)
struct AppTierSerialisationTests {

    private static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    /// A type declared at file scope that owns at least one `@Test`.
    private struct Declaration {
        let file: String
        let name: String
        let line: Int
        let attributes: [String]
    }

    private static func declarations() throws -> [Declaration] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: testsDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        var found: [Declaration] = []
        for name in names {
            let text = try String(
                contentsOf: testsDirectory.appendingPathComponent(name),
                encoding: .utf8
            )
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var starts: [(index: Int, name: String)] = []
            for (index, line) in lines.enumerated() {
                let words = line.split(separator: " ").map(String.init)
                guard let keyword = words.first(where: {
                    ["struct", "class", "enum", "actor"].contains($0)
                }) else { continue }
                guard let position = words.firstIndex(of: keyword),
                      position < words.count - 1,
                      line.first == words.first?.first,
                      !line.hasPrefix(" "),
                      // A doc comment is not a declaration: "on the main actor a few…" once read as `actor a`.
                      !line.hasPrefix("//") else { continue }
                let typeName = words[position + 1]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "{:<"))
                starts.append((index, typeName))
            }
            for (offset, start) in starts.enumerated() {
                let end = offset + 1 < starts.count ? starts[offset + 1].index : lines.count
                let body = lines[start.index..<end].joined(separator: "\n")
                guard body.contains("@Test") else { continue }
                var attributes: [String] = []
                var cursor = start.index - 1
                while cursor >= 0 {
                    let line = lines[cursor]
                    guard line.hasPrefix("@") || line.hasPrefix("//") else { break }
                    attributes.append(line)
                    cursor -= 1
                }
                found.append(
                    Declaration(file: name, name: start.name, line: start.index + 1, attributes: attributes)
                )
            }
        }
        return found
    }

    @Test("Every suite in the application test target carries the serial gate")
    func everySuiteIsSerialised() throws {
        let declarations = try Self.declarations()
        // A gate that scanned nothing must fail.
        #expect(declarations.count > 30, "the scan found \(declarations.count) suites")
        let offenders = declarations
            .filter { declaration in
                !declaration.attributes.contains { $0.contains(".appTierSerialised") }
            }
            .map { "\($0.file):\($0.line) \($0.name)" }
        #expect(
            offenders.isEmpty,
            """
            these suites would run in parallel with the document suites and reopen 15.15: \
            \(offenders). Add `@Suite(.appTierSerialised)`.
            """
        )
    }
}
