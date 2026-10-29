import Foundation

/// One page of some open document.
public struct PageReference: Sendable, Hashable, Codable {
    public let document: DocumentHandle
    public let pageIndex: Int

    public init(document: DocumentHandle, pageIndex: Int) {
        self.document = document
        self.pageIndex = pageIndex
    }
}

/// How a rotate operation changes a page's `/Rotate`.
public enum RotationChange: Sendable, Hashable, Codable {
    /// Add to the current rotation, normalising into `{0, 90, 180, 270}`.
    case relative(degrees: Int)
    /// Set the rotation outright.
    case absolute(degrees: Int)

    /// The resulting rotation, or `nil` when `degrees` is not a multiple of 90.
    public func applied(to current: Int) -> Int? {
        switch self {
        case let .relative(degrees):
            guard degrees % 90 == 0 else { return nil }
            return PageRotationMath.normalised(current + degrees)
        case let .absolute(degrees):
            guard degrees % 90 == 0 else { return nil }
            return PageRotationMath.normalised(degrees)
        }
    }
}

/// Normalising `/Rotate` values, including the negative ones real files contain.
public enum PageRotationMath {
    public static func normalised(_ degrees: Int) -> Int {
        let wrapped = degrees % 360
        return wrapped < 0 ? wrapped + 360 : wrapped
    }
}

/// The version-1 page operations of spec 20.1 that can be done safely by copying pages
/// into a new document.
///
/// Indices in every operation refer to the *current* state of the plan, so a batch reads
/// like a script: delete pages 2 and 3, then reorder what is left, then rotate the first.
public enum PageOperation: Sendable, Hashable {
    /// Rotate the named pages.
    case rotate(pageIndices: [Int], change: RotationChange)
    /// Remove the named pages.
    case delete(pageIndices: [Int])
    /// Reorder the whole document. `order` must be a permutation of `0 ..< pageCount`;
    /// `order[i]` is the current index of the page that ends up at position `i`.
    case reorder(order: [Int])
    /// Insert pages from any open document at `index`.
    case insert(pages: [PageReference], atIndex: Int)
    /// Keep only the named pages, in the order given.
    case extract(pageIndices: [Int])
    /// Append every page of another open document.
    case merge(document: DocumentHandle, pageCount: Int)
    /// Duplicate the named pages, inserting each copy directly after its original.
    case duplicate(pageIndices: [Int])
}

/// One page of the planned result.
public struct PlannedPage: Sendable, Hashable, Codable {
    /// Which page of which document supplies the content.
    public let source: PageReference
    /// The `/Rotate` the resulting page will carry.
    public let rotation: Int

    public init(source: PageReference, rotation: Int) {
        self.source = source
        self.rotation = rotation
    }
}

/// A single difference between the document as it is and the document as it would be.
public enum PageOperationChange: Sendable, Hashable, Codable {
    case deleted(source: PageReference)
    case inserted(source: PageReference, atResultIndex: Int)
    case duplicated(source: PageReference, atResultIndex: Int)
    case moved(source: PageReference, fromIndex: Int, toIndex: Int)
    case rotated(source: PageReference, from: Int, to: Int)
}

/// What a batch of operations would do, computed without opening a writer.
///
/// This is the dry run. It is a pure function of the operations and the starting page
/// list, so it is unit-tested on its own, and ``PDFDocumentProviding/applyPageOperations(_:on:to:limits:)``
/// is required to produce exactly the ``resultingPages`` this reports.
public struct PageOperationPlan: Sendable, Hashable, Codable {
    public let document: DocumentHandle
    public let initialPageCount: Int
    public let resultingPages: [PlannedPage]
    public let changes: [PageOperationChange]
    /// Documents other than `document` that supply pages, which must all still be open
    /// when the plan is applied.
    public let externalDocuments: [DocumentHandle]

    /// `true` when applying the plan would produce a page-for-page identical document.
    public var isNoOp: Bool { changes.isEmpty }

    public init(
        document: DocumentHandle,
        initialPageCount: Int,
        resultingPages: [PlannedPage],
        changes: [PageOperationChange],
        externalDocuments: [DocumentHandle]
    ) {
        self.document = document
        self.initialPageCount = initialPageCount
        self.resultingPages = resultingPages
        self.changes = changes
        self.externalDocuments = externalDocuments
    }

    /// Counts of each kind of change, for a confirmation sheet.
    public var summary: Summary {
        var summary = Summary()
        for change in changes {
            switch change {
            case .deleted: summary.deleted += 1
            case .inserted: summary.inserted += 1
            case .duplicated: summary.duplicated += 1
            case .moved: summary.moved += 1
            case .rotated: summary.rotated += 1
            }
        }
        return summary
    }

    public struct Summary: Sendable, Hashable, Codable {
        public var deleted = 0
        public var inserted = 0
        public var duplicated = 0
        public var moved = 0
        public var rotated = 0
        public init() {}
    }
}
