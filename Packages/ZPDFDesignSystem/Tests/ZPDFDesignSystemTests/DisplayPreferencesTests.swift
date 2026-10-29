import AppKit
import SwiftUI
import Testing
@testable import ZPDFDesignSystem

/// NL-PLAT-20: Reduce Transparency makes the status pill's tint a solid surface, and Differentiate
/// Without Color gives each severity a border that differs in greyscale. Checked as the paint rule
/// and as rendered pixels (an off-screen hosting view, never shown).
@MainActor
@Suite("Display preferences — Reduce Transparency, Differentiate Without Color")
struct DisplayPreferencesTests {

    @Test("The paint rule: translucent by default, solid under Reduce Transparency, shaped borders under Differentiate Without Color")
    func paintRule() {
        let plain = ZPDFStatusPillPaint.paint(severity: .warning, preferences: .init())
        #expect(plain.fillOpacity == 0.14 && !plain.solidSurface && plain.dash.isEmpty)
        let solid = ZPDFStatusPillPaint.paint(severity: .warning, preferences: .init(reduceTransparency: true))
        #expect(solid.solidSurface && solid.fillOpacity == 1 && solid.strokeOpacity == 1)
        let shaped = [ZPDFSeverity.warning, .danger, .success].map {
            ZPDFStatusPillPaint.paint(severity: $0, preferences: .init(differentiateWithoutColor: true))
        }
        #expect(shaped[0].dash == [3, 2])
        #expect(shaped[1].strokeWidth == ZPDFStroke.regular * 2 && shaped[1].dash.isEmpty)
        #expect(shaped[2].dash == [1, 2])
        #expect(Set(shaped.map { "\($0.dash)-\($0.strokeWidth)" }).count == 3, "three severities, three shapes")
    }

    static func render(_ preferences: ZPDFDisplayPreferences) -> [UInt8] {
        let view = NSHostingView(rootView: ZPDFStatusPill(severity: .warning, title: "Scale inherited")
            .environment(\.zpdfDisplayPreferences, preferences)
            .padding(4))
        view.frame = NSRect(x: 0, y: 0, width: 180, height: 32)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    @Test("Each setting changes the rendered pill")
    func renderingChanges() {
        let plain = Self.render(.init())
        let solid = Self.render(.init(reduceTransparency: true))
        let shaped = Self.render(.init(differentiateWithoutColor: true))
        #expect(!plain.isEmpty)
        #expect(plain != solid, "Reduce Transparency repaints the fill")
        #expect(plain != shaped, "Differentiate Without Color repaints the border")
    }
}
