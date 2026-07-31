import AppKit

/// The AppKit half of the design tokens (G2, `docs/24-design-contract.md`).
///
/// `Renderer/src/tokens.css` covers the diff itself; this covers everything around it — the
/// window, the two lists, the status line and the empty state. **A design that stops at the edge of
/// the webview leaves two thirds of the window untouched**, which is why the names here mirror the
/// token names there rather than being invented separately.
///
/// Values default to the system's own, so light and dark mode work with no effort. A design
/// replaces the values; the check in `diffscope-verify` cares that this is the only place they are
/// declared.
enum Theme {
    /// `--ds-font` / `--ds-text-size*`. Monospaced because both lists show paths, and a path is
    /// easier to compare when its characters line up.
    static let textSize: CGFloat = 12
    static let textSizeSmall: CGFloat = 11
    static let textSizeTiny: CGFloat = 10
    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
    /// The empty state is the one place that speaks in sentences rather than in paths, so it uses
    /// the system's proportional face.
    static func prose(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    /// `--ds-ink` / `--ds-ink-quiet`.
    static let ink = NSColor.labelColor
    static let inkQuiet = NSColor.secondaryLabelColor

    /// `--ds-space-*`.
    static let space2: CGFloat = 4
    static let space3: CGFloat = 6
    static let space4: CGFloat = 8
    static let space6: CGFloat = 16

    /// Row height in both lists. Not a token in the CSS, because the diff has no rows.
    static let rowHeight: CGFloat = 20
    /// Starting widths for the three panes. Constraints, not fixed sizes — the dividers stay
    /// draggable (see the note in `buildWindow`).
    static let repositoryPaneWidth: CGFloat = 280
    static let filePaneWidth: CGFloat = 320
    static let paneMinimumWidth: CGFloat = 140
    static let diffPaneMinimumWidth: CGFloat = 300
    static let windowWidth: CGFloat = 1400
    static let windowHeight: CGFloat = 860
    static let emptyStateMaximumWidth: CGFloat = 460
    static let emptyStateTitleSize: CGFloat = 20
}
