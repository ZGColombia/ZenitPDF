import Foundation

/// What is armed right now, said in one value: which preset, out of which set, in which mode.
///
/// # Why this is not just `activePreset`
///
/// The mode belongs to the **set the armed preset came from**, not to the panel that happens
/// to be open (``ToolLibraryPresenting/armedSetMode``). So an estimator can arm a stamp out of
/// `Project Tools`, browse `My Tools`, and be looking at a panel that says *Draw* while the
/// next click drops a stamp. Every surface that reports the armed state has to report the same
/// three facts or it will contradict another one; this is the one place they are assembled.
public struct ArmedToolState: Hashable, Sendable {

    /// The armed preset's name, for example `"Door Count"`.
    public let presetName: String
    /// The set it came from, for example `"Project Tools"`.
    public let setName: String
    /// The mode that set is in.
    public let mode: ToolSetMode

    /// Creates an armed-tool state.
    public init(presetName: String, setName: String, mode: ToolSetMode) {
        self.presetName = presetName
        self.setName = setName
        self.mode = mode
    }

    /// Whether the mode, not the tool, decides what the next click does.
    ///
    /// True for Apply and Place, which disarm both drawing families. In Draw the armed tool is
    /// a real tool and names itself; there is nothing here that the tool name does not say.
    public var modeDecidesTheClick: Bool { !mode.collectsDrawingGesture }

    /// The status bar's Tool segment while a mode is armed: `"Place · Door Count"`.
    ///
    /// The mode comes first because it is the part that changes what a click means. Before
    /// this the segment read `"Select"` while Place was armed — the name of a tool the canvas
    /// was not in — the cursor's old mismatch, stated in words instead of in pixels.
    public var indicatorText: String {
        String(
            format: NSLocalizedString(
                "%1$@ · %2$@",
                comment: "Status bar tool segment while a tool-set mode is armed: mode, then preset name"
            ),
            mode.displayName,
            presetName
        )
    }

    /// The Tool Library panel's banner: what the next click does, and which set decided that.
    public var bannerText: String {
        String(
            format: NSLocalizedString(
                "%1$@ armed from %2$@: %3$@",
                comment: "Tool Library armed banner: mode name, set name, what a click does"
            ),
            mode.displayName,
            setName,
            mode.shortHelp
        )
    }

    /// The spoken form, so the banner is not a visual-only signal.
    public var accessibilityDescription: String {
        String(
            format: NSLocalizedString(
                "%1$@ is armed in %2$@ mode, from %3$@. %4$@",
                comment: "Spoken armed-tool state: preset name, mode, set name, what a click does"
            ),
            presetName,
            mode.displayName,
            setName,
            mode.shortHelp
        )
    }
}

extension ToolLibraryPresenting {

    /// The armed preset, its set and that set's mode, or `nil` when nothing is armed.
    public var armedToolState: ArmedToolState? {
        guard let preset = activePreset else { return nil }
        return ArmedToolState(
            presetName: preset.name,
            setName: preset.panel.displayName,
            mode: mode(of: preset.panel)
        )
    }

    /// The armed state, but only when the **mode** is what decides the next click.
    ///
    /// This is what the status bar and the canvas cursor ask for: in Draw the armed tool is a
    /// real tool and every existing surface already names it correctly, so overriding those
    /// surfaces would be noise. In Apply and Place nothing else in the window is telling the
    /// truth about the pointer, which is the whole of the defect.
    public var armedModeState: ArmedToolState? {
        guard let state = armedToolState, state.modeDecidesTheClick else { return nil }
        return state
    }

    /// The cursor the canvas must show, given the tool it has armed.
    ///
    /// - Parameter tool: what the canvas armed. Pass ``ZenitToolMode/select`` when the canvas
    ///   is in its resting state — which is precisely the case Apply and Place produce, since
    ///   both disarm the drawing families.
    public func canvasCursorKind(tool: ZenitToolMode) -> CanvasCursorKind {
        CanvasCursorKind.resolve(
            tool: tool,
            setMode: armedSetMode,
            hasArmedPreset: activePreset != nil
        )
    }
}
