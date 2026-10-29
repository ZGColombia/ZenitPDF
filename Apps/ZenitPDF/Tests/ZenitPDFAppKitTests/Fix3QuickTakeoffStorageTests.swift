import Foundation
import Testing
import ZPDFContracts
import ZPDFPersistence
@testable import ZenitPDFAppKit

/// IM-181: Quick PDF Mode's container storage is one serialized type. The interleavings the
/// document's old `quickAutosaveInFlight` refused — two autosaves racing the create-if-absent,
/// the second deleting the directory the first had an open SQLite file in — are still refused,
/// and so now are the ones it never covered: a retire or a shutdown closing the package under an
/// autosave that is still writing.
@MainActor
@Suite(.appTierSerialised)
struct Fix3QuickTakeoffStorageTests {

    /// What the archive writer saw.
    @MainActor
    final class Probe {
        var active = 0
        var maxActive = 0
        var writes = 0
        var fullSaves = 0
        var lightSaves = 0
        /// Writes whose package was taken away (retired or shut down) while they ran.
        var stolen = 0
        var log: [String] = []
    }

    private struct Fixture {
        let root: URL
        let directory: URL
        let storage: QuickTakeoffStorage
        let probe: Probe
    }

    private func makeFixture(writeDelay: Duration = .milliseconds(2)) throws -> Fixture {
        let pdf = try AppTestSupport.writeFixturePDF(named: "IM181.pdf")
        let root = pdf.deletingLastPathComponent()
        let directory = root.appendingPathComponent("container-\(UUID().uuidString)", isDirectory: true)
        let probe = Probe()
        let storage = QuickTakeoffStorage(
            defaultDirectory: { directory },
            origin: { QuickTakeoffStorage.Origin(originalPDF: pdf, pageCount: 1, displayName: "IM181") },
            writeArchive: { _ in }
        )
        storage.writeArchive = { [unowned storage, probe] package in
            probe.active += 1
            probe.maxActive = max(probe.maxActive, probe.active)
            probe.log.append("write-start")
            defer {
                probe.active -= 1
                probe.writes += 1
                probe.log.append("write-end")
            }
            try await Task.sleep(for: writeDelay)
            if storage.package !== package { probe.stolen += 1 }
        }
        storage.didWrite = { [probe] fullSave in
            if fullSave { probe.fullSaves += 1 } else { probe.lightSaves += 1 }
        }
        return Fixture(root: root, directory: directory, storage: storage, probe: probe)
    }

    private func packageExists(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: QuickTakeoffStorage.packageURL(in: directory)
                .appendingPathComponent(ProjectPackageLayout.manifest).path
        )
    }

    // MARK: - The interleaving `quickAutosaveInFlight` guarded

    @Test("IM-181: concurrent autosaves create one container and never overlap")
    func concurrentFlushesAreSerialised() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tasks = (0..<40).map { _ in
            Task { @MainActor in try await fixture.storage.flush() }
        }
        var urls: Set<URL> = []
        for task in tasks { urls.insert(try await task.value) }

        #expect(urls.count == 1, "every caller got the one container package")
        #expect(fixture.probe.maxActive == 1, "two writes overlapped: the create-if-absent race")
        #expect(fixture.probe.writes == 40, "each caller still got a real save at its turn")
        #expect(fixture.probe.fullSaves == 1, "the container is created and fully saved exactly once")
        #expect(fixture.probe.lightSaves == 39)
        #expect(packageExists(in: fixture.directory))
        #expect(fixture.storage.pendingOperations == 0)
        await fixture.storage.retire()
    }

    // MARK: - The interleavings it never covered

    @Test("IM-181: a retire waits for the autosave already writing, then removes the container")
    func retireWaitsForTheWrite() async throws {
        let fixture = try makeFixture(writeDelay: .milliseconds(150))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let flush = Task { @MainActor in try await fixture.storage.flush() }
        #expect(await AppTestSupport.wait(upTo: 5) { fixture.probe.active == 1 })

        await fixture.storage.retire()
        fixture.probe.log.append("retired")

        // Old: the retire closed the package and deleted the directory under the running
        // write, whose `package.save()` then failed against a closed database.
        _ = try await flush.value
        #expect(fixture.probe.log == ["write-start", "write-end", "retired"])
        #expect(fixture.probe.stolen == 0)
        #expect(fixture.storage.package == nil && !fixture.storage.holdsStorage)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path), "retire removes the container")
    }

    @Test("IM-181: a shutdown waits for the autosave already writing and keeps the container on disk")
    func shutdownWaitsForTheWriteAndKeepsTheContainer() async throws {
        let fixture = try makeFixture(writeDelay: .milliseconds(150))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let flush = Task { @MainActor in try await fixture.storage.flush() }
        #expect(await AppTestSupport.wait(upTo: 5) { fixture.probe.active == 1 })

        await fixture.storage.shutDown()
        _ = try await flush.value
        #expect(fixture.probe.stolen == 0)
        #expect(!fixture.storage.holdsStorage, "every container handle is closed")
        #expect(packageExists(in: fixture.directory), "an edited takeoff's autosave is its crash-survival copy")
        await fixture.storage.shutDown()
        #expect(!fixture.storage.holdsStorage, "a second shutdown finds nothing open")
    }

    @Test("IM-181: a shutdown waits for autosaves only; a history open it overtakes closes its own database")
    func shutdownOvertakesAQueuedHistoryOpen() async throws {
        let fixture = try makeFixture(writeDelay: .milliseconds(150))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let flush = Task { @MainActor in try await fixture.storage.flush() }
        #expect(await AppTestSupport.wait(upTo: 5) { fixture.probe.active == 1 })
        let history = Task { @MainActor in try await fixture.storage.openHistoryDatabase() }
        #expect(await AppTestSupport.wait(upTo: 5) { fixture.storage.pendingOperations == 2 })

        // Quit waits on this: it must not also wait for a database nobody will read again.
        await fixture.storage.shutDown()
        _ = try await flush.value
        #expect(fixture.probe.stolen == 0, "the write queued before the shutdown finished first")
        let opened = await history.result
        if case .success = opened {
            Issue.record("a history database opened after the shutdown was kept: a leaked handle")
        }
        #expect(fixture.storage.historyDatabase == nil)
        #expect(!fixture.storage.holdsStorage)
        #expect(await AppTestSupport.wait(upTo: 5) { fixture.storage.pendingOperations == 0 })
    }

    @Test("IM-181: the history database opens in queue order — after a retire queued before it, never into its removal")
    func historyOpenQueuesBehindRetire() async throws {
        let fixture = try makeFixture(writeDelay: .milliseconds(100))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let flush = Task { @MainActor in try await fixture.storage.flush() }
        #expect(await AppTestSupport.wait(upTo: 5) { fixture.probe.active == 1 })
        let retire = Task { @MainActor in await fixture.storage.retire() }
        // The retire is queued behind the running write before the history open is.
        #expect(await AppTestSupport.wait(upTo: 5) { fixture.storage.pendingOperations == 2 })
        let history = try await fixture.storage.openHistoryDatabase()
        _ = try await flush.value
        await retire.value
        _ = history
        #expect(fixture.storage.historyDatabase != nil)
        #expect(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("history.sqlite").path
        ), "the history database opened after the retire, not into the directory it removed")
        await fixture.storage.shutDown()
    }

    @Test("IM-181: 300 autosaves, retires and shutdowns fired at once never interleave and leave a consistent container")
    func stressMixedOperations() async throws {
        let fixture = try makeFixture(writeDelay: .zero)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // A fixed pseudo-random order, so a failure reproduces.
        var seed: UInt64 = 0x1811_2026
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed >> 33
        }
        enum Operation { case flush, retire, shutDown }
        let plan: [Operation] = (0..<300).map { _ in
            switch next() % 10 {
            case 0: .retire
            case 1: .shutDown
            default: .flush
            }
        }
        var failures = 0
        let tasks: [Task<Bool, Never>] = plan.map { operation in
            Task { @MainActor in
                switch operation {
                case .flush:
                    do { _ = try await fixture.storage.flush(); return true } catch { return false }
                case .retire:
                    await fixture.storage.retire(); return true
                case .shutDown:
                    await fixture.storage.shutDown(); return true
                }
            }
        }
        for task in tasks where !(await task.value) { failures += 1 }

        #expect(failures == 0, "an autosave failed: an operation interleaved with it")
        #expect(fixture.probe.maxActive == 1)
        #expect(fixture.probe.stolen == 0, "a retire or shutdown took the package from under a write")
        #expect(fixture.probe.writes == plan.filter { if case .flush = $0 { true } else { false } }.count)
        #expect(fixture.storage.pendingOperations == 0)

        // Consistent at rest: one more autosave lands in a container that opens, and a retire
        // leaves nothing behind.
        _ = try await fixture.storage.flush()
        #expect(packageExists(in: fixture.directory))
        await fixture.storage.retire()
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(!fixture.storage.holdsStorage)
    }

    // MARK: - The document delegates

    @Test("IM-181: the document's autosave door is the storage's queue")
    func documentDelegatesToTheStorage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenit-im181-\(UUID().uuidString)", isDirectory: true)
        ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = root
        defer {
            ZenitPDFProjectDocument.quickPDFAutosaveRootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        let harness = try await Fix2Harness.make("IM181-Document.pdf")
        defer { harness.tearDown() }
        #expect(harness.document.mode == .quickPDF)
        #expect(harness.document.quickPDFAutosaveDirectory == harness.document.quickStorage.directory)
        // Only the explicit autosaves below are counted, not a debounced one armed by setup.
        harness.document.quickStorage.cancelScheduled()

        let tasks = (0..<8).map { _ in
            Task { @MainActor in try await harness.document.autosaveQuickPDFTakeoff() }
        }
        for task in tasks { _ = try await task.value }
        #expect(harness.document.fullPackageSaveCountForTesting == 1)
        #expect(harness.document.lightAutosaveCountForTesting == 7)
        #expect(harness.document.quickAutosavePackageForTesting != nil)
        #expect(harness.document.hasOpenStorage)

        await harness.document.discardQuickTakeoffForQuit()
        #expect(harness.document.quickAutosavePackageForTesting == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.document.quickPDFAutosaveDirectory.path))
    }
}
