import AppKit
import Foundation
import SwiftUI
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIShell

/// The warning tray's environment: the mock presenters with a status presenter over `warnings`.
@MainActor
func warningTrayEnvironment(_ warnings: [AppWarning]) -> ProjectShellEnvironment {
    let mocks = MockPresenters.makeEnvironment()
    return ProjectShellEnvironment(
        document: mocks.document, canvas: mocks.canvas, ledger: mocks.ledger, toolLibrary: mocks.toolLibrary,
        search: mocks.search, compare: mocks.compare, measurement: mocks.measurement,
        status: LiveTest5TrayStatus(warnings)
    )
}

/// The sizes a SwiftUI popover's hosting controller reads off the warning tray (L-32).
///
/// The status strip shows the tray with `.popover`, which hosts it in an `NSHostingController`.
/// With the default sizing options (minimum size, intrinsic size, maximum size), the controller
/// asks the tray three questions and hands the answers to AppKit:
///
/// - **ideal**: an unspecified proposal. This is the preferred content size the popover asks
///   for, read here from `preferredContentSize` with `sizingOptions = .preferredContentSize`.
/// - **minimum**: a zero proposal. It becomes a required minimum-size constraint on the
///   popover's content. In a binary stamped like the app (macOS 14 SDK), the same controller
///   as a window's content sets `contentMinSize` to exactly this value.
/// - **maximum**: an unbounded proposal.
///
/// The popover can be no shorter than the minimum, so the height it gives the tray is the
/// larger of the minimum and the ideal (the ideal capped by the maximum). The old test measured
/// only the height at a fixed width under an unbounded proposal. That is the ideal, and it was
/// right all along; the minimum was the one at fault.
@MainActor
struct WarningTrayPopoverSizing {
    let ideal: CGSize
    let minimum: CGSize
    let maximum: CGSize

    init(_ warnings: [AppWarning]) {
        let preferred = NSHostingController(rootView: WarningTrayView(environment: warningTrayEnvironment(warnings)))
        preferred.sizingOptions = .preferredContentSize
        preferred.view.layoutSubtreeIfNeeded()
        ideal = preferred.preferredContentSize
        let measuring = NSHostingController(rootView: WarningTrayView(environment: warningTrayEnvironment(warnings)))
        minimum = measuring.sizeThatFits(in: .zero)
        maximum = measuring.sizeThatFits(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
    }

    /// The popover's content width: the tray's ideal width.
    var width: CGFloat { ideal.width }

    /// The height the popover gives the tray: never under the minimum.
    var height: CGFloat { max(minimum.height, min(ideal.height, maximum.height)) }
}

/// L-32 (live check of the installed L-28 re-fix, 2026-10-03): with one notice, the status
/// strip's "1 notice" popover was far taller than its content. About 180 pt of empty space sat
/// above the NOTICES header, the card ran to the window's bottom edge, and the popover lay over
/// its own button. Headless: nothing is ever ordered on screen.
@MainActor
@Suite("L-32 — the warning tray's popover is as tall as its content", .shellTierSerialised)
struct L32WarningTrayPopoverSizeTests {

    /// The live notice: a scale proposal, dismissible, with its Apply action.
    static let scaleOffer = AppWarning(
        id: UUID(), severity: .info, title: "The drawing says 1:50.",
        message: "Found in the title block (SKALA 1:50). Apply it, or calibrate by hand as usual.",
        source: "Scale proposal", actionTitle: "Apply 1:50", isDismissible: true,
        timestamp: Date(timeIntervalSince1970: 0)
    )

    static let thirtyWarnings = (0..<30).map { index in
        AppWarning(id: UUID(), severity: .warning, title: "Warning \(index)", message: "Detail.",
                   source: "Source \(index % 3)", timestamp: Date(timeIntervalSince1970: Double(index)))
    }

    /// Old output (xctest): ideal 380 × 184 pt, minimum 112 × 490 pt, so a 490 pt popover for a
    /// 184 pt tray. In a binary stamped with the macOS 14 SDK, as the app is: ideal 180, minimum
    /// 502, and `contentMinSize` 112 × 502. The tray was centred in the extra height, about
    /// 160 pt above the header and the same below. The old `.frame(width: 380)` gave a
    /// 380 × 180 minimum; L-28's flexible width let the zero proposal wrap every row at 112 pt,
    /// and the list's fixed vertical size reported it at its 420 pt cap.
    @Test("L-32: one notice — the popover's height is the tray's content, header to Dismiss all")
    func oneNoticePopoverHeight() throws {
        let sizing = WarningTrayPopoverSizing([Self.scaleOffer])
        print("lv5 L-32: one notice: ideal \(sizing.ideal), minimum \(sizing.minimum), maximum \(sizing.maximum), popover height \(sizing.height)")
        #expect(sizing.width == WarningTrayView.width)
        // No question the popover asks can make it taller than the content.
        #expect(sizing.minimum.height <= sizing.ideal.height, "minimum \(sizing.minimum) is taller than the ideal \(sizing.ideal)")
        #expect(sizing.maximum.height == sizing.ideal.height, "maximum \(sizing.maximum) differs from the ideal \(sizing.ideal)")
        #expect(sizing.height == sizing.ideal.height)
        // Header, one caption, one card, Dismiss all and the padding: well under 200 pt.
        #expect(sizing.height < 200, "the popover gives one notice \(sizing.height) pt")

        // Rendered at the popover's size, the content fills it: the header's text sits in the
        // header band at the top, and below the Dismiss button there is only the padding.
        let render = try renderTray([Self.scaleOffer], width: sizing.width, height: sizing.height, name: "tray-popover-one")
        let ink = render.ink.rowRuns(columns: 0...render.ink.size.width)
        let top = try #require(ink.first?.lowerBound)
        let bottom = try #require(ink.last?.upperBound)
        print("lv5 L-32: one notice rendered at \(render.ink.size): ink from \(top) to \(bottom) pt")
        #expect(top <= ZPDFSpacing.l + ZPDFSpacing.Control.panelHeader,
                "empty space above the header: the first ink is at \(top) pt")
        #expect(render.ink.size.height - bottom <= ZPDFSpacing.l + 3,
                "empty space under the Dismiss button: the last ink ends at \(bottom) of \(render.ink.size.height) pt")
        #expect(scrollViews(in: render.host).isEmpty, "one notice is a plain stack")
    }

    @Test("L-32: thirty warnings — the list stops at its 420 pt cap and scrolls in one scroll view")
    func thirtyWarningsPopoverHeight() throws {
        let sizing = WarningTrayPopoverSizing(Self.thirtyWarnings)
        print("lv5 L-32: thirty warnings: ideal \(sizing.ideal), minimum \(sizing.minimum), maximum \(sizing.maximum), popover height \(sizing.height)")
        #expect(sizing.minimum.height <= sizing.ideal.height)
        #expect(sizing.maximum.height == sizing.ideal.height)
        #expect(sizing.height == sizing.ideal.height)
        // The cap plus the header, the Dismiss button and the padding.
        #expect(sizing.height > WarningTrayView.maximumListHeight + ZPDFSpacing.Control.panelHeader)
        #expect(sizing.height <= WarningTrayView.maximumListHeight + 100, "the list stops growing at its limit: \(sizing.height) pt")

        let render = try renderTray(Self.thirtyWarnings, width: sizing.width, height: sizing.height, name: "tray-popover-thirty")
        let scrolls = scrollViews(in: render.host)
        #expect(scrolls.count == 1, "a long list scrolls in exactly one scroll view")
        let scroll = try #require(scrolls.first)
        print("lv5 L-32: thirty warnings: scroll view \(scroll.frame.size)")
        #expect(abs(scroll.frame.height - WarningTrayView.maximumListHeight) < 0.5, "the list area is \(scroll.frame.height) pt, the cap is \(WarningTrayView.maximumListHeight)")
    }

    @Test("L-32: the list area's height is its rows', capped, and never more than its host offers")
    func listHeightRule() {
        let cap = WarningTrayView.maximumListHeight
        #expect(TrayListHeightLayout.height(rows: 90, cap: cap, offered: nil) == 90, "ideal: the rows")
        #expect(TrayListHeightLayout.height(rows: 900, cap: cap, offered: nil) == cap, "ideal: capped")
        #expect(TrayListHeightLayout.height(rows: 90, cap: cap, offered: .infinity) == 90, "maximum: the rows, not the cap")
        #expect(TrayListHeightLayout.height(rows: 900, cap: cap, offered: 0) == 0, "minimum: nothing")
        #expect(TrayListHeightLayout.height(rows: 900, cap: cap, offered: 300) == 300, "a shorter host: what it offers, and the list scrolls")
        #expect(TrayListHeightLayout.height(rows: 90, cap: cap, offered: 300) == 90, "a taller host: still the rows")
    }
}
