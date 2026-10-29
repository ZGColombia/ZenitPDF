import Foundation
import ZPDFContracts
import ZPDFSnapEngine

/// Vector Snap on every sheet (K-01).
///
/// The snap index used to be built for the first page at open, and again for the page on screen
/// only when a PDF layer was hidden. On page 2 and later `TakeoffSession.resolveSnap` found no
/// index, the presenters' `try?` turned that into "no candidate", and snapping silently did
/// nothing. The environment now asks ``AppCoreEnvironment/snapIndexSource`` for a page's index
/// the first time the page is on screen. Once installed, the session keeps every index in step
/// with each mutation, undo and redo (ADR-0030 §5.7), so an index built late still carries the
/// markups drawn before it.
extension AppCoreEnvironment {

    /// What building one page's snap index produced.
    public struct SnapIndexBuild: Sendable {
        /// The installed index's availability, or `nil` when nothing could be installed.
        public var availability: SnapIndexAvailability?
        /// Why the page's vector geometry could not be read, already localized; `nil` when it
        /// was read, or when the page simply has none.
        public var failureReason: String?

        public init(availability: SnapIndexAvailability? = nil, failureReason: String? = nil) {
            self.availability = availability
            self.failureReason = failureReason
        }
    }

    /// Makes sure the page has a snap index, and shows the availability of the page on screen.
    ///
    /// A page whose index is installed shows it at once. Otherwise the canvas and the status bar
    /// say the index is being built while ``snapIndexSource`` runs, and the result is shown only
    /// if the page is still the one on screen when it lands.
    func ensureSnapIndex(forPage pageID: UUID) {
        guard !snapIndexBuildsInFlight.contains(pageID) else {
            showSnapIndexBuilding()
            return
        }
        let session = self.session
        Task { @MainActor [weak self] in
            if let availability = await session.snapAvailability(page: PageID(pageID)) {
                self?.showSnapIndex(availability, failureReason: nil, forPage: pageID)
                return
            }
            guard let self, let source = self.snapIndexSource,
                  let page = await session.pageDescriptors.first(where: { $0.id.rawValue == pageID }),
                  !self.snapIndexBuildsInFlight.contains(pageID) else { return }
            self.snapIndexBuildsInFlight.insert(pageID)
            if self.document.currentPageID == pageID { self.showSnapIndexBuilding() }
            let build = await source(page)
            self.snapIndexBuildsInFlight.remove(pageID)
            self.snapIndexFailures[pageID] = build.failureReason
            self.showSnapIndex(build.availability, failureReason: build.failureReason, forPage: pageID)
        }
    }

    private func showSnapIndexBuilding() {
        canvas.setVectorSnapAvailable(false)
        status.updateGeometryIndex(.building(progress: 0))
    }

    private func showSnapIndex(_ availability: SnapIndexAvailability?, failureReason: String?, forPage pageID: UUID) {
        guard document.currentPageID == pageID else { return }
        setVectorSnapAvailability(availability)
        // A failed extraction is not a scanned sheet (BH-353): say what happened.
        if let reason = failureReason ?? snapIndexFailures[pageID] {
            status.updateGeometryIndex(.failed(reason: reason))
        }
    }
}
