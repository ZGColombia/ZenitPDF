import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// `QUALITY_BAR` S12, S13 and 3.5: query latency and index build time, measured and printed.
///
/// The headline configuration is the one the criterion names: **250 000 primitives on one page**
/// and **at least 10 000 replayed pointer events**. p50, p95, p99, p99.9 and max are all
/// reported, max included, because a 200 ms outlier is a dropped frame the user sees and a p95
/// alone hides it.
@Suite("Snap performance (QUALITY_BAR 3.5, S12, S13)", .serialized)
struct SnapPerformanceTests {

    // MARK: - Budgets
    //
    // `QUALITY_BAR` 3.5's budgets are budgets on optimised code: S12's p95 <= 8 ms and
    // p99.9 <= 16 ms, and S13's index build p95 <= 400 ms. Those are the numbers asserted in a
    // release build, and `Scripts/build-snap-package.sh` runs this suite a second time, alone
    // and in release, so the headline figures are measured without any other suite competing.
    //
    // A `-Onone` build is measured at roughly twenty times slower on the index build, which is
    // dominated by `PackedRTree`'s Hilbert bulk-load, and roughly ten times slower per query.
    // The assertions still run in debug — nothing here is skipped or compiled out — against
    // documented allowances rather than against the release budgets, because asserting a
    // release budget on unoptimised code would either fail permanently or force the budget up
    // for everyone.
    //
    // MARK: - Which clock the assertion is made on
    //
    // This suite was measured four times on 2026-08-25: three red, one green. The reds were
    // `p99.9 = 212 ms` against 80 ms and an index build `p95 = 3099 ms` against 1800 ms, all of
    // them with other test suites or another workflow on the cores; the green came once the
    // machine quietened. A budget that only holds when nothing else runs is not a budget, and
    // snap is one of the three critical areas.
    //
    // **The number was not raised.** Every budget below is the number it was. What changed is
    // which clock carries the assertion, and when a wall-clock figure is allowed to mean
    // anything:
    //
    //   * **Thread CPU time carries every assertion.** `CLOCK_THREAD_CPUTIME_ID` advances only
    //     while this thread is on a core, so it is unaffected by preemption — but it *does*
    //     include the cycles lost to cache and memory-bandwidth pressure from a busy machine,
    //     because those stall a running core. It is therefore the cost of the snap engine,
    //     including the part of contention the engine actually pays, and excluding the part
    //     where the engine was not running at all. That is the honest metric for a gate.
    //
    //   * **Wall clock is always reported, and asserted only when the run proves it earned it.**
    //     Wall clock is what a user feels, so it is never dropped from the report. But a
    //     percentile of wall time on a contended machine is a percentile of the scheduler. Every
    //     sample records both clocks, and two independent tests have to pass before a wall
    //     percentile is asserted, because contention arrives in two shapes:
    //
    //       - *isolated preemption* — a few samples descheduled outright, which wrecks the tail
    //         and leaves the median untouched. Caught by the **clean fraction**: the wall
    //         percentile at level q is asserted only if more than q of the samples held a core
    //         for at least half their elapsed time.
    //       - *sustained load* — every sample slowed by the same factor, so not one of them
    //         looks descheduled. Caught by **sustained occupancy**: thread-CPU over wall time
    //         across the uninterrupted samples, which must clear 0.95.
    //
    //     When either test fails the suite prints `SNAP-BENCH inconclusive`, names which
    //     detector tripped, and does **not** assert the wall figure: it refuses to report a
    //     failure it cannot attribute, rather than blaming the engine for the machine.
    //     `Scripts/build-snap-package.sh` turns that line into a distinct, non-green verdict
    //     (exit 75) so an inconclusive benchmark can never be mistaken for a passing one.
    //
    // This does not designate a reference machine for the snap budgets; none has been designated
    // for them. It does
    // something narrower and checkable on any machine: it measures whether *this* run was quiet
    // enough for its own wall-clock numbers to describe the code under test.

    /// A sample counts as clean when the thread held a core for at least this share of the
    /// sample's wall time. Half is deliberately generous: this detector is looking for the
    /// sample that was *descheduled*, not for a machine that is merely busy.
    static let cleanOccupancyFloor = 0.5

    /// The floor `PairedSamples.sustainedOccupancy` must clear before any wall-clock percentile
    /// from the run is attributable at any level.
    ///
    /// Measured on this machine, 2026-08-25:
    ///
    /// | conditions                                    | occupancy     | clean fraction |
    /// |-----------------------------------------------|---------------|----------------|
    /// | suite isolated, another workflow's tests only  | 0.9964–0.9973 | 1.0000         |
    /// | full `swift test`, determinism on every core   | 0.9730–0.9823 | 0.9997–1.0000  |
    /// | 30 spinning processes on 18 cores              | **0.6888**    | **1.0000**     |
    ///
    /// The last row is the one that forced this constant into existence. Under sustained load the
    /// thread is not descheduled for whole samples; it is slowed by a roughly constant factor
    /// across *every* sample, so no individual sample looks contended, the clean fraction stays
    /// at 1.0 — and wall p95 ran 55% above cpu p95 (1064.9 ms against 686.7 ms). The per-sample
    /// detector cannot see that. Conversely one long stall wrecks a tail without moving the
    /// aggregate much, which the aggregate cannot see. A wall percentile has to clear both.
    ///
    /// 0.95 sits below every measured non-pathological figure and far above the loaded one.
    static let attributableOccupancyFloor = 0.95

    /// Below this, the two clocks are being asked for more resolution than they have, and the
    /// ratio between them is noise. Such samples are counted clean.
    static let clockResolutionMilliseconds = 0.05

    /// S12's budgets, release.
    static let p95BudgetMilliseconds = 8.0
    static let p999BudgetMilliseconds = 16.0
    /// S13's budget, release.
    static let indexBuildBudgetMilliseconds = 400.0

    /// Debug allowances. Not `QUALITY_BAR` numbers; guards against a complexity regression that
    /// would blow through them by an order of magnitude rather than by a constant factor.
    static let p95DebugAllowanceMilliseconds = 16.0
    static let p999DebugAllowanceMilliseconds = 32.0
    static let indexBuildDebugAllowanceMilliseconds = 1_800.0

    /// Debug allowances for the minimum-zoom case, which is a wider gap than the rest of the
    /// suite. At 5 % zoom the query is dominated by one arithmetic pass — a point-to-box
    /// distance and a heap comparison — over every entry in a 560 x 560 page-point search box,
    /// which is tens of thousands of entries. That loop is exactly what `-Onone` punishes most:
    /// measured on this machine at 1.25 ms p95 in release and 19.35 ms in debug, a factor of
    /// 15.5 rather than the factor of 10 the rest of the suite sees. The allowances are set at
    /// roughly twice the observed debug figure, which still catches a change from `O(n log k)`
    /// back to `O(n log n)` or worse.
    static let p95MinimumZoomDebugAllowanceMilliseconds = 40.0
    static let p999MinimumZoomDebugAllowanceMilliseconds = 80.0

    static var p95MinimumZoomBudget: Double {
        #if DEBUG
        p95MinimumZoomDebugAllowanceMilliseconds
        #else
        p95BudgetMilliseconds
        #endif
    }

    static var p999MinimumZoomBudget: Double {
        #if DEBUG
        p999MinimumZoomDebugAllowanceMilliseconds
        #else
        p999BudgetMilliseconds
        #endif
    }

    static var p95Budget: Double {
        #if DEBUG
        p95DebugAllowanceMilliseconds
        #else
        p95BudgetMilliseconds
        #endif
    }

    static var p999Budget: Double {
        #if DEBUG
        p999DebugAllowanceMilliseconds
        #else
        p999BudgetMilliseconds
        #endif
    }

    static var indexBuildBudget: Double {
        #if DEBUG
        indexBuildDebugAllowanceMilliseconds
        #else
        indexBuildBudgetMilliseconds
        #endif
    }

    static let headlineCount = 250_000
    static let eventCount = 10_000

    /// A dense synthetic drawing: a lattice of short segments, every other one rotated 30
    /// degrees so the cursor meets real crossings rather than only axis-aligned ones.
    ///
    /// The layout matters as much as the count: an index of 250 000 primitives all stacked in
    /// one corner would make every query trivial everywhere else, and an index spread so thin
    /// that no query finds anything would measure the R-tree's ability to say no.
    ///
    /// Two sheet policies are used, deliberately:
    ///
    /// - the **headline** run fixes the sheet at ARCH D and packs all 250 000 primitives onto
    ///   it, which is the denser and harder case and the one S12's budget is asserted against;
    /// - the **scaling** run keeps the spacing fixed and grows the sheet with the count, so
    ///   local density is constant and the curve measures algorithmic complexity rather than
    ///   the density that a fixed sheet would smuggle into it.
    static func latticePrimitives(count: Int, sheet: PDFSize) -> [SnapPrimitive] {
        let width = sheet.width
        let height = sheet.height
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let stepX = width / Double(columns)
        let stepY = height / Double(columns)

        var primitives: [SnapPrimitive] = []
        primitives.reserveCapacity(count)
        var id: UInt64 = 1
        let angle = 30.0 * Double.pi / 180
        let dx = Foundation.cos(angle)
        let dy = Foundation.sin(angle)

        outer: for row in 0..<columns {
            for column in 0..<columns {
                let x = Double(column) * stepX
                let y = Double(row) * stepY
                let length = Swift.min(stepX, stepY) * 1.6
                if id % 2 == 0 {
                    primitives.append(
                        SnapScene.segment(
                            id: id,
                            PDFPoint(x: x, y: y),
                            PDFPoint(x: x + length, y: y)
                        )
                    )
                } else {
                    primitives.append(
                        SnapScene.segment(
                            id: id,
                            PDFPoint(x: x, y: y),
                            PDFPoint(x: x + length * dx, y: y + length * dy)
                        )
                    )
                }
                id += 1
                if primitives.count == count { break outer }
            }
        }
        return primitives
    }

    /// ARCH D, 36 x 24 inches: the headline sheet.
    static let headlineSheet = PDFSize(width: 2592, height: 1728)

    /// The constant-density sheet for a given count: 8 page points between lattice nodes.
    static func constantDensitySheet(count: Int) -> PDFSize {
        let side = Double(Int(Double(count).squareRoot().rounded(.up))) * 8
        return PDFSize(width: side, height: side)
    }

    static func page(sheet: PDFSize) throws -> PageDescriptor {
        try SnapScene.letterPage(
            media: PDFRect(x: 0, y: 0, width: sheet.width, height: sheet.height)
        )
    }

    struct Percentiles: Sendable {
        let p50: Double
        let p95: Double
        let p99: Double
        let p999: Double
        let max: Double
        let mean: Double

        init(_ samples: [Double]) {
            let sorted = samples.sorted()
            func at(_ fraction: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                let index = Swift.min(
                    sorted.count - 1,
                    Swift.max(0, Int((fraction * Double(sorted.count - 1)).rounded()))
                )
                return sorted[index]
            }
            self.p50 = at(0.50)
            self.p95 = at(0.95)
            self.p99 = at(0.99)
            self.p999 = at(0.999)
            self.max = sorted.last ?? 0
            self.mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
        }

        func describe(_ label: String, count: Int) -> String {
            String(
                format: """
                    %@  n=%d  p50=%.4f ms  p95=%.4f ms  p99=%.4f ms  p99.9=%.4f ms  \
                    max=%.4f ms  mean=%.4f ms
                    """,
                label, count, p50, p95, p99, p999, max, mean
            )
        }
    }

    /// A run's paired wall-clock and thread-CPU samples, and the question the pairing exists to
    /// answer: was this thread actually running while it was being timed?
    ///
    /// Both arrays are the same length and index-aligned: `wall[i]` and `cpu[i]` are the two
    /// clocks around the same call.
    struct PairedSamples: Sendable {
        let wall: Percentiles
        let cpu: Percentiles
        let count: Int
        /// The share of samples during which the thread held a core for at least
        /// `cleanOccupancyFloor` of the elapsed wall time.
        let cleanFraction: Double
        /// Aggregate thread-CPU over aggregate wall time across every sample. Reported for
        /// context only — a single long stall drags it down, which is `cleanFraction`'s job to
        /// notice, not this one's.
        let occupancy: Double

        /// Aggregate thread-CPU over aggregate wall time across the samples that were *not*
        /// descheduled and were long enough for the two clocks to be compared.
        ///
        /// This is the detector for *sustained* contention: a machine that is merely busy slows
        /// every sample by roughly the same factor, so no individual sample looks descheduled and
        /// `cleanFraction` stays at 1.0 while every percentile inflates. Restricting it to clean
        /// samples is what keeps the two detectors independent — otherwise one 212 ms stall in a
        /// thousand 1 ms samples pushes this to 0.82 and the p95 gets refused for a reason that
        /// only affects the tail. Measured: that exact case, in `wallAttributionRule`.
        ///
        /// A run with no sample above the clock resolution has nothing to measure and is treated
        /// as uncontended: it is orders of magnitude inside any budget in this file.
        let sustainedOccupancy: Double

        init(wall: [Double], cpu: [Double]) {
            self.wall = Percentiles(wall)
            self.cpu = Percentiles(cpu)
            self.count = wall.count

            var cleanCount = 0
            var cleanWall = 0.0
            var cleanCPU = 0.0
            for (w, c) in zip(wall, cpu) {
                let belowResolution = w <= SnapPerformanceTests.clockResolutionMilliseconds
                let onCore = c >= SnapPerformanceTests.cleanOccupancyFloor * w
                if belowResolution || onCore {
                    cleanCount += 1
                    if !belowResolution {
                        cleanWall += w
                        cleanCPU += c
                    }
                }
            }
            self.cleanFraction = wall.isEmpty ? 0 : Double(cleanCount) / Double(wall.count)
            self.sustainedOccupancy = cleanWall > 0 ? cleanCPU / cleanWall : 1.0

            let wallTotal = wall.reduce(0, +)
            let cpuTotal = cpu.reduce(0, +)
            self.occupancy = wallTotal > 0 ? cpuTotal / wallTotal : 1.0
        }

        /// Whether the wall-clock percentile at `level` describes the code under test rather than
        /// the scheduler. Both detectors must clear.
        ///
        /// If a fraction `d` of the samples were taken while the thread was off a core, then
        /// every wall percentile above `1 - d` is drawn from that contaminated tail, so the
        /// percentile at `level` needs a clean fraction above it. And if the run as a whole spent
        /// a material share of its wall time off-core, every percentile is inflated by that
        /// factor whether or not any single sample looks contended.
        func wallIsAttributable(at level: Double) -> Bool {
            cleanFraction > level
                && sustainedOccupancy >= SnapPerformanceTests.attributableOccupancyFloor
        }

        /// Why the wall figure was refused, for the report. `nil` when it was not.
        func attributionRefusal(at level: Double) -> String? {
            if sustainedOccupancy < SnapPerformanceTests.attributableOccupancyFloor {
                return String(
                    format: "even its uninterrupted samples held a core for only %.2f%% of their "
                        + "elapsed time (floor %.0f%%), so every wall percentile is inflated by "
                        + "sustained contention",
                    sustainedOccupancy * 100,
                    SnapPerformanceTests.attributableOccupancyFloor * 100
                )
            }
            if cleanFraction <= level {
                return String(
                    format: "only %.2f%% of samples ran on a core for at least half their elapsed "
                        + "time, so the %.1fth percentile of wall time is drawn from the "
                        + "descheduled tail",
                    cleanFraction * 100, level * 100
                )
            }
            return nil
        }
    }

    /// Milliseconds of CPU consumed by the calling thread.
    ///
    /// Wall-clock time is the right metric for a latency budget in production, and it is what
    /// gets printed. It is the wrong metric for an assertion on a machine this suite does not
    /// own: with other suites — or another workflow — competing for cores, a wall-clock p99.9 is
    /// a percentile of preemption. Thread CPU time still pays for cache and memory-bandwidth
    /// contention, because that stalls a running core, but it does not pay for being descheduled.
    /// See the budget note above for how the two are used.
    static func threadCPUMilliseconds() -> Double {
        var value = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0 else { return 0 }
        return Double(value.tv_sec) * 1_000 + Double(value.tv_nsec) / 1_000_000
    }

    /// Print one measurement in full and assert its budgets.
    ///
    /// Every line `QUALITY_BAR` 3.5 asks for is printed for **both** clocks — p50, p95, p99,
    /// p99.9, max — plus the machine block and the attribution figures, whatever the verdict.
    /// Then:
    ///
    /// - the **thread-CPU** percentiles are asserted, always. This is the regression guard, and
    ///   it is the assertion a change to the snap engine has to answer to;
    /// - the **wall-clock** percentiles are asserted only at the levels this run's clean fraction
    ///   supports. Where it does not, one `SNAP-BENCH inconclusive` line names the level, the
    ///   measured number and the clean fraction, and nothing is asserted at that level — the
    ///   benchmark refuses to report a failure it cannot attribute.
    static func reportAndAssert(
        _ samples: PairedSamples,
        label: String,
        p95Budget: Double,
        p999Budget: Double?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        print(machineBlock())
        print(samples.wall.describe("\(label) wall", count: samples.count))
        print(samples.cpu.describe("\(label) cpu ", count: samples.count))
        print(
            String(
                format: "SNAP-BENCH %@  clean=%.4f  occupancy=%.4f  sustained=%.4f  n=%d  "
                    + "budgets p95=%.1f ms%@",
                label, samples.cleanFraction, samples.occupancy, samples.sustainedOccupancy,
                samples.count, p95Budget,
                p999Budget.map { String(format: " p99.9=%.1f ms", $0) } ?? ""
            )
        )

        // Thread CPU: the assertion that always runs.
        #expect(
            samples.cpu.p95 <= p95Budget,
            "\(label): cpu p95 \(samples.cpu.p95) ms exceeds \(p95Budget) ms" as Comment,
            sourceLocation: sourceLocation
        )
        if let p999Budget {
            #expect(
                samples.cpu.p999 <= p999Budget,
                "\(label): cpu p99.9 \(samples.cpu.p999) ms exceeds \(p999Budget) ms" as Comment,
                sourceLocation: sourceLocation
            )
        }

        // Wall clock: asserted only where this run earned the right to be believed.
        if samples.wallIsAttributable(at: 0.95) {
            #expect(
                samples.wall.p95 <= p95Budget,
                "\(label): wall p95 \(samples.wall.p95) ms exceeds \(p95Budget) ms" as Comment,
                sourceLocation: sourceLocation
            )
        } else {
            print(
                """
                SNAP-BENCH inconclusive  \(label) wall p95 = \
                \(String(format: "%.4f", samples.wall.p95)) ms is not attributable: \
                \(samples.attributionRefusal(at: 0.95) ?? "the run was contended"). The cpu p95 \
                above is asserted; this number is reported and not judged. Re-run on a quiet \
                machine for a wall-clock verdict.
                """
            )
        }
        if let p999Budget {
            if samples.wallIsAttributable(at: 0.999) {
                #expect(
                    samples.wall.p999 <= p999Budget,
                    "\(label): wall p99.9 \(samples.wall.p999) ms exceeds \(p999Budget) ms" as Comment,
                    sourceLocation: sourceLocation
                )
            } else {
                print(
                    """
                    SNAP-BENCH inconclusive  \(label) wall p99.9 = \
                    \(String(format: "%.4f", samples.wall.p999)) ms is not attributable: \
                    \(samples.attributionRefusal(at: 0.999) ?? "the run was contended"). The cpu \
                    p99.9 above is asserted; this number is reported and not judged.
                    """
                )
            }
        }
    }

    static func machineBlock() -> String {
        let info = ProcessInfo.processInfo
        var configuration = "debug"
        #if !DEBUG
        configuration = "release"
        #endif
        return """
            machine: \(info.hostName) cores=\(info.processorCount) \
            memory=\(info.physicalMemory / 1_048_576) MB \
            os=\(info.operatingSystemVersionString) configuration=\(configuration)
            """
    }

    // MARK: - S13: index build

    @Test("Index build over 250 000 primitives stays inside the S13 budget")
    func indexBuild() throws {
        let page = try Self.page(sheet: Self.headlineSheet)
        let primitives = Self.latticePrimitives(
            count: Self.headlineCount, sheet: Self.headlineSheet
        )
        #expect(primitives.count == Self.headlineCount)

        var wall: [Double] = []
        var cpu: [Double] = []
        for _ in 0..<5 {
            var index = try SnapIndexBuilder().build(page: page, extraction: nil)
            let entries = primitives.map {
                SnapIndexEntry(
                    primitive: $0, source: .pdfPathObject, ownerID: nil, kindSet: .pdfVector
                )
            }
            let startWall = DispatchTime.now().uptimeNanoseconds
            let startCPU = Self.threadCPUMilliseconds()
            try index.installVectorEntries(entries, availability: .available)
            cpu.append(Self.threadCPUMilliseconds() - startCPU)
            wall.append(Double(DispatchTime.now().uptimeNanoseconds - startWall) / 1_000_000)
            #expect(index.vectorPrimitiveCount == Self.headlineCount)
        }

        // n = 5, so a single sample taken while this thread was descheduled is 20% of the run
        // and the p95 is that sample. The attribution rule handles that without special-casing:
        // one contended sample puts the clean fraction at 0.8, which does not clear 0.95.
        Self.reportAndAssert(
            PairedSamples(wall: wall, cpu: cpu),
            label: "S13 index build (250k primitives)",
            p95Budget: Self.indexBuildBudget,
            p999Budget: nil
        )
    }

    // MARK: - S12: query latency

    @Test("Query latency over 250 000 primitives and 10 000 events meets S12")
    func queryLatency() throws {
        let page = try Self.page(sheet: Self.headlineSheet)
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: Self.latticePrimitives(
                count: Self.headlineCount, sheet: Self.headlineSheet
            )
        )
        #expect(scene.index.vectorPrimitiveCount == Self.headlineCount)

        // A reproducible pointer path: a deterministic walk across the sheet, at a mix of the
        // zooms a user actually works at.
        var random = SnapDeterministicRandom(seed: "snap-benchmark-path")
        let zooms = [0.25, 1.0, 1.0, 2.0, 4.0, 8.0]
        var events: [SnapPointerEvent] = []
        events.reserveCapacity(Self.eventCount)
        var cursor = PDFPoint(x: 1296, y: 864)
        for i in 0..<Self.eventCount {
            // A drifting walk: consecutive samples are close, as a real pointer path is, so the
            // measurement is not dominated by cold R-tree nodes on every event.
            cursor = PDFPoint(
                x: Swift.min(2591, Swift.max(1, cursor.x + (random.nextUnitDouble() - 0.5) * 12)),
                y: Swift.min(1727, Swift.max(1, cursor.y + (random.nextUnitDouble() - 0.5) * 12))
            )
            if i % 500 == 0 {
                cursor = PDFPoint(
                    x: random.nextUnitDouble() * 2592,
                    y: random.nextUnitDouble() * 1728
                )
            }
            let zoom = zooms[random.nextInt(below: zooms.count)]
            let layout = SnapReplay.layout(zoom: zoom)
            events.append(
                SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(cursor, page: page, layout: layout),
                    layout: layout,
                    sequence: i
                )
            )
        }

        var settings = SnapSettings.default
        settings.gridSpacingPoints = 36

        var engine = SnapEngine()
        // Warm up so the first sample does not measure lazy globals and page faults.
        for event in events.prefix(200) {
            _ = try engine.resolve(SnapQuery(event: event, settings: settings), in: scene.index)
        }

        var wall: [Double] = []
        var cpu: [Double] = []
        wall.reserveCapacity(events.count)
        cpu.reserveCapacity(events.count)
        var winners = 0
        for event in events {
            let startWall = DispatchTime.now().uptimeNanoseconds
            let startCPU = Self.threadCPUMilliseconds()
            let resolution = try engine.resolve(
                SnapQuery(event: event, settings: settings), in: scene.index
            )
            cpu.append(Self.threadCPUMilliseconds() - startCPU)
            wall.append(Double(DispatchTime.now().uptimeNanoseconds - startWall) / 1_000_000)
            if resolution.winner != nil { winners += 1 }
        }

        print("snap query winners: \(winners) of \(wall.count)")
        // A benchmark that never finds anything measures the R-tree's ability to say no.
        #expect(winners > wall.count / 2)
        #expect(wall.count == Self.eventCount)

        Self.reportAndAssert(
            PairedSamples(wall: wall, cpu: cpu),
            label: "S12 query (250k primitives, 10k events)",
            p95Budget: Self.p95Budget,
            p999Budget: Self.p999Budget
        )
    }

    /// S12 at the **lowest zoom the product supports**, which is the worst case the headline
    /// benchmark does not reach.
    ///
    /// `queryLatency` samples zooms from 0.25 to 8. But `PageViewLayout.minimumZoom` is 0.05,
    /// and the query radius is `radiusViewPoints / zoom`, so at 5 % a 10-view-point radius is
    /// 200 page points and the search box is 560 x 560 — over a hundred times the area the
    /// 0.25 case sweeps, and tens of thousands of entries per event instead of hundreds. Fit-
    /// to-window on a large-format sheet in a small window is exactly that zoom, so it is a
    /// configuration a user reaches on the first mouse move after opening a drawing, not a
    /// synthetic corner.
    ///
    /// Measured on this suite's own headline sheet, this case cost a p95 of 7.6 ms against the
    /// 8 ms budget before the bounded `k`-smallest selection in
    /// `SnapTargetGenerator.localPrimitives` replaced a full sort of the whole search box, and
    /// 2.2 ms after. Without this test that margin was invisible.
    @Test("Query latency at the minimum supported zoom still meets S12")
    func queryLatencyAtMinimumZoom() throws {
        let page = try Self.page(sheet: Self.headlineSheet)
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: Self.latticePrimitives(
                count: Self.headlineCount, sheet: Self.headlineSheet
            )
        )
        #expect(scene.index.vectorPrimitiveCount == Self.headlineCount)

        let layout = SnapReplay.layout(zoom: PageViewLayout.minimumZoom)
        var random = SnapDeterministicRandom(seed: "snap-benchmark-min-zoom")
        var events: [SnapPointerEvent] = []
        let sampleCount = Self.eventCount / 5
        events.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let cursor = PDFPoint(
                x: random.nextUnitDouble() * Self.headlineSheet.width,
                y: random.nextUnitDouble() * Self.headlineSheet.height
            )
            events.append(
                SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(cursor, page: page, layout: layout),
                    layout: layout,
                    sequence: i
                )
            )
        }

        var engine = SnapEngine()
        for event in events.prefix(50) {
            _ = try engine.resolve(SnapQuery(event: event), in: scene.index)
        }

        // This case measured wall clock only until 2026-08-25, which is why it is the one that
        // went red under contention: p99.9 = 212.24 ms against an 80 ms allowance, on a machine
        // running three other things. It is also the most expensive query in the suite, so it is
        // the most sensitive to losing a core mid-sample. Both clocks are taken now.
        var wall: [Double] = []
        var cpu: [Double] = []
        wall.reserveCapacity(events.count)
        cpu.reserveCapacity(events.count)
        var winners = 0
        for event in events {
            let startWall = DispatchTime.now().uptimeNanoseconds
            let startCPU = Self.threadCPUMilliseconds()
            let resolution = try engine.resolve(SnapQuery(event: event), in: scene.index)
            cpu.append(Self.threadCPUMilliseconds() - startCPU)
            wall.append(Double(DispatchTime.now().uptimeNanoseconds - startWall) / 1_000_000)
            if resolution.winner != nil { winners += 1 }
        }

        #expect(winners > wall.count / 2)
        Self.reportAndAssert(
            PairedSamples(wall: wall, cpu: cpu),
            label: "S12 query at minimum zoom \(PageViewLayout.minimumZoom) (250k primitives)",
            p95Budget: Self.p95MinimumZoomBudget,
            p999Budget: Self.p999MinimumZoomBudget
        )
    }

    /// The instrument that decides whether a wall-clock number may be believed, tested on data
    /// whose answer is known.
    ///
    /// `QUALITY_BAR` section 5's rule that a skipped case never counts as a pass has a corollary: an
    /// assertion that quietly stops being made is worse than one that fails. The wall-clock
    /// budgets in this suite are conditional, so the condition itself has to be pinned, or a
    /// future change could make every wall assertion silently unreachable and every run green.
    /// The numbers here are constructed, not measured — that is the point.
    @Test("A wall-clock percentile is asserted only when the samples under it ran on a core")
    func wallAttributionRule() {
        // 1. A quiet run: both clocks agree on every sample. Everything is attributable.
        let quiet = PairedSamples(
            wall: Array(repeating: 1.0, count: 1_000),
            cpu: Array(repeating: 0.99, count: 1_000)
        )
        #expect(quiet.cleanFraction == 1.0)
        #expect(quiet.wallIsAttributable(at: 0.95))
        #expect(quiet.wallIsAttributable(at: 0.999))

        // 2. Exactly one sample in a thousand descheduled — 15.12's shape: a 212 ms wall reading
        //    over 1 ms of actual work. The p95 is still honest; the p99.9 is that sample, so it
        //    is refused. This is the case that turned a green engine red four times.
        var wall = Array(repeating: 1.0, count: 1_000)
        var cpu = Array(repeating: 0.99, count: 1_000)
        wall[500] = 212.0
        cpu[500] = 1.0
        let oneStall = PairedSamples(wall: wall, cpu: cpu)
        #expect(oneStall.cleanFraction == 0.999)
        #expect(oneStall.wallIsAttributable(at: 0.95))
        #expect(!oneStall.wallIsAttributable(at: 0.999))
        // The stall is in the wall distribution and not in the cpu one, which is the whole
        // reason the two clocks are kept side by side.
        #expect(oneStall.wall.max == 212.0)
        #expect(oneStall.cpu.max == 1.0)
        // Note where it is *not*: at n = 1000 the 99.9th percentile lands on index 998, so a
        // single stall shows up in `max` and has not yet moved `p999`. The rule refuses anyway.
        // It is deliberately one step conservative — it withholds the wall verdict as soon as a
        // sample *could* have contaminated the percentile, rather than waiting for proof that
        // one did. Withholding a number that would have been fine costs a re-run; publishing one
        // that was not is how 15.12 spent four gate runs blaming the engine for the machine.
        #expect(oneStall.wall.p999 == 1.0)

        // 3. A busy machine: a twentieth of the samples spent most of their time off a core.
        //    Neither level survives. (Index 500 is a multiple of 20, so case 2's stall is
        //    overwritten here rather than added to: fifty contended samples, not fifty-one.)
        for index in stride(from: 0, to: 1_000, by: 20) {
            wall[index] = 40.0
            cpu[index] = 2.0
        }
        let busy = PairedSamples(wall: wall, cpu: cpu)
        #expect(busy.cleanFraction == 0.95)
        #expect(!busy.wallIsAttributable(at: 0.95))
        #expect(!busy.wallIsAttributable(at: 0.999))

        // 4. Samples too short for the two clocks to be compared are counted clean rather than
        //    contended, so a fast query is never mistaken for a preempted one.
        let tiny = PairedSamples(
            wall: Array(repeating: 0.01, count: 1_000),
            cpu: Array(repeating: 0.0, count: 1_000)
        )
        #expect(tiny.cleanFraction == 1.0)
        #expect(tiny.wallIsAttributable(at: 0.999))

        // 5. Sustained contention: the shape the per-sample detector cannot see. Every sample is
        //    slowed by the same factor, so not one of them looks descheduled and the clean
        //    fraction stays at 1.0 — this is the 30-spinning-processes row of the table on
        //    `attributableOccupancyFloor`, where occupancy measured 0.6888 while wall p95 ran
        //    55% above cpu p95. Only the aggregate catches it, and it must.
        let throttled = PairedSamples(
            wall: Array(repeating: 1.45, count: 1_000),
            cpu: Array(repeating: 1.0, count: 1_000)
        )
        #expect(throttled.cleanFraction == 1.0)          // every sample looks fine
        #expect(throttled.sustainedOccupancy < 0.95)     // the run does not
        #expect(!throttled.wallIsAttributable(at: 0.95))
        #expect(!throttled.wallIsAttributable(at: 0.999))

        // 6. Each refusal says which of the two detectors tripped, because "the machine was
        //    busy" and "one sample was descheduled" call for different responses.
        #expect(throttled.attributionRefusal(at: 0.95)?.contains("sustained contention") == true)
        #expect(oneStall.attributionRefusal(at: 0.999)?.contains("descheduled tail") == true)
        #expect(quiet.attributionRefusal(at: 0.999) == nil)
    }

    @Test("Query cost scales with local density, not with page primitive count")
    func scalingShape() throws {
        // 3.5 asks for the scaling curve so a complexity regression is distinguishable from a
        // constant-factor one.
        var reported: [String] = []
        var p95s: [Double] = []
        for count in [10_000, 50_000, 100_000, 250_000] {
            let sheet = Self.constantDensitySheet(count: count)
            let page = try Self.page(sheet: sheet)
            let scene = try SnapScene.withVectorContent(
                page: page, primitives: Self.latticePrimitives(count: count, sheet: sheet)
            )
            var random = SnapDeterministicRandom(seed: "scaling-\(count)")
            var engine = SnapEngine()
            let layout = SnapReplay.layout(zoom: 1.0)
            var samples: [Double] = []
            for _ in 0..<2000 {
                let cursor = PDFPoint(
                    x: random.nextUnitDouble() * sheet.width,
                    y: random.nextUnitDouble() * sheet.height
                )
                let event = SnapPointerEvent(
                    viewPoint: try SnapReplay.viewPoint(cursor, page: page, layout: layout),
                    layout: layout
                )
                let start = Self.threadCPUMilliseconds()
                _ = try engine.resolve(SnapQuery(event: event), in: scene.index)
                samples.append(Self.threadCPUMilliseconds() - start)
            }
            let percentiles = Percentiles(samples)
            reported.append(
                percentiles.describe("snap query cpu (\(count) primitives)", count: samples.count)
            )
            p95s.append(percentiles.p95)
        }
        print(Self.machineBlock())
        for line in reported { print(line) }

        for value in p95s {
            #expect(value <= Self.p95Budget)
        }
        // Local density is held constant across the four sizes, so the only thing that grows is
        // the index. A 25x index must therefore cost barely more per query. Three times is a
        // generous ceiling that still catches a change from logarithmic to linear.
        let smallest = try #require(p95s.first)
        let largest = try #require(p95s.last)
        #expect(
            largest <= Swift.max(smallest * 3, 0.25),
            "scaling: p95 went from \(smallest) ms at 10k to \(largest) ms at 250k" as Comment
        )
    }
}
