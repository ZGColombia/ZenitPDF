import Foundation
import GRDB
import Testing
import ZPDFPersistence

struct GeometryBlobTests {

    @Test("A blob round-trips through its own encoder")
    func roundTrip() throws {
        let blob = GeometryBlob(kind: .polygonWithHoles, rings: [
            [GeometryPoint(x: 0, y: 0), GeometryPoint(x: 100, y: 0), GeometryPoint(x: 100, y: 50)],
            [GeometryPoint(x: 10, y: 10), GeometryPoint(x: 20, y: 10), GeometryPoint(x: 20, y: 20)]
        ])
        let data = try blob.encode()
        #expect(try GeometryBlob.decode(data) == blob)
    }

    @Test("Coordinates keep every bit of their Double")
    func coordinatesAreBitExact() throws {
        let awkward = [
            Double.leastNormalMagnitude, -Double.greatestFiniteMagnitude,
            0.1, -0.0, 1e-300, 1e300, .pi
        ]
        let blob = GeometryBlob(kind: .freeform, points: awkward.map { GeometryPoint(x: $0, y: -$0) })
        let decoded = try GeometryBlob.decode(try blob.encode())
        for (index, point) in decoded.rings[0].enumerated() {
            #expect(point.x.bitPattern == awkward[index].bitPattern)
            #expect(point.y.bitPattern == (-awkward[index]).bitPattern)
        }
    }

    @Test("The header names its own version, so a v2 reader can tell")
    func headerIsVersioned() throws {
        let data = try GeometryBlob(kind: .point, points: [GeometryPoint(x: 1, y: 2)]).encode()
        #expect(Array(data[0..<4]) == Array("ZPG1".utf8))
        #expect(data[4] == 1 && data[5] == 0)
    }

    @Test("A future format version is refused rather than guessed at")
    func futureVersionIsRefused() throws {
        var data = try GeometryBlob(kind: .point, points: [GeometryPoint(x: 1, y: 2)]).encode()
        data[4] = 2
        #expect(throws: GeometryBlobError.unsupportedFormatVersion(found: 2, supported: 1)) {
            _ = try GeometryBlob.decode(data)
        }
    }

    @Test("Every structural corruption is a typed error and never a crash")
    func corruptionIsRejected() throws {
        let good = try GeometryBlob(kind: .polygon, rings: [
            (0..<8).map { GeometryPoint(x: Double($0), y: Double($0 * 2)) }
        ]).encode()

        // Truncation at every length.
        for length in 0..<good.count {
            #expect(throws: (any Error).self) {
                _ = try GeometryBlob.decode(good.prefix(length))
            }
        }
        // Trailing slack.
        #expect(throws: (any Error).self) { _ = try GeometryBlob.decode(good + Data([0])) }
        // Bad magic.
        var badMagic = good
        badMagic[0] = 0x00
        #expect(throws: (any Error).self) { _ = try GeometryBlob.decode(badMagic) }
        // Every single-byte flip must be caught by the CRC or by a structural check.
        for index in stride(from: 0, to: good.count, by: 7) {
            var mutated = good
            mutated[index] ^= 0xFF
            #expect(throws: (any Error).self, "byte \(index) flip went undetected") {
                _ = try GeometryBlob.decode(mutated)
            }
        }
    }

    @Test("An absurd ring count is refused before anything is allocated")
    func ringCountCapIsEnforced() throws {
        var data = try GeometryBlob(kind: .polygon, points: [GeometryPoint(x: 0, y: 0)]).encode()
        // ringCount at offset 12, little-endian.
        data[12] = 0xFF; data[13] = 0xFF; data[14] = 0xFF; data[15] = 0xFF
        #expect(throws: GeometryBlobError.ringCountOverLimit(found: 0xFFFF_FFFF, limit: 4_096)) {
            _ = try GeometryBlob.decode(data)
        }
    }

    @Test("NaN and infinity never become coordinates")
    func nonFiniteIsRejected() throws {
        #expect(throws: GeometryBlobError.nonFiniteCoordinate(ring: 0, point: 1)) {
            _ = try GeometryBlob(
                kind: .polyline,
                points: [GeometryPoint(x: 0, y: 0), GeometryPoint(x: .nan, y: 1)]
            ).encode()
        }
        // And on the way in, where the bytes did not come from our encoder.
        var data = try GeometryBlob(
            kind: .polyline, points: [GeometryPoint(x: 1, y: 2), GeometryPoint(x: 3, y: 4)]
        ).encode()
        let quietNaN = Double.nan.bitPattern.littleEndian
        withUnsafeBytes(of: quietNaN) { raw in
            for offset in 0..<8 { data[24 + 16 + offset] = raw[offset] }
        }
        // Recompute the CRC so the only remaining objection is the NaN itself.
        let bodyLimit = data.count - 4
        let recomputed = CRC32Probe.checksum(data[0..<bodyLimit])
        withUnsafeBytes(of: recomputed.littleEndian) { raw in
            for offset in 0..<4 { data[bodyLimit + offset] = raw[offset] }
        }
        #expect(throws: (any Error).self) { _ = try GeometryBlob.decode(data) }
    }

    @Test("A blob column survives a real database round trip")
    func databaseRoundTrip() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("Blob")
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await ProjectDatabaseActor.open(
            at: directory.appendingPathComponent("project.sqlite")
        )
        let blob = GeometryBlob(kind: .rectangle, points: [
            GeometryPoint(x: 0, y: 0), GeometryPoint(x: 210, y: 297)
        ])
        let fetched: GeometryBlob? = try await database.write { db in
            try db.execute(sql: "CREATE TABLE probe (id INTEGER PRIMARY KEY, shape BLOB NOT NULL)")
            try db.execute(sql: "INSERT INTO probe VALUES (1, ?)", arguments: [blob])
            return try GeometryBlob.fetchOne(db, sql: "SELECT shape FROM probe")
        }
        #expect(fetched == blob)
        try await database.close()
    }
}

/// A local CRC-32 so the corruption test can rebuild a checksum without the production
/// implementation being made public just for a test.
enum CRC32Probe {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        return value
    }

    static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)] }
        return crc ^ 0xFFFF_FFFF
    }
}

struct PackedRGBATests {

    @Test("Packing and unpacking are inverses across the whole channel range")
    func roundTrip() {
        for red in stride(from: 0, through: 255, by: 17) {
            for alpha in [0, 1, 127, 254, 255] {
                let colour = PackedRGBA(
                    red: UInt8(red), green: 0x9A, blue: 0x3C, alpha: UInt8(alpha)
                )
                #expect(PackedRGBA(packedValue: colour.packedValue) == colour)
            }
        }
    }

    @Test("The packed layout is 0xRRGGBBAA")
    func layout() {
        let colour = PackedRGBA(red: 0x12, green: 0x34, blue: 0x56, alpha: 0x78)
        #expect(colour.packedValue == 0x1234_5678)
        #expect(colour.description == "#12345678")
    }

    @Test("A colour is never stored or read as a negative integer")
    func neverNegative() {
        let white = PackedRGBA(red: 255, green: 255, blue: 255, alpha: 255)
        #expect(white.databaseValue == Int64(0xFFFF_FFFF).databaseValue)
        #expect(PackedRGBA.fromDatabaseValue(Int64(-1).databaseValue) == nil)
        #expect(PackedRGBA.fromDatabaseValue(Int64(0x1_0000_0000).databaseValue) == nil)
        #expect(PackedRGBA.fromDatabaseValue(Int64(0xFFFF_FFFF).databaseValue) == white)
    }

    @Test("Unit components clamp instead of trapping")
    func unitComponentsClamp() {
        #expect(PackedRGBA(unitRed: 2, unitGreen: -1, unitBlue: 0.5, unitAlpha: .nan)
            == PackedRGBA(red: 255, green: 0, blue: 128, alpha: 0))
    }
}
