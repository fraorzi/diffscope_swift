import AppKit
import DiffScopeGit
import DiffScopeShell

/// The controls version two adds (DEC-092): the inclusion mark, the commit box, the banner that
/// says a repository is in the middle of something, and the sync control that is one button with
/// three states.
///
/// All four are drawn from `Theme` rather than assembled out of system controls, for the reason
/// DEC-091 gave: a mark set in a font wears that font's weight and optical centre, and none of
/// those belongs to this window.

/// How much of a file is staged. Three states, because *some of this file* is a fact a reader has
/// to be able to see without opening it — the state GitHub Desktop draws as a dash.
enum InclusionState: Equatable {
    case none, partial, all
}

/// The box beside a path. A click stages or unstages the whole file; the state is read back from
/// the index rather than remembered, so it cannot disagree with what git thinks.
final class CheckButton: HandButton {
    var inclusion: InclusionState = .none { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Theme.checkBoxSize + Theme.space2, height: Theme.checkBoxSize + Theme.space2)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.drawCheck(in: bounds, state: inclusion)
    }

    override var isFlipped: Bool { false }
}

/// GitHub Desktop's commit box, with its two fields and its one wide button — and with the
/// index still visible beside it, which is the half of the hybrid DEC-092 chose.
final class CommitBox: NSView {
    let summary = NSTextField()
    let body = NSTextView()
    let button = NSButton()
    let amend = NSButton()
    let status = NSTextField(labelWithString: "")

    /// What the button says. The branch is in the label because *commit* on its own does not say
    /// where it lands, and a reader who has just switched branches is asking exactly that.
    var branchName: String = "" {
        didSet { button.title = branchName.isEmpty ? "Commit" : "Commit to \(branchName)" }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.panelFiles.cgColor

        summary.font = Theme.prose(Theme.textSizeSmall)
        summary.placeholderString = "Summary"
        summary.isBezeled = false
        summary.drawsBackground = false
        summary.focusRingType = .none
        summary.textColor = Theme.ink
        summary.identifier = NSUserInterfaceItemIdentifier("commit.summary")

        body.font = Theme.prose(Theme.textSizeSmall)
        body.isRichText = false
        body.drawsBackground = false
        body.textColor = Theme.ink
        body.textContainerInset = NSSize(width: 0, height: 2)
        body.identifier = NSUserInterfaceItemIdentifier("commit.description")

        let descriptionScroll = OverlayScrollView()
        descriptionScroll.documentView = body
        descriptionScroll.drawsBackground = false
        descriptionScroll.hasVerticalScroller = true
        descriptionScroll.verticalScroller = SlimScroller()
        descriptionScroll.translatesAutoresizingMaskIntoConstraints = false
        body.autoresizingMask = [.width]

        button.title = "Commit"
        button.bezelStyle = .rounded
        button.font = Theme.prose(Theme.textSizeSmall, weight: .semibold)
        button.identifier = NSUserInterfaceItemIdentifier("commit.button")
        button.toolTip = KeyboardMap.binding(id: "git.commit")?.shortcut

        amend.setButtonType(.switch)
        amend.title = "Amend the last commit"
        amend.font = Theme.prose(Theme.textSizeTiny)
        amend.identifier = NSUserInterfaceItemIdentifier("commit.amend")

        status.font = Theme.font(Theme.textSizeTiny)
        status.textColor = Theme.inkQuiet
        status.lineBreakMode = .byTruncatingTail

        let summaryHost = RimHost.wrapping(summary, verticalPadding: Theme.searchTextPadding)
        let descriptionHost = RimHost.wrapping(descriptionScroll, verticalPadding: Theme.searchTextPadding)

        for view in [summaryHost, descriptionHost, amend, status, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            // **Nothing in this box may set the pane's minimum width.** `Commit to some-long-branch`
            // and `Amend the last commit` are strings the reader's repository decides the length
            // of, and pinned to both edges at the default resistance they became a floor under the
            // file pane — measured at 292 pt against the 260 the divider was dragged to, which is a
            // divider that refuses to move because of a button's title.
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        button.cell?.lineBreakMode = .byTruncatingTail
        amend.cell?.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            summaryHost.topAnchor.constraint(equalTo: topAnchor, constant: Theme.space3),
            summaryHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.space3),
            summaryHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.space3),
            summaryHost.heightAnchor.constraint(equalToConstant: Theme.commitSummaryHeight),

            descriptionHost.topAnchor.constraint(equalTo: summaryHost.bottomAnchor, constant: Theme.space2),
            descriptionHost.leadingAnchor.constraint(equalTo: summaryHost.leadingAnchor),
            descriptionHost.trailingAnchor.constraint(equalTo: summaryHost.trailingAnchor),
            descriptionHost.heightAnchor.constraint(equalToConstant: Theme.commitDescriptionHeight),

            amend.topAnchor.constraint(equalTo: descriptionHost.bottomAnchor, constant: Theme.space2),
            amend.leadingAnchor.constraint(equalTo: summaryHost.leadingAnchor),

            status.centerYAnchor.constraint(equalTo: amend.centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: amend.trailingAnchor, constant: Theme.space2),
            status.trailingAnchor.constraint(equalTo: summaryHost.trailingAnchor),

            button.topAnchor.constraint(equalTo: amend.bottomAnchor, constant: Theme.space2),
            button.leadingAnchor.constraint(equalTo: summaryHost.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: summaryHost.trailingAnchor),
            button.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Theme.space3),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The seam above it, the same hairline every other band in this window is separated by.
        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    var summaryText: String { summary.stringValue }
    var descriptionText: String { body.string }

    func clear() {
        summary.stringValue = ""
        body.string = ""
        amend.state = .off
    }
}

/// The band that says a repository is mid-merge, mid-rebase, mid-bisect or detached — with the
/// verbs on it.
///
/// This is the control lazygit's users trust it for and the one GitHub Desktop leaves to a
/// disabled button and a sentence: a repository in a state you did not choose, with no way out of
/// it on screen, is the single most confusing thing a Git interface can produce.
final class OperationBanner: NSView {
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    var verbTarget: AnyObject?
    var verbAction: Selector?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.bannerSurface.cgColor
        label.font = Theme.prose(Theme.textSizeSmall, weight: .semibold)
        label.textColor = Theme.bannerInk
        label.lineBreakMode = .byTruncatingTail
        stack.orientation = .horizontal
        stack.spacing = Theme.space2
        for view in [label, stack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.space6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: Theme.space4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.space6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Redrawn from the state rather than mutated: the verbs differ per operation, and a banner
    /// that keeps a stale button is a banner offering an action that does not apply.
    func show(_ operation: RepositoryOperation) {
        isHidden = !(operation.isInProgress || operation.bannerText != nil)
        label.stringValue = operation.bannerText ?? ""
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        for verb in operation.verbs {
            let button = NSButton(title: verb, target: verbTarget, action: verbAction)
            button.bezelStyle = .rounded
            button.font = Theme.prose(Theme.textSizeTiny)
            button.identifier = NSUserInterfaceItemIdentifier("banner.\(verb.lowercased())")
            stack.addArrangedSubview(button)
        }
    }
}

/// GitHub Desktop's one sync button, with its three states — and the counts beside it, which this
/// application has had since DEC-012 and which that one puts inside the button.
final class SyncButton: NSButton {
    enum Mode: Equatable {
        case fetch
        case pull(Int)
        case push(Int)
        case publish

        var title: String {
            switch self {
            case .fetch: return "Fetch origin"
            case let .pull(count): return "Pull origin \(count)"
            case let .push(count): return "Push origin \(count)"
            case .publish: return "Publish branch"
            }
        }
    }

    var mode: Mode = .fetch { didSet { title = mode.title } }
}
