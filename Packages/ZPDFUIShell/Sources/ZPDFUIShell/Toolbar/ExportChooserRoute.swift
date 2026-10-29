import Foundation

extension ProjectShellEnvironment {

    /// What the toolbar's Export chip does: the chooser of every export when the app wired
    /// one, the ledger export otherwise (nl-ux).
    public func presentExportChooser() {
        if let onPresentExportChooser {
            onPresentExportChooser()
        } else {
            perform(.export)
        }
    }
}
