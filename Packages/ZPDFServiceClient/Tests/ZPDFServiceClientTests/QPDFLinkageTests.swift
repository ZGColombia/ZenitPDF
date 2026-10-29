import Foundation
import Testing

/// Finding S17-03: qpdf's C++ parser was statically linked into the application
/// binary — 510 `QPDF` symbols, identical to the service's — because
/// `ZPDFRepairServiceClient`'s `.inProcess` fallback called `ZPDFQPDF` directly.
///
/// The fix is a link-time one, so the test has to be a link-time one. Reading the
/// source and finding no `import ZPDFQPDF` proves nothing: a transitive dependency
/// would put the archive back without changing a line of Swift. This scans the
/// object files the build actually emitted.
///
/// Scope, and why it is the right scope: `Zenit PDF.app` links exactly two products
/// out of this package, `ZPDFServiceClient` and `ZPDFServiceWire` (see
/// `Apps/ZenitPDF/Package.swift`). If neither of those targets' objects names a qpdf
/// symbol, the linker has nothing to resolve and pulls no qpdf archive into the
/// application. `ZPDFRepairServiceCore` — which the two service executables and this
/// test bundle link, and the application does not — is expected to be full of them,
/// and is checked for that, so a scan that found nothing anywhere would fail here
/// rather than pass quietly.
struct QPDFLinkageTests {

    /// Two spellings, because a Swift target reaches qpdf through the `ZPDFQPDF`
    /// wrapper and only the wrapper's own objects carry the Itanium-mangled C++
    /// names. `8ZPDFQPDF` is the Swift module in a mangled symbol; `_ZN4QPDF` and
    /// `QPDFObjectHandle` are the C++ classes themselves. Either one appearing in a
    /// target the application links is the finding coming back.
    static let qpdfSymbols = "_ZN4QPDF|QPDFObjectHandle|_ZN9QPDFWriter|ZPDFQPDF"

    @Test("No target the application links names a qpdf symbol; the service's target is full of them")
    func applicationSideTargetsCarryNoQPDF() throws {
        let layout = try Self.objectLayout()

        let appLinked = ["ZPDFServiceClient", "ZPDFServiceWire"]
        var scannedTotal = 0
        for target in appLinked {
            let (symbols, hits) = try Self.scan(target: target, in: layout)
            scannedTotal += symbols
            #expect(symbols > 200, "\(target): only \(symbols) symbols read — the scan did not run")
            #expect(hits == 0, "\(target) names \(hits) qpdf symbols; it must name none")
            print("S17-03 symbol scan: \(target) — \(symbols) symbols, \(hits) matching /\(Self.qpdfSymbols)/")
        }

        // The positive control. Without it, a scan that silently looked at the
        // wrong directory would report a clean application and prove nothing.
        let (serviceSymbols, serviceHits) = try Self.scan(target: "ZPDFRepairServiceCore", in: layout)
        #expect(serviceSymbols > 200)
        #expect(serviceSymbols > 0)
        #expect(serviceHits > 0,
                "ZPDFRepairServiceCore must still reach qpdf — if it does not, this scan is looking at nothing")
        print("S17-03 symbol scan: ZPDFRepairServiceCore — \(serviceSymbols) symbols, "
            + "\(serviceHits) matching /\(Self.qpdfSymbols)/ (expected: the service is where qpdf belongs)")
        #expect(scannedTotal > 400)
    }

    // MARK: - Support

    /// Where this test bundle's build keeps its object files, for either SwiftPM
    /// build system.
    ///
    /// - native: `.build/<triple>/debug/<Target>.build/*.o`, next to the bundle.
    /// - Swift Build (the toolchain default since Xcode 26): the bundle is under
    ///   `.build/out/Products/Debug` and the objects under
    ///   `.build/out/Intermediates.noindex/<Package>.build/Debug/<Target>-t.build/
    ///   Objects-normal/<arch>/*.o`.
    ///
    /// The scan originally knew only the first layout and, under Swift Build,
    /// failed with "could not find a directory containing ZPDFServiceClient.build"
    /// before reading a single symbol.
    enum ObjectLayout {
        case native(URL)
        case swiftBuild(intermediates: URL)
    }

    static func objectLayout() throws -> ObjectLayout {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else {
            throw CocoaError(.fileNoSuchFile)
        }
        var directory = URL(fileURLWithPath: String(cString: name))
            .deletingLastPathComponent().standardizedFileURL
        for _ in 0..<6 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("ZPDFServiceClient.build").path) {
                return .native(directory)
            }
            let intermediates = directory.appendingPathComponent("Intermediates.noindex")
            if FileManager.default.fileExists(atPath: intermediates.path) {
                return .swiftBuild(intermediates: intermediates)
            }
            directory.deleteLastPathComponent()
        }
        Issue.record("could not find a directory containing ZPDFServiceClient.build or Intermediates.noindex")
        throw CocoaError(.fileNoSuchFile)
    }

    /// The object files the build emitted for `target`.
    static func objectFiles(target: String, in layout: ObjectLayout) throws -> [String] {
        switch layout {
        case .native(let binDirectory):
            let objects = binDirectory.appendingPathComponent("\(target).build")
            try #require(FileManager.default.fileExists(atPath: objects.path),
                         "\(target).build is not present at \(objects.path)")
            return (try FileManager.default.contentsOfDirectory(atPath: objects.path))
                .filter { $0.hasSuffix(".o") }
                .map { objects.appendingPathComponent($0).path }
        case .swiftBuild(let intermediates):
            let wanted: Set<String> = ["\(target)-t.build", "\(target).build"]
            var files: [String] = []
            guard let walker = FileManager.default.enumerator(
                at: intermediates, includingPropertiesForKeys: nil) else { return [] }
            for case let url as URL in walker where url.pathExtension == "o" {
                let components = url.pathComponents
                guard let index = components.lastIndex(of: "Objects-normal"), index > 0,
                      wanted.contains(components[index - 1]) else { continue }
                files.append(url.path)
            }
            return files
        }
    }

    static func scan(target: String, in layout: ObjectLayout) throws -> (symbols: Int, hits: Int) {
        let files = try objectFiles(target: target, in: layout)
        try #require(!files.isEmpty, "no object files found for \(target)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-o"] + files
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let pattern = try NSRegularExpression(pattern: qpdfSymbols)
        var hits = 0
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if pattern.firstMatch(in: String(line), range: range) != nil { hits += 1 }
        }
        return (lines.count, hits)
    }
}
