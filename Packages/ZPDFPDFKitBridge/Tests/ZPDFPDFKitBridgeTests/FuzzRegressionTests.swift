import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFPDFKitBridge

/// Regression cover for the defects byte-level mutation fuzzing found in this package,
/// plus the seeded fuzz loop itself.
///
/// The rule `QUALITY_BAR.md` 2.4 sets for property-test failures applies to fuzz failures
/// too: each is minimised and promoted to a permanent named regression fixture in the same
/// commit as the fix. The two
/// minimised fixtures are built here in code rather than checked in as binaries, so what
/// makes them hostile is readable.
@Suite("Fuzz regressions")
struct FuzzRegressionTests {

    // MARK: - The minimised fixture

    /// A 433-byte, otherwise valid one-page PDF whose `/Info` dictionary carries a name
    /// key made of bytes that are not valid UTF-8.
    ///
    /// CoreGraphics reports that key when enumerating; PDFKit's `documentAttributes`
    /// cannot map it to an `NSString`, and inserts `nil` into an `NSMutableDictionary`,
    /// which raises `NSInvalidArgumentException`. An Objective-C exception cannot be
    /// caught in Swift, so before the fix this file terminated any process that opened
    /// it. Minimised from fuzz seed 372734462224352 over the `.rectangle` fixture.
    static func infoWithUnmappableKey() -> Data {
        let objects: [[UInt8]] = [
            Array("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Array("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Array("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << >> >>".utf8),
            Array("<< /Producer (Zenit) /".utf8) + [UInt8](repeating: 0xED, count: 6) + Array(" (value) >>".utf8)
        ]
        var bytes = Array("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes += Array("\(index + 1) 0 obj\n".utf8) + body + Array("\nendobj\n".utf8)
        }
        let xref = bytes.count
        bytes += Array("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for offset in offsets {
            bytes += Array(String(format: "%010d 00000 n \n", offset).utf8)
        }
        bytes += Array("""
            trailer
            << /Size \(objects.count + 1) /Root 1 0 R /Info 4 0 R >>
            startxref
            \(xref)
            %%EOF

            """.utf8)
        return Data(bytes)
    }

    @Test("An /Info key PDFKit cannot map does not kill the process")
    func unmappableInfoKeyOpens() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(.data(Self.infoWithUnmappableKey()), password: nil, limits: .standard)
        #expect(opened.descriptor.pageCount == 1)
        // The readable half of `/Info` still comes back: the CoreGraphics reader skips the
        // key it cannot use instead of giving up on the dictionary.
        #expect(opened.descriptor.attributes.producer == "Zenit")
        #expect(opened.descriptor.attributes.title == nil)
        await provider.close(opened.handle)
    }

    @Test("Every content path on that document returns rather than raising")
    func unmappableInfoKeyContentPaths() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(.data(Self.infoWithUnmappableKey()), password: nil, limits: .standard)
        // Each of these reaches `-[PDFPage _buildPageLayout]`, which is where PDFKit
        // calls `documentAttributes` internally. Fuzz seed 578343136699809 found this
        // second, deeper route through `characterBounds(at:)`.
        _ = try await provider.pageText(of: opened.handle, pageIndex: 0)
        _ = try await provider.characterBoxes(of: opened.handle, pageIndex: 0, range: nil)
        _ = try await provider.annotations(of: opened.handle, pageIndex: 0)
        _ = try await provider.outline(of: opened.handle)
        _ = try await provider.pageLabels(of: opened.handle)
        _ = try await provider.namedDestinations(of: opened.handle)
        _ = try await provider.search(in: opened.handle, query: "a")
        _ = try? await provider.selection(of: opened.handle, pageIndex: 0, from: .zero, to: CGPoint(x: 200, y: 200))
        await provider.close(opened.handle)
    }

    // MARK: - The barrier itself

    @Test("The barrier turns a raised NSException into a typed error")
    func barrierConvertsRaise() throws {
        #expect(throws: PDFBridgeError.self) {
            try EngineBarrier.guarded("unit") { () -> Int in
                NSException(name: .invalidArgumentException, reason: "deliberate", userInfo: nil).raise()
                return 0
            }
        }
        do {
            _ = try EngineBarrier.guarded("unit") { () -> Int in
                NSException(name: .invalidArgumentException, reason: "deliberate", userInfo: nil).raise()
                return 0
            }
            Issue.record("the barrier let a raise through")
        } catch let error as PDFBridgeError {
            guard case let .engineRaised(operation, name, reason) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(operation == "unit")
            #expect(name == NSExceptionName.invalidArgumentException.rawValue)
            #expect(reason == "deliberate")
        }
    }

    @Test("The barrier passes a value straight through and rethrows a Swift error unchanged")
    func barrierIsTransparent() throws {
        #expect(try EngineBarrier.guarded("unit") { 41 + 1 } == 42)
        #expect(throws: PDFBridgeError.cancelled) {
            try EngineBarrier.guarded("unit") { () -> Int in throw PDFBridgeError.cancelled }
        }
    }

    // MARK: - The seeded fuzz loop

    /// Byte-level mutation of the corpus, fed to document opening and the annotation
    /// reader. Fixed seed, so a failure is reproducible from the reported iteration.
    ///
    /// The assertion is not on the result — a mutated PDF may legitimately open, or be
    /// refused — but on the *manner*: every outcome is either a value or a
    /// ``PDFBridgeError``, and the process is still alive at the end.
    @Test("500 mutated documents open or fail typed, and never crash or hang", .timeLimit(.minutes(5)))
    func fuzzDocumentOpening() async throws {
        var opened = 0
        var rejected = 0
        for iteration in 0..<500 {
            let seed = FuzzCorpus.seed(base: 20260823, iteration: iteration)
            var generator = SplitMix64(seed: seed)
            let base = FuzzCorpus.pick(&generator)
            let mutated = FuzzCorpus.mutate(base, generator: &generator, preserveLength: iteration % 2 == 0)

            let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 4)
            do {
                let document = try await provider.open(.data(mutated), password: nil, limits: .standard)
                opened += 1
                _ = try? await provider.pageDescriptors(of: document.handle, range: 0..<1)
                _ = try? await provider.pageLabels(of: document.handle)
                _ = try? await provider.outline(of: document.handle)
                _ = try? await provider.namedDestinations(of: document.handle)
                _ = try? await provider.allAnnotations(of: document.handle)
                _ = try? await provider.pageText(of: document.handle, pageIndex: 0)
                _ = try? await provider.characterBoxes(of: document.handle, pageIndex: 0, range: nil)
                await provider.close(document.handle)
            } catch is PDFBridgeError {
                rejected += 1
            } catch {
                Issue.record("iteration \(iteration) seed \(seed) produced an untyped error: \(error)")
            }
            await provider.closeAll()
        }
        // Both outcomes must actually occur, or the loop is not exercising anything.
        #expect(opened > 0, "no mutated document opened — the mutator is too destructive")
        #expect(rejected > 0, "no mutated document was refused — the parser is too permissive")
    }
}
