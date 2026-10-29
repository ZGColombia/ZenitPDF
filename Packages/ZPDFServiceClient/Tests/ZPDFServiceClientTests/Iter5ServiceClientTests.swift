import Darwin
import Foundation
import Testing
import ZPDFServiceClient

/// Iteration 5: the repair request through the XPC service budgets for the two copies the
/// service makes, as geometry has since BH-212 (V-091).
@Suite("Iteration 5 — service client")
struct Iter5ServiceClientTests {

    /// A file of `bytes` logical bytes that occupies next to nothing on disk.
    static func sparseFile(bytes: Int64) throws -> (URL, FileHandle) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-it5-deadline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("set.pdf")
        try #require(FileManager.default.createFile(atPath: url.path, contents: nil))
        let writer = try FileHandle(forWritingTo: url)
        try #require(ftruncate(writer.fileDescriptor, off_t(bytes)) == 0)
        try writer.close()
        return (directory, try FileHandle(forReadingFrom: url))
    }

    /// Old behaviour: the XPC request carried the flat `.repair` 300 s whatever the set's size
    /// (`deadline: deadline` in `performOnce`), although the service copies the input in and the
    /// output back before it can answer, and a timeout is never retried.
    @Test("V-091: the repair XPC deadline grows with the input copied in and an output of its size copied back")
    func repairDeadlineBudgetsForStaging() throws {
        let (directory, handle) = try Self.sparseFile(bytes: 1_500_000_000)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: directory)
        }
        // Hand-derived: 2 × 1.5 GB = 3 GB at 25 MB/s is 120 s, on top of the 300 s.
        #expect(ZPDFRepairServiceClient.xpcDeadline(.repair, input: handle) == ZPDFServiceDeadline(.seconds(420)))

        let (emptyDirectory, empty) = try Self.sparseFile(bytes: 0)
        defer {
            try? empty.close()
            try? FileManager.default.removeItem(at: emptyDirectory)
        }
        #expect(ZPDFRepairServiceClient.xpcDeadline(.repair, input: empty) == .repair, "nothing to copy, nothing added")
    }

    @Test("V-091: geometry and repair read the staged size through one helper")
    func stagingByteCountReadsTheDescriptor() throws {
        let (directory, handle) = try Self.sparseFile(bytes: 123_456_789)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(ZPDFServiceDeadline.stagingByteCount(of: handle) == 123_456_789)
    }
}
