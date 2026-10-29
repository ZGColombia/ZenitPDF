import AppKit
import CoreGraphics
import SwiftUI
import ZPDFUIPresentation

// The one place where a presentation value becomes something drawable.
//
// `ZPDFUIPresentation` stores colours as `ColorRGBA` and tools as `MeasurementKind`, both free of
// AppKit so they stay `Sendable` and `Codable` across actor boundaries. Every surface package
// needs the same two translations, and before this file each of them wrote its own — which is how
// the four copies of the measurement-icon table drifted apart. The translations live here now,
// once, and the surface packages call them.

// MARK: - Colour

extension ColorRGBA {

    /// The same colour as a design-system ``ZPDFRGBA``.
    public var zpdfRGBA: ZPDFRGBA {
        ZPDFRGBA(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }

    /// The same colour as a non-dynamic `NSColor` in the sRGB space.
    public var nsColor: NSColor { zpdfRGBA.nsColor }

    /// The same colour as a `CGColor` in the sRGB space, for layer-backed drawing.
    public var cgColor: CGColor { zpdfRGBA.nsColor.cgColor }

    /// The same colour as a SwiftUI `Color` in the sRGB space.
    public var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// Reads a colour back out of AppKit, which is what a colour well hands over.
    ///
    /// The colour is converted into sRGB first. A colour that cannot be represented in sRGB —
    /// a pattern or a catalogue colour with no numeric components — has no honest storage value,
    /// so it falls back to opaque white rather than producing arbitrary components.
    public init(nsColor: NSColor) {
        // BH-131: the fallback must itself be an sRGB colour. `NSColor.white` lives in the
        // Generic Gray space, and reading `redComponent` from it raises
        // NSInvalidArgumentException — the fallback that was meant to store white crashed.
        let resolved = nsColor.usingColorSpace(.sRGB)
            ?? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            alpha: Double(resolved.alphaComponent)
        )
    }

    /// Reads a colour back out of SwiftUI.
    public init(swiftUIColor: Color) {
        self.init(nsColor: NSColor(swiftUIColor))
    }
}

extension ZPDFRGBA {

    /// The same colour as a presentation-layer ``ColorRGBA``.
    public var presentationColor: ColorRGBA {
        ColorRGBA(
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            alpha: Double(alpha)
        )
    }
}

// MARK: - Measurement icons

extension ZPDFIconKind {

    /// The Zenit-drawn icon that stands for a measurement tool.
    ///
    /// This is the app's single measurement-icon table. Kinds that share a reading share a glyph:
    /// a dimension and a temporary measure are both a straight length; both cutout shapes are the
    /// cutout glyph; a three-point circle reads as a radius, matching
    /// ``MeasurementKind/primaryField``; and every sloped variant reads as slope, because slope is
    /// what distinguishes it from the flat tool beside it in the picker.
    public init(measurementKind kind: MeasurementKind) {
        switch kind {
        case .length, .dimension, .temporaryMeasure: self = .length
        case .polylength: self = .polylength
        case .perimeter: self = .perimeter
        case .area: self = .area
        case .rectangleArea: self = .rectangleArea
        case .ellipseArea: self = .ellipseArea
        case .polygonCutout, .ellipseCutout: self = .cutout
        case .volume: self = .volume
        case .wallArea: self = .wallArea
        case .count: self = .count
        case .radius, .threePointCircle: self = .radius
        case .diameter: self = .diameter
        case .angle: self = .angle
        case .slope, .riseDrop, .trueSlopedLength, .trueSlopedArea: self = .slope
        case .arcLength: self = .arc
        }
    }
}

extension ZPDFGlyph {

    /// The glyph that stands for a measurement tool.
    public static func measurement(for kind: MeasurementKind) -> ZPDFGlyph {
        .measurement(ZPDFIconKind(measurementKind: kind))
    }
}
