import Foundation

/// A half-open range of character offsets into the formula source.
///
/// Offsets count `Character`s, not UTF-8 bytes, so a span is stable under any input the user can
/// type into a column editor. `end` is exclusive.
public struct FormulaSourceSpan: Hashable, Sendable, CustomStringConvertible {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = Swift.min(start, end)
        self.end = Swift.max(start, end)
    }

    /// A span for nodes that were synthesised rather than parsed.
    public static let synthetic = FormulaSourceSpan(start: 0, end: 0)

    public var length: Int { end - start }

    /// The smallest span covering both operands. Used to give a binary node the extent of its
    /// whole sub-expression rather than just its operator.
    public func merged(with other: FormulaSourceSpan) -> FormulaSourceSpan {
        FormulaSourceSpan(start: Swift.min(start, other.start), end: Swift.max(end, other.end))
    }

    /// Extracts the covered text from a source string, clamping to its bounds.
    public func text(in source: String) -> String {
        let characters = Array(source)
        guard !characters.isEmpty else { return "" }
        let low = Swift.max(0, Swift.min(start, characters.count))
        let high = Swift.max(low, Swift.min(end, characters.count))
        return String(characters[low..<high])
    }

    public var description: String { "\(start)..<\(end)" }
}
