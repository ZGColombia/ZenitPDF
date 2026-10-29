// swift-tools-version:6.0
import PackageDescription

/// `ZPDFCollaboration` is the Shared Review Folder's engine (NL-COLLAB-12, ADR-0026): the
/// operation log each participant appends to, the hybrid logical clock that orders it, and the
/// deterministic merge that turns everybody's logs into one review state.
///
/// Portable by design — Foundation and the frozen contracts only, no AppKit, no database — so the
/// merge can be proven byte for byte in tests and reused by any future target. The app tier owns
/// the folder bookmark and the file watching; this package only reads and writes files it is
/// handed, and only ever writes the one log that belongs to the participant running it.
///
/// No server, no account, no network: the folder is whatever the people involved already share
/// (a synced drive, a file server). Nothing here opens a socket.
let package = Package(
    name: "ZPDFCollaboration",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ZPDFCollaboration", targets: ["ZPDFCollaboration"])
    ],
    dependencies: [
        .package(path: "../ZPDFContracts")
    ],
    targets: [
        .target(
            name: "ZPDFCollaboration",
            dependencies: [.product(name: "ZPDFContracts", package: "ZPDFContracts")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZPDFCollaborationTests",
            dependencies: ["ZPDFCollaboration"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
