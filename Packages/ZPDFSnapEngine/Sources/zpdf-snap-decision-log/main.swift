import Foundation
import ZPDFSnapScenario

// Prints the snap decision log for the standard determinism scenario and exits.
//
// `ZPDFSnapDeterminismTests` spawns this 20 times. Every process gets a fresh, randomly seeded
// `Hasher`, which is the whole point: `QUALITY_BAR` 3.4 rule 4 forbids running the determinism
// test with `SWIFT_DETERMINISTIC_HASHING` forced on, because that defeats it. If any ordering
// in the engine reached into a `Set` or a `Dictionary`, these 20 outputs would differ.
//
// Usage: zpdf-snap-decision-log [insertionSeed]
// A non-zero insertion seed shuffles the order geometry is inserted into the index, which must
// not change a single byte of the output either.

let arguments = CommandLine.arguments

// An unparseable seed is refused, never mapped to 0: seed 0 is the unshuffled reference run,
// so a shuffled-insertion comparison fed "0x1f" or "-3" used to pass while testing nothing
// (BH-673). 64 is EX_USAGE.
func refuse(_ message: String) -> Never {
    FileHandle.standardError.write(Data("zpdf-snap-decision-log: \(message)\nUsage: zpdf-snap-decision-log [insertionSeed]\n".utf8))
    exit(64)
}

let seed: UInt64
switch arguments.count {
case 1:
    seed = 0
case 2:
    guard let parsed = UInt64(arguments[1]) else {
        refuse("insertion seed '\(arguments[1])' is not a decimal UInt64")
    }
    seed = parsed
default:
    refuse("expected at most one argument, the insertion seed")
}

do {
    let log = try SnapDeterminismScenario.decisionLog(insertionSeed: seed)
    var output = ""
    output.reserveCapacity(log.count * 96)
    for line in log {
        output += line
        output += "\n"
    }
    FileHandle.standardOutput.write(Data(output.utf8))
} catch {
    FileHandle.standardError.write(Data("snap-decision-log failed: \(error)\n".utf8))
    exit(2)
}
