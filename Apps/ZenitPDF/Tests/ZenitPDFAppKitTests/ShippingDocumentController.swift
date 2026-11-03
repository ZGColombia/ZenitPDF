import AppKit
@testable import ZenitPDFAppKit

@MainActor
extension AppTestSupport {

    /// The process's shared document controller, held once it is made.
    private static var shippingDocumentController: ZenitDocumentController?

    /// Makes the shipping ``ZenitDocumentController`` this process's `NSDocumentController.shared`,
    /// once, as `ZenitApplicationDelegate` does at launch.
    ///
    /// The first document controller created stays `NSDocumentController.shared` for the life of
    /// the process; a later `ZenitDocumentController()` hands back that object, whatever its
    /// class. Any `NSDocument` save or close reaches for the shared controller, so without this
    /// the first test to touch a document left a plain `NSDocumentController` in charge. A plain
    /// controller has no `documentClass(forType:)` for the project type and resolves a
    /// `.zpdfproj` only through LaunchServices, which knows the type only on a Mac where the
    /// app is registered: the ⌘O tests passed there and opened a project as a PDF on a clean
    /// runner, and none of them ever reached the shipping controller's own routing.
    ///
    /// ``AppTierSerialisation`` calls this before any test in the target runs.
    static func installShippingDocumentController() {
        guard shippingDocumentController == nil else { return }
        shippingDocumentController = ZenitDocumentController()
    }
}
