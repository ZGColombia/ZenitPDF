import CryptoKit
import Foundation
import os

/// SHA-256 over a document's bytes.
///
/// The file variant streams in fixed chunks and never holds the whole file: a takeoff
/// set is routinely 300 MB, and hashing it must not be the thing that decides how much
/// memory the app uses.
public enum FileDigestReader {

    /// Bytes read per chunk. 1 MiB: large enough that the syscall cost disappears, small
    /// enough that peak memory does not depend on the file.
    public static let chunkByteCount = 1 << 20

    /// Hashes `data`.
    public static func digest(of data: Data) -> FileDigest {
        var hasher = SHA256()
        hasher.update(data: data)
        return FileDigest(sha256: hexadecimal(hasher.finalize()), byteCount: data.count)
    }

    /// Hashes `data` together with a page index, so two pages of one PDF address different
    /// artwork.
    ///
    /// The artwork store is content-addressed by this digest and inserts `OR IGNORE` on it, so a
    /// digest that ignores the page would make page 2 of a title-block PDF collide with page 0 —
    /// the second import is dropped and every sheet draws page 0's picture (CR-72). The page
    /// index is folded in as eight little-endian bytes after the file bytes; the same page of the
    /// same file therefore still hashes to the same value, which is what lets a digest address a
    /// picture.
    public static func digest(of data: Data, pageIndex: Int) -> FileDigest {
        var hasher = SHA256()
        hasher.update(data: data)
        let folded = UInt64(bitPattern: Int64(pageIndex)).littleEndian
        withUnsafeBytes(of: folded) { hasher.update(bufferPointer: $0) }
        return FileDigest(sha256: hexadecimal(hasher.finalize()), byteCount: data.count)
    }

    /// Hashes the file at `url`, streaming and cancellable.
    ///
    /// - Throws: ``PDFBridgeError/fileNotFound(path:)``,
    ///   ``PDFBridgeError/fileUnreadable(path:reason:)``,
    ///   ``PDFBridgeError/fileTooLarge(byteCount:limit:)`` or
    ///   ``PDFBridgeError/cancelled``.
    public static func digest(
        ofFileAt url: URL,
        maximumByteCount: Int
    ) throws -> FileDigest {
        fileDigestObserver.withLock { $0 }?(url)
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw PDFBridgeError.fileNotFound(path: url.path)
        }

        let byteCount = try fileByteCount(at: url)
        guard byteCount <= maximumByteCount else {
            throw PDFBridgeError.fileTooLarge(byteCount: byteCount, limit: maximumByteCount)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PDFBridgeError.fileUnreadable(path: url.path, reason: error.localizedDescription)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var readTotal = 0
        // Bounded: each iteration must consume at least one byte or the loop ends, and
        // `readTotal` can never exceed the size measured above.
        while readTotal < byteCount {
            if Task.isCancelled { throw PDFBridgeError.cancelled }
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkByteCount)
            } catch {
                throw PDFBridgeError.fileUnreadable(path: url.path, reason: error.localizedDescription)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            readTotal += chunk.count
        }

        return FileDigest(sha256: hexadecimal(hasher.finalize()), byteCount: readTotal)
    }

    /// The size of a file in bytes, without reading it.
    public static func fileByteCount(at url: URL) throws -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw PDFBridgeError.fileNotFound(path: url.path)
        }
        do {
            // Resolved first: a URL's resource values describe a symbolic link itself, while
            // `fileExists` above and every read (`FileHandle`) follow it. Opening a drawing
            // through a symlink measured the link (a few dozen bytes), so the digest covered
            // only its first chunk and the probe looked for `%%EOF` at the wrong offset (BH-179).
            let values = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize else {
                throw PDFBridgeError.fileUnreadable(path: url.path, reason: "size unavailable")
            }
            return size
        } catch let error as PDFBridgeError {
            throw error
        } catch {
            throw PDFBridgeError.fileUnreadable(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Called with the URL at the start of every streamed file hash. `nil` in production;
    /// a test installs it to count how often a file is hashed (IM-005).
    static let fileDigestObserver = OSAllocatedUnfairLock<(@Sendable (URL) -> Void)?>(initialState: nil)

    /// Whether `digest` is a well-formed SHA-256 for a file of `byteCount` bytes: 64 lower-case
    /// hexadecimal characters and the same size. A caller-supplied digest that fails this is
    /// ignored and the file is hashed.
    static func isPlausible(_ digest: FileDigest, byteCount: Int) -> Bool {
        digest.byteCount == byteCount
            && digest.sha256.utf8.count == 64
            && digest.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func hexadecimal(_ digest: SHA256Digest) -> String {
        var out = ""
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexTable[Int(byte >> 4)])
            out.append(hexTable[Int(byte & 0x0F)])
        }
        return out
    }

    private static let hexTable: [Character] = Array("0123456789abcdef")
}
