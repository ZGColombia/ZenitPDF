import AppKit
import Foundation
import ZPDFDesignSystem

// A command-line audit of the Graphite Workshop design system.
//
// It runs exactly the invariants the unit tests assert. Full Xcode is not required to run it,
// which matters on machines that only have the Command Line Tools and therefore have no
// XCTest framework to link against.

// `--contact-sheet <path>` renders the measurement glyphs into one PNG for visual review.
let arguments = Array(CommandLine.arguments.dropFirst())
if let flagIndex = arguments.firstIndex(of: "--contact-sheet") {
    guard flagIndex + 1 < arguments.count else {
        FileHandle.standardError.write(Data("--contact-sheet needs an output path\n".utf8))
        exit(2)
    }
    let path = arguments[flagIndex + 1]
    let wrote = MainActor.assumeIsolated { ContactSheet.write(to: path) }
    print(wrote ? "wrote \(path)" : "could not write \(path)")
    exit(wrote ? 0 : 1)
}

let report = MainActor.assumeIsolated { ZPDFSelfCheck.run() }

print("ZPDFDesignSystem audit")
print("  colour tokens      : \(ZPDFColorToken.allCases.count)")
print("  appearance variants: \(ZPDFAppearanceVariant.allCases.count)")
print("  measurement icons  : \(ZPDFIconKind.allCases.count)")
print("  system symbols     : \(ZPDFSymbol.allCases.count)")
print("  assertions run     : \(report.assertionCount)")

if report.passed {
    print("  result             : PASS")
    exit(0)
} else {
    print("  result             : FAIL (\(report.failures.count))")
    for failure in report.failures {
        print("    - \(failure.description)")
    }
    exit(1)
}
