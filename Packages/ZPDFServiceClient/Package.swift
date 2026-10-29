// swift-tools-version:6.0
import PackageDescription

/// `ZPDFServiceClient` is the S15 XPC-isolation seam.
///
/// Parsing-heavy work — vector extraction (`ZPDFVectorExtraction`) and structural
/// repair (`ZPDFQPDF`) — runs out of process so a hostile PDF can kill a worker
/// without taking the app down. This package owns every side of that boundary:
///
/// - `ZPDFServiceWire` — the Sendable, Codable DTOs and the `@objc` XPC protocols.
///   Everything that crosses a process boundary is defined here and nowhere else.
/// - `ZPDFGeometryServiceCore` / `ZPDFRepairServiceCore` — the service-side request
///   handlers. `Apps/GeometryService` and `Apps/RepairService` are thin `main.swift`
///   wrappers around these, so the exact code the shipped `.xpc` bundles run is the
///   code the tests in this package exercise.
/// - `ZPDFServiceClient` — the async facade the app calls. It prefers the embedded
///   XPC service, restarts it on crash, and falls back to IN-PROCESS execution when
///   no service bundle exists (dev builds, `swift test`), so nothing regresses when
///   XPC is unavailable.
/// - `zpdf-geometry-worker` / `zpdf-repair-worker` — test workers: the same service
///   cores speaking the same wire frames over stdio, spawnable from `swift test`,
///   where an `.xpc` bundle cannot be launched. The crash-isolation tests kill these
///   mid-request and assert the client's typed error + restart + retry policy.
///
/// macOS-only by design: `NSXPCListener`/`NSXPCConnection` service bundles are a
/// macOS app-tier construct. The portable tier is untouched — the packages this one
/// wraps keep their own iOS 17 compile targets.
let package = Package(
    name: "ZPDFServiceClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZPDFServiceClient", targets: ["ZPDFServiceClient"]),
        .library(name: "ZPDFServiceWire", targets: ["ZPDFServiceWire"]),
        .library(name: "ZPDFGeometryServiceCore", targets: ["ZPDFGeometryServiceCore"]),
        .library(name: "ZPDFRepairServiceCore", targets: ["ZPDFRepairServiceCore"]),
        .executable(name: "zpdf-geometry-worker", targets: ["zpdf-geometry-worker"]),
        .executable(name: "zpdf-repair-worker", targets: ["zpdf-repair-worker"])
    ],
    dependencies: [
        .package(path: "../ZPDFVectorExtraction"),
        .package(path: "../ZPDFPDFKitBridge"),
        .package(path: "../ZPDFCompare"),
        .package(path: "../ZPDFDXF"),   // NL-PLAT-05 round 2: DXF parsed in GeometryService.xpc
        .package(path: "../../Bridges/QPDFBridge"),
        .package(path: "../ZPDFTestingSupport")
    ],
    targets: [
        .target(
            name: "ZPDFServiceWire",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Vector extraction *and*, since S17-02, page rasterisation. The
        // rasteriser is `ZPDFPDFKitBridge`'s, unchanged, so the pixels the service
        // produces are the pixels the in-process path produced; the grayscale
        // reduction is `ZPDFCompare`'s `GrayImage`, for the same reason.
        .target(
            name: "ZPDFGeometryServiceCore",
            dependencies: [
                "ZPDFServiceWire",
                .product(name: "ZPDFVectorExtraction", package: "ZPDFVectorExtraction"),
                .product(name: "ZPDFPDFKitBridge", package: "ZPDFPDFKitBridge"),
                .product(name: "ZPDFCompare", package: "ZPDFCompare"),
                .product(name: "ZPDFDXF", package: "ZPDFDXF")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "ZPDFRepairServiceCore",
            dependencies: [
                "ZPDFServiceWire",
                .product(name: "ZPDFQPDF", package: "QPDFBridge")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Deliberately does NOT depend on `ZPDFQPDF` (finding S17-03). qpdf's C++
        // parser used to be linked into every binary that linked this target — the
        // application included — because the `.inProcess` repair fallback called it
        // directly. The fallback is now injected through
        // `RepairInProcessExecuting`, whose only conformance lives in
        // `ZPDFRepairServiceCore`, so qpdf reaches a shipping process only inside
        // `RepairService.xpc`. `QPDFLinkageTests` scans this target's objects and
        // fails if a qpdf symbol reappears.
        .target(
            name: "ZPDFServiceClient",
            dependencies: [
                "ZPDFServiceWire",
                // The geometry service core, and NOT the repair one. That
                // asymmetry is the security position, not an accident: the vector
                // and raster in-process fallbacks are Apple's parsers, deliberately
                // kept so `swift test` and a service-less build still work, while
                // the repair fallback is qpdf's C++ and must not be reachable from
                // the application at all.
                "ZPDFGeometryServiceCore",
                .product(name: "ZPDFVectorExtraction", package: "ZPDFVectorExtraction"),
                .product(name: "ZPDFCompare", package: "ZPDFCompare"),
                // StagedFileReplacement: the one staging rule for a file bound for a chosen
                // destination (V-051). Already linked through the geometry core; no qpdf.
                .product(name: "ZPDFPDFKitBridge", package: "ZPDFPDFKitBridge")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "zpdf-geometry-worker",
            dependencies: ["ZPDFGeometryServiceCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "zpdf-repair-worker",
            dependencies: ["ZPDFRepairServiceCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFServiceClientTests",
            dependencies: [
                "ZPDFServiceClient",
                "ZPDFGeometryServiceCore",
                "ZPDFRepairServiceCore",
                "zpdf-geometry-worker",
                "zpdf-repair-worker",
                .product(name: "ZPDFCompare", package: "ZPDFCompare"),
                .product(name: "ZPDFPDFKitBridge", package: "ZPDFPDFKitBridge"),
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
