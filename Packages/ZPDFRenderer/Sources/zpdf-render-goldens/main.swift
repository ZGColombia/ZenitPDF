import Foundation
import ZPDFRenderer
import ZPDFRendererScenario

// zpdf-render-goldens — the regeneration script for the golden PNGs.
//
//   swift run zpdf-render-goldens                 verify: render every scene, check it against
//                                                 the oracle AND against its stored PNG; write nothing
//   swift run zpdf-render-goldens --write         re-verify and rewrite them
//   swift run zpdf-render-goldens --write --force rewrite even a scene that fails provenance
//   swift run zpdf-render-goldens --only a,b      restrict to the named scenes
//   swift run zpdf-render-goldens --out <dir>     write somewhere else
//
// A golden is only written after the scene has been checked against `ReferenceRasterizer`, the
// independent coverage oracle. That is the answer to "how do you know the first generation was
// correct": it was not taken on trust from the renderer, it was checked against a rasteriser that
// shares no code with it and was written from the specification. The scenes the oracle cannot
// judge — the ones whose ink is count symbols or text, which both backends take from the same
// atlas — are listed as such and are covered by the closed-form ink assertions in
// `GoldenProvenanceTests` instead.

/// The command line, parsed strictly. A flag that needs a value and has none, or a value that
/// is itself a flag, is a usage error — never a silent fallback. `--write --out` with the path
/// forgotten used to ignore `--out` and overwrite the committed goldens, and `--out --write`
/// took the literal "--write" as the directory (BH-642).
struct Options {
    var shouldWrite = false
    var force = false
    var outputDirectory: URL?
    var only: Set<String>?
}

func usage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("zpdf-render-goldens: \(message)\n".utf8))
    FileHandle.standardError.write(Data(
        "usage: zpdf-render-goldens [--write [--force]] [--only a,b] [--out <dir>]\n".utf8
    ))
    exit(2)
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 1
    func value(for flag: String) -> String {
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            usage("\(flag) needs a value")
        }
        index += 1
        return arguments[index]
    }
    while index < arguments.count {
        switch arguments[index] {
        case "--write": options.shouldWrite = true
        case "--force": options.force = true
        case "--out": options.outputDirectory = URL(fileURLWithPath: value(for: "--out"))
        case "--only":
            options.only = Set(value(for: "--only").split(separator: ",").map(String.init))
        default: usage("unknown argument \(arguments[index])")
        }
        index += 1
    }
    if options.force && !options.shouldWrite { usage("--force only makes sense with --write") }
    return options
}

let options = parse(CommandLine.arguments)
let shouldWrite = options.shouldWrite
let force = options.force

func defaultGoldensDirectory() -> URL {
    // Sources/zpdf-render-goldens/main.swift -> Tests/ZPDFRendererGoldenTests/Goldens
    let thisFile = URL(fileURLWithPath: #filePath)
    let packageRoot = thisFile
        .deletingLastPathComponent()   // zpdf-render-goldens
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // ZPDFRenderer
    return packageRoot
        .appendingPathComponent("Tests")
        .appendingPathComponent("ZPDFRendererGoldenTests")
        .appendingPathComponent("Goldens")
}

let outputDirectory = options.outputDirectory ?? defaultGoldensDirectory()
let scenes = SceneLibrary.goldens.filter { options.only?.contains($0.name) ?? true }
if let only = options.only {
    let unknown = only.subtracting(SceneLibrary.goldens.map(\.name))
    if !unknown.isEmpty { usage("no such scene: \(unknown.sorted().joined(separator: ", "))") }
}

try? FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

print("zpdf-render-goldens")
print("  output: \(outputDirectory.path)")
print("  mode:   \(shouldWrite ? (force ? "write (forced)" : "write") : "verify only")")
print("")

var failures = 0
var written = 0

for scene in scenes {
    let renderer = CoreGraphicsMarkupRenderer()
    defer { renderer.dispose() }

    let image: RasterImage
    do {
        image = try scene.render(with: renderer)
    } catch {
        print("FAIL \(scene.name): rendering failed — \(error)")
        failures += 1
        continue
    }

    var provenance = "not verifiable by the coverage oracle (symbol or text ink)"
    var provenanceOK = true
    if ReferenceRasterizer.verifiableScenes.contains(scene.name) {
        let reference = ReferenceRasterizer.rasterize(scene)
        let result = GoldenProvenance.compare(image: image, reference: reference)
        provenance = result.summary
        provenanceOK = result.matches
    }

    let status = provenanceOK ? "ok  " : "FAIL"
    print("\(status) \(scene.name)  \(image.width)x\(image.height)")
    print("       purpose:    \(scene.purpose)")
    print("       provenance: \(provenance)")

    if !provenanceOK { failures += 1 }

    // The stored PNG itself, which the verify mode used to render around without ever opening:
    // after a renderer change every scene printed "ok" while the committed goldens were stale
    // (BH-643). Compared with the same comparator the test suite uses.
    let storedURL = outputDirectory.appendingPathComponent("\(scene.name).png")
    if let data = try? Data(contentsOf: storedURL), let stored = RasterImage.fromPNG(data) {
        let result = ImageComparator.compare(image, stored)
        print("       stored:     \(result.matches ? "matches" : "STALE — \(result.summary)")")
        if !result.matches && !shouldWrite { failures += 1 }
    } else {
        print("       stored:     MISSING")
        if !shouldWrite { failures += 1 }
    }

    if shouldWrite, provenanceOK || force {
        guard let data = image.pngData() else {
            print("       write:      FAILED to encode PNG")
            failures += 1
            continue
        }
        let url = outputDirectory.appendingPathComponent("\(scene.name).png")
        do {
            try data.write(to: url, options: .atomic)
            written += 1
            print("       write:      \(data.count) bytes")
        } catch {
            print("       write:      FAILED — \(error)")
            failures += 1
        }
    }
    print("")
}

print("scenes: \(scenes.count), written: \(written), failures: \(failures)")
if failures > 0 {
    exit(1)
}
