import AppKit
import Observation
import SwiftUI
import ZPDFDesignSystem

/// "Undid Change Colour (12 Markups)" over the canvas for a moment after ⌘Z (NL-UX-12).
///
/// Estimators fear a total that changed without them seeing why. The Edit menu names the step,
/// but nothing on the canvas said what an undo just took back; this says it where the eyes are,
/// for 1.5 s, announces it to VoiceOver, and appears without motion under Reduce Motion.
@MainActor
@Observable
public final class UndoToastModel {

    /// The line on screen, or `nil`.
    public private(set) var message: String?
    /// Bumped per message so a late hide from an older one cannot clear a newer one.
    @ObservationIgnored private var generation = 0
    /// How long a message stays.
    @ObservationIgnored public var duration: Duration = .milliseconds(1500)
    /// Posts the VoiceOver announcement; injectable so a test can count announcements.
    @ObservationIgnored public var announce: @MainActor (String) -> Void = { text in
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    public init() {}

    /// The text for an undo or a redo of a named step.
    public static func text(undid actionName: String, isRedo: Bool) -> String? {
        let name = actionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return String(
            format: isRedo
                ? NSLocalizedString("Redid %@", comment: "Canvas toast after Redo; the placeholder is the step's name")
                : NSLocalizedString("Undid %@", comment: "Canvas toast after Undo; the placeholder is the step's name"),
            name
        )
    }

    /// Shows a line and hides it after ``duration``.
    public func show(_ text: String) {
        generation &+= 1
        let token = generation
        message = text
        announce(text)
        let duration = self.duration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, self.generation == token else { return }
            self.message = nil
        }
    }

    /// Hides at once.
    public func dismiss() {
        generation &+= 1
        message = nil
    }
}

/// The toast's view: a pill with the line, or nothing.
public struct UndoToastView: View {
    let model: UndoToastModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: UndoToastModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            if let message = model.message {
                Text(message)
                    .zpdfText(.control, .textPrimary)
                    .padding(.horizontal, ZPDFSpacing.l)
                    .padding(.vertical, ZPDFSpacing.s)
                    .zpdfControlBackground(fill: .elevated, cornerRadius: ZPDFRadius.large)
                    .transition(ZPDFMotion.transition(.opacity, reduceMotion: reduceMotion))
                    // Announced by the model; the pill itself is not a stop for VoiceOver.
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .zpdfAnimation(ZPDFMotion.quick, value: model.message)
        .allowsHitTesting(false)
    }
}

/// A hosting view that never takes a click: the toast floats over the canvas and must not
/// swallow the drawing's input under it.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
