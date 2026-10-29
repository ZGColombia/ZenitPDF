import Foundation
import Testing
import ZPDFQPDF
import ZPDFTestingSupport

/// Decryption and encryption carry-over against the encrypted fixture.
///
/// The fixture is written by CoreGraphics with a known user password and 128-bit
/// standard security. Note that qpdf rejects the fixture's *owner* password:
/// CoreGraphics does not produce an `/O` entry that qpdf's owner-password check
/// accepts, so every test here authenticates with the user password. That is a
/// property of the fixture generator, not of this bridge.
@Suite("Encryption")
struct EncryptionTests {

    private var userPassword: String { ZPDFFixtures.encryptedUserPassword }

    @Test("an encrypted file refuses to open without a password")
    func refusesWithoutPassword() throws {
        let box = try Sandbox("noPassword")
        let input = try box.fixture(.encryptedUserPassword)

        expectQPDFError("passwordRequired") {
            _ = try QPDF.inspect(input)
        }
        // An empty password is not a password.
        expectQPDFError("passwordRequired") {
            _ = try QPDF.inspect(input, password: "")
        }
    }

    @Test("an encrypted file refuses to open with the wrong password")
    func refusesWrongPassword() throws {
        let box = try Sandbox("wrongPassword")
        let input = try box.fixture(.encryptedUserPassword)
        let output = box.file("should-not-exist.pdf")

        expectQPDFError("passwordIncorrect") {
            _ = try QPDF.inspect(input, password: userPassword + "x")
        }
        expectQPDFError("passwordIncorrect") {
            _ = try QPDF.decrypt(input: input, output: output, password: "definitely-not-it")
        }
        // A refused operation writes nothing at all, not even a partial file.
        #expect(FileManager.default.fileExists(atPath: output.path) == false)
        #expect(
            FileManager.default.fileExists(atPath: output.path + ".zpdf-partial") == false,
            "a failed write must not leave its temporary behind")
    }

    @Test("inspection reports the encryption parameters and permissions")
    func reportsEncryptionParameters() throws {
        let box = try Sandbox("encryptionInventory")
        let input = try box.fixture(.encryptedUserPassword)

        let inventory = try QPDF.inspect(input, password: userPassword)
        let encryption = try #require(inventory.encryption)

        #expect(encryption.revision == 4)
        #expect(encryption.keyBits == 128)
        #expect(encryption.userPasswordMatched)
        #expect(encryption.ownerPasswordMatched == false)
        // The fixture forbids high-resolution printing; that restriction is
        // exactly what the permission bits are for.
        #expect(encryption.allowsPrintHighResolution == false)
        print(
            "[encryption] R=\(encryption.revision) key=\(encryption.keyBits) bits "
                + "P=\(encryption.permissions)")
    }

    @Test("the correct password decrypts into a file anyone can open")
    func decryptsWithCorrectPassword() throws {
        let box = try Sandbox("decrypt")
        let input = try box.fixture(.encryptedUserPassword)
        let output = box.file("decrypted.pdf")

        try timed("decrypt") {
            try QPDF.decrypt(input: input, output: output, password: userPassword)
        }

        let after = try QPDF.inspect(output)
        #expect(after.isEncrypted == false)
        #expect(after.pageCount == 1)
        // PDFKit opens it with no password at all — independent proof that the
        // encryption really is gone rather than merely unreported.
        #expect(IndependentReader.pageCount(of: output) == 1)
    }

    @Test("contradictory write options are refused before anything is read")
    func contradictoryOptionsRefused() throws {
        let box = try Sandbox("contradiction")
        let input = try box.fixture(.encryptedUserPassword)
        let output = box.file("nope.pdf")

        // X-029: the retired removesRestrictions/preservesEncryption pair was this case; qdf
        // output, which forces encryption off, contradicts preservesEncryption the same way.
        let options = QPDFWriteOptions(preservesEncryption: true, qdf: true)
        expectQPDFError("invalidArgument") {
            _ = try QPDF.repair(
                input: input, output: output, password: userPassword, writeOptions: options)
        }
        #expect(FileManager.default.fileExists(atPath: output.path) == false)
    }

    @Test("encryption can be carried across to the new file")
    func preservesEncryptionWhenAsked() throws {
        let box = try Sandbox("preserve")
        let input = try box.fixture(.encryptedUserPassword)
        let output = box.file("still-encrypted.pdf")

        try QPDF.repair(
            input: input,
            output: output,
            password: userPassword,
            writeOptions: QPDFWriteOptions(preservesEncryption: true))

        expectQPDFError("passwordRequired") { _ = try QPDF.inspect(output) }
        let after = try QPDF.inspect(output, password: userPassword)
        #expect(after.isEncrypted)
    }
}
