import Foundation
import Testing

/// One process-wide serial gate for the whole `ZPDFUIWorkflows` test target.
///
/// ### Why this exists
///
/// The CR-202 harness (``RenderedPanel``) renders panels in an `NSHostingView` inside an
/// off-screen `NSWindow` that is never ordered in, and spins the main run loop while the view
/// lays out and takes a key event. Making that window boots `NSApplication` as a side effect,
/// and every suite in this target that runs on the main actor would otherwise interleave with
/// it — against one `NSApplication`, one window server connection and one `NSCursor` stack.
/// The shell tier found what that costs: an AppKit global such as `NSCursor.arrow` is an
/// empty, invalid image until `NSApplication.shared` exists, and a suite that reads it while
/// another suite races to boot the application killed the test **process** twice in six runs.
/// Running one test at a time makes every one of those globals a per-test resource by
/// construction, and keeps a rendered panel's run-loop spin from servicing another suite's
/// work.
///
/// This is the shell tier's `ShellTierSerialGate` applied to the workflows tier, for the same
/// reason and with the same shape, including the gate on the gate below.
///
/// `.serialized` alone cannot do this: it orders tests *within* a suite, and the race is
/// across suites.
actor WorkflowsTierSerialGate {

    static let shared = WorkflowsTierSerialGate()

    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// FIFO, so a test cannot be starved by later arrivals.
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

/// Applies ``WorkflowsTierSerialGate`` to a suite and everything inside it.
///
/// Attached to every suite in this target. A suite added without it re-opens the race for
/// itself and for whichever suite it interleaves with, which is why
/// ``WorkflowsTierSerialisationTests`` fails the build when one is missing.
struct WorkflowsTierSerialisation: SuiteTrait, TestTrait, TestScoping {

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
        await WorkflowsTierSerialGate.shared.acquire()
        do {
            try await function()
        } catch {
            await WorkflowsTierSerialGate.shared.release()
            throw error
        }
        await WorkflowsTierSerialGate.shared.release()
    }
}

extension Trait where Self == WorkflowsTierSerialisation {
    /// One test at a time, across every suite in the workflows test target.
    static var workflowsTierSerialised: Self { Self() }
}

/// The gate on the gate: a suite added to this target without ``WorkflowsTierSerialisation``
/// re-opens the race the moment it interleaves with a suite that boots `NSApplication`,
/// and nothing else in the build would notice — a flake does not fail on the run that
/// introduces it. That is exactly how the original race went unnoticed until a full gate run.
@Suite(.workflowsTierSerialised)
struct WorkflowsTierSerialisationTests {

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

    @Test("Every suite in the workflows test target carries the serial gate")
    func everySuiteIsSerialised() throws {
        let declarations = try Self.declarations()
        // A gate that scanned nothing must fail.
        #expect(declarations.count > 15, "the scan found \(declarations.count) suites")
        let offenders = declarations
            .filter { declaration in
                !declaration.attributes.contains { $0.contains(".workflowsTierSerialised") }
            }
            .map { "\($0.file):\($0.line) \($0.name)" }
        #expect(
            offenders.isEmpty,
            """
            these suites would run in parallel with the suites that boot NSApplication and \
            reopen the NSCursor race: \(offenders). Add `.workflowsTierSerialised` to the @Suite attribute.
            """
        )
    }

    @Test("The gate really does hold one permit at a time")
    func theGateAdmitsOneHolderAtATime() async {
        // A serialisation trait nobody has seen exclude anything is a trait nobody knows works.
        // Two concurrent holders, one permit: the second must not enter until the first leaves.
        let gate = WorkflowsTierSerialGate()
        actor Trace {
            private(set) var events: [String] = []
            func record(_ event: String) { events.append(event) }
        }
        let trace = Trace()

        await gate.acquire()
        let second = Task {
            await gate.acquire()
            await trace.record("second-in")
            await gate.release()
        }
        // Give the second task every chance to jump the queue before the first releases.
        for _ in 0..<50 { await Task.yield() }
        await trace.record("first-out")
        await gate.release()
        await second.value

        let events = await trace.events
        #expect(events == ["first-out", "second-in"], "the gate let two holders in at once: \(events)")
    }
}
