import Darwin
import Foundation
import Testing
import ZPDFQPDF
import ZPDFTestingSupport

/// Mutated-input sweep.
///
/// The contract being tested is not "qpdf gets the right answer" — for a
/// randomly corrupted file there is no right answer. It is that **every**
/// outcome is one of two things: a success whose output an independent reader
/// can open, or a typed ``QPDFError``. Never a trap, never a hang, never an
/// allocation that grows with the attacker's imagination.
///
/// Serialized so the resident-size measurement means something.
@Suite("Fuzz", .serialized)
struct FuzzTests {

    /// Wall-clock ceiling for one iteration. A mutated 5 KB file that takes a
    /// second is a hang for our purposes.
    static let perIterationBudget: TimeInterval = 2.0
    /// Resident-size growth allowed across the whole sweep.
    static let residentGrowthBudget: UInt64 = 384 * 1024 * 1024
    static let iterations = 400

    @Test("400 mutated inputs produce typed errors, never a crash, hang or runaway allocation")
    func mutatedInputsAreAlwaysTyped() throws {
        let box = try Sandbox("fuzz")
        #expect(FuzzCorpus.bytes.isEmpty == false)

        var options = QPDFOptions.default
        options.maximumInputBytes = 64 * 1024 * 1024
        options.maximumPageCount = 4096
        options.maximumDecodedStreamBytes = 32 * 1024 * 1024

        var outcomes: [String: Int] = [:]
        var repairedAndOpenable = 0
        var slowest: (seed: UInt64, seconds: TimeInterval) = (0, 0)
        var largestOutput = 0
        let residentBefore = Memory.residentBytes()
        var residentPeak = residentBefore
        let sweepStart = Date()

        for iteration in 0..<Self.iterations {
            let seed = FuzzCorpus.seed(base: 0x5A45_4E49_5450_4446, iteration: iteration)
            var generator = SplitMix64(seed: seed)
            let base = FuzzCorpus.pick(&generator)
            let mutated = FuzzCorpus.mutate(
                base, generator: &generator, preserveLength: iteration % 2 == 0)

            let input = box.file("fuzz-\(iteration).pdf")
            let output = box.file("fuzz-\(iteration)-out.pdf")
            try mutated.write(to: input, options: .atomic)
            defer {
                try? FileManager.default.removeItem(at: input)
                try? FileManager.default.removeItem(at: output)
            }

            let start = Date()
            let tag = run(input: input, output: output, options: options)
            let elapsed = Date().timeIntervalSince(start)

            outcomes[tag, default: 0] += 1
            if elapsed > slowest.seconds { slowest = (seed, elapsed) }
            #expect(
                elapsed < Self.perIterationBudget,
                "seed \(seed) took \(elapsed) s, over the \(Self.perIterationBudget) s budget")

            if FileManager.default.fileExists(atPath: output.path) {
                let size = (try? Data(contentsOf: output).count) ?? 0
                largestOutput = max(largestOutput, size)
                #expect(
                    size < 32 * 1024 * 1024,
                    "seed \(seed) produced a \(size)-byte output from a \(mutated.count)-byte input")
                if tag == "ok" && IndependentReader.opens(output) {
                    repairedAndOpenable += 1
                }
                #expect(
                    tag == "ok",
                    "seed \(seed) failed with \(tag) but still left an output file behind")
            }
            // A failure must never leave a temporary behind either.
            #expect(
                FileManager.default.fileExists(atPath: output.path + ".zpdf-partial") == false,
                "seed \(seed) left a partial file")

            residentPeak = max(residentPeak, Memory.residentBytes())
        }

        let sweepSeconds = Date().timeIntervalSince(sweepStart)
        let growth = residentPeak > residentBefore ? residentPeak - residentBefore : 0

        print("[fuzz] \(Self.iterations) mutated inputs in \(String(format: "%.2f", sweepSeconds)) s "
            + "(\(String(format: "%.2f", sweepSeconds / Double(Self.iterations) * 1000)) ms each)")
        print("[fuzz] outcomes: \(outcomes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        print("[fuzz] repaired and openable by PDFKit: \(repairedAndOpenable)")
        print("[fuzz] slowest iteration: seed \(slowest.seed) at "
            + "\(String(format: "%.1f", slowest.seconds * 1000)) ms")
        print("[fuzz] largest output: \(largestOutput) bytes")
        print("[fuzz] resident size \(residentBefore / 1_048_576) MiB -> peak "
            + "\(residentPeak / 1_048_576) MiB (growth \(growth / 1_048_576) MiB)")

        #expect(outcomes["unknownStatus"] == nil, "the shim returned a status Swift does not map")
        #expect(outcomes["internalFailure"] == nil, "an unexpected C++ exception escaped qpdf")
        #expect(
            growth < Self.residentGrowthBudget,
            "resident size grew by \(growth / 1_048_576) MiB across the sweep")
        // A sweep in which nothing ever succeeded would pass every assertion
        // above while testing nothing, so require some real work to have
        // happened.
        #expect(repairedAndOpenable > 0, "no mutated input was ever successfully repaired")
    }

    @Test("hostile non-PDF inputs are refused, not misread")
    func nonPDFInputsAreRefused() throws {
        let box = try Sandbox("nonPDF")
        let output = box.file("out.pdf")

        let empty = box.file("empty.pdf")
        try Data().write(to: empty)
        expectQPDFError("damaged") { _ = try QPDF.inspect(empty) }

        let noise = box.file("noise.pdf")
        var generator = SplitMix64(seed: 42)
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &generator) })
            .write(to: noise)
        expectQPDFError("damaged") { _ = try QPDF.inspect(noise) }

        expectQPDFError("cannotRead") {
            _ = try QPDF.inspect(box.file("does-not-exist.pdf"))
        }
        // A directory is not a regular file.
        expectQPDFError("cannotRead") { _ = try QPDF.inspect(box.url) }
        // An output directory that does not exist is an argument error, caught
        // before anything is read.
        expectQPDFError("invalidArgument") {
            _ = try QPDF.repair(
                input: try box.fixture(.rectangle),
                output: box.url.appendingPathComponent("nope/deeper/out.pdf"))
        }
        #expect(FileManager.default.fileExists(atPath: output.path) == false)
    }

    /// Runs the two entry points a hostile file would reach first and returns a
    /// tag for the outcome. Any error that is not a ``QPDFError`` is a failure
    /// of the bridge's central promise, so it is recorded as such rather than
    /// being rethrown and losing the seed.
    private func run(input: URL, output: URL, options: QPDFOptions) -> String {
        do {
            _ = try QPDF.inspect(input, options: options)
        } catch let error as QPDFError {
            return error.tag
        } catch {
            Issue.record("inspect threw a non-QPDFError: \(error)")
            return "untyped"
        }
        do {
            _ = try QPDF.repair(input: input, output: output, options: options)
            return "ok"
        } catch let error as QPDFError {
            return error.tag
        } catch {
            Issue.record("repair threw a non-QPDFError: \(error)")
            return "untyped"
        }
    }
}

enum Memory {
    /// Resident size of this process, in bytes.
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
