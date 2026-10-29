import Foundation

extension ToolPresetSummary {

    /// The drawing tool this preset arms when its set is in Draw, or `nil` when it arms none.
    ///
    /// A measuring preset arms its measurement tool; any other preset arms its markup tool when
    /// that family can draw the kind (``ZenitToolMode/isDrawable(_:)``, the honest-refusal
    /// rule); a kind nobody can draw by hand arms nothing. The app core's Draw-mode arming
    /// lights exactly this tool in the toolbar, and Select when it is `nil`
    /// (`AppCoreEnvironment.onLibraryArmedTool`, X-018).
    public var drawingTool: ZenitToolMode? {
        if let kind = measurementKind { return .measure(kind) }
        return ZenitToolMode.isDrawable(markupKind) ? .markup(markupKind) : nil
    }
}
