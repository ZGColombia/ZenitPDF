import Foundation
import Observation

/// The common shape of every Zenit presenter.
///
/// Presenters are reference types isolated to the main actor and observable through the
/// `Observation` framework, so a SwiftUI view or an AppKit controller can read their
/// properties directly and be re-invalidated when those properties change. Everything a
/// presenter exposes is a `Sendable` value type, which is what lets the core
/// engines compute on background actors and hand results across without copying view state.
///
/// UI packages depend on these protocols, never on a concrete implementation. Previews and
/// package tests bind them to the mock presenters in this package; the application binds the
/// same protocols to the frozen domain contracts.
public protocol ZenitPresenting: AnyObject, Observable {}
