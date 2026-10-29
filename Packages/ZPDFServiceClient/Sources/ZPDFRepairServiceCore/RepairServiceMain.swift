import Foundation
import ZPDFServiceWire

// MARK: - Stdio handler (test worker path)

public struct RepairStdioHandler: StdioRequestHandler {
    private let core: RepairServiceCore

    public init(core: RepairServiceCore = RepairServiceCore()) {
        self.core = core
    }

    public func handle(_ frame: WireRequestFrame) async -> WireReplyFrame {
        switch frame.kind {
        case .ping:
            return WireReplyFrame(id: frame.id, body: Data("\(RepairServiceCore.protocolVersion)".utf8))
        case .cancel:
            if let id = UUID(uuidString: String(decoding: frame.body, as: UTF8.self)) {
                await core.cancel(id)
            }
            return WireReplyFrame(id: frame.id, body: Data())
        case .repairPerform:
            guard let request = try? WireFraming.decodeBody(RepairWireRequest.self, from: frame.body),
                  let path = frame.filePath
            else {
                return WireReplyFrame(id: frame.id, failure: WireFailure(
                    domain: "ZPDFRepairService", code: 4, message: "malformed repairPerform frame"))
            }
            let outcome = await core.perform(
                request: request,
                inputAt: URL(fileURLWithPath: path),
                outputPath: frame.outputPath)
            switch outcome {
            case .success(let reply):
                return WireReplyFrame(id: frame.id, body: try? JSONEncoder().encode(reply))
            case .failure(let failure):
                return WireReplyFrame(id: frame.id, failure: failure)
            }
        case .geometryExtract, .geometryRasterize, .geometryPageBox, .geometryDXF:
            return WireReplyFrame(id: frame.id, failure: WireFailure(
                domain: "ZPDFRepairService", code: 5,
                // The kind that was actually sent: this arm serves three (BH-652).
                message: "\(frame.kind.rawValue) is not a repair operation"))
        }
    }
}

// MARK: - XPC listener path (.xpc bundle)

final class RepairXPCExported: NSObject, ZPDFRepairXPCProtocol {
    private let core: RepairServiceCore

    init(core: RepairServiceCore) {
        self.core = core
    }

    func performOperation(
        _ requestData: Data,
        input: FileHandle,
        output: FileHandle?,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        guard let request = try? JSONDecoder().decode(RepairWireRequest.self, from: requestData) else {
            reply(nil, WireFailure(
                domain: "ZPDFRepairService", code: 4, message: "malformed request payload").nsError)
            return
        }
        guard let (inputFD, outputFD) = Self.duplicateDescriptors(
            input: input.fileDescriptor, output: output?.fileDescriptor)
        else {
            reply(nil, WireFailure(
                domain: "ZPDFRepairService", code: 3, message: "could not dup inherited descriptor").nsError)
            return
        }
        let core = self.core
        Task {
            defer {
                close(inputFD)
                if let outputFD { close(outputFD) }
            }
            switch await core.perform(request: request, inputDescriptor: inputFD, outputDescriptor: outputFD) {
            case .success(let wireReply):
                reply(try? JSONEncoder().encode(wireReply), nil)
            case .failure(let failure):
                reply(nil, failure.nsError)
            }
        }
    }

    /// Duplicates the inherited input descriptor and, when present, the output
    /// one, or returns nil having closed whatever it had already duplicated.
    ///
    /// The output used to be duplicated before the input's result was checked,
    /// and the failure branch closed only the input, so a failed input dup leaked
    /// the output descriptor for the life of the service (BH-653). `dup` and
    /// `close` are injectable so the failure branch is testable.
    static func duplicateDescriptors(
        input: Int32,
        output: Int32?,
        dup duplicate: (Int32) -> Int32 = { Darwin.dup($0) },
        close closeDescriptor: (Int32) -> Void = { _ = Darwin.close($0) }
    ) -> (input: Int32, output: Int32?)? {
        let inputFD = duplicate(input)
        guard inputFD >= 0 else { return nil }
        guard let output else { return (inputFD, nil) }
        let outputFD = duplicate(output)
        guard outputFD >= 0 else {
            closeDescriptor(inputFD)
            return nil
        }
        return (inputFD, outputFD)
    }

    func cancelRequest(_ requestID: String) {
        guard let id = UUID(uuidString: requestID) else { return }
        let core = self.core
        Task { await core.cancel(id) }
    }

    func ping(reply: @escaping @Sendable (Int) -> Void) {
        reply(RepairServiceCore.protocolVersion)
    }
}

final class RepairListenerDelegate: NSObject, NSXPCListenerDelegate {
    /// A cancelled request whose qpdf call is still running after the grace ends this process
    /// (R-198); launchd starts a clean one for the next request.
    private let core = RepairServiceCore(onWedgedCancellation: ServiceWedgeWatchdog.exitProcess)

    override init() {
        // Staged inputs and outputs an earlier run left when its watchdog ended it (S-117).
        RepairServiceCore.sweepStaleStagedFiles()
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ZPDFRepairXPCProtocol.self)
        newConnection.exportedObject = RepairXPCExported(core: core)
        newConnection.resume()
        return true
    }
}

// MARK: - Entry point

public enum RepairServiceMain {
    public static func run() -> Never {
        if CommandLine.arguments.contains("--stdio") {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await StdioServiceLoop.run(handler: RepairStdioHandler(
                    core: RepairServiceCore(onWedgedCancellation: ServiceWedgeWatchdog.exitProcess)))
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        let delegate = RepairListenerDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        exit(0)
    }
}
