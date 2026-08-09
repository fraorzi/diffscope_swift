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

    /// One value per appearance, resolved when AppKit draws rather than when this file is read, so
    /// a light/dark switch mid-diff is handled for free — the same thing the media query in
    /// `tokens.css` does for the two webviews.
    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: alpha)
    }

    /// `--ds-text` / `--ds-dim` / `--ds-faint`. Three steps, and the third is the one that has to
    /// be watched: it carries paths, counts and key hints at 10–11 px, and the adopted design's
    /// first draft had it at 2.7:1 against paper. These clear 4.5:1 in both appearances.
    static let ink = dynamic(dark: hex(0xf2f2f5), light: hex(0x16161a))
    static let inkQuiet = dynamic(dark: hex(0xa8a8b1), light: hex(0x4f4f58))
    static let inkFaint = dynamic(dark: hex(0x86868f), light: hex(0x6b6b74))

    /// The surfaces AppKit draws, mirrored from the `@chrome` block of `tokens.css` (DEC-066).
    /// The check suite requires every token in that block to be named here; a design that stops at
    /// the edge of the webview leaves two thirds of the window looking like a different
    /// application.
    ///
    /// `--ds-chrome`
    static let chrome = dynamic(dark: hex(0x161618), light: hex(0xececed))
    /// `--ds-panel-repos`
    static let panelRepositories = dynamic(dark: hex(0x0b0b0d), light: hex(0xf6f6f8))
    /// `--ds-panel-files`
    static let panelFiles = dynamic(dark: hex(0x0e0e11), light: hex(0xfbfbfd))
    /// `--ds-empty-bg`
    static let emptyStateSurface = dynamic(dark: hex(0x000000), light: hex(0xf2f2f5))
    /// `--ds-row-selected` and `--ds-row-ring`. Two halves of one signal: the ring is the shape
    /// that survives when the fill is disabled, so selection is never carried by colour alone.
    static let rowSelected = dynamic(dark: hex(0x1d1d21), light: hex(0xe3e3e8))
    static let rowRing = dynamic(dark: hex(0x34343a), light: hex(0xcfcfd6))
    /// `--ds-win-edge`
    static let windowEdge = dynamic(dark: .white, light: .black).withAlphaComponent(0.16)
    /// `--ds-focus-ring`
    static let focusRing = dynamic(dark: hex(0x0a84ff), light: hex(0x0064d2))

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
    /// Collapsed widths (DEC-060). The rail holds three letters and a dot; the spine holds one bar
    /// per file with its kind glyph. Neither is a hidden pane — both still answer *which* and
    /// *how many*.
    static let railWidth: CGFloat = 44
    static let spineWidth: CGFloat = 34
    static let diffPaneMinimumWidth: CGFloat = 300
    static let windowWidth: CGFloat = 1400
    static let windowHeight: CGFloat = 860
    static let emptyStateMaximumWidth: CGFloat = 460
    static let emptyStateTitleSize: CGFloat = 20
    /// The terminal pane (DEC-054). Starting height and floor, both as constraints so the divider
    /// stays draggable — `--ds-term-*` covers what is drawn *inside* it.
    static let terminalPaneHeight: CGFloat = 260
    static let terminalPaneMinimumHeight: CGFloat = 90
}
