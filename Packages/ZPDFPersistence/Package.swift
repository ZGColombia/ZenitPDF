// swift-tools-version:6.0
import PackageDescription

/// `ZPDFPersistence` owns the project database and the `.zpdfproj` document package.
///
/// Two responsibilities, one package, because they are one durability story: the SQLite
/// database is the payload and the package is the crash-safe envelope it travels in.
/// A takeoff is days of a human's work, so every write path here is written so that a
/// power loss, a `SIGKILL` or a full disk leaves the user with either the previous good
/// state or the new good state, and never a mixture of the two.
///
/// GRDB is pinned by revision, not by range: `0d8cf958b4b66a0473ec6e6986eb9da462171da9`
/// is the exact commit recorded in `Docs/Execution/RESEARCH_REPOSITORIES.lock.json`
/// (`v7.11.1-2-g0d8cf958`, MIT, Copyright (C) 2015-2025 Gwendal Roué).
let package = Package(
    name: "ZPDFPersistence",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFPersistence", targets: ["ZPDFPersistence"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            revision: "0d8cf958b4b66a0473ec6e6986eb9da462171da9"
        ),
        // The stored-zip writer Send Project streams its archive through (R-212): a
        // Foundation-only leaf with no dependencies of its own, so the persistence layer
        // shares one zip format with the spreadsheet round trip instead of keeping a copy.
        .package(path: "../ZPDFSpreadsheet"),
        // Test-only. The product is bound to the test target alone; the library target
        // must never see the fixture corpus.
        .package(path: "../ZPDFTestingSupport")
    ],
    targets: [
        .target(
            name: "ZPDFPersistence",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZPDFSpreadsheet", package: "ZPDFSpreadsheet")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // A real, separately linked process whose only job is to be killed halfway
        // through a save. The durability tests launch it and send it SIGKILL at named
        // checkpoints; simulating the kill in-process would prove nothing about what
        // the filesystem actually holds after the process is gone.
        .executableTarget(
            name: "zpdf-save-harness",
            dependencies: ["ZPDFPersistence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFPersistenceTests",
            dependencies: [
                "ZPDFPersistence",
                "zpdf-save-harness",
                .product(name: "ZPDFSpreadsheet", package: "ZPDFSpreadsheet"),
                .product(name: "ZPDFTestingSupport", package: "ZPDFTestingSupport")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
