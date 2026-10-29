// swift-tools-version:6.0
import PackageDescription

/// `ZPDFUIShell` is the gate G12 window shell of Zenit PDF.
///
/// It owns the AppKit composition of a project window — the three-pane split, the docked
/// Quantity Ledger, the document tab bar, the main toolbar, the Navigator, the Inspector and
/// the status bar — and hosts every SwiftUI panel inside `NSHostingView`.
///
/// The shell depends on the two local foundation packages, plus three sibling UI packages it
/// *hosts*: `ZPDFUILedger` for the docked Quantity Ledger table (the grouped `NSOutlineView`
/// is the pane's default view), `ZPDFUIMeasurement` for the Scale Regions
/// panel, and `ZPDFUIWorkflows` for the canvas view modes — Split Canvas and Revision Overlay —
/// and the no-dead-ends mode registry those modes are entered through. The shell is the only
/// place that composes a whole project window, so it is the only place those panels can be made
/// reachable; the dependency arrows all point *into* the shell and there is no cycle.
///
/// It still never talks to a document store, a renderer or a measurement engine: it renders
/// whatever the `ZPDFUIPresentation` presenter protocols hand it, which lets the whole window be
/// exercised against `MockPresenters` without the core engines.
let package = Package(
    name: "ZPDFUIShell",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZPDFUIShell", targets: ["ZPDFUIShell"]),
        // The hosted hit-target probe (NL-MARKUP-01, LT3-01). An executable on purpose: SwiftPM
        // stamps it with the package's macOS 14 deployment target, exactly as the shipped app is
        // stamped, so SwiftUI runs the same hit-testing rules the app runs. `xctest` is stamped
        // with the current SDK and runs the modern rules, which is why package tests could not
        // see a colour well that the app never let anybody click.
        .executable(name: "zpdf-hit-probe", targets: ["ZPDFUIShellHitProbe"])
    ],
    dependencies: [
        .package(path: "../ZPDFUIPresentation"),
        .package(path: "../ZPDFDesignSystem"),
        .package(path: "../ZPDFUILedger"),
        .package(path: "../ZPDFUIMeasurement"),
        .package(path: "../ZPDFUIWorkflows")
    ],
    targets: [
        .target(
            name: "ZPDFUIShell",
            dependencies: [
                "ZPDFUIPresentation", "ZPDFDesignSystem", "ZPDFUILedger",
                "ZPDFUIMeasurement", "ZPDFUIWorkflows"
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ZPDFUIShellHitProbe",
            dependencies: ["ZPDFUIShell", "ZPDFUIPresentation", "ZPDFDesignSystem"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFUIShellTests",
            dependencies: [
                "ZPDFUIShell", "ZPDFUIPresentation", "ZPDFDesignSystem", "ZPDFUILedger",
                "ZPDFUIMeasurement", "ZPDFUIWorkflows"
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
