import Foundation

/// A seeded 64-bit PRNG for fuzzing.
///
/// Not `SystemRandomNumberGenerator`: a fuzz failure that cannot be replayed from its
/// seed is an anecdote, not a bug report.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The mutation corpus: valid and hostile fixtures, and the operators that damage them.
public enum FuzzCorpus {

    /// Kinds small enough to mutate thousands of times in a test's time budget.
    public static let kinds: [FixtureKind] = [
        .rectangle, .lShape, .polygonOneHole, .bezierCircle, .nestedFormXObjects,
        .clippedContent, .hugeMalformedOperatorStream, .rotation90,
        .cropBoxNegativeOrigin, .mixedPageSizes, .titleBlockSheet,
        .truncatedFile, .brokenXref, .cyclicPageTree, .missingObject,
        .deeplyNestedForms, .embeddedFileWithLaunchAction, .javaScriptAction
    ]

    /// Every kind's generation outcome, in `kinds` order, computed once per process.
    private static let generated: [(kind: FixtureKind, bytes: [UInt8]?, failure: String?)] = kinds.map { kind in
        do {
            return (kind, [UInt8](try ZPDFFixtures.data(kind).data), nil)
        } catch {
            return (kind, nil, "\(error)")
        }
    }

    /// Generated once per process, in a `static let`, so parallel suites only read.
    ///
    /// A kind whose generation throws is left out, which shrinks the corpus and remaps
    /// what every seed picks. That is never silent: the failure is listed in
    /// `generationFailures`, and `isComplete` is `false`, so a fuzz suite can assert
    /// the corpus it thinks it is fuzzing is the corpus it has.
    public static let bytes: [[UInt8]] = generated.compactMap(\.bytes)

    /// Kinds that failed to generate, with the error each one threw. Empty when the
    /// whole corpus is present.
    public static let generationFailures: [FixtureKind: String] = Dictionary(
        uniqueKeysWithValues: generated.compactMap { entry in
            entry.failure.map { (entry.kind, $0) }
        }
    )

    /// `true` when every kind in `kinds` generated, so `bytes[i]` is `kinds[i]` and a
    /// recorded seed replays against the document it originally picked.
    public static var isComplete: Bool { bytes.count == kinds.count }

    /// The seed for one iteration. Reported on failure, and enough to replay it alone.
    public static func seed(base: UInt64, iteration: Int) -> UInt64 {
        base &+ UInt64(iteration) &* 0x0000_0100_0000_01B3
    }

    public static func pick(_ generator: inout SplitMix64) -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        return bytes[Int.random(in: 0..<bytes.count, using: &generator)]
    }

    /// Applies one to eight damage operators.
    ///
    /// - Parameter preserveLength: when `true`, only operators that keep the byte count
    ///   are used, so every cross-reference offset in the file stays valid and the
    ///   document still opens. That is what drives the corruption *past* the parser and
    ///   into the content-stream scanner, page layout and annotation reader; a
    ///   length-changing mutation usually just gets the file refused at open.
    public static func mutate(_ base: [UInt8], generator: inout SplitMix64, preserveLength: Bool) -> Data {
        var bytes = base
        guard !bytes.isEmpty else { return Data() }
        let lengthPreserving = [0, 1, 2, 5]
        for _ in 0..<Int.random(in: 1...8, using: &generator) {
            guard !bytes.isEmpty else { break }
            let choice = preserveLength
                ? (lengthPreserving.randomElement(using: &generator) ?? 0)
                : Int.random(in: 0..<8, using: &generator)
            switch choice {
            case 0: // flip one bit
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                bytes[index] ^= UInt8(1 << Int.random(in: 0..<8, using: &generator))
            case 1: // one random byte
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                bytes[index] = UInt8.random(in: 0...255, using: &generator)
            case 2: // one byte from the set that means something to a PDF lexer
                let interesting: [UInt8] = [0x00, 0x0A, 0x0D, 0x20, 0x25, 0x2F, 0x3C, 0x3E, 0x5B, 0x5D, 0x80, 0xFF]
                let index = Int.random(in: 0..<bytes.count, using: &generator)
                bytes[index] = interesting.randomElement(using: &generator) ?? 0
            case 3: // truncate
                bytes = Array(bytes[0..<Int.random(in: 0..<bytes.count, using: &generator)])
            case 4: // delete a run
                let start = Int.random(in: 0..<bytes.count, using: &generator)
                let length = min(bytes.count - start, Int.random(in: 1...512, using: &generator))
                bytes.removeSubrange(start..<(start + length))
            case 5: // overwrite a structural keyword in place
                let keywords = ["xref", "trailer", "startxref", "/Length", "endstream", "endobj", "/Root", "/Kids"]
                let keyword = Array((keywords.randomElement(using: &generator) ?? "xref").utf8)
                if let at = firstOccurrence(of: keyword, in: bytes, generator: &generator) {
                    for offset in 0..<keyword.count where at + offset < bytes.count {
                        bytes[at + offset] = UInt8.random(in: 0x41...0x5A, using: &generator)
                    }
                }
            case 6: // an integer a parser might multiply by something
                let hostile = ["999999999999999999", "-999999999999", "0", "2147483647", "-2147483648", "1e309", "nan"]
                if let range = numberRun(in: bytes, generator: &generator) {
                    bytes.replaceSubrange(range, with: Array((hostile.randomElement(using: &generator) ?? "0").utf8))
                }
            default: // splice in a run, for allocation pressure
                let filler = [UInt8](
                    repeating: UInt8.random(in: 0...255, using: &generator),
                    count: Int.random(in: 1...4096, using: &generator)
                )
                bytes.insert(contentsOf: filler, at: Int.random(in: 0...bytes.count, using: &generator))
            }
        }
        return Data(bytes)
    }

    private static func numberRun(in bytes: [UInt8], generator: inout SplitMix64) -> Range<Int>? {
        guard !bytes.isEmpty else { return nil }
        var index = Int.random(in: 0..<bytes.count, using: &generator)
        for _ in 0..<min(bytes.count, 4096) {
            if bytes[index] >= 0x30, bytes[index] <= 0x39 {
                var start = index
                while start > 0, bytes[start - 1] >= 0x30, bytes[start - 1] <= 0x39 { start -= 1 }
                var end = index
                while end < bytes.count, bytes[end] >= 0x30, bytes[end] <= 0x39 { end += 1 }
                return start..<end
            }
            index = (index + 1) % bytes.count
        }
        return nil
    }

    private static func firstOccurrence(
        of needle: [UInt8],
        in haystack: [UInt8],
        generator: inout SplitMix64
    ) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        var hits: [Int] = []
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                hits.append(start)
                if hits.count >= 32 { break }
            }
        }
        return hits.randomElement(using: &generator)
    }
}
