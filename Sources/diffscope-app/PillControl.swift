import AppKit
import DiffScopeShell

/// The segmented control the adopted design draws: a trough with one raised pill in it.
///
/// **Why not `NSSegmentedControl`.** Its look is the system's and cannot be moved far; the design's
/// scope bar, mode switch and lens switch are the three places a reader looks first, and they are
/// what makes the window recognisable. Drawing them is the smaller cost here than it was for the
/// empty state's buttons, and the reason is `12-…` §9: **every one of these is also a menu item**,
/// so the keyboard path does not run through this control at all. ⌘1 selects Structural whether or
/// not this view has ever seen a key event.
///
/// What is drawn rather than inherited, and therefore had to be built:
///
/// - the focus ring, so the control still says when it holds the keyboard (DEC-016);
/// - arrow-key movement while it does, because a control a reader can focus and not operate is
///   worse than one they cannot focus;
/// - the disabled state, **with its reason**, which `12-…` §3 requires of an unavailable scope and
///   which a system control renders as grey and silent.
final class PillControl: NSView {
    struct Segment {
        var title: String
        var enabled: Bool = true
        /// Why this segment cannot be chosen. Shown as a tooltip *and* — for the scope bar — put on
        /// the status line by the window, because a tooltip is invisible until pointed at.
        var reason: String?
    }

    private(set) var segments: [Segment] = []
    weak var target: AnyObject?
    var action: Selector?

    var selectedSegment: Int = 0 {
        didSet { needsDisplay = true; layoutGlass() }
    }

    // MARK: - Glass (DEC-077, `28-…` item 6)

    /// The raised pill, as the **system's own material** where the system has one.
    ///
    /// `NSGlassEffectView` is real AppKit on macOS 26 and this is the whole of using it: the thumb
    /// is a glass view whose `contentView` is the selected segment's label, so the text is rendered
    /// *inside* the glass rather than under it — the header is explicit that only `contentView` is
    /// guaranteed a place inside the effect, and a label added as a plain subview has no promised
    /// z-order against it.
    ///
    /// The container is here for the reason its documentation gives — it batches sibling glass and
    /// merges views that come within `spacing` of each other — and it is the seam `28-…` items 7
    /// and 8 need: a popover's glass approaching this control's is the morph the owner asked for,
    /// and the system does it rather than an animation this project would have to write.
    ///
    /// **Nothing imitates it below macOS 26.** The package targets `.macOS(.v13)`, where these
    /// stored properties are `nil` and `draw(_:)` fills the pill exactly as it did before. A drawn
    /// approximation of a material is the one thing the owner asked not to have.
    private var glassContainer: NSView?
    private var glassHost: NSView?
    private var glassThumb: NSView?
    private let glassLabel = NSTextField(labelWithString: "")
    private let glassLabelHost = NSView()

    init(labels: [String]) {
        super.init(frame: .zero)
        segments = labels.map { Segment(title: $0) }
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        buildGlass()
    }

    private func buildGlass() {
        guard #available(macOS 26, *) else { return }
        glassLabel.alignment = .center
        glassLabel.font = Theme.prose(Theme.textSizeSmall, weight: .semibold)
        glassLabel.textColor = Theme.ink
        glassLabelHost.addSubview(glassLabel)

        let thumb = NSGlassEffectView()
        thumb.cornerRadius = Theme.pillRadius - Theme.pillInset
        thumb.style = .regular
        thumb.contentView = glassLabelHost

        // **`contentView` is filled by the view it is given, on both of these.** Handing the glass
        // itself to the container made the thumb the size of the whole control: a solid pill across
        // all four scopes with the labels behind it. `contentView` is the *host* of the glass, not
        // the glass — the container's own words are "descendant views to merge together" — so a
        // plain transparent view goes here and the thumb is placed inside it by frame.
        let host = NSView()
        let container = NSGlassEffectContainerView()
        container.spacing = Theme.glassMergeSpacing
        container.contentView = host
        host.addSubview(thumb)

        addSubview(container)
        glassContainer = container
        glassHost = host
        glassThumb = thumb
    }

    /// The thumb is placed by hand rather than by constraints, for the reason `frame(ofSegment:)`
    /// exists: a segment's width is its title's width, which Auto Layout would have to be told
    /// about in a second place. The container fills the control and the thumb sits in it.
    private func layoutGlass() {
        guard let container = glassContainer, let host = glassHost, let thumb = glassThumb else { return }
        container.frame = bounds
        host.frame = bounds
        let box = frame(ofSegment: selectedSegment)
        thumb.frame = box
        glassLabelHost.frame = NSRect(origin: .zero, size: box.size)
        glassLabel.stringValue = segments.indices.contains(selectedSegment)
            ? segments[selectedSegment].title : ""
        let labelHeight = glassLabel.intrinsicContentSize.height
        glassLabel.frame = NSRect(x: 0, y: (box.height - labelHeight) / 2,
                                  width: box.width, height: labelHeight)
        // A segment that cannot be chosen is never raised — the trough's dashed outline is what
        // says so, and glass under a dashed outline would read as *chosen and unavailable*.
        let selectable = segments.indices.contains(selectedSegment)
            && segments[selectedSegment].enabled
        container.isHidden = !selectable
    }

    /// The glass thumb's frame in the control's own coordinates, and whether it is drawn at all.
    /// Read by the selftest: the material itself cannot be photographed on a machine without screen
    /// recording — `cacheDisplay` does not capture it any more than it captures a `WKWebView` — so
    /// what is asserted is that a **real** `NSGlassEffectView` exists, that it covers the selected
    /// segment and nothing else, and that it is absent where it should be.
    /// The label goes with it, because the one thing a flat capture cannot rule out is a chosen
    /// segment whose title is not drawn at all: it lives *inside* the glass, which is where the
    /// API asks for it and where nothing this project draws can be seen to put it.
    var glassReport: (present: Bool, hidden: Bool, frame: NSRect, className: String,
                      label: String, labelFrame: NSRect, labelInGlass: Bool) {
        guard let thumb = glassThumb, let container = glassContainer else {
            return (false, true, .zero, "none", "", .zero, false)
        }
        return (true, container.isHidden, thumb.frame, String(describing: type(of: thumb)),
                glassLabel.stringValue, glassLabel.frame,
                glassLabel.isDescendant(of: thumb) && !glassLabel.isHiddenOrHasHiddenAncestor)
    }

    override func layout() {
        super.layout()
        layoutGlass()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    // MARK: - The API the window already speaks

    func setEnabled(_ enabled: Bool, forSegment index: Int) {
        guard segments.indices.contains(index) else { return }
        segments[index].enabled = enabled
        needsDisplay = true
        // The glass follows: a segment that has just become unavailable must stop being raised in
        // the same pass that starts drawing its dashed outline, or the control says *chosen* and
        // *unavailable* at once. `needsDisplay` alone does not run `layout()`.
        layoutGlass()
    }

    func setToolTip(_ tip: String?, forSegment index: Int) {
        guard segments.indices.contains(index) else { return }
        segments[index].reason = tip
        toolTip = segments.compactMap { $0.enabled ? nil : $0.reason }.first
    }

    // MARK: - Geometry

    private var font: NSFont { Theme.prose(Theme.textSizeSmall) }

    private func width(of segment: Segment) -> CGFloat {
        (segment.title as NSString).size(withAttributes: [.font: font]).width + 2 * Theme.pillPadding
    }

    private func frame(ofSegment index: Int) -> NSRect {
        var x = Theme.pillInset
        for (position, segment) in segments.enumerated() {
            let segmentWidth = width(of: segment)
            if position == index {
                return NSRect(x: x, y: Theme.pillInset,
                              width: segmentWidth, height: bounds.height - 2 * Theme.pillInset)
            }
            x += segmentWidth
        }
        return .zero
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segments.reduce(2 * Theme.pillInset) { $0 + width(of: $1) },
               height: Theme.pillHeight)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let trough = NSBezierPath(roundedRect: bounds,
                                  xRadius: Theme.pillRadius, yRadius: Theme.pillRadius)
        Theme.controlTrough.setFill()
        trough.fill()
        Theme.controlBorder.setStroke()
        trough.lineWidth = 1
        trough.stroke()

        for (index, segment) in segments.enumerated() {
            let box = frame(ofSegment: index)
            if index == selectedSegment, segment.enabled {
                // Drawn **only where there is no glass to use** — macOS 25 and earlier. Above that
                // the thumb is an `NSGlassEffectView` and drawing a second pill under it would put
                // an opaque fill behind a material whose whole business is what is behind it.
                guard glassThumb == nil else { continue }
                let pill = NSBezierPath(roundedRect: box.insetBy(dx: 0, dy: 0),
                                        xRadius: Theme.pillRadius - Theme.pillInset,
                                        yRadius: Theme.pillRadius - Theme.pillInset)
                Theme.controlThumb.setFill()
                pill.fill()
                Theme.controlBorder.setStroke()
                pill.lineWidth = 1
                pill.stroke()
            } else if !segment.enabled {
                // Disabled is a **shape**, not a shade: a dashed outline survives greyscale and a
                // screenshot, which is the rule the whole change language follows (DEC-035).
                let outline = NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1),
                                           xRadius: Theme.pillRadius - Theme.pillInset,
                                           yRadius: Theme.pillRadius - Theme.pillInset)
                outline.setLineDash([3, 2], count: 2, phase: 0)
                Theme.controlBorder.setStroke()
                outline.lineWidth = 1
                outline.stroke()
            }

            // Tertiary again since DEC-076 re-sized that ink against the trough and the thumb.
            // The dashed outline is what says *unavailable*; the colour never was.
            let colour: NSColor = !segment.enabled ? Theme.inkFaint
                : index == selectedSegment ? Theme.ink : Theme.inkQuiet
            let weight: NSFont.Weight = index == selectedSegment ? .semibold : .regular
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Theme.prose(Theme.textSizeSmall, weight: weight),
                .foregroundColor: colour,
            ]
            let text = segment.title as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2),
                      withAttributes: attributes)
        }

    }

    // MARK: - Acting

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for index in segments.indices where frame(ofSegment: index).contains(point) {
            guard segments[index].enabled else { return }
            selectedSegment = index
            if let action { NSApp.sendAction(action, to: target, from: self) }
            return
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func keyDown(with event: NSEvent) {
        let step: Int
        switch event.keyCode {
        case 123: step = -1   // ←
        case 124: step = 1    // →
        default: super.keyDown(with: event); return
        }
        // Skips what it cannot choose: an unavailable scope is not a stop on the way to the next
        // one, for the same reason a group header is not a stop in the file list (DEC-033).
        var index = selectedSegment
        for _ in segments.indices {
            index += step
            guard segments.indices.contains(index) else { return }
            if segments[index].enabled { break }
        }
        guard segments.indices.contains(index), segments[index].enabled else { return }
        selectedSegment = index
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
}

/// A block in the chrome: a caption, the fact, and the keystroke that changes it (DEC-072).
///
/// The base is the one input to the comparison a reader chooses rather than reads, and prose cannot
/// say that. Clicking it runs the same command `⇧⌘B` runs — the button is a route to a binding, not
/// a second implementation of it (DEC-071).
///
/// **The rim is dashed when the fact is not the one on screen**, which is `ChipView`'s dashed
/// unknown count and `PillControl`'s dashed unavailable scope saying the same thing in the same
/// shape: a distinction that survives greyscale (DEC-035).
final class FactBlock: NSView {
    private let captionLabel = NSTextField(labelWithString: "")
    private let separator = NSTextField(labelWithString: "|")
    private let detailLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var dashed = true

    weak var target: AnyObject?
    var action: Selector?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for (field, colour) in [(captionLabel, Theme.inkQuiet), (separator, Theme.inkFaint),
                                (detailLabel, Theme.ink), (shortcutLabel, Theme.inkFaint)] {
            field.font = Theme.font(Theme.textSizeTiny,
                                    weight: field === captionLabel ? .semibold : .regular)
            field.textColor = colour
            field.lineBreakMode = .byTruncatingTail
        }
        // The keystroke is gone from the block (DEC-077); it is still on the tooltip and in the menu.
        shortcutLabel.isHidden = true
        let stack = NSStackView(views: [captionLabel, separator, detailLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Theme.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.space3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.space3),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.pillHeight),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// Everything the block says, in one call, from one composition (`ChromeLabels`).
    func show(_ text: ChromeLabels.BlockText) {
        captionLabel.stringValue = text.caption
        detailLabel.stringValue = text.detail
        shortcutLabel.stringValue = text.shortcut
        toolTip = "\(text.caption): \(text.detail) — \(text.shortcut)"
        dashed = text.dashed
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rim = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               xRadius: Theme.chipRadius, yRadius: Theme.chipRadius)
        if dashed { rim.setLineDash([3, 2], count: 2, phase: 0) }
        (dashed ? Theme.borderStrong : Theme.hairline).setStroke()
        rim.lineWidth = 1
        rim.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}

/// A chip: a short fact in a bordered pill (the adopted design's rows).
///
/// Dashed when the fact is *unknown* rather than small — `↑ unknown` is the only chip in the window
/// that is not a number, and `12-…` §2 requires it to read as a different kind of thing, not as a
/// quieter number. A dash survives greyscale; a lighter grey does not.
final class ChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dashed: Bool

    init(text: String, dashed: Bool = false, emphasis: Bool = false) {
        self.dashed = dashed
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = text
        label.font = Theme.font(Theme.textSizeTiny)
        label.textColor = emphasis ? Theme.ink : Theme.inkQuiet
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.space2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.space2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.chipHeight),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: Theme.chipRadius, yRadius: Theme.chipRadius)
        if dashed { outline.setLineDash([3, 2], count: 2, phase: 0) }
        (dashed ? Theme.borderStrong : Theme.hairline).setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}

/// The changed-file pane: a header over a list, laid out by hand (DEC-071, and the measurement in
/// step 63).
///
/// **A pane inside `NSSplitView` cannot use Auto Layout for its own contents.** The split sets its
/// arranged subviews' frames directly, so the frame and the layout engine disagree the moment a
/// divider moves: on ⌃⌘0 the pane's frame went to 34 pt while the engine still valued its width at
/// 320, and a `width == pane.width` constraint on the list was satisfied against the engine's
/// number — a full-width file list inside a 34 pt spine, in a window where every check passed.
///
/// So this view places its two children in `layout()`, from `bounds`, which is the one number that
/// is true whoever set it.
final class FilePane: NSView {
    var header: NSView?
    var list: NSView?

    override func layout() {
        super.layout()
        place()
    }

    /// **`setFrameSize`, not only `layout`.** `NSSplitView` resizes a pane by setting its frame, and
    /// a frame change alone runs *autoresizing* — `layout()` is never asked. The first version of
    /// this view placed its children in `layout()` and measured a 320 pt list inside a 34 pt pane in
    /// five runs out of five, which is the same disagreement one level down.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    /// Internal, because the split view's own layout pass runs after this one and puts the list
    /// back — the same fix-up the table already needs (`applyCollapses`).
    func place() {
        guard let header, let list else { return }
        header.frame = NSRect(x: 0, y: bounds.height - Theme.paneHeaderHeight,
                              width: bounds.width, height: Theme.paneHeaderHeight)
        list.frame = NSRect(x: 0, y: 0, width: bounds.width,
                            height: max(0, bounds.height - Theme.paneHeaderHeight))
    }
}
