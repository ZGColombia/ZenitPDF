import Foundation
import Testing
import ZPDFSpreadsheet
@testable import ZPDFExtensions

/// NL-PLAT-23 phase 1: a pack is data only, read under limits, refused whole when anything in it
/// is not a data file.
@Suite("Declarative packs (.zpdfpack)")
struct ZenitPackTests {

    private let tools = Data(#"{"schemaVersion":1,"presets":[]}"#.utf8)
    private let template = Data(#"{"formatVersion":1}"#.utf8)
    private let profile = Data(#"{"format":"zenit-export-profile"}"#.utf8)

    private func manifest(_ items: [ZenitPack.Manifest.Item]) -> ZenitPack.Manifest {
        ZenitPack.Manifest(name: "Office", version: "2", author: "Estimating", summary: "House standards", items: items)
    }

    @Test("A pack written here reads back: manifest, kinds, bytes")
    func roundTrip() throws {
        let items = [
            ZenitPack.Manifest.Item(path: "tools/Office.zpdftools", kind: .toolSet),
            ZenitPack.Manifest.Item(path: "templates/Flooring.zpdftemplate", kind: .jobTemplate),
            ZenitPack.Manifest.Item(path: "profiles/Estimating.zpdfprofile", kind: .exportProfile),
        ]
        let data = try ZenitPack.write(manifest: manifest(items), files: [
            "tools/Office.zpdftools": tools, "templates/Flooring.zpdftemplate": template, "profiles/Estimating.zpdfprofile": profile,
        ])
        let pack = try ZenitPack.read(data)
        #expect(pack.manifest.name == "Office")
        #expect(pack.manifest.version == "2")
        #expect(pack.items.map(\.kind) == [.toolSet, .jobTemplate, .exportProfile])
        #expect(pack.items(of: .toolSet).first?.data == tools)
        #expect(pack.items(of: .exportProfile).first?.fileName == "Estimating.zpdfprofile")
        // The same entries always make the same bytes.
        let again = try ZenitPack.write(manifest: manifest(items), files: [
            "tools/Office.zpdftools": tools, "templates/Flooring.zpdftemplate": template, "profiles/Estimating.zpdfprofile": profile,
        ])
        #expect(again == data)
    }

    @Test("A script inside the pack refuses the whole pack, even when the manifest does not list it")
    func scriptRefused() throws {
        var writer = ZipStoredWriter()
        let encoder = JSONEncoder()
        try writer.add("pack.json", data: encoder.encode(manifest([.init(path: "tools/Office.zpdftools", kind: .toolSet)])))
        try writer.add("tools/Office.zpdftools", data: tools)
        try writer.add("install.sh", data: Data("#!/bin/sh\nrm -rf ~\n".utf8))
        #expect(throws: ZenitPack.ReadError.notADataFile("install.sh")) { try ZenitPack.read(try writer.archive()) }
    }

    @Test("A listed path outside the pack, a mislabelled kind, a missing or unlisted file: each refused by name")
    func refusals() throws {
        func pack(_ items: [ZenitPack.Manifest.Item], files: [(String, Data)]) throws -> Data {
            var writer = ZipStoredWriter()
            try writer.add("pack.json", data: JSONEncoder().encode(manifest(items)))
            for (name, data) in files { try writer.add(name, data: data) }
            return try writer.archive()
        }
        #expect(throws: ZenitPack.ReadError.unsafePath("../Office.zpdftools")) {
            try ZenitPack.read(try pack([.init(path: "../Office.zpdftools", kind: .toolSet)], files: [("tools/a.zpdftools", tools)]))
        }
        #expect(throws: ZenitPack.ReadError.kindMismatch(path: "tools/a.zpdftools", declared: .jobTemplate)) {
            try ZenitPack.read(try pack([.init(path: "tools/a.zpdftools", kind: .jobTemplate)], files: [("tools/a.zpdftools", tools)]))
        }
        #expect(throws: ZenitPack.ReadError.missing("tools/b.zpdftools")) {
            try ZenitPack.read(try pack([.init(path: "tools/b.zpdftools", kind: .toolSet)], files: [("tools/a.zpdftools", tools)]))
        }
        #expect(throws: ZenitPack.ReadError.unlisted("tools/b.zpdftools")) {
            try ZenitPack.read(try pack([.init(path: "tools/a.zpdftools", kind: .toolSet)],
                                        files: [("tools/a.zpdftools", tools), ("tools/b.zpdftools", tools)]))
        }
        #expect(throws: ZenitPack.ReadError.emptyPack) { try ZenitPack.read(try pack([], files: [])) }
    }

    @Test("Not a zip, no manifest, a foreign format, a newer format: refused with a sentence")
    func containerRefusals() throws {
        #expect(throws: ZenitPack.ReadError.container(.notAZip)) { try ZenitPack.read(Data("hello".utf8)) }
        var writer = ZipStoredWriter()
        try writer.add("tools/a.zpdftools", data: tools)
        #expect(throws: ZenitPack.ReadError.noManifest) { try ZenitPack.read(try writer.archive()) }

        var foreign = manifest([.init(path: "tools/a.zpdftools", kind: .toolSet)])
        foreign.format = "something-else"
        var writer2 = ZipStoredWriter()
        try writer2.add("pack.json", data: JSONEncoder().encode(foreign))
        try writer2.add("tools/a.zpdftools", data: tools)
        #expect(throws: ZenitPack.ReadError.notAPack(format: "something-else")) { try ZenitPack.read(try writer2.archive()) }

        var newer = manifest([.init(path: "tools/a.zpdftools", kind: .toolSet)])
        newer.formatVersion = 9
        var writer3 = ZipStoredWriter()
        try writer3.add("pack.json", data: JSONEncoder().encode(newer))
        try writer3.add("tools/a.zpdftools", data: tools)
        let error = #expect(throws: ZenitPack.ReadError.self) { try ZenitPack.read(try writer3.archive()) }
        #expect(error?.description.contains("newer Zenit PDF") == true)
    }

    @Test("Suggested paths never escape their folder")
    func suggestedPaths() {
        #expect(ZenitPack.suggestedPath(kind: .toolSet, name: "Office") == "tools/Office.zpdftools")
        #expect(ZenitPack.suggestedPath(kind: .jobTemplate, name: "../evil") == "templates/..-evil.zpdftemplate")
        #expect(ZenitPack.suggestedPath(kind: .exportProfile, name: "..") == "profiles/Untitled.zpdfprofile")
        #expect(ZipStoredWriter.isSafeEntryName(ZenitPack.suggestedPath(kind: .jobTemplate, name: "a/b\\c")))
    }
}
