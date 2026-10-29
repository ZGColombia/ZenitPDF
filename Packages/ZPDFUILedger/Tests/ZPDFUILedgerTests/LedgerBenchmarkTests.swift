import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUILedger

/// A synthetic 100 000 row ledger, measured the way the table actually reads it.
///
/// The table never materialises a row array: for each cell it is about to draw it asks the
/// controller for that cell's content, which fetches the row from the source. The window
/// benchmark drives that same function (`LedgerTableController.rowCellContent`, V-065) — it
/// used to time a separate helper the table never ran — prints the timing so a regression is
/// visible in the log, and the other tests assert that the resident row cache stays bounded no
/// matter how far the ledger is scrolled.
@MainActor
@Suite("Ledger 100k benchmark", .ledgerTierSerialised)
struct LedgerBenchmarkTests {

    /// Rows in the synthetic ledger.
    static let rowCount = 100_000
    /// Rows in one scroll window, roughly a tall window at the ledger's row height.
    static let windowSize = 60
    /// Number of windows sampled.
    static let sampleCount = 200

    private func makeSource() -> LedgerSyntheticRowSource {
        LedgerSyntheticRowSource(count: Self.rowCount)
    }

    @Test("A 100 000 row ledger costs nothing until it is scrolled")
    func constructionIsLazy() {
        let source = makeSource()
        #expect(source.ledgerRowCount == Self.rowCount)
        #expect(source.synthesisCount == 0)

        _ = Self.rows(source, in: 0..<Self.windowSize)
        #expect(source.synthesisCount == Self.windowSize)
    }

    /// The rows in a window, fetched one by one as the table fetches them.
    private static func rows(_ source: LedgerSyntheticRowSource, in range: Range<Int>) -> [LedgerRow] {
        range.clamped(to: 0..<source.ledgerRowCount).compactMap { source.ledgerRow(at: $0) }
    }

    /// One scroll window through the data source's own cell path: every visible column of
    /// every row in `range`. Returns the cells read.
    private static func window(_ controller: LedgerTableController, _ range: Range<Int>) -> Int {
        let visible = controller.columns.filter(\.visible)
        var cells = 0
        for position in range.clamped(to: 0..<controller.plan.order.count) {
            for column in visible where controller.rowCellContent(displayPosition: position, column: column) != nil {
                cells += 1
            }
        }
        return cells
    }

    @Test("Scroll-window fetch stays inside a frame budget across the whole ledger")
    func scrollWindowFetchTime() {
        let source = makeSource()
        let controller = LedgerTableController(rowSource: source)
        controller.loadViewIfNeeded()
        let columns = controller.columns.filter(\.visible)
        #expect(controller.plan.order.count == Self.rowCount)
        #expect(controller.view.window == nil, "never on screen")

        // Warm the code paths without warming the data cache.
        _ = Self.window(controller, 0..<Self.windowSize)
        source.clearCache()
        source.resetStatistics()

        var durations: [Double] = []
        durations.reserveCapacity(Self.sampleCount)
        var cells = 0
        let stride = max(1, Self.rowCount / Self.sampleCount)

        for sample in 0..<Self.sampleCount {
            let start = sample * stride
            let range = start..<min(Self.rowCount, start + Self.windowSize)
            let began = DispatchTime.now().uptimeNanoseconds
            cells += Self.window(controller, range)
            let ended = DispatchTime.now().uptimeNanoseconds
            durations.append(Double(ended - began) / 1_000_000)
        }

        let total = durations.reduce(0, +)
        let average = total / Double(durations.count)
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let worst = sorted[sorted.count - 1]

        print("""
        [ZPDFUILedger benchmark] 100 000-row ledger, \(Self.sampleCount) scroll windows of \
        \(Self.windowSize) rows x \(columns.count) columns (\(cells) cells read)
          average window fetch: \(String(format: "%.3f", average)) ms
          median  window fetch: \(String(format: "%.3f", median)) ms
          slowest window fetch: \(String(format: "%.3f", worst)) ms
          rows synthesised: \(source.synthesisCount), cache hits: \(source.cacheHitCount)
          resident cache limit: \(source.cacheLimit) rows
        """)

        #expect(cells == Self.sampleCount * Self.windowSize * columns.count)
        // One 60-Hz frame is 16.7 ms. A cold window fetch has to fit inside one with room
        // to spare, because the table still has to build the cell views afterwards.
        #expect(average < 16.0, "Average cold scroll-window fetch exceeded one frame")
        #expect(worst < 80.0, "A single scroll-window fetch stalled the run loop")
    }

    @Test("Scrolling the whole ledger never grows the resident row set")
    func residentSetStaysBounded() {
        let source = LedgerSyntheticRowSource(count: Self.rowCount, cacheLimit: 512)
        for start in Swift.stride(from: 0, to: Self.rowCount, by: Self.windowSize) {
            _ = Self.rows(source, in: start..<(start + Self.windowSize))
        }
        #expect(source.synthesisCount == Self.rowCount)

        let cache = LedgerOutlineItemCache(rowLimit: 512)
        for position in 0..<Self.rowCount {
            _ = cache.item(displayPosition: position)
        }
        #expect(cache.residentRowCount <= 512)
    }

    @Test("Outline items keep their identity while they are resident")
    func outlineItemIdentity() {
        let cache = LedgerOutlineItemCache(rowLimit: 128)
        let first = cache.item(displayPosition: 42)
        let again = cache.item(displayPosition: 42)
        #expect(first === again)
        #expect(first == LedgerOutlineItem(displayPosition: 42))
        #expect(first != LedgerOutlineItem(displayPosition: 43))
    }

    @Test("Selected rows are never evicted from the outline cache")
    func selectionSurvivesEviction() {
        let cache = LedgerOutlineItemCache(rowLimit: 64)
        let pinnedPosition = 5
        let selected = cache.item(displayPosition: pinnedPosition)
        cache.pin(displayPositions: [pinnedPosition])
        for position in 100..<1_000 {
            _ = cache.item(displayPosition: position)
        }
        #expect(cache.item(displayPosition: pinnedPosition) === selected)
    }
}
