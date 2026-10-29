#!/usr/bin/env bash
#
# generate-app-icon.sh — regenerate every Zenit PDF icon raster from the master geometry.
#
# Produces, under Resources/Icons/:
#   AppIcon.icns              app icon, all ten macOS representations
#   AppIcon.appiconset/       the same rasters plus Contents.json, for an Xcode asset catalog
#   ProjectDocument.icns      document icon for .zpdfproj project packages
#
# Rasteriser
# ----------
# The design master is Resources/Icons/AppIcon.svg. This machine has no SVG
# rasteriser that is safe to depend on (no rsvg-convert, no cairosvg, no
# Inkscape; qlmanage does not render SVG reliably headless), so the rasters are
# drawn by a small CoreGraphics program embedded below. It encodes exactly the
# geometry and colour stops that AppIcon.svg declares — see the constants block
# in the Swift source, which mirrors the SVG one-for-one. The upside over an
# external rasteriser is that the output is byte-identical on any Mac with a
# Swift toolchain, with nothing to install.
#
# Every size is drawn from vectors at its own pixel resolution rather than
# downsampled from 1024, and the drawing-sheet ground detail (drafting grid,
# dimension line) is omitted below 128 px where it cannot resolve. See
# Resources/Icons/README.md.
#
# Usage:  Scripts/generate-app-icon.sh [--keep-work]
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ICONS_DIR="${REPO_ROOT}/Resources/Icons"
KEEP_WORK=0

for arg in "$@"; do
  case "$arg" in
    --keep-work) KEEP_WORK=1 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- preflight

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: required tool '$1' not found" >&2; exit 1; }
}
need swift
need iconutil
need sips

probe() { command -v "$1" >/dev/null 2>&1 && echo "  $1: $(command -v "$1")" || echo "  $1: not installed"; }
echo "rasteriser probe (informational — the embedded CoreGraphics renderer is used regardless):"
probe rsvg-convert
probe inkscape
probe qlmanage
probe sips
probe python3
python3 -c 'import cairosvg' >/dev/null 2>&1 \
  && echo "  python3 cairosvg: available" || echo "  python3 cairosvg: not installed"
echo

mkdir -p "${ICONS_DIR}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zenit-icon.XXXXXX")"
cleanup() { [ "${KEEP_WORK}" -eq 1 ] && echo "work kept at ${WORK}" || rm -rf "${WORK}"; }
trap cleanup EXIT

# ---------------------------------------------------------------- renderer

cat > "${WORK}/ZenitIconRenderer.swift" <<'SWIFT'
// Zenit PDF icon renderer.
//
// Mirrors Resources/Icons/AppIcon.svg. Every constant below appears in the SVG;
// if you change one, change both. Coordinates are on the 1024 x 1024 master
// canvas with y increasing downwards, matching SVG.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// ---------------------------------------------------------------- palette
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func col(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat((hex >> 16) & 0xFF) / 255,
                                           CGFloat((hex >> 8) & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, alpha])!
}
let zenitCyan: UInt32 = 0x50D6DE      // measurement accent, document icon only
let graphite:  UInt32 = 0x101317      // deep graphite, shading only
let graphite2: UInt32 = 0x171B21      // graphite surface, document ink only

// Brand mark, redrawn 2026-08-26 from the Zenit reference artwork.
let navyLight: UInt32 = 0x33456B      // ground, towards the light
let navyDeep:  UInt32 = 0x1B2438      // ground, away from it
let ringLight: UInt32 = 0x7C9CCB
let ringMid:   UInt32 = 0x4C6795
let ringDeep:  UInt32 = 0x2E3F60
let bevelLit:  UInt32 = 0xCFE0F7
let redLight:  UInt32 = 0xE8434F
let red:       UInt32 = 0xD8202F
let redDeep:   UInt32 = 0x96121D
let ribbonLit: UInt32 = 0xF0505C
let ribbonMid: UInt32 = 0xC01B28
let ribbonDeep: UInt32 = 0x7E0F18

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

// ---------------------------------------------------------------- geometry
// Body: 824 square, 100 inset, corner radius 0.225 x 824, corner smoothing 0.6.
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185.4
let cornerSmoothing: CGFloat = 0.6

// Ring: centre 512,512, band 72 wide.
let ringCentre = CGPoint(x: 512, y: 512)
let ringOuter: CGFloat = 272
let ringInner: CGFloat = 200

// Ribbon: annular sectors between these radii, tapering to a point at one end.
let ribbonOuter: CGFloat = 302
let ribbonInner: CGFloat = 236

// Monogram grid.
let zx0: CGFloat = 344, zx1: CGFloat = 680        // datum bar span, width 336
let zy0: CGFloat = 356, zy1: CGFloat = 668        // cap span, height 312
let zWeight: CGFloat = 64                         // datum bar weight
let zTerminal: CGFloat = 18                       // vertical terminal at the diagonal junction
let zRun: CGFloat = 168                           // diagonal horizontal run over 184 vertical

/// Continuous-curvature rounded rectangle — the macOS app-icon silhouette.
/// Each corner is bezier / arc / bezier so curvature is continuous across the
/// joins, which a plain circular-arc rounded rect is not.
func squircle(_ rect: CGRect, radius R: CGFloat, smoothing s: CGFloat) -> CGPath {
    let p = (1 + s) * R
    let arcMeasure = (CGFloat.pi / 2) * (1 - s)
    let arcSection = sin(arcMeasure / 2) * R * sqrt(2)
    let alpha = (CGFloat.pi / 4) * s
    let c = R * tan(alpha / 2) * cos(alpha)
    let d = c * tan(alpha)
    let b = (p - arcSection - c - d) / 3
    let a = 2 * b
    let abc = a + b + c
    let x0 = rect.minX, y0 = rect.minY, x1 = rect.maxX, y1 = rect.maxY
    let path = CGMutablePath()
    func corner(_ centre: CGPoint) {
        let cur = path.currentPoint
        path.addRelativeArc(center: centre, radius: R,
                            startAngle: atan2(cur.y - centre.y, cur.x - centre.x), delta: arcMeasure)
    }
    path.move(to: pt(x0 + p, y0))
    path.addLine(to: pt(x1 - p, y0))
    path.addCurve(to: pt(x1 - p + abc, y0 + d),
                  control1: pt(x1 - p + a, y0), control2: pt(x1 - p + a + b, y0))
    corner(pt(x1 - R, y0 + R)); var u = path.currentPoint
    path.addCurve(to: pt(x1, y0 + p), control1: pt(u.x + d, u.y + c), control2: pt(u.x + d, u.y + b + c))
    path.addLine(to: pt(x1, y1 - p))
    path.addCurve(to: pt(x1 - d, y1 - p + abc),
                  control1: pt(x1, y1 - p + a), control2: pt(x1, y1 - p + a + b))
    corner(pt(x1 - R, y1 - R)); u = path.currentPoint
    path.addCurve(to: pt(x1 - p, y1), control1: pt(u.x - c, u.y + d), control2: pt(u.x - b - c, u.y + d))
    path.addLine(to: pt(x0 + p, y1))
    path.addCurve(to: pt(x0 + p - abc, y1 - d),
                  control1: pt(x0 + p - a, y1), control2: pt(x0 + p - a - b, y1))
    corner(pt(x0 + R, y1 - R)); u = path.currentPoint
    path.addCurve(to: pt(x0, y1 - p), control1: pt(u.x - d, u.y - c), control2: pt(u.x - d, u.y - b - c))
    path.addLine(to: pt(x0, y0 + p))
    path.addCurve(to: pt(x0 + d, y0 + p - abc),
                  control1: pt(x0, y0 + p - a), control2: pt(x0, y0 + p - a - b))
    corner(pt(x0 + R, y0 + R)); u = path.currentPoint
    path.addCurve(to: pt(x0 + p, y0), control1: pt(u.x + c, u.y - d), control2: pt(u.x + b + c, u.y - d))
    path.closeSubpath()
    return path
}

/// The ring, as an even-odd annulus.
func ring() -> CGPath {
    let p = CGMutablePath()
    p.addEllipse(in: CGRect(x: ringCentre.x - ringOuter, y: ringCentre.y - ringOuter,
                            width: ringOuter * 2, height: ringOuter * 2))
    p.addEllipse(in: CGRect(x: ringCentre.x - ringInner, y: ringCentre.y - ringInner,
                            width: ringInner * 2, height: ringInner * 2))
    return p
}

func rad(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

/// One ribbon tail: an annular sector that tapers to a rounded point at `a1`.
///
/// The two quadratics between the outer and inner arcs are what make it a ribbon rather than a
/// broken arc. Their control and end points are the same numbers the SVG carries; they are
/// literal because they were computed once, on the circle, and rounding them again here would
/// let the two masters drift.
func ribbonTail(a0: CGFloat, a1: CGFloat,
                q1: CGPoint, tip: CGPoint, q2: CGPoint, i1: CGPoint) -> CGPath {
    let p = CGMutablePath()
    // In the flipped, y-down context an increasing angle sweeps clockwise on screen, which is
    // what `clockwise: false` produces — the same direction as the SVG's sweep flag 1.
    p.addArc(center: ringCentre, radius: ribbonOuter,
             startAngle: rad(a0), endAngle: rad(a1), clockwise: false)
    p.addQuadCurve(to: tip, control: q1)
    p.addQuadCurve(to: i1, control: q2)
    p.addArc(center: ringCentre, radius: ribbonInner,
             startAngle: rad(a1), endAngle: rad(a0), clockwise: true)
    p.closeSubpath()
    return p
}

/// The tail that passes **behind** the ring, lower left.
func tailUnder() -> CGPath {
    ribbonTail(a0: 62, a1: 186,
               q1: pt(217.51, 454.76), tip: pt(252.17, 442.38),
               q2: pt(278.37, 466.59), i1: pt(277.29, 487.33))
}

/// The tail that passes **in front of** the Z, upper right. One draw order is the whole of the
/// interlock; there is no masking anywhere.
func tailOver() -> CGPath {
    ribbonTail(a0: -118, a1: 6,
               q1: pt(806.49, 569.24), tip: pt(771.83, 581.62),
               q2: pt(745.63, 557.41), i1: pt(746.71, 536.67))
}

/// The Z. Ten points, no curves: two datum bars tied by one diagonal.
func monogram() -> CGPath {
    let topBarBottom = zy0 + zWeight
    let bottomBarTop = zy1 - zWeight
    let path = CGMutablePath()
    path.addLines(between: [
        pt(zx0, zy0), pt(zx1, zy0), pt(zx1, zy0 + zTerminal),
        pt(zx1 - zRun, bottomBarTop), pt(zx1, bottomBarTop),
        pt(zx1, zy1), pt(zx0, zy1), pt(zx0, zy1 - zTerminal),
        pt(zx0 + zRun, topBarBottom), pt(zx0, topBarBottom),
    ])
    path.closeSubpath()
    return path
}

// ---------------------------------------------------------------- painting
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}
func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, _ from: CGPoint, _ to: CGPoint) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func fill(_ ctx: CGContext, _ path: CGPath, _ colour: CGColor) {
    ctx.setFillColor(colour); ctx.addPath(path); ctx.fillPath()
}

/// Body, depth, the ring, the ribbon and the monogram.
///
/// `sheetDetail` keeps its name and its meaning — *draw the ground detail* — but the detail is
/// now the ribbon rather than a drafting grid. It is false for small rasters and for the
/// document-icon badge, where a 66 pt band is under two pixels and reads as dirt.
func drawMark(_ ctx: CGContext, sheetDetail: Bool, glyph: Bool = true) {
    let body = squircle(bodyRect, radius: bodyRadius, smoothing: cornerSmoothing)

    fill(ctx, body, gradient([(0, col(navyLight)), (1, col(navyDeep))]), pt(150, 60), pt(874, 964))
    fill(ctx, body, gradient([(0, col(graphite, 0)), (1, col(graphite, 0.42))]), pt(340, 240), pt(940, 1030))
    fill(ctx, body, gradient([(0, col(0xFFFFFF, 0.10)), (1, col(0xFFFFFF, 0))]), pt(0, 100), pt(0, 420))

    ctx.saveGState(); ctx.addPath(body); ctx.clip()

    // The ribbon weaves: this tail goes down before the ring, the other one after the Z.
    if sheetDetail {
        fill(ctx, tailUnder(), gradient([(0, col(ribbonMid)), (1, col(ribbonDeep))]),
             pt(222, 222), pt(802, 802))
    }

    // Ring: outer disc minus inner disc.
    ctx.saveGState()
    ctx.addPath(ring()); ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(gradient([(0, col(ringLight)), (0.52, col(ringMid)), (1, col(ringDeep))]),
                           start: pt(300, 264), end: pt(724, 760),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Bevels: light on the outer edge from the upper left, dark on the inner edge from the
    // lower right. One light source, upper left, the same one the body gradient uses.
    func bevel(radius: CGFloat, from a0: CGFloat, to a1: CGFloat, colour: CGColor) {
        let arc = CGMutablePath()
        arc.addArc(center: ringCentre, radius: radius,
                   startAngle: rad(a0), endAngle: rad(a1), clockwise: false)
        ctx.setStrokeColor(colour)
        ctx.setLineWidth(9)
        ctx.setLineCap(.round)
        ctx.addPath(arc)
        ctx.strokePath()
    }
    bevel(radius: 276, from: 186, to: 304, colour: col(bevelLit, 0.62))
    bevel(radius: 196, from: 6, to: 124, colour: col(graphite, 0.52))

    if glyph {
        fill(ctx, monogram(), gradient([(0, col(redLight)), (0.55, col(red)), (1, col(redDeep))]),
             pt(340, 352), pt(700, 672))
    }

    if sheetDetail {
        fill(ctx, tailOver(), gradient([(0, col(ribbonLit)), (1, col(ribbonMid))]),
             pt(420, 200), pt(830, 520))
    }

    ctx.restoreGState()

    // inner rim light: stroke straddles the edge, clip keeps the inner half
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    ctx.addPath(body); ctx.setLineWidth(7); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, col(0xFFFFFF, 0.34)), (0.45, col(0xFFFFFF, 0.06)),
                                     (1, col(graphite, 0.28))]),
                           start: pt(0, 100), end: pt(0, 924), options: [])
    ctx.restoreGState()
}

// ---------------------------------------------------------------- document
// Portrait sheet with a folded corner, carrying the mark as a badge. The
// silhouette alone separates it from the app icon at 16 px.
let sheetRect = CGRect(x: 200, y: 88, width: 624, height: 848)
let sheetRadius: CGFloat = 22
let foldSize: CGFloat = 176
let badgeRect = CGRect(x: 296, y: 424, width: 432, height: 432)

func sheetPath() -> CGPath {
    let x0 = sheetRect.minX, y0 = sheetRect.minY, x1 = sheetRect.maxX, y1 = sheetRect.maxY
    let r = sheetRadius
    let p = CGMutablePath()
    p.move(to: pt(x0 + r, y0))
    p.addLine(to: pt(x1 - foldSize, y0))
    p.addLine(to: pt(x1, y0 + foldSize))
    p.addLine(to: pt(x1, y1 - r))
    p.addQuadCurve(to: pt(x1 - r, y1), control: pt(x1, y1))
    p.addLine(to: pt(x0 + r, y1))
    p.addQuadCurve(to: pt(x0, y1 - r), control: pt(x0, y1))
    p.addLine(to: pt(x0, y0 + r))
    p.addQuadCurve(to: pt(x0 + r, y0), control: pt(x0, y0))
    p.closeSubpath()
    return p
}

func drawDocument(_ ctx: CGContext, sheetDetail: Bool, badgeGlyph: Bool) {
    let sheet = sheetPath()
    let x1 = sheetRect.maxX, y0 = sheetRect.minY

    // paper: white, deepening very slightly down the page
    fill(ctx, sheet, col(0xFFFFFF))
    fill(ctx, sheet, gradient([(0, col(graphite2, 0)), (1, col(graphite2, 0.07))]),
         pt(0, sheetRect.minY), pt(0, sheetRect.maxY))

    // folded corner (underside of the flap)
    let flap = CGMutablePath()
    flap.addLines(between: [pt(x1 - foldSize, y0), pt(x1, y0 + foldSize), pt(x1 - foldSize, y0 + foldSize)])
    flap.closeSubpath()
    fill(ctx, flap, col(graphite2, 0.18))

    if sheetDetail {
        ctx.saveGState(); ctx.addPath(sheet); ctx.clip()

        // a measured plan, not lines of prose: room outline, one partition with a
        // door opening, and the span dimensioned in measurement cyan above it
        let dim = CGMutablePath()
        let dy: CGFloat = 198, dx0: CGFloat = 268, dx1: CGFloat = 636, w: CGFloat = 8, tick: CGFloat = 30
        dim.addRect(CGRect(x: dx0, y: dy - w / 2, width: dx1 - dx0, height: w))
        for cx in [dx0, dx1] { dim.addRect(CGRect(x: cx - w / 2, y: dy - tick / 2, width: w, height: tick)) }
        fill(ctx, dim, col(zenitCyan))

        let plan = CGMutablePath()
        plan.addRect(CGRect(x: 272, y: 248, width: 360, height: 132))
        fill2(ctx, plan, stroke: col(graphite2, 0.22), width: 9)
        let partition = CGMutablePath()
        partition.addRect(CGRect(x: 465.5, y: 248, width: 9, height: 84))
        fill(ctx, partition, col(graphite2, 0.22))

        ctx.restoreGState()
    }

    // paper edge
    ctx.setStrokeColor(col(graphite2, 0.50)); ctx.setLineWidth(4)
    ctx.addPath(sheet); ctx.strokePath()

    // the mark, as a badge on the sheet
    ctx.saveGState()
    let s = badgeRect.width / bodyRect.width
    ctx.translateBy(x: badgeRect.minX, y: badgeRect.minY)
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: -bodyRect.minX, y: -bodyRect.minY)
    drawMark(ctx, sheetDetail: false, glyph: badgeGlyph)
    ctx.restoreGState()
}

func fill2(_ ctx: CGContext, _ path: CGPath, stroke: CGColor, width: CGFloat) {
    ctx.saveGState(); ctx.setStrokeColor(stroke); ctx.setLineWidth(width)
    ctx.addPath(path); ctx.strokePath(); ctx.restoreGState()
}

// ---------------------------------------------------------------- output
func render(_ px: Int, document: Bool) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    // flip to y-down and scale the 1024 master to the target
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / 1024, y: -CGFloat(px) / 1024)
    // ground detail cannot resolve below 128 px; below that it is noise
    let detail = px >= 128
    if document {
        drawDocument(ctx, sheetDetail: detail, badgeGlyph: px >= 32)
    } else {
        drawMark(ctx, sheetDetail: detail)
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("cannot create \(path)\n".data(using: .utf8)!); exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("cannot write \(path)\n".data(using: .utf8)!); exit(1)
    }
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for px in [16, 32, 64, 128, 256, 512, 1024] {
    writePNG(render(px, document: false), "\(outDir)/app-\(px).png")
    writePNG(render(px, document: true), "\(outDir)/doc-\(px).png")
}
print("rendered 7 sizes x 2 icons")
SWIFT

echo "rendering…"
swift "${WORK}/ZenitIconRenderer.swift" "${WORK}"

# ---------------------------------------------------------------- assemble

# pixel size -> iconset member names
iconset_members() {
  case "$1" in
    16)   echo "icon_16x16.png" ;;
    32)   echo "icon_16x16@2x.png icon_32x32.png" ;;
    64)   echo "icon_32x32@2x.png" ;;
    128)  echo "icon_128x128.png" ;;
    256)  echo "icon_128x128@2x.png icon_256x256.png" ;;
    512)  echo "icon_256x256@2x.png icon_512x512.png" ;;
    1024) echo "icon_512x512@2x.png" ;;
  esac
}

build_iconset() {
  local prefix="$1" iconset="$2"
  rm -rf "${iconset}"; mkdir -p "${iconset}"
  for px in 16 32 64 128 256 512 1024; do
    for member in $(iconset_members "${px}"); do
      cp "${WORK}/${prefix}-${px}.png" "${iconset}/${member}"
    done
  done
}

build_iconset app "${WORK}/AppIcon.iconset"
build_iconset doc "${WORK}/ProjectDocument.iconset"

iconutil -c icns "${WORK}/AppIcon.iconset"         -o "${ICONS_DIR}/AppIcon.icns"
iconutil -c icns "${WORK}/ProjectDocument.iconset" -o "${ICONS_DIR}/ProjectDocument.icns"

# ---------------------------------------------------------------- catalog

APPICONSET="${ICONS_DIR}/AppIcon.appiconset"
rm -rf "${APPICONSET}"; mkdir -p "${APPICONSET}"
for px in 16 32 64 128 256 512 1024; do
  for member in $(iconset_members "${px}"); do
    cp "${WORK}/app-${px}.png" "${APPICONSET}/${member}"
  done
done

cat > "${APPICONSET}/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16"   },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16"   },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32"   },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32"   },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

# ---------------------------------------------------------------- verify

fail=0
for f in "${ICONS_DIR}/AppIcon.icns" "${ICONS_DIR}/ProjectDocument.icns"; do
  [ -s "$f" ] || { echo "error: ${f} missing or empty" >&2; fail=1; }
done
for px in 16 32 64 128 256 512 1024; do
  for member in $(iconset_members "${px}"); do
    f="${APPICONSET}/${member}"
    [ -s "$f" ] || { echo "error: ${f} missing" >&2; fail=1; continue; }
    got="$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')"
    [ "$got" = "$px" ] || { echo "error: ${member} is ${got}px, expected ${px}px" >&2; fail=1; }
  done
done
[ "$fail" -eq 0 ] || exit 1

echo
echo "written to ${ICONS_DIR}:"
for f in AppIcon.icns ProjectDocument.icns; do
  printf "  %-24s %9s bytes\n" "$f" "$(stat -f %z "${ICONS_DIR}/${f}")"
done
printf "  %-24s %s files\n" "AppIcon.appiconset/" "$(/bin/ls -1 "${APPICONSET}" | wc -l | tr -d ' ')"
echo "ok"
