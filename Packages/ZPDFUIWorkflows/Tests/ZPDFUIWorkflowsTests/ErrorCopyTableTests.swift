import Foundation
import Testing
@testable import ZPDFUIWorkflows

/// Walks the whole failure vocabulary and asserts that every case says four things in plain
/// language: what happened, why, what to do next, and what the safe way out is.
///
/// The table is the only place in Zenit where failure copy lives, so this suite is the only place
/// that has to guard it. A new ``ZPDFErrorKind`` cannot ship without copy, because the switch is
/// exhaustive and these assertions run over `allCases`.
@Suite("User-facing error copy", .workflowsTierSerialised)
struct ErrorCopyTableTests {

    /// Words that mean nothing to a person holding a set of drawings.
    private static let bannedTokens: Set<String> = [
        "nil", "null", "nserror", "errno", "exception", "stacktrace", "traceback",
        "sql", "sqlite", "json", "utf8", "api", "uuid", "xml", "codec", "malloc",
        "segfault", "assertion", "deadlock", "mutex", "throw", "unwrap", "descriptor"
    ]

    private func tokens(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { !$0.isEmpty }
        )
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @Test("Every case has a title, a message, a recovery and a safe default action")
    func everyCaseIsComplete() {
        for kind in ZPDFErrorKind.allCases {
            let copy = ZPDFErrorCopyTable.copy(for: ZPDFUserFacingError(kind: kind))
            #expect(!isBlank(copy.title), "\(kind.rawValue) has no title")
            #expect(!isBlank(copy.message), "\(kind.rawValue) has no message")
            #expect(!isBlank(copy.recovery), "\(kind.rawValue) has no recovery")
            #expect(!isBlank(copy.primaryActionTitle), "\(kind.rawValue) has no primary action")
            if let secondary = copy.secondaryActionTitle {
                #expect(!isBlank(secondary), "\(kind.rawValue) has an empty secondary action")
            }
        }
    }

    @Test("The four sentences are actually four different sentences")
    func sentencesAreDistinct() {
        for kind in ZPDFErrorKind.allCases {
            let copy = ZPDFErrorCopyTable.copy(for: ZPDFUserFacingError(kind: kind))
            #expect(copy.title != copy.message, "\(kind.rawValue) repeats its title as the message")
            #expect(copy.message != copy.recovery, "\(kind.rawValue) repeats its message as the recovery")
            #expect(
                copy.primaryActionTitle != copy.secondaryActionTitle,
                "\(kind.rawValue) offers the same action twice"
            )
        }
    }

    @Test("No format placeholder survives into what a person reads")
    func placeholdersAreResolved() {
        for kind in ZPDFErrorKind.allCases {
            let copy = ZPDFErrorCopyTable.copy(for: ZPDFUserFacingError(kind: kind))
            for text in [copy.title, copy.message, copy.recovery, copy.primaryActionTitle] {
                #expect(!text.contains("%@"), "\(kind.rawValue) leaks a %@ placeholder")
                #expect(!text.contains("%1$@"), "\(kind.rawValue) leaks a positional placeholder")
                #expect(!text.contains("%d"), "\(kind.rawValue) leaks a %d placeholder")
            }
        }
    }

    @Test("No jargon reaches the primary message")
    func copyIsFreeOfJargon() {
        for kind in ZPDFErrorKind.allCases {
            let copy = ZPDFErrorCopyTable.copy(for: ZPDFUserFacingError(kind: kind))
            for text in [copy.title, copy.message, copy.recovery, copy.primaryActionTitle] {
                let leaked = tokens(in: text).intersection(Self.bannedTokens)
                #expect(leaked.isEmpty, "\(kind.rawValue) uses jargon: \(leaked.sorted())")
            }
        }
    }

    @Test("An error code is never the headline")
    func supportReferenceStaysOutOfTheCopy() {
        for kind in ZPDFErrorKind.allCases {
            let error = ZPDFUserFacingError(kind: kind, technicalDetail: "code 4711")
            let copy = ZPDFErrorCopyTable.copy(for: error)
            #expect(!copy.message.contains("4711"))
            #expect(!copy.title.contains(kind.rawValue))
        }
    }

    @Test("Every case reads as its own situation")
    func titlesAreUnique() {
        let titles = ZPDFErrorKind.allCases.map {
            ZPDFErrorCopyTable.copy(for: ZPDFUserFacingError(kind: $0)).title
        }
        #expect(Set(titles).count == titles.count, "Two failures share a title")
    }

    @Test("The subject the caller supplies reaches the message")
    func subjectIsSubstituted() {
        for kind in ZPDFErrorKind.allCases {
            let error = ZPDFUserFacingError(
                kind: kind,
                subject: "Ground Floor Plan.pdf",
                secondarySubject: "Rev C"
            )
            let copy = ZPDFErrorCopyTable.copy(for: error)
            #expect(
                copy.message.contains("Ground Floor Plan.pdf"),
                "\(kind.rawValue) drops the subject it was given"
            )
        }
    }

    @Test("A blank subject falls back to a readable noun")
    func blankSubjectFallsBack() {
        for kind in ZPDFErrorKind.allCases {
            let copy = ZPDFErrorCopyTable.copy(for: ZPDFUserFacingError(kind: kind, subject: "   "))
            let fallback = ZPDFErrorCopyTable.fallbackSubject(for: kind)
            #expect(copy.message.contains(fallback), "\(kind.rawValue) has no readable fallback noun")
        }
    }

    @Test("The situations gate G15 has to cover are all present")
    func requiredSituationsExist() {
        let required: [ZPDFErrorKind] = [
            .documentUnreadable,
            .documentEncrypted,
            .noVectorContentForSnap,
            .scaleMissing,
            .incompatibleUnits,
            .exportPathNotWritable,
            .projectRecoveryAvailable
        ]
        for kind in required {
            #expect(ZPDFErrorKind.allCases.contains(kind))
        }
    }

    /// R-119. The app hands every failure to AppKit's `presentError`, which reads it through the
    /// `NSError` bridge. Old output for all three kinds below: localizedDescription
    /// "The operation couldn’t be completed. (ZPDFUIWorkflows.ZPDFUserFacingError error 1.)" and
    /// no recovery suggestion at all, because the type had no `LocalizedError` conformance.
    @Test("A tool set failure reaches AppKit with its written copy, not an error code")
    func bridgedErrorCarriesTheCopy() throws {
        let cases: [ZPDFUserFacingError] = [
            ZPDFUserFacingError(kind: .toolSetFileTooLarge, subject: "Office.zpdftools", secondarySubject: "8 MB"),
            ZPDFUserFacingError(kind: .toolSetFileUnreadable, subject: "Office.zpdftools"),
            ZPDFUserFacingError(kind: .toolSetPictureNotKept, subject: "Door Stamp")
        ]
        for error in cases {
            let copy = ZPDFErrorCopyTable.copy(for: error)
            let bridged = error as NSError
            #expect(bridged.localizedDescription == copy.title, "\(error.kind.rawValue)")
            #expect(bridged.localizedFailureReason == copy.message, "\(error.kind.rawValue)")
            let suggestion = try #require(bridged.localizedRecoverySuggestion)
            // AppKit's alert shows only the description and the suggestion, so the suggestion
            // carries the why and then the what-next.
            #expect(suggestion.hasPrefix(copy.message), "\(error.kind.rawValue)")
            #expect(suggestion.hasSuffix(copy.recovery), "\(error.kind.rawValue)")
            #expect(!bridged.localizedDescription.contains("ZPDFUserFacingError"))
            #expect(!bridged.localizedDescription.contains("error 1"))
        }
    }
}
