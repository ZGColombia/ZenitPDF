# Keyboard commands

Open **Help → Keyboard Shortcuts** in the application for the effective bindings. That reference
reads the installed menu and command table, including customized bindings and AppKit document
commands. It avoids maintaining a second static table that can disagree with the menus.

Standard document actions use macOS conventions such as Command-O (Open), Command-S (Save),
and Command-Z (Undo). AppKit may adjust document commands such as Duplicate and Save As;
read the installed menu rather than assuming a chord from a source-table default.

Bare tool keys apply in canvas context. They must not consume typing in search fields,
text markups, or inspector editors. Context availability and focus determine whether an action
is enabled. Canceling a gesture must leave focus in a useful place.

## Contributor reference

- `Apps/ZenitPDF/Sources/ZenitPDFAppKit/Menu/KeyboardShortcutsReference.swift` builds the help reference.
- `ZPDFCommandTable` in `Packages/ZPDFUIShell` supplies shell command definitions.
- Platform menu composition and shortcut settings live in `Apps/ZenitPDF`.

When changing a binding, review conflicts, text-input focus, menu display, customization,
and accessibility together. See [Interaction](INTERACTION_MATRIX.md) and
[Accessibility](ACCESSIBILITY_PLAN.md).
