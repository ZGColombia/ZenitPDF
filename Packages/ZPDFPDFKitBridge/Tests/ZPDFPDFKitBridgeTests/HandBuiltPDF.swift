import CryptoKit
import Foundation

/// Hand-assembled PDFs for the fix-round regression suites.
///
/// Every byte is written here so a hostile or unusual construct is exactly what the test
/// says it is: object `n` is `bodies[n - 1]`, the cross-reference table is correct, and the
/// file lands in the temporary directory, never anywhere a person keeps documents.
enum HandBuiltPDF {

    /// A content-stream object body with a correct `/Length`.
    static func stream(_ content: String, extra: String = "") -> String {
        let bytes = Data(content.utf8)
        return "<< /Length \(bytes.count) \(extra) >>\nstream\n\(content)\nendstream"
    }

    /// Serialises `bodies` as objects `1 … n`, with `1 0 R` as the catalogue.
    static func data(_ bodies: [String], trailerExtra: String = "") -> Data {
        var out = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int] = []
        for (index, body) in bodies.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
        let xrefOffset = out.count
        var xref = "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            xref += String(format: "%010d 00000 n \n", offset)
        }
        xref += "trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R \(trailerExtra) >>\n"
        xref += "startxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data(xref.utf8))
        return out
    }

    /// Writes `bodies` to a fresh file under the temporary directory.
    static func write(_ bodies: [String], label: String, trailerExtra: String = "") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-fix2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(label).pdf", isDirectory: false)
        try data(bodies, trailerExtra: trailerExtra).write(to: url, options: .atomic)
        return url
    }

    /// A one-page document: catalogue extras, page extras and a content stream.
    static func onePage(
        content: String,
        mediaBox: String = "[0 0 200 200]",
        pageExtra: String = "",
        catalogExtra: String = "",
        additional: [String] = [],
        label: String
    ) throws -> URL {
        var bodies = [
            "<< /Type /Catalog /Pages 2 0 R \(catalogExtra) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox \(mediaBox) /Resources << >> /Contents 4 0 R \(pageExtra) >>",
            stream(content)
        ]
        bodies.append(contentsOf: additional)
        return try write(bodies, label: label)
    }

    /// `pageCount` empty pages, objects 3 …, with catalogue extras and extra objects appended
    /// after the pages (so the first extra object is number `3 + pageCount`).
    static func pages(
        _ pageCount: Int,
        mediaBox: String = "[0 0 200 200]",
        catalogExtra: String = "",
        pageExtra: (Int) -> String = { _ in "" },
        additional: [String] = [],
        label: String
    ) throws -> URL {
        let kids = (0..<pageCount).map { "\(3 + $0) 0 R" }.joined(separator: " ")
        var bodies = [
            "<< /Type /Catalog /Pages 2 0 R \(catalogExtra) >>",
            "<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>"
        ]
        for index in 0..<pageCount {
            bodies.append("<< /Type /Page /Parent 2 0 R /MediaBox \(mediaBox) \(pageExtra(index)) >>")
        }
        bodies.append(contentsOf: additional)
        return try write(bodies, label: label)
    }
}

extension HandBuiltPDF {

    /// Writes `bodies` encrypted with the Standard security handler, revision 2 (40-bit RC4),
    /// behind a non-empty user password, so the document opens **locked**.
    ///
    /// PDFKit's own encrypted writer drops `/PageLabels` and `/Names`, so a fixture that needs
    /// both a password and catalogue structure has to be encrypted by hand. A string literal is
    /// written in a body as `«text»`; it is encrypted with its object's key and emitted as hex.
    /// Bodies carry no streams.
    static func writeEncrypted(
        _ bodies: [String], userPassword: String, label: String
    ) throws -> URL {
        let padding: [UInt8] = [
            0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA,
            0x01, 0x08, 0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE,
            0x64, 0x53, 0x69, 0x7A
        ]
        func padded(_ password: String) -> [UInt8] {
            Array((Array(password.utf8) + padding).prefix(32))
        }
        func md5(_ bytes: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: Data(bytes))) }
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined() }

        let ownerPassword = "owner-" + userPassword
        let permissions: Int32 = -4
        let fileID = Array(repeating: UInt8(0xA5), count: 16)

        // Algorithm 3: /O.
        let ownerKey = Array(md5(padded(ownerPassword)).prefix(5))
        let owner = rc4(key: ownerKey, padded(userPassword))
        // Algorithm 2: the file key.
        var keyInput = padded(userPassword) + owner
        withUnsafeBytes(of: permissions.littleEndian) { keyInput.append(contentsOf: $0) }
        keyInput += fileID
        let fileKey = Array(md5(keyInput).prefix(5))
        // Algorithm 4: /U.
        let user = rc4(key: fileKey, padding)

        var encryptedBodies: [String] = []
        for (index, body) in bodies.enumerated() {
            let objectNumber = index + 1
            var objectKeyInput = fileKey
            objectKeyInput += [UInt8(objectNumber & 0xFF), UInt8((objectNumber >> 8) & 0xFF),
                               UInt8((objectNumber >> 16) & 0xFF), 0, 0]
            let objectKey = Array(md5(objectKeyInput).prefix(10))
            var out = ""
            var rest = Substring(body)
            while let open = rest.firstIndex(of: "«") {
                out += rest[..<open]
                let afterOpen = rest.index(after: open)
                guard let close = rest[afterOpen...].firstIndex(of: "»") else { break }
                let plain = Array(String(rest[afterOpen..<close]).utf8)
                out += "<" + hex(rc4(key: objectKey, plain)) + ">"
                rest = rest[rest.index(after: close)...]
            }
            out += rest
            encryptedBodies.append(out)
        }
        let encryptObject = bodies.count + 1
        encryptedBodies.append(
            "<< /Filter /Standard /V 1 /R 2 /O <\(hex(owner))> /U <\(hex(user))> /P \(permissions) >>"
        )
        let trailer = "/Encrypt \(encryptObject) 0 R /ID [<\(hex(fileID))> <\(hex(fileID))>]"
        return try write(encryptedBodies, label: label, trailerExtra: trailer)
    }

    static func rc4(key: [UInt8], _ input: [UInt8]) -> [UInt8] {
        var state = Array(0...255).map(UInt8.init)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(state[i]) + Int(key[i % key.count])) & 0xFF
            state.swapAt(i, j)
        }
        var i = 0
        j = 0
        return input.map { byte in
            i = (i + 1) & 0xFF
            j = (j + Int(state[i])) & 0xFF
            state.swapAt(i, j)
            return byte ^ state[(Int(state[i]) + Int(state[j])) & 0xFF]
        }
    }
}
