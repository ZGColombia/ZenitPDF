import CryptoKit
import Foundation
import PDFKit
import Testing
import ZPDFQPDF
import ZPDFTestingSupport

/// A throwaway directory that removes itself. Every test gets its own, so the
/// "refuse to overwrite an existing output" rule never trips on a leftover.
final class Sandbox {
    let url: URL

    init(_ label: String = #function) throws {
        let safe = label.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "_")
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-qpdf-\(safe)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Writes a fixture into the sandbox and returns its URL.
    func fixture(_ kind: FixtureKind) throws -> URL {
        try ZPDFFixtures.make(kind, in: url).url
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

enum Hashing {
    /// SHA-256 of a file, used to prove an input was not mutated.
    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// An independent reader. PDFKit sits on CoreGraphics' PDF parser, which shares
/// no code with qpdf, so "PDFKit opens it and reports N pages" is real evidence
/// that a repair produced a usable file rather than a self-consistent lie.
enum IndependentReader {
    static func pageCount(of url: URL) -> Int? {
        guard let document = PDFDocument(url: url) else { return nil }
        return document.pageCount
    }

    static func opens(_ url: URL) -> Bool {
        pageCount(of: url) != nil
    }

    /// Media boxes of every page, the independent reference for "nothing moved".
    static func mediaBoxes(of url: URL) -> [CGRect]? {
        guard let document = PDFDocument(url: url) else { return nil }
        return (0..<document.pageCount).compactMap { index in
            document.page(at: index)?.bounds(for: .mediaBox)
        }
    }
}

/// Wall-clock timing, printed so the numbers in the report are measured rather
/// than asserted into existence.
@discardableResult
func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try body()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    print(String(format: "[timing] %@: %.2f ms", label, elapsed))
    return value
}

extension QPDFError {
    /// A short tag used in fuzz output, so a failure names the case that fired.
    var tag: String {
        switch self {
        case .invalidArgument: "invalidArgument"
        case .outputConflict: "outputConflict"
        case .cannotRead: "cannotRead"
        case .passwordRequired: "passwordRequired"
        case .passwordIncorrect: "passwordIncorrect"
        case .damaged: "damaged"
        case .writeFailed: "writeFailed"
        case .unsupported: "unsupported"
        case .cancelled: "cancelled"
        case .limitExceeded: "limitExceeded"
        case .outOfMemory: "outOfMemory"
        case .internalFailure: "internalFailure"
        case .pageRangeInvalid: "pageRangeInvalid"
        case .unknownStatus(let code, _): "unknownStatus(\(code))"
        case .splitIncomplete: "splitIncomplete"
        }
    }
}

/// Asserts that `body` fails with a specific ``QPDFError`` case, named by its
/// tag. Swift Testing's `#expect(throws:)` cannot take an enum case with an
/// associated value as a value, and matching on the case alone is exactly what
/// these tests want.
func expectQPDFError(
    _ tag: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record("expected QPDFError.\(tag) but the call succeeded", sourceLocation: sourceLocation)
    } catch let error as QPDFError {
        #expect(error.tag == tag, "expected \(tag), got \(error)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected QPDFError.\(tag) but got \(error)", sourceLocation: sourceLocation)
    }
}

/// A one-shot gate, used to order a `Task`'s work strictly after `cancel()`.
actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
