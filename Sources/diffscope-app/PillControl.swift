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
        /// The keystroke that selects this segment (DEC-073), from `KeyboardMap` and never typed
        /// here. Drawn on the pill because the map was visible only in the menu bar: a reader
        /// looking at the control had no way to learn its key without opening a menu.
        var hint: String = ""
        var enabled: Bool = true
        /// Why this segment cannot be chosen. Shown as a tooltip *and* — for the scope bar — put on
        /// the status line by the window, because a tooltip is invisible until pointed at.
        var reason: String?
    }

    private(set) var segments: [Segment] = []
    weak var target: AnyObject?
    var action: Selector?

    var selectedSegment: Int = 0 {
        didSet { needsDisplay = true }
    }

    init(labels: [String], hints: [String] = []) {
        super.init(frame: .zero)
        segments = labels.enumerated().map { Segment(title: $1, hint: hints.indices.contains($0) ? hints[$0] : "") }
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    // MARK: - The API the window already speaks

    func setEnabled(_ enabled: Bool, forSegment index: Int) {
        guard segments.indices.contains(index) else { return }
        segments[index].enabled = enabled
        needsDisplay = true
    }

    func setToolTip(_ tip: String?, forSegment index: Int) {
        guard segments.indices.contains(index) else { return }
        segments[index].reason = tip
        toolTip = segments.compactMap { $0.enabled ? nil : $0.reason }.first
    }

    // MARK: - Geometry

    private var font: NSFont { Theme.prose(Theme.textSizeSmall) }
    /// The key is set in the monospace face at the smallest size: a keystroke is a thing to be typed,
    /// not a word to be read, and the two faces say which is which without a rule between them.
    private var hintFont: NSFont { Theme.font(Theme.textSizeTiny) }

    private func hintWidth(of segment: Segment) -> CGFloat {
        guard !segment.hint.isEmpty else { return 0 }
        return (segment.hint as NSString).size(withAttributes: [.font: hintFont]).width + Theme.space2
    }

    private func width(of segment: Segment) -> CGFloat {
        (segment.title as NSString).size(withAttributes: [.font: font]).width
            + hintWidth(of: segment) + 2 * Theme.pillPadding
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

            // `inkQuiet`, not `inkFaint`: measured, the faint step is 4.32:1 on the trough and
            // 3.47:1 on the thumb in dark — under the 4.5 the design's own review fixed this ink to
            // (`27-…` §3). The dashed outline is what says *unavailable*; the colour never was.
            let colour: NSColor = !segment.enabled ? Theme.inkQuiet
                : index == selectedSegment ? Theme.ink : Theme.inkQuiet
            let weight: NSFont.Weight = index == selectedSegment ? .semibold : .regular
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Theme.prose(Theme.textSizeSmall, weight: weight),
                .foregroundColor: colour,
            ]
            let text = segment.title as NSString
            let size = text.size(withAttributes: attributes)
            let hint = segment.hint as NSString
            let hintAttributes: [NSAttributedString.Key: Any] = [
                // Same measurement: a key hint on the trough is 4.32:1 at `inkFaint`. It is set
                // in the monospace face at 10 pt, which is what keeps it quieter than the title.
                .font: hintFont, .foregroundColor: Theme.inkQuiet,
            ]
            let hintSize = segment.hint.isEmpty ? .zero : hint.size(withAttributes: hintAttributes)
            // Title and key are laid out as one block and then centred together, so the pair stays
            // centred in the pill rather than the title drifting left as the key grows.
            let blockWidth = size.width + (segment.hint.isEmpty ? 0 : Theme.space2 + hintSize.width)
            let left = box.midX - blockWidth / 2
            text.draw(at: NSPoint(x: left, y: box.midY - size.height / 2), withAttributes: attributes)
            if !segment.hint.isEmpty {
                hint.draw(at: NSPoint(x: left + size.width + Theme.space2,
                                      y: box.midY - hintSize.height / 2),
                          withAttributes: hintAttributes)
            }
        }

        if window?.firstResponder === self {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: -1, dy: -1),
                                    xRadius: Theme.pillRadius + 1, yRadius: Theme.pillRadius + 1)
            Theme.focusRing.setStroke()
            ring.lineWidth = Theme.focusRingWidth
            ring.stroke()
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
        // The block sits on the chrome band, where `inkFaint` measures 4.47:1.
        for (field, colour) in [(captionLabel, Theme.inkQuiet), (separator, Theme.inkQuiet),
                                (detailLabel, Theme.ink), (shortcutLabel, Theme.inkQuiet)] {
            field.font = Theme.font(Theme.textSizeTiny,
                                    weight: field === captionLabel ? .semibold : .regular)
            field.textColor = colour
            field.lineBreakMode = .byTruncatingTail
        }
        let stack = NSStackView(views: [captionLabel, separator, detailLabel, shortcutLabel])
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
