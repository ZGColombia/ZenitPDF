import AppKit
import ZenitPDFAppKit

// An AppKit document application is started by hand rather than by `NSApplicationMain`, because
// there is no nib: the menu bar is built from `ZPDFCommandTable` and the window is composed in
// code by `ZPDFUIShell`. `NSApplicationMain` would look for `NSMainNibFile` and find nothing.
//
// The delegate is held by a top-level `let` so it outlives `run()`; `NSApplication.delegate` is a
// weak reference and a locally scoped delegate would be deallocated before the first event.
// `ZenitApplication` (not the base class): its `terminate(_:)` override is what keeps
// quitting alive while a workflow sheet is open.
let application = ZenitApplication.shared
let delegate = ZenitApplicationDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
