import CoreGraphics
import Foundation
import ZPDFExport

/// zpdf-redaction-probe — Apply Redactions' file writes, as a process a test can sandbox (C-09).
///
///     zpdf-redaction-probe folder <folder> [--sharp] [--box x,y,w,h] <drawing.pdf> ...
///         one redacted copy of each drawing inside <folder>, through RedactionCopySet.write —
///         the writer Apply uses for several marked drawings, after a folder chooser
///     zpdf-redaction-probe file <output.pdf> [--sharp] [--box x,y,w,h] <drawing.pdf>
///         one redacted copy at <output.pdf>, as Apply writes one marked drawing after a save panel
///
/// Each drawing is marked with one box on its first sheet (default 60,180,300,40). `--sharp`
/// redacts through a VectorRedactionSession (assess, then redact: Keep Sharp's path); otherwise
/// RasterRedactor. Prints each file written; exits 1 with the error on standard error.
@main
enum RedactionProbe {

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func redact(_ drawing: URL, marks: [RedactionMark], sharp: Bool, to output: URL) async throws -> RedactionOutcome {
        guard sharp else { return try RasterRedactor.redact(source: drawing, marks: marks, to: output) }
        let session = VectorRedactionSession()
        _ = await session.assess(source: drawing, marks: marks)
        return try await session.redact(source: drawing, marks: marks, to: output)
    }

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 3 else {
            fail("usage: zpdf-redaction-probe folder|file <destination> [--sharp] [--box x,y,w,h] <drawing.pdf> ...")
        }
        let mode = arguments.removeFirst()
        let destination = URL(fileURLWithPath: arguments.removeFirst())
        var sharp = false
        var box = CGRect(x: 60, y: 180, width: 300, height: 40)
        var drawings: [URL] = []
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            switch argument {
            case "--sharp": sharp = true
            case "--box":
                let parts = (arguments.isEmpty ? "" : arguments.removeFirst()).split(separator: ",").compactMap { Double($0) }
                guard parts.count == 4 else { fail("--box needs x,y,w,h") }
                box = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            default: drawings.append(URL(fileURLWithPath: argument))
            }
        }
        let marks = [RedactionMark(pageIndex: 0, rect: box)]
        let keepSharp = sharp
        let sources = drawings
        do {
            switch mode {
            case "folder":
                let written = try await RedactionCopySet.write(
                    names: sources.map { $0.deletingPathExtension().lastPathComponent },
                    into: destination, protecting: sources
                ) { index, staged in
                    try await redact(sources[index], marks: marks, sharp: keepSharp, to: staged)
                }
                for copy in written { print(copy.output.path) }
            case "file":
                guard sources.count == 1 else { fail("file mode takes one drawing") }
                _ = try await redact(sources[0], marks: marks, sharp: keepSharp, to: destination)
                print(destination.path)
            default:
                fail("unknown mode \(mode)")
            }
        } catch {
            fail("\(error)")
        }
    }
}
