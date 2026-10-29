import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIPresentation

/// The template library on disk, and the `.zpdftemplate` file: both refuse before they guess.
///
/// | Rule | Test |
/// |---|---|
/// | Templates survive a write and a fresh store's read | ``templatesSurviveSaveAndReopen()`` |
/// | A foreign file is refused by name | ``aForeignFileIsRefusedByName()`` |
/// | A future schema is refused by version | ``aFutureSchemaIsRefusedByVersion()`` |
/// | Export and import round-trip a template through its digest | ``aTemplateFileRoundTripsThroughItsDigest()`` |
/// | A tampered payload is refused by digest, naming both values | ``aTamperedPayloadIsRefusedByDigest()`` |
/// | A foreign or future `.zpdftemplate` is refused before its body | ``aForeignOrFutureTemplateFileIsRefused()`` |
@Suite("Job template persistence")
struct JobTemplateStoreTests {

    /// A fresh temporary directory per test. Never the real Application Support: the store's
    /// directory is injected, which is the whole reason it is injectable.
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-job-template-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTemplate(name: String) -> JobTemplate {
        JobTemplate(
            name: name,
            createdAt: Date(timeIntervalSince1970: 1_756_400_000),
            presets: DefaultToolSet.presets,
            subjects: JobTemplateApplier.subjects(from: DefaultToolSet.presets),
            columnPreferences: [
                JobTemplateColumnPreference(columnID: LedgerColumnID.subject.rawValue, visible: true)
            ],
            units: JobTemplateUnits(selection: .metric)
        )
    }

    // MARK: - The container store

    @Test("Templates survive a write and a fresh store's read over the same directory")
    func templatesSurviveSaveAndReopen() async throws {
        let directory = try makeTemporaryDirectory()
        let templates = [makeTemplate(name: "Groundwork"), makeTemplate(name: "Roofing")]

        let store = JobTemplateStore(directory: directory)
        try await store.write(templates)

        // A fresh actor over the same directory, as the next launch would build one.
        let reopened = JobTemplateStore(directory: directory)
        let read = try await reopened.read()
        #expect(read == templates)

        // Two writes of one library are byte-identical — the sorted-keys promise.
        let firstBytes = try Data(contentsOf: await store.fileURL)
        try await store.write(templates)
        let secondBytes = try Data(contentsOf: await store.fileURL)
        #expect(firstBytes == secondBytes)
    }

    @Test("A directory nothing was written to reads as nil, not as an empty library")
    func anUnwrittenDirectoryReadsAsNil() async throws {
        let store = JobTemplateStore(directory: try makeTemporaryDirectory())
        let read = try await store.read()
        #expect(read == nil)
    }

    @Test("A foreign file is refused by name")
    func aForeignFileIsRefusedByName() async throws {
        let directory = try makeTemporaryDirectory()
        let store = JobTemplateStore(directory: directory)
        let foreign = #"{"format": "somebody.elses.file", "schemaVersion": 1, "templates": []}"#
        try foreign.data(using: .utf8)!.write(to: await store.fileURL)

        await #expect(throws: JobTemplateStore.StoreError.notAZenitTemplateLibrary(
            found: "somebody.elses.file"
        )) {
            _ = try await store.read()
        }
    }

    @Test("A future schema is refused by version, not by a decode failure three fields deep")
    func aFutureSchemaIsRefusedByVersion() async throws {
        let directory = try makeTemporaryDirectory()
        let store = JobTemplateStore(directory: directory)
        let future = """
        {"format": "\(JobTemplateStore.formatIdentifier)", "schemaVersion": 99, "templates": []}
        """
        try future.data(using: .utf8)!.write(to: await store.fileURL)

        await #expect(throws: JobTemplateStore.StoreError.unsupportedSchemaVersion(
            found: 99, supported: JobTemplateStore.currentSchemaVersion
        )) {
            _ = try await store.read()
        }
    }

    // MARK: - The .zpdftemplate file

    @Test("Export and import round-trip a template through its digest")
    func aTemplateFileRoundTripsThroughItsDigest() throws {
        let template = makeTemplate(name: "Groundwork")
        let data = try JobTemplateFile.export(template)
        let read = try JobTemplateFile.read(data)
        #expect(read == template)

        // The envelope really carries the digest of the canonical payload, not a constant.
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let declared = envelope?["payloadSHA256"] as? String
        #expect(declared?.count == 64, "a SHA-256 in lower-case hex is 64 characters")
    }

    @Test("A tampered payload is refused by digest, naming both values")
    func aTamperedPayloadIsRefusedByDigest() throws {
        let data = try JobTemplateFile.export(makeTemplate(name: "Groundwork"))
        var envelope = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var body = try #require(envelope["template"] as? [String: Any])
        body["name"] = "Groundwork, adjusted in transit"
        envelope["template"] = body
        let tampered = try JSONSerialization.data(withJSONObject: envelope)

        #expect {
            _ = try JobTemplateFile.read(tampered)
        } throws: { error in
            guard case JobTemplateFile.FileError.digestMismatch(let declared, let computed) = error
            else { return false }
            return declared != computed
        }
    }

    @Test("A foreign or future .zpdftemplate is refused before its body")
    func aForeignOrFutureTemplateFileIsRefused() throws {
        let foreign = #"{"format": "not.a.template", "formatVersion": 1}"#.data(using: .utf8)!
        #expect(throws: JobTemplateFile.FileError.notAJobTemplate(found: "not.a.template")) {
            _ = try JobTemplateFile.read(foreign)
        }

        let future = """
        {"format": "\(JobTemplateFile.formatIdentifier)", "formatVersion": 99, "payloadSHA256": "", "template": {}}
        """.data(using: .utf8)!
        #expect(throws: JobTemplateFile.FileError.unsupportedFormatVersion(
            found: 99, supported: JobTemplateFile.currentFormatVersion
        )) {
            _ = try JobTemplateFile.read(future)
        }

        let notJSON = Data([0x25, 0x50, 0x44, 0x46])
        #expect(throws: JobTemplateFile.FileError.self) {
            _ = try JobTemplateFile.read(notJSON)
        }
    }
}
