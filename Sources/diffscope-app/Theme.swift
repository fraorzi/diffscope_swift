import AppKit
import DiffScopeGit

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
    /// be watched: the adopted design's first draft had it at 2.7:1 against paper (`27-…` §3).
    ///
    /// **That correction was measured against the paper only**, and the chrome has eight other
    /// surfaces: the faint step measured **4.47:1** on the chrome band, **4.32:1** on the control
    /// trough, **4.12:1** on a selected row and **3.47:1** on the raised thumb in dark. DEC-076
    /// re-sized it against the extremes instead — `--ds-row-selected` in light and
    /// `--ds-control-thumb` in dark, both at **4.72:1** — so the third ink is usable everywhere the
    /// chrome draws. 4.7 rather than 5.0 because at 5.0 the dark value lands 1.06:1 from `inkQuiet`,
    /// and three inks that read as two are worse than a tenth of headroom.
    /// `runChromeChecks` holds every pair to 4.5:1 in both appearances.
    static let ink = dynamic(dark: hex(0xf2f2f5), light: hex(0x16161a))
    static let inkQuiet = dynamic(dark: hex(0xa8a8b1), light: hex(0x42424a))
    static let inkFaint = dynamic(dark: hex(0x9e9ea7), light: hex(0x57575f))

    /// The surfaces AppKit draws, mirrored from the `@chrome` block of `tokens.css` (DEC-066).
    /// The check suite requires every token in that block to be named here; a design that stops at
    /// the edge of the webview leaves two thirds of the window looking like a different
    /// application.
    ///
    /// `--ds-chrome`, `--ds-panel-repos`, `--ds-panel-files` — **one value** (DEC-088, reversing
    /// DEC-080). The three names stay because the token table is the design's and a design may pull
    /// them apart again; what they no longer do is put three neutrals a hundredth apart in one
    /// window. The step that survives is the one that was always the point — the code against the
    /// chrome around it — and the seams do the rest.
    static let chrome = dynamic(dark: hex(0x131317), light: hex(0xf2f2f6))
    static let panelRepositories = chrome
    static let panelFiles = chrome
    /// `--ds-empty-bg`
    static let emptyStateSurface = dynamic(dark: hex(0x0a0a0c), light: hex(0xeeeef2))
    /// `--ds-row-selected` and `--ds-row-ring`. Two halves of one signal: the ring is the shape
    /// that survives when the fill is disabled, so selection is never carried by colour alone.
    static let rowSelected = dynamic(dark: hex(0x2f2f38), light: hex(0xd5d5de))
    static let rowRing = dynamic(dark: hex(0x484852), light: hex(0xbcbcc8))
    /// `--ds-win-edge`
    static let windowEdge = dynamic(dark: .white, light: .black).withAlphaComponent(0.16)
    /// `--ds-border`, for the one hairline a chrome bar draws.
    static let hairline = dynamic(dark: hex(0x28282d), light: hex(0xd9d9de))

    /// `--ds-focus-ring`, and the 2 px `12-…` §9 asks for: on the region's own border, never on a
    /// row inside it, so a reader can see *which of the three* has the keyboard.
    static let focusRing = dynamic(dark: hex(0x0a84ff), light: hex(0x0064d2))
    static let focusRingWidth: CGFloat = 2
    /// The bar marking the selected row (DEC-077). Three points, at the leading edge, in the
    /// strongest ink — *which repository am I in* is a question the window has to answer from the
    /// list itself, not only from the title bar.
    static let selectedEdgeWidth: CGFloat = 3

    /// `--ds-button-rim` and `--ds-button-fill`. The empty state is the first screen a stranger
    /// meets, and its two buttons are the only place in the window where a control is the subject
    /// rather than a tool. The rim is drawn **around a standard `NSButton`** rather than replacing
    /// it: a hand-drawn button loses the key-equivalent ring, the pressed state and the focus
    /// behaviour that come free with the system's, and none of those is worth a border.
    static let buttonRim = dynamic(dark: hex(0x6e6e78), light: hex(0xb8b8c0))
    static let buttonFill = dynamic(dark: hex(0x1c1c1f), light: hex(0xffffff))
    static let buttonRimWidth: CGFloat = 1
    static let buttonRadius: CGFloat = 6

    /// `--ds-rim-highlight`, `--ds-rim-shadow`, `--ds-rim-fill` (DEC-084): the adopted design's
    /// rimmed disc, which the `+` wears.
    ///
    /// **The rim is a pair, and the pair is the effect.** A gradient whose two ends are the same
    /// colour is a flat stroke with extra steps, so the two are held **1.30:1 apart in luminance** —
    /// the same form of assertion the change tints get, and for the same reason: metal is a
    /// *lightness* gradient, and a check on hue would pass a rim nobody can see. Measured at 4.49:1
    /// in dark and 2.72:1 in light.
    ///
    /// Derived from `--ds-button-rim` opened out in both directions along DEC-080's ladder rather
    /// than transcribed: the design arrived as a small paste and never as a file, so nothing in it
    /// was measured. If the design's own values differ this is a token edit and nothing else.
    static let rimHighlight = dynamic(dark: hex(0x9a9aa6), light: hex(0xffffff))
    static let rimShadow = dynamic(dark: hex(0x33333c), light: hex(0x9c9ca8))
    static let rimFill = dynamic(dark: hex(0x1b1b21), light: hex(0xe9e9f0))
    /// A guess, and named as one in DEC-084: legible on this machine, unmeasured from the design.
    static let rimWidth: CGFloat = 1.5

    /// **Light on metal, not a ramp** (DEC-085 item 5). DEC-084 built a two-stop axial gradient and
    /// the owner read it as exactly that: *a gradient*, not a reflection.
    ///
    /// What a curved metal edge actually does under a light above it: **bright along a narrow arc
    /// at the top, falling off quickly either side, and lifting again at the bottom** where the
    /// surface below bounces light back. Five stops, and the brightest is not in the middle — a
    /// symmetric ramp is the thing this replaces, so the check asserts both the count and the
    /// asymmetry.
    ///
    /// Positions run bottom (0) to top (1), which is how `draw(in:angle:)` reads 90° in an
    /// unflipped view.
    static let rimStops: [(colour: NSColor, at: CGFloat)] = [
        (rimShadow.blended(withFraction: 0.35, of: rimHighlight) ?? rimShadow, 0.0),
        (rimShadow, 0.30),
        (rimShadow.blended(withFraction: 0.45, of: rimHighlight) ?? rimShadow, 0.72),
        (rimHighlight, 0.88),
        (rimHighlight.blended(withFraction: 0.25, of: rimShadow) ?? rimHighlight, 1.0),
    ]

    /// The one place the specular ramp is built, so the `+`, the search field and the checkbox
    /// cannot end up with three different metals.
    static var rimGradient: NSGradient? {
        NSGradient(colors: rimStops.map(\.colour),
                   atLocations: rimStops.map(\.at),
                   colorSpace: .sRGB)
    }

    /// `--ds-kind-added`, `--ds-kind-modified`, `--ds-kind-deleted`, `--ds-kind-renamed` (DEC-081).
    /// Named in full rather than abbreviated, because the mirror check reads these names literally
    /// — the shorthand `-modified` left three of the four unmirrored and the check said so. The
    /// owner's report was
    /// *"nie widzę żeby te ikonki miały kolor np żółty gdy było coś zmieniane w pliku"*.
    ///
    /// **Colour is the second carrier, never the first.** `ChangeKind.glyph` — `+ − → ✎` — says the
    /// kind with every colour removed, which is DEC-035 and which `24-…` records the adopted design
    /// getting wrong once already: it drew the collapsed spine's bars distinguished by hue alone.
    /// So this is redundancy for a reader scanning a list of sixty files, and the three kinds with
    /// no colour of their own keep the ordinary ink rather than being given one to fill the table.
    ///
    /// Held to 4.5:1 on **all three surfaces a row is drawn on** — the file pane, the repository
    /// pane and a selected row — because a glyph is only legible where it is drawn, which is the
    /// lesson DEC-076 paid for with the tertiary ink.
    static func kind(_ kind: ChangeKind) -> NSColor {
        switch kind {
        // `untracked` rides with `added` (DEC-088): it wears the same `+`, and a `+` in the added
        // hue beside one in the ordinary ink would have been two marks for one fact.
        case .added, .untracked: return dynamic(dark: hex(0x5cd67d), light: hex(0x16602a))
        case .modified: return dynamic(dark: hex(0xe8bd45), light: hex(0x7a5300))
        case .deleted: return dynamic(dark: hex(0xff8b84), light: hex(0x9e1420))
        case .renamed: return dynamic(dark: hex(0x7fb8ff), light: hex(0x1a4f9c))
        case .typeChanged, .unmerged: return ink
        }
    }

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
    /// 30, not 24: the status line holds the mode switch since DEC-075, and a 24 pt pill cannot sit
    /// in a 24 pt bar.
    static let statusBarHeight: CGFloat = 30
    static let trafficLightInset: CGFloat = 78
    /// The scope row across the window (DEC-072): a 24 pt pill with the row's own padding around it.
    static let scopeBarHeight: CGFloat = 36
    /// The header over each of the **three** panes (DEC-071, sized by DEC-083). Two of them hold an
    /// upper-cased word and a count; the third holds the lens switch, and a 24 pt pill does not fit
    /// in the 22 pt this was.
    ///
    /// **One number, because the three surfaces have to begin at the same height.** The diff pane's
    /// band was built separately at `space4 + pill + space4` = 40 pt, so the code's background
    /// started 18 pt below the two lists' and the window read as three things laid out apart — which
    /// they were. Sized to the control rather than to the word: still well under the 44 pt title
    /// bar, so it does not read as a second one.
    ///
    /// `--ds-pane-header-height`, and it is a token because the **third** header is a `<div>` in a
    /// webview (DEC-088). Two of the three are `ChromeBar`s of this height; the third was
    /// `space3 + text + space3` = 27, so the seam under the file's path sat five points above the
    /// seam under `CHANGED FILES` — one line across the window, laid out twice. A check requires
    /// the two numbers to agree.
    static let paneHeaderHeight: CGFloat = pillHeight + 2 * space2

    /// The segmented pills (the adopted design): a trough, one raised segment in it, and a dashed
    /// outline where a segment cannot be chosen.
    ///
    /// `--ds-control-trough`, `--ds-control-thumb`, `--ds-control-border`.
    static let controlTrough = dynamic(dark: hex(0x1a1a1e), light: hex(0xe3e3ea))
    static let controlThumb = dynamic(dark: hex(0x33333a), light: hex(0xffffff))
    static let controlBorder = dynamic(dark: hex(0x3a3a42), light: hex(0xd0d0d8))
    static let pillHeight: CGFloat = 24
    static let pillRadius: CGFloat = 7
    static let pillInset: CGFloat = 2
    static let pillPadding: CGFloat = 12

    /// The smallest a pointer target may be (DEC-083). The `+` and the two collapse chevrons were
    /// borderless buttons with no size of their own, so the target was the glyph — 11 pt — and a
    /// pane collapsed to a 44 pt rail left that chevron as the only thing in it to hit.
    ///
    /// 24 rather than the 44 the phone guidelines use: this is a pointer with a pixel of precision
    /// on a dense window, not a fingertip, and 44 pt of chrome per chevron would cost the lists the
    /// room they exist to give. It is a **floor** — a control with more to say stays wider.
    static let minimumHitTarget: CGFloat = 24

    /// **The chevron, drawn** (DEC-085 item 6). It was the character `⌄`, which is a *modifier
    /// letter*: it carries its own side bearings and its own baseline, so it read as a `>` and sat
    /// off-centre against both the label beside it and the padding around it. A font's idea of
    /// where that glyph sits is precisely what was wrong with it.
    ///
    /// Two strokes, mitred, centred on the box by arithmetic rather than by metrics — so the same
    /// call centres it in a pill, in the title bar, and anywhere else a switch appears.
    static func drawChevron(in box: NSRect, colour: NSColor? = nil) {
        let width = chevronArmWidth
        let height = chevronArmHeight
        let path = NSBezierPath()
        path.move(to: NSPoint(x: box.midX - width, y: box.midY + height / 2))
        path.line(to: NSPoint(x: box.midX, y: box.midY - height / 2))
        path.line(to: NSPoint(x: box.midX + width, y: box.midY + height / 2))
        path.lineWidth = chevronStroke
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (colour ?? inkQuiet).setStroke()
        path.stroke()
    }
    /// Half the chevron's span and its drop. Sized against the small text it sits beside rather
    /// than against a font's glyph box.
    static let chevronArmWidth: CGFloat = 3.5
    static let chevronArmHeight: CGFloat = 3.5
    static let chevronStroke: CGFloat = 1.5

    /// The vertical room above and below the search field's line (DEC-088). The field was its
    /// font's line height and nothing else — `intrinsicContentSize` reports 14 — so the caret sat
    /// on the metal. Used twice: as the rim's vertical inset, so the control is taller, and inside
    /// `SearchFieldCell` so the field editor gets the room rather than only the box around it.
    static let searchTextPadding: CGFloat = 4

    /// The lists' scrollbar (DEC-088). AppKit's overlay scroller is 15 pt wide with a 7 pt knob;
    /// in a 320 pt pane of paths that is a stripe down the side of every row it overlays. The knob
    /// is drawn here instead — narrower, inset from the edge, and with **no slot behind it**, so
    /// nothing is drawn at all until the reader scrolls.
    static let scrollerWidth: CGFloat = 9
    static let scrollerKnobWidth: CGFloat = 4
    static let scrollerKnobInset: CGFloat = 2
    /// The knob, in both appearances. It is drawn over whichever list it belongs to and over the
    /// code where a row runs under it, so it is an alpha rather than a value from the table.
    static let scrollerKnob = dynamic(dark: .white, light: .black).withAlphaComponent(0.34)

    /// The width of the box the chevron is centred in (DEC-077).
    /// A control showing one of several with nothing to say so reads as a label.
    static let pillChevronWidth: CGFloat = 14

    /// The popover holding the options a switch is not showing. A row is one option; an option that
    /// cannot be chosen is a row and a half, because the reason goes under it rather than into a
    /// tooltip (`12-…` §3).
    static let optionRowHeight: CGFloat = 22
    static let optionReasonHeight: CGFloat = 14
    static let optionInset: CGFloat = 6
    static let optionMarkWidth: CGFloat = 20

    /// How close two glass views have to be before `NSGlassEffectContainerView` merges them
    /// (macOS 26, DEC-077). The system does the morph; this is the only number it takes, and it is
    /// here rather than at the call site so the three switches cannot merge at three distances.
    /// Sized against `pillPadding`: two controls a segment's padding apart read as one control.
    static let glassMergeSpacing: CGFloat = 12

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
    /// 42 since DEC-083, and the eight points are the cost of a clickable chevron. Collapsed, this
    /// pane's header holds two things that both have to be there: the **count**, because DEC-060
    /// drops the word and keeps the number, and the **chevron**, because it is the only way back.
    /// A 24 pt target beside a 12 pt count does not fit in 34.
    ///
    /// The rail beside it stayed at 44 by dropping its `+` instead — adding a source has two other
    /// pointer routes and the chevron has none, so that is where the room came from there.
    static let spineWidth: CGFloat = 42
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
        // **A bar at the leading edge** (DEC-077). The fill is one step of grey away from the panel
        // it sits on — deliberately quiet, and the owner could not see which repository was open
        // without reading the title bar. An edge is the strongest mark that costs no colour, and it
        // is the one the lens already uses for work that is not committed.
        Theme.ink.setFill()
        NSRect(x: 0, y: 0, width: Theme.selectedEdgeWidth, height: bounds.height).fill()
    }
}

/// A band of chrome with one hairline edge — the title bar's is at the bottom, the status line's
/// at the top. Drawn rather than composed from a box view and a separator, because a separator
/// that is a subview gets laid out, and a hairline that is one point off reads as a mistake.
final class ChromeBar: NSView {
    enum Edge { case top, bottom }

    private let surface: NSColor?
    private let edge: Edge

    /// DEC-086: **a bar can be see-through.** The title band is the system's own vibrancy now, so
    /// the surface behind it must not be painted — `nil` means *draw the seam and nothing else*.
    init(surface: NSColor?, edge: Edge) {
        self.surface = surface
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        surface?.setFill()
        if surface != nil { bounds.fill() }
        Theme.hairline.setStroke()
        let line = NSBezierPath()
        let y = edge == .top ? bounds.maxY - 0.5 : bounds.minY + 0.5
        line.move(to: NSPoint(x: bounds.minX, y: y))
        line.line(to: NSPoint(x: bounds.maxX, y: y))
        line.lineWidth = 1
        line.stroke()
    }
}
