import Foundation
import Testing
import ZPDFSnapScenario

/// BH-673 / BH-674: the decision-log driver refuses an insertion seed it cannot parse instead of
/// silently printing the unshuffled reference log.
@Suite("Decision log driver arguments (BH-673)")
struct DecisionLogArgumentTests {

    static func run(_ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
        let executable = try #require(SnapDeterminismTests.locateDecisionLogExecutable())
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SWIFT_DETERMINISTIC_HASHING")
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
    }

    @Test("Unparseable seeds exit 64 with a diagnostic and print no log", arguments: ["0x1f", "-3", "7 ", "1e3", "18446744073709551616", ""])
    func unparseableSeedIsRefused(seed: String) throws {
        let result = try Self.run([seed])
        // Old output: exit 0 and the unshuffled reference log — the seed silently became 0.
        #expect(result.status == 64, "seed '\(seed)' exited \(result.status)" as Comment)
        #expect(result.output.isEmpty)
        #expect(result.error.contains("insertion seed"))
    }

    @Test("A valid seed prints exactly the in-process log for that seed")
    func validSeedMatchesInProcessLog() throws {
        let result = try Self.run(["7"])
        #expect(result.status == 0)
        let expected = try SnapDeterminismScenario.decisionLog(insertionSeed: 7).map { $0 + "\n" }.joined()
        #expect(result.output == expected)
        #expect(try Self.run([]).output == expected, "shuffling must not change the log")
    }
}
