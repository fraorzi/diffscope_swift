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
    /// `--ds-border`, for the one hairline a chrome bar draws.
    static let hairline = dynamic(dark: hex(0x28282d), light: hex(0xd9d9de))

    /// `--ds-focus-ring`, and the 2 px `12-…` §9 asks for: on the region's own border, never on a
    /// row inside it, so a reader can see *which of the three* has the keyboard.
    static let focusRing = dynamic(dark: hex(0x0a84ff), light: hex(0x0064d2))
    static let focusRingWidth: CGFloat = 2

    /// `--ds-button-rim` and `--ds-button-fill`. The empty state is the first screen a stranger
    /// meets, and its two buttons are the only place in the window where a control is the subject
    /// rather than a tool. The rim is drawn **around a standard `NSButton`** rather than replacing
    /// it: a hand-drawn button loses the key-equivalent ring, the pressed state and the focus
    /// behaviour that come free with the system's, and none of those is worth a border.
    static let buttonRim = dynamic(dark: hex(0x6e6e78), light: hex(0xb8b8c0))
    static let buttonFill = dynamic(dark: hex(0x1c1c1f), light: hex(0xffffff))
    static let buttonRimWidth: CGFloat = 1
    static let buttonRadius: CGFloat = 6

    /// `--ds-space-*`.
    static let space2: CGFloat = 4
    static let space3: CGFloat = 6
    static let space4: CGFloat = 8
    static let space6: CGFloat = 16

    /// `--ds-motion-quick`, in seconds. The same number as the webviews use, so a pane and a chip
    /// settle together rather than one chasing the other (DEC-064).
    static let motionQuick: TimeInterval = 0.12

    /// The window's own bars (the adopted design). The title bar carries the repository and its
    /// path; the status line sits at the bottom edge. `trafficLightInset` clears the three buttons
    /// the system draws in the title bar and nothing else.
    static let titleBarHeight: CGFloat = 44
    static let statusBarHeight: CGFloat = 24
    static let trafficLightInset: CGFloat = 78
    /// The column header over each list (DEC-071). Shorter than the status line, because it holds one
    /// upper-cased word at the smallest size and a count beside it — a bar as tall as the title's
    /// would read as a second title bar.
    static let paneHeaderHeight: CGFloat = 22

    /// The segmented pills (the adopted design): a trough, one raised segment in it, and a dashed
    /// outline where a segment cannot be chosen.
    ///
    /// `--ds-control-trough`, `--ds-control-thumb`, `--ds-control-border`.
    static let controlTrough = dynamic(dark: hex(0x1a1a1e), light: hex(0xe8e8ec))
    static let controlThumb = dynamic(dark: hex(0x33333a), light: hex(0xffffff))
    static let controlBorder = dynamic(dark: hex(0x3a3a42), light: hex(0xd0d0d8))
    static let pillHeight: CGFloat = 24
    static let pillRadius: CGFloat = 7
    static let pillInset: CGFloat = 2
    static let pillPadding: CGFloat = 12

    /// A chip in a row: the ahead-count, a file's note. `--ds-border-strong` outlines the dashed
    /// one, which is the *unknown* count and has to read as a different kind of thing.
    static let borderStrong = dynamic(dark: hex(0x6c6c76), light: hex(0x8f8f99))
    static let chipHeight: CGFloat = 15
    static let chipRadius: CGFloat = 4

    /// Row heights. Not tokens in the CSS, because the diff has no rows. The repository row is
    /// two lines since the adopted design: name and head state above, path below — a path is what
    /// tells two repositories of the same name apart (DEC-037), so it is not a tooltip.
    static let rowHeight: CGFloat = 20
    static let repositoryRowHeight: CGFloat = 34
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
    /// A floor the window cannot go under, whoever is asking — the reader dragging a corner, or
    /// AppKit satisfying a constraint. Hiding the split view for the empty state collapsed the
    /// content to **69 pt**, which is the two bars and nothing between them: both buttons were laid
    /// out at `y = −28`, off the top of a window that had shrunk under them, and the photograph of
    /// the first screen a stranger meets came out as a 2800×138 strip holding only the caption.
    static let windowMinimumWidth: CGFloat = 720
    static let windowMinimumHeight: CGFloat = 420
    /// The floor that actually holds the content view up. A split view has no height of its own, so
    /// the drawer needs one — see the constraint's own note in `buildWindow`.
    static let drawerMinimumHeight: CGFloat = 320
    static let emptyStateMaximumWidth: CGFloat = 460
    static let emptyStateTitleSize: CGFloat = 20
    /// The terminal pane (DEC-054). Starting height and floor, both as constraints so the divider
    /// stays draggable — `--ds-term-*` covers what is drawn *inside* it.
    static let terminalPaneHeight: CGFloat = 260
    static let terminalPaneMinimumHeight: CGFloat = 90
}

/// The selected row, drawn from the design's two tokens rather than by AppKit (DEC-066).
///
/// `--ds-row-selected` is the fill and `--ds-row-ring` is the shape, and the second is the point:
/// with the fill disabled — increased contrast, a greyscale screenshot, a printout — the ring is
/// what still says *this row*. AppKit's own highlight is a solid accent fill that also repaints
/// the row's text white, which would take the file-kind glyph's colour with it.
final class SelectedRowView: NSTableRowView {
    /// AppKit turns a selected row's labels white by telling the cell its background is
    /// "emphasized". The design's selected surface is a quiet grey, so white text on it is
    /// unreadable — and the file-kind glyph would lose the colour that is half of what it says.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.rowSelected.setFill()
        bounds.fill()
        Theme.rowRing.setStroke()
        let ring = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }
}

/// A band of chrome with one hairline edge — the title bar's is at the bottom, the status line's
/// at the top. Drawn rather than composed from a box view and a separator, because a separator
/// that is a subview gets laid out, and a hairline that is one point off reads as a mistake.
final class ChromeBar: NSView {
    enum Edge { case top, bottom }

    private let surface: NSColor
    private let edge: Edge

    init(surface: NSColor, edge: Edge) {
        self.surface = surface
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        surface.setFill()
        bounds.fill()
        Theme.hairline.setStroke()
        let line = NSBezierPath()
        let y = edge == .top ? bounds.maxY - 0.5 : bounds.minY + 0.5
        line.move(to: NSPoint(x: bounds.minX, y: y))
        line.line(to: NSPoint(x: bounds.maxX, y: y))
        line.lineWidth = 1
        line.stroke()
    }
}
