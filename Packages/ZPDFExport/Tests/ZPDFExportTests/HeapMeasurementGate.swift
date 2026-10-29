import Foundation
import Testing

/// Keeps process-wide heap measurements honest (sweep 7, 2026-09-26).
///
/// `Fix2E1ExporterTests` measures peak heap growth with `heapInUse()`, which counts every allocation in the test
/// process. swift-testing runs suites in parallel in one process, so the redaction suites added in round 2, which
/// build large image and font fixtures, were counted as the CSV exporter's memory. IM-061 then read 78 MB for a
/// streamed 13 MB file. This gate is a reader–writer lock: every other suite in this target holds a shared permit
/// per test, and the measuring suite holds the exclusive permit. A measurement then runs while no other test in the
/// target is allocating.
actor HeapMeasurementGate {
    static let shared = HeapMeasurementGate()

    private var readers = 0
    private var writer = false
    private var waitingReaders: [CheckedContinuation<Void, Never>] = []
    private var waitingWriters: [CheckedContinuation<Void, Never>] = []

    func acquireShared() async {
        if !writer && waitingWriters.isEmpty {
            readers += 1
            return
        }
        await withCheckedContinuation { waitingReaders.append($0) }
    }

    func releaseShared() {
        readers -= 1
        wakeNext()
    }

    func acquireExclusive() async {
        if !writer && readers == 0 {
            writer = true
            return
        }
        await withCheckedContinuation { waitingWriters.append($0) }
    }

    func releaseExclusive() {
        writer = false
        wakeNext()
    }

    private func wakeNext() {
        guard !writer else { return }
        if readers == 0, !waitingWriters.isEmpty {
            writer = true
            waitingWriters.removeFirst().resume()
            return
        }
        if waitingWriters.isEmpty {
            while !waitingReaders.isEmpty {
                readers += 1
                waitingReaders.removeFirst().resume()
            }
        }
    }
}

/// Every test of a suite carrying this trait holds a shared permit while it runs.
struct SharedHeapPermit: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        await HeapMeasurementGate.shared.acquireShared()
        do { try await function() } catch {
            await HeapMeasurementGate.shared.releaseShared()
            throw error
        }
        await HeapMeasurementGate.shared.releaseShared()
    }
}

/// Every test of a suite carrying this trait runs alone in the target.
struct ExclusiveHeapPermit: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { return try await function() }
        await HeapMeasurementGate.shared.acquireExclusive()
        do { try await function() } catch {
            await HeapMeasurementGate.shared.releaseExclusive()
            throw error
        }
        await HeapMeasurementGate.shared.releaseExclusive()
    }
}

extension Trait where Self == SharedHeapPermit {
    static var sharedHeap: Self { Self() }
}

extension Trait where Self == ExclusiveHeapPermit {
    static var exclusiveHeap: Self { Self() }
}

/// The gate on the gate: a suite added without a permit would allocate during a measurement again.
@Suite(.sharedHeap)
struct HeapMeasurementGateCoverageTests {
    @Test("Every suite in the export test target holds a heap permit")
    func everySuiteHoldsAPermit() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }
        var offenders: [String] = []
        var suites = 0
        for name in names {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() where !line.hasPrefix(" ") {
                let words = line.split(separator: " ").map(String.init)
                guard let keyword = words.first(where: { ["struct", "final", "class", "enum"].contains($0) }),
                      let position = words.firstIndex(of: keyword), position < words.count - 1 else { continue }
                let rest = lines[index...].prefix(4000).joined(separator: "\n")
                guard rest.contains("@Test") else { continue }
                var cursor = index - 1
                var attributes: [String] = []
                while cursor >= 0, lines[cursor].hasPrefix("@") || lines[cursor].hasPrefix("//") {
                    attributes.append(lines[cursor]); cursor -= 1
                }
                guard attributes.contains(where: { $0.hasPrefix("@Suite") }) || line.hasPrefix("@Suite") else { continue }
                suites += 1
                if !attributes.contains(where: { $0.contains(".sharedHeap") || $0.contains(".exclusiveHeap") })
                    && !line.contains(".sharedHeap") && !line.contains(".exclusiveHeap") {
                    offenders.append("\(name):\(index + 1)")
                }
            }
        }
        #expect(suites > 30, "the scan found \(suites) suites")
        #expect(offenders.isEmpty, "suites without a heap permit: \(offenders)")
    }
}
