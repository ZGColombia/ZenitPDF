import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFSnapEngine
import ZPDFTestingSupport
import ZPDFUIPresentation
import ZPDFVectorExtraction

/// NL-AUTO-25: precision and recall per detector over a labelled corpus, gated by
/// `Docs/Execution/quality-thresholds.json` → `automation`.
///
/// The synthetic corpus (`AutomationSyntheticCorpus`, in git) always runs. A local corpus of
/// real drawings runs when `ZENIT_AUTOMATION_CORPUS` names its manifest; it stays outside git.
/// `Scripts/automation-benchmark.sh` runs this suite and prints the table.
@Suite("Automation benchmark (NL-AUTO-25)")
struct AutomationBenchmarkTests {

    /// Counts for one detector.
    struct Score: CustomStringConvertible {
        var truePositives = 0
        var falsePositives = 0
        var falseNegatives = 0

        var precision: Double {
            let found = truePositives + falsePositives
            return found == 0 ? 1 : Double(truePositives) / Double(found)
        }
        var recall: Double {
            let labelled = truePositives + falseNegatives
            return labelled == 0 ? 1 : Double(truePositives) / Double(labelled)
        }
        var description: String {
            String(format: "precision %.3f recall %.3f (tp %d fp %d fn %d)", precision, recall,
                   truePositives, falsePositives, falseNegatives)
        }
        static func + (a: Score, b: Score) -> Score {
            Score(
                truePositives: a.truePositives + b.truePositives,
                falsePositives: a.falsePositives + b.falsePositives,
                falseNegatives: a.falseNegatives + b.falseNegatives
            )
        }
    }

    struct Gate: Decodable {
        let precision: Double
        let recall: Double
    }

    /// The four gates, read from the threshold file rather than written here.
    static func gates() throws -> [String: Gate] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Docs/Execution/quality-thresholds.json")
        struct File: Decodable {
            struct Automation: Decodable {
                let symbols: Gate
                let rooms: Gate
                let sheetNames: Gate
                let scales: Gate
            }
            let automation: Automation
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return [
            "symbols": file.automation.symbols, "rooms": file.automation.rooms,
            "sheetNames": file.automation.sheetNames, "scales": file.automation.scales
        ]
    }

    // MARK: - Detectors

    static func symbolScore(_ label: AutomationSymbolLabel, primitives: [VectorPrimitive]) -> Score {
        let box = label.exemplarBox
        guard let exemplar = try? SymbolExemplar(
            primitives: primitives,
            region: VectorBounds(minX: box.x, minY: box.y, maxX: box.x + box.width, maxY: box.y + box.height)
        ), let report = try? SymbolMatcher().matches(exemplar: exemplar, in: primitives) else {
            return Score(falseNegatives: label.instances.count)
        }
        var unmatched = label.instances
        var score = Score()
        for found in report.confirmed {
            if let index = unmatched.firstIndex(where: {
                hypot($0.x - found.position.x, $0.y - found.position.y) <= label.matchRadius
            }) {
                unmatched.remove(at: index)
                score.truePositives += 1
            } else {
                score.falsePositives += 1
            }
        }
        score.falseNegatives = unmatched.count
        return score
    }

    /// Area agreement for a room: QUALITY_BAR's 0.10 %.
    static let roomAreaTolerance = 0.001
    /// An uncalibrated sheet's closure cap, as the canvas uses it.
    static let closureCap = 72.0

    static func roomScore(_ rooms: [AutomationRoomLabel], primitives: [VectorPrimitive]) -> Score {
        let prepared = RegionTracer.prepare(primitives: primitives)
        var score = Score()
        for room in rooms {
            let outcome = RegionTracer.traceProposingClosures(
                prepared, click: PDFPoint(x: room.click.x, y: room.click.y), maximumClosureWidth: closureCap
            )
            let region: TracedRegion?
            switch outcome {
            case .traced(let traced): region = traced
            case .closesOpenings(let proposal): region = proposal.region
            case .refused: region = nil
            }
            guard let region else {
                score.falseNegatives += 1
                continue
            }
            if abs(region.area - room.area) / room.area <= roomAreaTolerance {
                score.truePositives += 1
            } else {
                score.falsePositives += 1
                score.falseNegatives += 1
            }
        }
        return score
    }

    static func textScore(expected: String?, found: String?) -> Score {
        switch (expected, found) {
        case (nil, nil): return Score()
        case (nil, .some): return Score(falsePositives: 1)
        case (.some, nil): return Score(falseNegatives: 1)
        case let (.some(label), .some(value)):
            return label == value ? Score(truePositives: 1) : Score(falsePositives: 1, falseNegatives: 1)
        }
    }

    // MARK: - Running a corpus

    static func run(manifest: AutomationCorpusManifest, base: URL) async throws -> [String: Score] {
        var scores: [String: Score] = ["symbols": Score(), "rooms": Score(), "sheetNames": Score(), "scales": Score()]
        let extractor = VectorExtractor()
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        for drawing in manifest.drawings {
            let url = drawing.file.hasPrefix("/") ? URL(fileURLWithPath: drawing.file) : base.appendingPathComponent(drawing.file)
            let opened = try await provider.open(.url(url), password: nil, limits: .standard)
            let descriptors = try await provider.pageDescriptors(of: opened.handle, range: nil)
            for page in drawing.pages {
                let extraction = try await extractor.extract(documentAt: url, pageIndex: page.pageIndex)
                let primitives = extraction.primitives
                for label in page.symbols {
                    scores["symbols"] = scores["symbols"]! + symbolScore(label, primitives: primitives)
                }
                if !page.rooms.isEmpty {
                    scores["rooms"] = scores["rooms"]! + roomScore(page.rooms, primitives: primitives)
                }
                let crop = descriptors[page.pageIndex].boxes.crop
                let box = PDFRectValue(x: crop.origin.x, y: crop.origin.y, width: crop.size.width, height: crop.size.height)
                let lines = try await provider.pageTextLines(of: opened.handle, pageIndex: page.pageIndex).map {
                    RecognisedTextLine(
                        text: $0.text,
                        boundsInPageSpace: PDFRectValue(
                            x: $0.boundsInPageSpace.origin.x, y: $0.boundsInPageSpace.origin.y,
                            width: $0.boundsInPageSpace.width, height: $0.boundsInPageSpace.height
                        )
                    )
                }
                let name = TitleBlockReader().readAutomatically(pageIndex: page.pageIndex, pageBox: box, lines: lines)
                scores["sheetNames"] = scores["sheetNames"]! + textScore(expected: page.sheetNumber, found: name.number)
                let scale = SheetScaleProposer().proposal(lines: lines, pageBox: box)
                if ProcessInfo.processInfo.environment["ZENIT_AUTOMATION_BENCHMARK_VERBOSE"] != nil {
                    print("AUTOMATION-BENCHMARK page \(drawing.file)#\(page.pageIndex): lines \(lines.map(\.text)) number \(name.number ?? "-") scale \(scale?.displayString ?? "-")")
                }
                scores["scales"] = scores["scales"]! + textScore(expected: page.scale, found: scale?.displayString)
            }
            await provider.close(opened.handle)
        }
        return scores
    }

    static func report(_ name: String, _ scores: [String: Score], gates: [String: Gate]) -> [String] {
        var failures: [String] = []
        for detector in ["symbols", "rooms", "sheetNames", "scales"] {
            let score = scores[detector]!
            let gate = gates[detector]!
            let passes = score.precision >= gate.precision && score.recall >= gate.recall
            print("AUTOMATION-BENCHMARK \(name) \(detector): \(score) gate p≥\(gate.precision) r≥\(gate.recall) \(passes ? "PASS" : "FAIL")")
            if !passes { failures.append("\(name) \(detector): \(score)") }
        }
        return failures
    }

    @Test("The synthetic corpus meets every automation gate")
    func syntheticCorpus() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-automation-corpus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try AutomationSyntheticCorpus.write(in: directory)
        let scores = try await Self.run(manifest: manifest, base: directory)
        let failures = Self.report("synthetic", scores, gates: try Self.gates())
        #expect(failures.isEmpty, "\(failures)")
        // Every detector was actually exercised: a gate over nothing proves nothing.
        for (detector, score) in scores {
            #expect(score.truePositives + score.falseNegatives > 0, "\(detector) had no labels")
        }
    }

    @Test("A local corpus, when configured, meets the same gates")
    func localCorpus() async throws {
        guard let path = ProcessInfo.processInfo.environment["ZENIT_AUTOMATION_CORPUS"], !path.isEmpty else {
            print("AUTOMATION-BENCHMARK local: not configured (set ZENIT_AUTOMATION_CORPUS to a manifest path)")
            return
        }
        let (manifest, base) = try AutomationCorpusManifest.load(from: URL(fileURLWithPath: path))
        let scores = try await Self.run(manifest: manifest, base: base)
        let failures = Self.report("local", scores, gates: try Self.gates())
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test("The manifest format round-trips through JSON")
    func manifestRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-automation-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try AutomationSyntheticCorpus.write(in: directory)
        let (loaded, base) = try AutomationCorpusManifest.load(from: directory.appendingPathComponent("automation-corpus.json"))
        #expect(loaded == manifest)
        #expect(base.standardizedFileURL == directory.standardizedFileURL)
    }
}
