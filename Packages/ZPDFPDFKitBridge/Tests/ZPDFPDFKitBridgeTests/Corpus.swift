import Foundation
import Testing
import ZPDFTestingSupport
import os

/// The synthetic PDF corpus, generated once per test process.
///
/// Every fixture is written up front, single-threaded, in the `static let` initialiser,
/// so the parallel test suites that follow only ever *read* the directory. Generating on
/// demand from several tests at once would race on the same file.
enum Corpus {

    static let directory: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ZPDFPDFKitBridgeTests-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corpus = root.appendingPathComponent("corpus", isDirectory: true)
        try? FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        _ = try? ZPDFFixtures.makeAll(in: corpus)
        return corpus
    }()

    static func url(_ kind: FixtureKind) -> URL {
        directory.appendingPathComponent(kind.fileName, isDirectory: false)
    }

    static func data(_ kind: FixtureKind) throws -> Data {
        try Data(contentsOf: url(kind))
    }

    static func manifest(_ kind: FixtureKind) throws -> FixtureManifest {
        try ZPDFFixtures.manifest(for: kind)
    }

    static func sha256(_ url: URL) throws -> String {
        try FileDigestProbe.hex(of: url)
    }

    private static let scratchCounter = OSAllocatedUnfairLock(initialState: 0)

    /// A fresh, empty directory for a test that writes files.
    ///
    /// Numbered rather than UUID-named so a failing run's leftovers are readable.
    static func scratchDirectory(_ label: String) throws -> URL {
        let index = scratchCounter.withLock { value -> Int in
            value += 1
            return value
        }
        let url = directory
            .deletingLastPathComponent()
            .appendingPathComponent("scratch-\(index)-\(label)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// An independent SHA-256, used by the immutability assertions.
///
/// Deliberately *not* the bridge's own ``FileDigestReader``: a test that proves the
/// original file is untouched must not depend on the code it is testing to say so.
enum FileDigestProbe {
    static func hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return hex(of: data)
    }

    static func hex(of data: Data) -> String {
        var hash = [UInt32](repeating: 0, count: 8)
        // FIPS 180-4 SHA-256, written out so the assertion depends on nothing in the
        // package under test.
        hash = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
            0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
            0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
            0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
            0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
            0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
            0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
            0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8truncating(bitLength >> UInt64(shift)))
        }

        var blockStart = 0
        while blockStart < message.count {
            var w = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let base = blockStart + index * 4
                w[index] = (UInt32(message[base]) << 24) | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8) | UInt32(message[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotr(w[index - 15], 7) ^ rotr(w[index - 15], 18) ^ (w[index - 15] >> 3)
                let s1 = rotr(w[index - 2], 17) ^ rotr(w[index - 2], 19) ^ (w[index - 2] >> 10)
                w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
            var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for index in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ ch &+ k[index] &+ w[index]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                h = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            hash[0] = hash[0] &+ a; hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c; hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e; hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g; hash[7] = hash[7] &+ h
            blockStart += 64
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private static func UInt8truncating(_ value: UInt64) -> UInt8 {
        UInt8(truncatingIfNeeded: value)
    }
}
