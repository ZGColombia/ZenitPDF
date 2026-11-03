import AppKit

/// Off-screen rendering for the canvas pixel tests, at a resolution and in a colour space the
/// test states instead of the ones the machine happens to have.
///
/// `bitmapImageRepForCachingDisplay(in:)` takes both from the display: its backing scale and
/// its colour profile. A 1.25 pt stroke centred on a whole point fills two device pixels at 2x,
/// but at 1x it covers each of the two pixels it straddles by only 62 %, so on a 1x display a
/// correctly drawn line reads back as a blend toward the paper. A canvas view in no window
/// already places its rasters for 2x (`CanvasPageView.effectiveBackingScale`), so 2x is the
/// default here.
@MainActor
extension AppTestSupport {

    /// Draws `view` through `cacheDisplay(in:to:)` into a bitmap of `scale` device pixels per
    /// point. The bitmap is tagged sRGB before anything is drawn, so its bytes are sRGB on every
    /// machine; untagged device RGB means the display profile once a window-server connection
    /// exists. Read it with ``NSBitmapImageRep/sRGBColorAt(x:y:)``.
    static func renderOffscreen(_ view: NSView, scale: CGFloat = 2) -> NSBitmapImageRep {
        let device = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((view.bounds.width * scale).rounded(.up)),
            pixelsHigh: Int((view.bounds.height * scale).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let rep = device.retagging(with: .sRGB) ?? device
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

extension NSBitmapImageRep {

    /// The pixel at (`x`, `y`) in sRGB, read from its bytes in the colour space the bitmap is
    /// tagged with; `nil` outside the bitmap or for a layout other than 8-bit RGBA.
    ///
    /// Not `colorAt(x:y:)`: that builds its colour from the colour-space *name*, so on a bitmap
    /// retagged sRGB it reports the bytes as Generic RGB, and #1A55CF drawn in reads back as
    /// #1F6DD8.
    func sRGBColorAt(x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < pixelsWide, y < pixelsHigh,
              bitsPerSample == 8, samplesPerPixel == 4, hasAlpha else { return nil }
        var sample = [Int](repeating: 0, count: 4)
        getPixel(&sample, atX: x, y: y)
        let alphaFirst = bitmapFormat.contains(.alphaFirst)
        let alpha = CGFloat(alphaFirst ? sample[0] : sample[3]) / 255
        var components = (alphaFirst ? Array(sample[1...3]) : Array(sample[0...2])).map { CGFloat($0) / 255 }
        if !bitmapFormat.contains(.alphaNonpremultiplied), alpha > 0 {
            components = components.map { min(1, $0 / alpha) }
        }
        components.append(alpha)
        return NSColor(colorSpace: colorSpace, components: components, count: components.count)
            .usingColorSpace(.sRGB)
    }
}
