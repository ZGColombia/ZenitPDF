import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Live finding LT-3: the warning tray read "The drawing says 1:50.." because the scale
/// proposal's headline is composed from a notation and already ended a sentence, while the
/// surface that showed it appended a full stop of its own.
///
/// These tests pin the join, not the callers: whatever punctuation a headline arrives with,
/// the composed line ends each sentence exactly once.
@Suite("Warning sentence composition")
struct AppWarningSentenceTests {

    /// The title the scale proposal actually posts — the notation is substituted into a
    /// template that already carries the full stop.
    private func scaleProposalTitle(notation: String) -> String {
        String(format: "The drawing says %@.", notation)
    }

    private func proposalWarning(notation: String) -> AppWarning {
        AppWarning(
            id: UUID(),
            severity: .info,
            title: scaleProposalTitle(notation: notation),
            message: "Found in the title block (SKALA \(notation)). Apply it, or calibrate by hand as usual.",
            source: "Scale proposal",
            actionTitle: "Apply \(notation)",
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: The reported defect

    @Test("LT-3: the tray line for a scale proposal never doubles the full stop")
    func trayLineHasNoDoublePeriod() {
        let warning = proposalWarning(notation: "1:50")

        // The composition the tray used to do by hand, kept here so the test states what it
        // is defending against rather than only what it wants.
        let naive = "\(warning.title). \(warning.message)"
        #expect(naive.contains(".."), "The naive join is the defect; if it stopped producing '..' this test is no longer about LT-3")

        #expect(!warning.trayMessage.contains(".."))
        #expect(warning.trayMessage.hasPrefix("The drawing says 1:50. Found in the title block"))
        #expect(warning.trayMessage.hasSuffix("calibrate by hand as usual."))
    }

    @Test("LT-3: VoiceOver reads the same line without a doubled full stop")
    func accessibilityLabelHasNoDoublePeriod() {
        let warning = proposalWarning(notation: "1:50")
        #expect(!warning.accessibilityLabel.contains(".."))
        #expect(warning.accessibilityLabel.hasPrefix("Information. The drawing says 1:50. Found in the title block"))
    }

    @Test(
        "LT-3: the sentence ends once whatever the notation trails",
        arguments: ["1:50", "1:50.", "1:50..", "1:50 .", "1:50   "]
    )
    func oneFullStopWhateverTheNotationCarries(notation: String) {
        let composed = AppWarning.sentences(scaleProposalTitle(notation: notation))
        #expect(composed.hasPrefix("The drawing says 1:50"))
        #expect(composed.hasSuffix("."))
        #expect(!composed.contains(".."), "Composed: \(composed)")
        // Exactly one full stop in the whole sentence — the ratio itself carries none.
        #expect(composed.filter { $0 == "." }.count == 1, "Composed: \(composed)")
    }

    // MARK: The primitive

    @Test("A headline with no terminator gains exactly one full stop")
    func addsMissingFullStop() {
        #expect(AppWarning.terminated("Scale changed after measuring") == "Scale changed after measuring.")
    }

    @Test("A run of full stops collapses to one")
    func collapsesRuns() {
        #expect(AppWarning.terminated("Ready...") == "Ready.")
        #expect(AppWarning.terminated("Ready ..  ") == "Ready.")
    }

    @Test("A question or an exclamation keeps its own terminator")
    func keepsOtherTerminators() {
        #expect(AppWarning.terminated("Which scale applies?") == "Which scale applies?")
        #expect(AppWarning.terminated("Stop!") == "Stop!")
        #expect(AppWarning.terminated("Reading…") == "Reading…")
    }

    @Test("An abbreviation is left readable")
    func abbreviationSurvives() {
        // "e.g." must not lose its internal stops, and must not gain a second terminal one.
        #expect(AppWarning.terminated("Use a stated dimension, e.g.") == "Use a stated dimension, e.g.")
    }

    @Test("Terminating is idempotent")
    func idempotent() {
        let once = AppWarning.terminated("The drawing says 1:50..")
        #expect(AppWarning.terminated(once) == once)
        #expect(once == "The drawing says 1:50.")
    }

    @Test("Empty and whitespace-only parts drop out instead of leaving a stranded stop")
    func emptyPartsDropOut() {
        #expect(AppWarning.terminated("") == "")
        #expect(AppWarning.terminated("   ") == "")
        #expect(AppWarning.terminated("...") == "")
        #expect(AppWarning.sentences("Information", "", "  ") == "Information.")
    }

    @Test("A warning with no detail reads as one sentence")
    func emptyMessageMakesOneSentence() {
        let warning = AppWarning(
            id: UUID(),
            severity: .warning,
            title: "Scale changed after measuring",
            message: "",
            source: "Scale",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        #expect(warning.trayMessage == "Scale changed after measuring.")
        #expect(warning.accessibilityLabel == "Warning. Scale changed after measuring.")
    }

    @Test("Every sample warning composes without a doubled full stop")
    func sampleWarningsAreClean() {
        let warnings = ZenitSampleProject.shared.warnings
        #expect(!warnings.isEmpty)
        for warning in warnings {
            #expect(!warning.trayMessage.contains(".."), "\(warning.trayMessage)")
            #expect(!warning.accessibilityLabel.contains(".."), "\(warning.accessibilityLabel)")
            #expect(warning.trayMessage.hasSuffix("."))
        }
    }
}

/// CR-105 — the other half of LT-3's shape.
///
/// `terminated` tested for `?`/`!`/`…` **before** stripping a trailing run of full stops, so a
/// question mark hiding behind a stray stop fell through to the strip and had the stop put
/// straight back on. Old output, against the code before the fix:
///
/// ```
/// ✘ Test "A question mark behind a stray full stop is not given a second terminator" recorded
///   an issue at AppWarningSentenceTests.swift:151:9: Expectation failed:
///   (AppWarning.terminated("Replace the scale?.") → "Replace the scale?.") == "Replace the scale?"
/// ✘ Test "A composed tray line ends a question exactly once" recorded an issue at
///   AppWarningSentenceTests.swift:180:9: Expectation failed:
///   (warning.trayMessage → "Replace the scale?. The drawing says 1:50.")
///   == "Replace the scale? The drawing says 1:50."
/// ✘ Suite "Sentence terminators after ? and !" failed after 0.008 seconds with 7 issues.
/// ```
@Suite("Sentence terminators after ? and !")
struct AppWarningTerminatorTests {

    @Test("A question mark behind a stray full stop is not given a second terminator")
    func terminatorIsNotDoubledAfterAQuestionMark() {
        #expect(AppWarning.terminated("Replace the scale?.") == "Replace the scale?")
        #expect(AppWarning.terminated("Replace the scale?..") == "Replace the scale?")
        #expect(AppWarning.terminated("Replace the scale? .") == "Replace the scale?")
        #expect(AppWarning.terminated("Stop!.") == "Stop!")
        #expect(AppWarning.terminated("Stop! ") == "Stop!")
        #expect(AppWarning.terminated("Wait….") == "Wait…")
    }

    @Test("The cases the strip already handled still hold")
    func plainCasesAreUnchanged() {
        #expect(AppWarning.terminated("The drawing says 1:50") == "The drawing says 1:50.")
        #expect(AppWarning.terminated("The drawing says 1:50.") == "The drawing says 1:50.")
        #expect(AppWarning.terminated("The drawing says 1:50..") == "The drawing says 1:50.")
        #expect(AppWarning.terminated("The drawing says 1:50 .") == "The drawing says 1:50.")
        #expect(AppWarning.terminated("Really?") == "Really?")
        #expect(AppWarning.terminated("") == "")
        #expect(AppWarning.terminated("...") == "")
    }

    @Test("A composed tray line ends a question exactly once")
    func composedLineKeepsOneTerminator() {
        let warning = AppWarning(
            id: UUID(),
            severity: .warning,
            title: "Replace the scale?.",
            message: "The drawing says 1:50..",
            source: "Scale",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        #expect(warning.trayMessage == "Replace the scale? The drawing says 1:50.")
        #expect(!warning.trayMessage.contains("?."))
    }
}
