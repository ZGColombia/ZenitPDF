import Foundation

/// The on-disk shape of a `.zpdfproj`, spec 6.3.
///
/// ```text
/// Project.zpdfproj/
/// ├── manifest.json
/// ├── project.sqlite
/// ├── documents/
/// │   ├── original.pdf
/// │   ├── working.pdf
/// │   └── revisions/
/// ├── attachments/
/// ├── thumbnails/
/// ├── ocr/
/// ├── geometry/
/// ├── reports/
/// ├── toolsets/
/// ├── recovery/
/// └── licences/
/// ```
///
/// Every path in this type is relative to the package root, and every one of them is a
/// constant: nothing in this package builds a path by string concatenation at a call
/// site, so there is exactly one place to look when the layout changes.
public enum ProjectPackageLayout {

    /// The extension, without the dot.
    public static let fileExtension = "zpdfproj"

    public static let manifest = "manifest.json"
    public static let database = "project.sqlite"
    /// Spec 6.4 hashes the manifest as well as the database and the PDFs, and a
    /// manifest cannot contain its own hash. The integrity record is where the hash of
    /// the manifest, the hash of the database and the save token live.
    public static let integrity = "integrity.json"

    public static let documents = "documents"
    public static let originalPDF = "documents/original.pdf"
    public static let workingPDF = "documents/working.pdf"
    public static let revisions = "documents/revisions"

    /// Where a document added after creation lives: `documents/added-<id>.pdf`.
    ///
    /// The first drawing keeps the fixed `original.pdf`/`working.pdf` pair; every later
    /// drawing is named by its own `document.id`, which is unique by construction, so an
    /// add can never collide with the originals or with another added drawing.
    public static func addedDocumentPath(id: String) -> String {
        "\(documents)/added-\(id).pdf"
    }

    public static let attachments = "attachments"
    public static let thumbnails = "thumbnails"
    /// The folder macOS reads a package's Finder thumbnail from (`QuickLook/Thumbnail.png`).
    /// Written by the app after a save, like ``thumbnails``; never read by this package.
    public static let finderQuickLook = "QuickLook"
    public static let ocr = "ocr"
    public static let geometry = "geometry"
    public static let reports = "reports"
    public static let toolsets = "toolsets"
    public static let recovery = "recovery"
    public static let licences = "licences"

    public static let recoveryJournal = "recovery/journal.json"
    public static let lastGoodManifest = "recovery/last-good-manifest.json"
    public static let crashMarker = "recovery/crash-marker"
    public static let autosaveDatabase = "recovery/autosave.sqlite"

    /// Saved versions of the package, INSIDE the package, where the App Sandbox's grant for
    /// the package covers them.
    ///
    /// ```text
    /// Project.zpdfproj/versions/
    /// ├── latest/     the package exactly as the last save wrote it
    /// └── previous/   the package exactly as the save before that wrote it
    /// ```
    ///
    /// Inside the package rather than a hidden sibling, because under the App Sandbox a
    /// save panel's powerbox grant covers the chosen URL and nothing beside it: a sibling
    /// versions directory was unwritable at every destination a user could pick, which is
    /// exactly how gap 12.5 presented. Inside the package the grant always covers it, and
    /// the versions travel with the project when the user moves or copies it.
    ///
    /// Two slots, not one, and both are clones of a *completed save* rather than of the
    /// working package. That distinction is the whole design: the live `project.sqlite`
    /// is edited in place, so by the time a save runs, the directory it replaces already
    /// contains the new rows. Rotating a clone taken at the end of each save is the only
    /// way "the previous version" means the state the user could actually go back to.
    /// Clone-on-write makes each slot cost the blocks that changed, not the size of the
    /// project. The version clones themselves exclude `versions`, so a slot never nests
    /// another slot.
    public static let versions = "versions"

    /// The directories created by ``ProjectPackage/create(at:displayName:originalPDF:environment:)``.
    public static let directories: [String] = [
        documents, revisions, attachments, thumbnails, ocr, geometry,
        reports, toolsets, recovery, licences, versions
    ]

    /// The members that must be present for a package to be openable at all.
    ///
    /// `integrity.json` joined the list with S17-07. It has to be required rather than
    /// optional: a check that a package can opt out of by deleting the file it is checked
    /// against is not a check, and every package this build has ever written has one.
    public static let requiredMembers: [String] = [manifest, database, integrity, originalPDF]

    // MARK: Sibling names

    /// The legacy pre-12.5 sibling that held saved versions (`.Project.zpdfproj.versions`).
    /// Read as a fallback by recovery for packages saved by older builds; never written.
    public static func versionsName(for packageName: String) -> String {
        ".\(packageName).versions"
    }

    /// The package as the most recent completed save wrote it.
    public static let latestVersion = "latest"
    /// The package as the save before that wrote it.
    public static let previousVersion = "previous"

    /// The directory the save pipeline builds the temporary package under.
    ///
    /// Since the 12.5 fix the temporary is created inside
    /// `FileManager.url(for: .itemReplacementDirectory, appropriateFor: destination)` —
    /// same volume as the destination (so the swap is one `rename`), always writable
    /// relative to a powerbox-granted URL, and cleaned by the system if a crash strands
    /// it. This name is what the temporary is called *inside* that directory.
    public static func temporaryName(for packageName: String, token: String) -> String {
        ".\(packageName).save-\(token).tmp"
    }

    /// True for the leftovers a crashed save can strand next to a package.
    ///
    /// Deliberately narrow: it matches this package's own temporary and discard names
    /// and nothing else, so a cleanup pass can never remove a saved version, a user's
    /// file, or another project. Since 12.5 the temporaries live in the system's item
    /// replacement directory, so this matches only what *older builds* stranded.
    public static func isReclaimableLeftover(name: String, packageName: String) -> Bool {
        let temporaryPrefix = ".\(packageName).save-"
        let discardPrefix = ".\(packageName).discard-"
        if name.hasPrefix(temporaryPrefix) && name.hasSuffix(".tmp") { return true }
        if name.hasPrefix(discardPrefix) { return true }
        return false
    }

    // MARK: Names inside the package

    /// The name a recovery gives the `project.sqlite` (and its sidecars) it replaced:
    /// `recovery/superseded-<token>.sqlite[-wal|-shm]`. Kept across saves (BH-186).
    public static func supersededDatabaseName(token: String, suffix: String = "") -> String {
        "superseded-\(token).sqlite\(suffix)"
    }

    /// True for a superseded database or one of its sidecars parked in `recovery/`.
    public static func isSupersededDatabaseFile(name: String) -> Bool {
        name.hasPrefix("superseded-") && name.contains(".sqlite")
    }

    /// The file a restore stages in the package root before renaming it into place:
    /// `.restore-<token>.sqlite`. A crash between the clone and the rename strands it,
    /// and nothing names it again (BH-606).
    public static func restoreStagingName(token: String) -> String {
        ".restore-\(token).sqlite"
    }

    /// True for a stranded restore staging file in the package root.
    public static func isStrandedRestoreFile(name: String) -> Bool {
        name.hasPrefix(".restore-") && name.hasSuffix(".sqlite")
    }

    /// True for a `versions/staging-<token>` or `versions/discard-<token>` directory a
    /// version rotation left behind when a crash interrupted it (BH-603).
    public static func isStrandedVersionRotation(name: String) -> Bool {
        name.hasPrefix("staging-") || name.hasPrefix("discard-")
    }
}

public extension URL {
    /// Resolves one of ``ProjectPackageLayout``'s relative paths against a package root:
    /// `packageRoot.member(ProjectPackageLayout.database)`.
    ///
    /// Public because the app layer and the tests both address package members, and a
    /// method beats string concatenation at sixty call sites. It splits on `/` and
    /// appends component by component, so a member constant can spell a nested path
    /// without any call site doing path arithmetic.
    func member(_ relativePath: String) -> URL {
        var url = self
        for component in relativePath.split(separator: "/") {
            url = url.appendingPathComponent(String(component))
        }
        return url
    }
}
