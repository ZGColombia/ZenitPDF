import Foundation

/// Collects indirect objects and hands `RawPDFWriter` a provider over them.
///
/// Two-phase construction is supported: `reserve()` claims an object number before its
/// body is known, which is what a page tree needs, since `/Pages` must list its kids
/// and each kid must point back at `/Pages`.
final class PDFObjectTable {
    private var bodies: [PDFObjectBody?] = []

    var count: Int { bodies.count }

    /// Claims the next object number without supplying a body yet.
    func reserve() -> Int {
        bodies.append(nil)
        return bodies.count
    }

    /// Appends an object and returns its number.
    @discardableResult
    func add(_ body: PDFObjectBody) -> Int {
        bodies.append(body)
        return bodies.count
    }

    /// Appends a verbatim object and returns its number.
    @discardableResult
    func add(_ text: String) -> Int {
        add(.verbatim(text))
    }

    /// Fills in a previously reserved object.
    func set(_ number: Int, _ body: PDFObjectBody) {
        guard number >= 1, number <= bodies.count else { return }
        bodies[number - 1] = body
    }

    /// Fills in a previously reserved object with a verbatim body.
    func set(_ number: Int, _ text: String) {
        set(number, .verbatim(text))
    }

    /// A provider for `RawPDFWriter`. Throws if any reserved object was never filled,
    /// which would otherwise produce a silently broken file.
    func provider(kind: FixtureKind) -> (Int) throws -> PDFObjectBody? {
        let snapshot = bodies
        return { number in
            guard number >= 1, number <= snapshot.count else {
                throw FixtureError.generationFailed(kind: kind, reason: "object \(number) out of range")
            }
            guard let body = snapshot[number - 1] else {
                throw FixtureError.generationFailed(kind: kind, reason: "object \(number) was reserved but never filled")
            }
            return body
        }
    }
}
