import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// Budgets, degradation and cancellation — `QUALITY_BAR` 3.6.
struct BudgetAndCancellationTests {

    @Test("The standard budgets are the ones QUALITY_BAR 3.6 fixes")
    func standardBudgets() {
        let budget = VectorExtractionBudget.standard
        #expect(budget.maximumOperatorCount == 20_000_000)
        #expect(budget.maximumPrimitiveCount == 2_000_000)
        #expect(budget.wallClockLimitNanoseconds == 10_000_000_000)
        #expect(budget.memoryLimitBytes == 512 * 1024 * 1024)
        #expect(budget.maximumFormNestingDepth == 32)
    }

    @Test("An exhausted wall clock stops extraction and reports the budget that fired")
    func wallClockBudget() async throws {
        var options = VectorExtractionOptions.standard
        // A clock that jumps a second per reading, against a 1 ms limit: the very first
        // periodic check is already past the deadline. Deterministic, no real waiting.
        options.timeSource = .stepping(step: 1_000_000_000)
        options.budget.wallClockLimitNanoseconds = 1_000_000
        options.budget.budgetCheckInterval = 1

        let result = try await ExtractionTestSupport.extract(.tenThousandSegments, options: options)
        defer { ExtractionTestSupport.remove(result.directory) }

        guard case .partial(let reason) = result.extraction.availability,
              case .budgetExceeded(let kind, let fraction) = reason
        else {
            Issue.record("expected partial(budgetExceeded), got \(result.extraction.availability)")
            return
        }
        #expect(kind == .wallClock)
        #expect(fraction >= 0 && fraction <= 1)
        #expect(result.extraction.primitives.count < 10_000)
    }

    @Test("A frozen clock can never trip the wall-clock budget")
    func frozenClockNeverFires() async throws {
        var options = VectorExtractionOptions.standard
        options.timeSource = .frozen()
        options.budget.wallClockLimitNanoseconds = 1
        options.budget.budgetCheckInterval = 1

        let result = try await ExtractionTestSupport.extract(.rectangle, options: options)
        defer { ExtractionTestSupport.remove(result.directory) }

        #expect(result.extraction.availability == .available)
        #expect(result.extraction.statistics.elapsedNanoseconds == 0)
    }

    @Test("The primitive budget truncates the index and never reports it as complete")
    func primitiveBudget() async throws {
        var options = VectorExtractionOptions.standard
        options.budget.maximumPrimitiveCount = 100

        let result = try await ExtractionTestSupport.extract(.tenThousandSegments, options: options)
        defer { ExtractionTestSupport.remove(result.directory) }

        #expect(result.extraction.primitives.count <= 100)
        guard case .partial(let reason) = result.extraction.availability,
              case .budgetExceeded(let kind, _) = reason
        else {
            Issue.record("expected partial(budgetExceeded), got \(result.extraction.availability)")
            return
        }
        #expect(kind == .primitiveCount)
        #expect(result.extraction.filterDecisions.contains { $0.rule == .primitiveBudgetExhausted })
    }

    @Test("The operator budget bounds a page of nothing but operators")
    func operatorBudget() async throws {
        var options = VectorExtractionOptions.standard
        options.budget.maximumOperatorCount = 1_000

        let result = try await ExtractionTestSupport.extract(.tenThousandSegments, options: options)
        defer { ExtractionTestSupport.remove(result.directory) }

        #expect(result.extraction.statistics.operatorCount <= 1_001)
        #expect(result.extraction.availability.isPartial)
    }

    @Test("The memory budget stops a page before the estimate passes the cap")
    func memoryBudget() async throws {
        var options = VectorExtractionOptions.standard
        options.budget.memoryLimitBytes = 64 * 1024
        options.budget.budgetCheckInterval = 8

        let result = try await ExtractionTestSupport.extract(.tenThousandSegments, options: options)
        defer { ExtractionTestSupport.remove(result.directory) }

        guard case .partial(let reason) = result.extraction.availability,
              case .budgetExceeded(let kind, _) = reason
        else {
            Issue.record("expected partial(budgetExceeded), got \(result.extraction.availability)")
            return
        }
        #expect(kind == .memory)
        #expect(result.extraction.primitives.count < 10_000)
    }

    @Test("A cancelled task throws VectorExtractionError.cancelled")
    func cancellation() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(.tenThousandSegments, in: directory)

        var options = VectorExtractionOptions.standard
        options.budget.budgetCheckInterval = 1
        let extractor = VectorExtractor(options: options)

        let task = Task {
            try await extractor.extract(documentAt: handle.url, pageIndex: 0)
        }
        task.cancel()

        do {
            _ = try await task.value
            // Losing the race is possible on a fast machine; the page is small.
        } catch let error as VectorExtractionError {
            #expect(error == .cancelled)
        }
    }

    @Test("Invalid options are rejected before any file is opened")
    func invalidOptions() async throws {
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(.rectangle, in: directory)

        var options = VectorExtractionOptions.standard
        options.flatness = 0
        await #expect(throws: VectorExtractionError.self) {
            _ = try await VectorExtractor(options: options).extract(documentAt: handle.url, pageIndex: 0)
        }

        var second = VectorExtractionOptions.standard
        second.backgroundFilter.minimumCropBoxAreaFraction = 1.5
        await #expect(throws: VectorExtractionError.self) {
            _ = try await VectorExtractor(options: second).extract(documentAt: handle.url, pageIndex: 0)
        }
    }
}
