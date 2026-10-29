import Foundation
import Observation

/// One attached site photograph as the Inspector lists it: identity and a human label,
/// never the pixels — the row is attribution, the blob stays in the project package.
public struct InspectorPhotoRow: Identifiable, Hashable, Sendable {
    /// The attachment's id (not the photo digest: the same photo attached twice to two
    /// markups is two rows).
    public let id: UUID
    /// What the row says — the caption when there is one, else capture date, else size.
    public let label: String

    public init(id: UUID, label: String) {
        self.id = id
        self.label = label
    }
}

/// The Inspector's photo-row invalidation tick. The application bumps ``revision`` after
/// every attach and remove; the panel reads it inside its body, which is what registers
/// the observation — the row closure itself is deliberately a plain function.
@MainActor
@Observable
public final class InspectorPhotoTick {
    public var revision: Int = 0
    public init() {}
}
