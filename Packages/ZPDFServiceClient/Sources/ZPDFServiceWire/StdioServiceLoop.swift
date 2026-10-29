import Foundation

/// A service core, seen from the stdio loop: one request in, one reply out.
/// `cancel` frames are delivered through the same method (kind `.cancel`, body =
/// UUID string data) so a handler can interrupt an in-flight sibling request.
public protocol StdioRequestHandler: Sendable {
    func handle(_ frame: WireRequestFrame) async -> WireReplyFrame
}

/// Runs a service core against stdin/stdout using ``WireFraming``.
///
/// Frames are handled concurrently — a `cancel` frame must be able to land while
/// an extraction is running — and replies are matched by id on the client side, so
/// reply order does not matter. EOF on stdin means the parent is gone: exit.
public enum StdioServiceLoop {

    public static func run(handler: some StdioRequestHandler) async {
        // The parent killing us mid-write must not raise SIGPIPE into a crash
        // report; a dead pipe is an expected way for this process to end.
        signal(SIGPIPE, SIG_IGN)

        let writer = FrameWriter(handle: FileHandle.standardOutput)
        let frames = frameStream(reading: FileHandle.standardInput)

        // Each frame gets its own unstructured task, and this function returns as
        // soon as the stream ends — it does NOT wait for handlers still running.
        // It used to run them in a discarding task group, which waits for every
        // child when the loop ends, so a worker whose parent died while a handler
        // was spinning (a scanner loop, a long debug delay) outlived its parent
        // indefinitely instead of exiting on EOF (BH-657). The callers exit the
        // process when this returns, which ends any handler still running; its
        // reply had no reader anyway.
        //
        // Frames are still dispatched in arrival order from this one loop, and a
        // cancel that overtakes its own request on the way to the core is held by
        // the core until the request registers (BH-658).
        for await frame in frames {
            Task {
                let reply = await handler.handle(frame)
                await writer.write(reply)
            }
        }
    }

    /// Reads length-prefixed frames on a dedicated thread; the stream finishes on
    /// EOF or any protocol violation (oversized or short frame).
    private static func frameStream(reading handle: FileHandle) -> AsyncStream<WireRequestFrame> {
        AsyncStream { continuation in
            let thread = Thread {
                while true {
                    guard let header = readExactly(4, from: handle) else { break }
                    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).byteSwapped }
                    guard length > 0, Int(length) <= WireFraming.maximumBodyBytes else { break }
                    guard let body = readExactly(Int(length), from: handle),
                          let frame = try? WireFraming.decodeBody(WireRequestFrame.self, from: body)
                    else { break }
                    continuation.yield(frame)
                }
                continuation.finish()
            }
            thread.name = "zpdf.wire.reader"
            thread.start()
        }
    }

    /// Reads exactly `count` bytes, looping over short reads, or returns nil on EOF
    /// or a read error before `count` bytes arrived.
    ///
    /// `read(upToCount:)` on a pipe returns whatever is available, so the 4-byte
    /// length prefix can arrive split across two reads just as a body can — the
    /// kernel splits a writer's single `write` when the pipe buffer has only a few
    /// bytes free. The header used to be read once, and a short read was treated
    /// as a protocol violation that ended the worker mid-session (BH-659).
    static func readExactly(_ count: Int, from handle: FileHandle) -> Data? {
        var buffer = Data()
        while buffer.count < count {
            guard let chunk = try? handle.read(upToCount: count - buffer.count),
                  !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
        return buffer
    }
}

/// Serialises reply writes: two concurrent replies must never interleave bytes.
private actor FrameWriter {
    private let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }

    func write(_ reply: WireReplyFrame) {
        guard let data = try? WireFraming.encode(reply) else { return }
        try? handle.write(contentsOf: data)
    }
}
