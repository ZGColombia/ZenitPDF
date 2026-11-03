import CoreGraphics
import Foundation
import OSLog
import Vision

/// The order in which Vision's text recogniser is tried, shared by the page recognition run
/// (``OCRService``) and the region reads of the app tier (`RegionTextRecognizer`).
///
/// ### Why there is more than one attempt
///
/// On macOS 27 the default (revision 3) `.accurate` recogniser can throw instead of reading. On
/// a virtual Mac with no Neural Engine every `.accurate` call threw, revision 2 included, and only
/// `.fast` read. On Apple silicon the default revision is reported to read once per process and
/// then throw, while revision 2 `.accurate` and `.fast` kept reading. Until 1.0.1 the thrown error
/// was swallowed and the page was reported as having no text.
///
/// So the request runs first exactly as its caller configured it. Only when Vision **throws** is
/// it tried again at revision 2 `.accurate`, then at `.fast`, and the first attempt that does not
/// throw is the answer. An attempt that returns no observations has read the image and found
/// nothing: that is an answer, not a failure, and it does not fall through. On a Mac where the
/// first attempt works, nothing changes.
///
/// Each thrown attempt and each fallback that reads is logged (subsystem
/// `com.zenitgroup.zenitpdf`, category `ocr`) with the attempt, the error domain and the error
/// code. Never recognised text, a file name or a path (spec 17.4).
public enum TextRecognitionFallback {

    /// One way of running the request.
    public enum Attempt: String, Sendable, Hashable, CaseIterable {
        /// The request as its caller configured it: the default revision, the caller's level.
        case configured
        /// Revision 2 at `.accurate`.
        case accurateRevision2
        /// `.fast` at the default revision.
        case fast
    }

    /// What the recognition was for, as the log names it.
    public enum Purpose: String, Sendable {
        /// A page, or one tile of a page, of a recognition run.
        case page
        /// A region of a page read for one command.
        case region
    }

    /// Runs one attempt's request on the image. ``performWithVision(_:_:_:)`` is the live one; a
    /// test passes its own to make chosen attempts throw.
    public typealias Perform = (Attempt, VNRecognizeTextRequest, CGImage) throws -> Void

    /// Recognises the text in `image`, falling back as described above.
    ///
    /// - Parameters:
    ///   - accurate: whether the caller asks for `.accurate`. A `.fast` request has nothing to
    ///     fall back to and runs once.
    ///   - languages: the BCP-47 codes asked for. Each attempt keeps the ones its own request
    ///     supports, and keeps Vision's default when none is.
    ///   - purpose: what the read is for, for the log.
    ///   - configure: sets the caller's other options, such as language correction and custom
    ///     words. The level, the revision and the languages are the attempt's.
    ///   - perform: runs one attempt; Vision unless a test says otherwise.
    /// - Returns: the observations of the first attempt that did not throw.
    /// - Throws: the first attempt's error, when every attempt threw.
    public static func recognize(
        image: CGImage,
        accurate: Bool,
        languages: [String],
        purpose: Purpose,
        configure: (VNRecognizeTextRequest) -> Void = { _ in },
        perform: Perform = TextRecognitionFallback.performWithVision
    ) throws -> [VNRecognizedTextObservation] {
        try firstSuccess(of: attempts(accurate: accurate), purpose: purpose) { attempt in
            let request = makeRequest(
                for: attempt, accurate: accurate, languages: languages, configure: configure
            )
            try perform(attempt, request, image)
            return request.results ?? []
        }
    }

    /// Hands `request` to Vision. Blocks the calling thread for as long as recognition takes.
    public static func performWithVision(
        _ attempt: Attempt,
        _ request: VNRecognizeTextRequest,
        _ image: CGImage
    ) throws {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    }

    /// Logs a read that threw in every attempt, by the error's domain and code, for a caller that
    /// goes on without text.
    public static func logFailure(_ error: any Error, purpose: Purpose) {
        let failure = error as NSError
        logger.error(
            "\(purpose.rawValue, privacy: .public) text recognition threw in every attempt (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)); nothing was read"
        )
    }

    // MARK: - The chain

    /// The attempts, in order, for a request at `accurate` on an OS with `supportedRevisions`.
    static func attempts(
        accurate: Bool,
        supportedRevisions: IndexSet = VNRecognizeTextRequest.supportedRevisions
    ) -> [Attempt] {
        guard accurate else { return [.configured] }
        return supportedRevisions.contains(2)
            ? [.configured, .accurateRevision2, .fast]
            : [.configured, .fast]
    }

    /// Runs `perform` for each attempt in order and returns the first result that did not throw.
    ///
    /// The seam the chain's tests drive: `perform` stands for one Vision call.
    static func firstSuccess<Value>(
        of attempts: [Attempt],
        purpose: Purpose,
        perform: (Attempt) throws -> Value
    ) throws -> Value {
        var firstError: (any Error)?
        for attempt in attempts {
            do {
                let value = try perform(attempt)
                if firstError != nil {
                    logger.notice(
                        "\(purpose.rawValue, privacy: .public) text recognition read with the \(attempt.rawValue, privacy: .public) fallback"
                    )
                }
                return value
            } catch {
                let failure = error as NSError
                logger.error(
                    "\(purpose.rawValue, privacy: .public) text recognition attempt \(attempt.rawValue, privacy: .public) threw (\(failure.domain, privacy: .public) \(failure.code, privacy: .public))"
                )
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? NoAttempt()
    }

    /// The request one attempt runs.
    static func makeRequest(
        for attempt: Attempt,
        accurate: Bool,
        languages: [String],
        configure: (VNRecognizeTextRequest) -> Void
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        switch attempt {
        case .configured:
            request.recognitionLevel = accurate ? .accurate : .fast
        case .accurateRevision2:
            // By number: the named revision constant is deprecated.
            request.revision = 2
            request.recognitionLevel = .accurate
        case .fast:
            request.recognitionLevel = .fast
        }
        configure(request)
        if !languages.isEmpty {
            // Keep only the codes this request has. A drawing set in a language this machine,
            // revision or level does not carry must still be read in the languages it does.
            let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
            let usable = languages.filter { supported.contains($0) }
            if !usable.isEmpty { request.recognitionLanguages = usable }
        }
        return request
    }

    /// An empty list of attempts. ``attempts(accurate:supportedRevisions:)`` never returns one.
    struct NoAttempt: Error {}

    static let logger = Logger(subsystem: "com.zenitgroup.zenitpdf", category: "ocr")
}
