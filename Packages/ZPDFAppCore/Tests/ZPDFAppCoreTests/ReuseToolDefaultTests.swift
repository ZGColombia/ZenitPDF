import Testing
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// A measuring tool stays armed after it commits.
///
/// Reported 2026-08-26: measuring one length or area and then another needed the tool clicked
/// again, because it did not stay armed. Taking off two hundred wall runs is two hundred
/// measurements, not two hundred tool choices.
///
/// The mechanism was already correct; the default was not. `MeasurementInputConfiguration`
/// has defaulted `reusesToolAfterCommit` to `true` since it was written, the mock presenter
/// defaulted to `true`, and the sample project sets `true` — only the shipping presenter said
/// `false`, and because the toolbar acts on that one, that one decided.
@MainActor
struct ReuseToolDefaultTests {

    @Test("A fresh tool library reuses the tool after a commit")
    func defaultIsOn() {
        let library = AppToolLibraryPresenter()
        #expect(
            library.reuseToolEnabled,
            "the tool disarms after every measurement; the estimator has to re-pick it each time"
        )
        #expect(library.markupCommitted(), "the caller was told to return to Select")
    }

    @Test("Turning it off returns to Select after a commit, as it always did")
    func theSwitchStillWorks() {
        let library = AppToolLibraryPresenter()
        library.setReuseToolEnabled(false)
        #expect(library.reuseToolEnabled == false)
        #expect(library.markupCommitted() == false, "with reuse off the caller must return to Select")

        library.setReuseToolEnabled(true)
        #expect(library.markupCommitted())
    }

    @Test("The shipping presenter and the mock agree on the default")
    func theTwoPresentersAgree() {
        // They disagreed for months, and the disagreement was the bug: every test that used the
        // mock saw the expected behaviour, and the application did not.
        #expect(AppToolLibraryPresenter().reuseToolEnabled == MockToolLibraryPresenter().reuseToolEnabled)
    }
}
