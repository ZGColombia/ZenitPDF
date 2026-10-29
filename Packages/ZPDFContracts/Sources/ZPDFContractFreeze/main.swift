import Foundation
import ZPDFContracts

/// Writes the frozen contract documents to `Docs/Contracts`.
///
/// Usage:
///
///     zpdf-contract-freeze <output-directory> [iso-timestamp]
///
/// The timestamp defaults to the current system time in UTC. It is an argument so a freeze can
/// be reproduced exactly: the same arguments produce byte-identical files.

let arguments = CommandLine.arguments

guard arguments.count >= 2 else {
    FileHandle.standardError.write(
        Data("usage: zpdf-contract-freeze <output-directory> [iso-timestamp]\n".utf8)
    )
    exit(2)
}

let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let frozenAt = arguments.count >= 3 ? arguments[2] : ContractCatalog.isoTimestamp(Date())

do {
    let written = try ContractCatalog.write(to: directory, frozenAt: frozenAt)
    for url in written {
        let size = (try? Data(contentsOf: url).count) ?? 0
        print("wrote \(url.lastPathComponent)  \(size) bytes")
    }
    print("frozenAt \(frozenAt)")
    print("\(written.count) contract documents written to \(directory.path)")
} catch {
    FileHandle.standardError.write(Data("freeze failed: \(error)\n".utf8))
    exit(1)
}
