import Foundation
import Observation

/// Presents the status bar and the warning tray.
@MainActor
public protocol StatusPresenting: ZenitPresenting {

    /// Everything the status bar shows, as one atomic value.
    var snapshot: StatusBarSnapshot { get }
    /// Outstanding warnings, most serious first.
    var warnings: [AppWarning] { get }

    /// Turns Grid Snap on or off.
    func setGridSnapEnabled(_ enabled: Bool)
    /// Turns Vector Snap on or off. Has no effect on a page without vector content.
    func setVectorSnapEnabled(_ enabled: Bool)
    /// Turns Markup Snap on or off.
    func setMarkupSnapEnabled(_ enabled: Bool)
    /// Turns reuse-tool on or off.
    func setReuseToolEnabled(_ enabled: Bool)
    /// Names the armed tool in the status bar, with an honest note when the tool is
    /// incomplete — arming a tool must be visible and true.
    func setActiveTool(name: String, note: String?)
    /// Dismisses one warning.
    func dismissWarning(id: AppWarning.ID)
    /// Dismisses every dismissible warning.
    func dismissAllWarnings()
}

extension StatusPresenting {

    /// Replaces only the active tool's note, keeping its name — the one-line channel a
    /// spoken refusal travels (a refusal must never be silent).
    public func setActiveToolNote(_ note: String?) {
        setActiveTool(name: snapshot.activeToolName, note: note)
    }


    /// The most serious outstanding severity, or `nil` when the tray is empty.
    public var highestSeverity: AppWarningSeverity? { warnings.map(\.severity).max() }
}
