import Foundation
import ZPDFEngineBarrier

/// The boundary between Swift's error handling and PDFKit's.
///
/// PDFKit is Objective-C, and Objective-C reports some malformed input by *raising*
/// rather than by returning nil. An `NSException` unwinds straight past Swift frames and
/// calls `std::terminate`: it cannot be caught with `do`/`catch`, cannot be turned into a
/// typed error at the call site, and kills the process. That is a remote-crash primitive
/// in an application whose entire input is files other people wrote.
///
/// The concrete case this package hit, found by byte-level mutation fuzzing:
/// `-[PDFDocument documentAttributes]` enumerates `/Info` into an `NSMutableDictionary`
/// and inserts without checking, so an `/Info` key CoreGraphics reports but PDFKit cannot
/// map raises `NSInvalidArgumentException`. It is not reachable only through the obvious
/// getter — PDFKit calls it internally while building a page layout, so
/// `characterBounds(at:)`, `string`, `selection(from:to:)` and everything else that
/// touches text reach it too. Reproducing seeds: 372734462224352 (direct) and
/// 578343136699809 (via `characterBounds(at:)`).
///
/// **What catching an exception costs.** The framework that raised is left in whatever
/// state it was in. This barrier therefore does not pretend the operation partially
/// succeeded: it converts the raise into ``PDFBridgeError/engineRaised(operation:name:reason:)``
/// and the caller abandons that operation. It is a way to fail typed instead of dying,
/// not a way to carry on.
enum EngineBarrier {

    /// Runs `body` with an Objective-C exception barrier around it.
    ///
    /// - Parameter operation: what was attempted, for the typed error. A short verb
    ///   phrase such as `"pageText"`.
    static func guarded<T>(_ operation: String, _ body: () throws -> T) throws -> T {
        var value: T?
        var thrown: (any Error)?
        let raised = ZPDFRunCatchingObjCException {
            do { value = try body() } catch { thrown = error }
        }
        if let raised {
            throw PDFBridgeError.engineRaised(
                operation: operation,
                name: raised.name,
                reason: raised.reason
            )
        }
        if let thrown { throw thrown }
        guard let value else {
            // Unreachable: the block either assigns, throws, or raises.
            throw PDFBridgeError.engineRaised(
                operation: operation,
                name: "ZPDFBarrierInvariant",
                reason: "the guarded block produced neither a value nor an error"
            )
        }
        return value
    }

    /// The non-throwing form, for a body that cannot fail on its own.
    static func guarded(_ operation: String, _ body: () -> Void) throws {
        _ = try guarded(operation) { () throws -> Bool in
            body()
            return true
        }
    }
}
