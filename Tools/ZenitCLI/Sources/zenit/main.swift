import Foundation
import ZenitCLICore
import ZPDFExport
import ZPDFPersistence

// zenit — read-only command-line access to Zenit PDF projects (NL-PLAT-13).
//
//   zenit totals  <Project.zpdfproj> [--json] [--allow-unverified]
//   zenit export  <Project.zpdfproj> --format csv|xlsx|json --output <file> [--allow-unverified]
//   zenit info    <Project.zpdfproj> [--allow-unverified]
//   zenit verify  <Project.zpdfproj>
//
// Every command opens the package read-only; nothing in it is ever written. Exit codes: 0 done,
// 1 the project could not be read, or fails verification (U-101), 2 usage. `totals`, `export`
// and `info` refuse a project `verify` fails unless `--allow-unverified` is given, and then
// name its problems on standard error.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: zenit totals <Project.zpdfproj> [--json] [--allow-unverified]
           zenit export <Project.zpdfproj> --format csv|xlsx|json --output <file> [--allow-unverified]
           zenit info   <Project.zpdfproj> [--allow-unverified]
           zenit verify <Project.zpdfproj>

    """.utf8))
    exit(2)
}

/// Says, on standard error, that the numbers about to be reported come from a project that fails
/// verification — only ever reached under `--allow-unverified`.
func warnUnverified(_ loaded: ProjectReader.Loaded, _ project: URL) {
    guard !loaded.verificationProblems.isEmpty else { return }
    FileHandle.standardError.write(Data((
        ["zenit: warning: \(project.lastPathComponent) fails verification; reporting it because of --allow-unverified"]
            + loaded.verificationProblems.map { "  \($0)" }
    ).joined(separator: "\n").appending("\n").utf8))
}

func option(_ name: String, _ arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("zenit: \(String(describing: error))\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { usage() }
let command = arguments[0]
let project = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let reader = ProjectReader(url: project, allowUnverified: arguments.contains("--allow-unverified"))

do {
    switch command {
    case "verify":
        let verification = try await ProjectReader.verify(project)
        guard verification.isSound else {
            // R-188: a project the application would refuse is not "ok".
            FileHandle.standardError.write(Data((
                ["zenit: \(project.lastPathComponent) fails verification"] + verification.problems.map { "  \($0)" }
            ).joined(separator: "\n").appending("\n").utf8))
            exit(1)
        }
        if verification.closedCleanly {
            print("ok: \(project.lastPathComponent) opens cleanly (integrity checked)")
        } else {
            print("ok: \(project.lastPathComponent) opens; the last session did not close cleanly")
        }
    case "info":
        let loaded = try await reader.load()
        warnUnverified(loaded, project)
        print("project: \(loaded.projectName)")
        print("drawings: \(loaded.drawingCount)")
        print("pages: \(loaded.pageCount)")
        print("markups: \(loaded.markupCount)" + (loaded.unreadableMarkupCount > 0 ? " (\(loaded.unreadableMarkupCount) unreadable by this build)" : ""))
        print("scales: \(loaded.scaleCount)")
    case "totals":
        let loaded = try await reader.load()
        warnUnverified(loaded, project)
        let totals = ProjectReader.totals(try await ProjectReader.projection(loaded))
        if arguments.contains("--json") {
            let objects = totals.map { ["column": $0.title, "text": $0.text, "value": $0.value, "unit": $0.unit, "function": $0.function] }
            let data = try JSONSerialization.data(withJSONObject: ["project": loaded.projectName, "totals": objects], options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            for total in totals { print("\(total.function) of \(total.title): \(total.text)") }
        }
    case "export":
        guard let format = option("--format", arguments), let output = option("--output", arguments) else { usage() }
        let loaded = try await reader.load()
        warnUnverified(loaded, project)
        let projection = try await ProjectReader.projection(loaded)
        let destination = URL(fileURLWithPath: output)
        switch format {
        case "csv": try CSVExporter().export(projection, to: destination)
        case "xlsx": try XLSXExporter().export(projection, to: destination)
        case "json": try ZenitJSONExporter().export(projection).write(to: destination, options: .atomic)
        default: usage()
        }
        print("wrote \(destination.path)")
    default:
        usage()
    }
} catch {
    fail(error)
}
