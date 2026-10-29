import Foundation

/// A latency sample set, summarised the way `QUALITY_BAR` 3.5 asks for: p50, p95, p99 and the
/// maximum, because a single 200 ms outlier is a dropped frame the user sees and a p95 hides it.
struct LatencySummary {
    let name: String
    let samples: [Double]

    init(name: String, samples: [Double]) {
        self.name = name
        self.samples = samples.sorted()
    }

    var count: Int { samples.count }
    var p50: Double { percentile(0.50) }
    var p95: Double { percentile(0.95) }
    var p99: Double { percentile(0.99) }
    var maximum: Double { samples.last ?? 0 }
    var mean: Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }

    func percentile(_ fraction: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let index = Int((Double(samples.count - 1) * fraction).rounded())
        return samples[Swift.min(Swift.max(index, 0), samples.count - 1)]
    }

    /// One line, in milliseconds.
    var line: String {
        String(
            format: "%-52@ n=%-5d p50 %8.3f  p95 %8.3f  p99 %8.3f  max %8.3f  mean %8.3f",
            name as NSString, count, p50, p95, p99, maximum, mean
        )
    }
}

/// Wall-clock milliseconds for one call.
func measureMilliseconds(_ body: () -> Void) -> Double {
    let clock = ContinuousClock()
    let elapsed = clock.measure(body)
    return Double(elapsed.components.seconds) * 1_000
        + Double(elapsed.components.attoseconds) / 1e15
}

/// Resident memory of this process in bytes, or `nil` when the kernel will not say.
func residentMemoryBytes() -> Int? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Int(info.resident_size)
}

/// Whether this build is optimised. Every budget below is a budget on optimised code, and a debug
/// run says so rather than pretending.
var isReleaseBuild: Bool {
    #if DEBUG
    false
    #else
    true
    #endif
}
