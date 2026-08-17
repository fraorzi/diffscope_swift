import Foundation

/// The keyboard map as **data**, so the coverage `12-desktop-ux-specification.md` §9 makes binding
/// can be checked rather than read (DEC-016, DEC-057).
///
/// DEC-016 commits to full keyboard operation of every function and says that *"any function
/// reachable only by pointer is a defect"*. That sentence has no teeth while the specification's
/// coverage table lives in Markdown and the menu lives in a hand-written list — the two can drift
/// without anything noticing, and they had: *show raw for the current region* was specified,
/// unimplemented, and unreported for the whole of M6 through M8.
///
/// So the table is transcribed here as an enum, every binding declares which row of it it
/// satisfies, and `diffscope-verify` fails when a row has no binding. The application builds its
/// menu bar from `KeyboardMap.bindings` rather than from literals, which is what makes the map the
/// map rather than a second copy of it — the T1 lesson about gate T0 measuring the shipping code.
///
/// This target holds no AppKit: modifiers are named here and translated in the shell, so the map
/// stays linkable by the check suite.
public enum KeyboardFunction: String, CaseIterable, Sendable {
    case moveBetweenRepositories
    case moveBetweenFiles
    case switchScope
    case changeNavigation
    case switchMode
    case expandCollapsed
    case rawForCurrentRegion
    case openInEditor
    case moveFocus
    // Version two's rows (DEC-092). `12-…` §9b is the table these transcribe, added with them —
    // DEC-016's rule is unchanged and now covers operations that write: a function reachable only
    // by pointer is still a defect, and staging by clicking a box would have been exactly that.
    case stageAndUnstage
    case commitChanges
    case manageBranches
    case syncWithRemote
    case actOnCommit

    /// The row of `12-…` §9 this transcribes, quoted so a later reader can check the transcription
    /// against the specification rather than trusting the enum's name.
    public var requirement: String {
        switch self {
        case .moveBetweenRepositories: return "Move between repositories"
        case .moveBetweenFiles: return "Move between files (one-dimensional, per DEC-033)"
        case .switchScope: return "Switch scope"
        case .changeNavigation: return "Next / previous change"
        case .switchMode: return "Switch mode (Structural / Expanded / Raw)"
        case .expandCollapsed: return "Expand a collapsed range or formatting group"
        case .rawForCurrentRegion: return "Show raw for the current region"
        case .openInEditor: return "Open current file and line in the editor"
        case .moveFocus: return "Focus movement between sidebar, file list, and diff"
        case .stageAndUnstage: return "Stage and unstage the selected file"
        case .commitChanges: return "Commit what is staged"
        case .manageBranches: return "Switch, create and manage branches"
        case .syncWithRemote: return "Fetch, pull and push"
        case .actOnCommit: return "Act on a commit in History"
        }
    }
}

public struct KeyboardModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyboardModifiers(rawValue: 1 << 0)
    public static let shift = KeyboardModifiers(rawValue: 1 << 1)
    public static let option = KeyboardModifiers(rawValue: 1 << 2)
    /// Added by DEC-065 for the layout tier. Nothing needed it while every binding was ⌘-based,
    /// and `⌃1`–`⌃4` stayed rejected: macOS takes those for switching desktops.
    public static let control = KeyboardModifiers(rawValue: 1 << 3)

    /// `⌥⌘R` rather than `option+command+r`: this string is shown to a person in the tester packet
    /// and written into the documents, so it is composed once here. The order is the one macOS
    /// prints — ⌃⌥⇧⌘ — so a shortcut in a document matches the same shortcut in the menu bar.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// Which menu a binding is drawn in. The menu bar is the keyboard map's visible form (DEC-016):
/// bindings live there so they are discoverable, and so macOS routes them whatever holds focus.
public enum KeyboardMenu: String, CaseIterable, Sendable {
    case application, view, sources, navigate, repository

    public var title: String {
        switch self {
        case .application: return "DiffScope"
        case .view: return "View"
        case .sources: return "Sources"
        case .navigate: return "Navigate"
        // Version two's menu (DEC-092). Everything that writes is in one place, so *what can this
        // application change* is a question a reader answers by opening one menu.
        case .repository: return "Repository"
        }
    }
}

public struct KeyboardBinding: Sendable, Equatable {
    /// A stable identifier the shell maps to a selector. A `Selector` here would drag AppKit into
    /// the target the check suite links.
    public let id: String
    public let title: String
    public let key: String
    public let modifiers: KeyboardModifiers
    public let menu: KeyboardMenu
    /// The row of `12-…` §9 this binding satisfies, or `nil` for a function the specification's
    /// table does not list — the terminal (DEC-053…056), source management, quitting.
    public let satisfies: KeyboardFunction?
    /// Passed through to the menu item, for the bindings that select one of several segments.
    public let tag: Int?
    /// Items that carry a checkmark and are toggled rather than invoked.
    public let isToggle: Bool

    public init(id: String, title: String, key: String, modifiers: KeyboardModifiers,
                menu: KeyboardMenu, satisfies: KeyboardFunction? = nil,
                tag: Int? = nil, isToggle: Bool = false) {
        self.id = id
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.menu = menu
        self.satisfies = satisfies
        self.tag = tag
        self.isToggle = isToggle
    }

    /// Arrows, Return and the backtick are written as the reader sees them; letters are upper-cased
    /// the way a menu prints them. `key` is the design's notation throughout and the shell
    /// translates it into AppKit's function-key constants, so nothing outside the shell has to know
    /// that a down arrow is `U+F701`.
    public var shortcut: String { modifiers.symbols + (key.count == 1 && key.first!.isLetter ? key.uppercased() : key) }
}

public enum KeyboardMap {
    /// The bindings, in menu order. Adding a function to the application means adding a row here;
    /// there is nowhere else to add it.
    public static let bindings: [KeyboardBinding] = [
        // ⌘, is where macOS keeps settings, and DEC-015's template is the first thing this
        // application has that a person configures rather than chooses per repository.
        .init(id: "preferences", title: "Settings…", key: ",", modifiers: [.command], menu: .application),
        .init(id: "quit", title: "Quit DiffScope", key: "q", modifiers: [.command], menu: .application),

        // Structural first, because it is the default mode and the one a reader returns to
        // (DEC-065). The tags are positions in `PresentationMode.allCases` and are unchanged; only
        // the keys moved.
        .init(id: "mode.structural", title: "Structural", key: "1", modifiers: [.command], menu: .view,
              satisfies: .switchMode, tag: 1),
        .init(id: "mode.expanded", title: "Expanded", key: "2", modifiers: [.command], menu: .view,
              satisfies: .switchMode, tag: 2),
        .init(id: "mode.raw", title: "Raw", key: "3", modifiers: [.command], menu: .view,
              satisfies: .switchMode, tag: 0),
        // The control view of DEC-013, pointed at where the reader is standing rather than at the
        // whole file. Not a fourth mode: it switches to Raw and back, keeping the change stop.
        // `⌘R` rather than DEC-057's `⌥⌘V`, and the reversal is recorded in DEC-065: `R` was
        // rejected as reading like *refresh*, but refresh here is automatic and has no binding for
        // the mistake to collide with, and this is a move a reader makes constantly.
        .init(id: "rawRegion", title: "Raw for Current Region", key: "r", modifiers: [.command],
              menu: .view, satisfies: .rawForCurrentRegion, isToggle: true),
        .init(id: "terminal", title: "Terminal", key: "`", modifiers: [.control],
              menu: .view, isToggle: true),
        // Tabs (DEC-067). ⌥⌘T is free since ⌃` took the drawer, and it is what the drawer used to
        // be — the muscle memory lands on "another shell" rather than on nothing.
        .init(id: "terminal.newTab", title: "New Terminal Tab", key: "t",
              modifiers: [.option, .command], menu: .view),
        .init(id: "terminal.nextTab", title: "Next Terminal Tab", key: "]",
              modifiers: [.control, .command], menu: .view),
        .init(id: "terminal.previousTab", title: "Previous Terminal Tab", key: "[",
              modifiers: [.control, .command], menu: .view),
        .init(id: "terminal.closeTab", title: "Close Terminal Tab", key: "w",
              modifiers: [.control, .command], menu: .view),
        .init(id: "terminal.raw", title: "Terminal Raw Mode", key: "r", modifiers: [.option, .command],
              menu: .view, isToggle: true),
        .init(id: "terminal.follow", title: "Terminal: Follow Selection", key: "k",
              modifiers: [.option, .command], menu: .view),
        .init(id: "wrap", title: "Wrap Long Lines", key: "w", modifiers: [.option, .command],
              menu: .view, isToggle: true),
        // DEC-059: unified is the default and this is the way out of it. Not a mode of the model —
        // both layouts project the same canonical diff over the same pinned pair.
        .init(id: "layout.sideBySide", title: "Side by Side", key: "→", modifiers: [.option, .command],
              menu: .view, isToggle: true),
        // DEC-060: the layout tier, and the reason `.control` exists in this file.
        // The three lenses (DEC-061). ⌃⌘H is free on macOS; ⌥⌘H is Hide Others and would have
        // hidden the application every time a reader asked for its history.
        .init(id: "lens.diff", title: "Lens: Diff", key: "d", modifiers: [.control, .command],
              menu: .view, isToggle: true),
        .init(id: "lens.blame", title: "Lens: Blame", key: "b", modifiers: [.control, .command],
              menu: .view, isToggle: true),
        .init(id: "lens.history", title: "Lens: History", key: "h", modifiers: [.control, .command],
              menu: .view, isToggle: true),
        .init(id: "collapse.repositories", title: "Collapse Repositories", key: "1",
              modifiers: [.control, .command], menu: .view, isToggle: true),
        .init(id: "collapse.files", title: "Collapse Changed Files", key: "2",
              modifiers: [.control, .command], menu: .view, isToggle: true),
        .init(id: "collapse.both", title: "Collapse Both", key: "0",
              modifiers: [.control, .command], menu: .view),
        .init(id: "scope.allLocal", title: "Scope: All local", key: "1", modifiers: [.shift, .command],
              menu: .view, satisfies: .switchScope, tag: 0),
        .init(id: "scope.unstaged", title: "Scope: Unstaged", key: "2", modifiers: [.shift, .command],
              menu: .view, satisfies: .switchScope, tag: 1),
        .init(id: "scope.staged", title: "Scope: Staged", key: "3", modifiers: [.shift, .command],
              menu: .view, satisfies: .switchScope, tag: 2),
        .init(id: "scope.base", title: "Scope: vs base", key: "4", modifiers: [.shift, .command],
              menu: .view, satisfies: .switchScope, tag: 3),

        .init(id: "sources.addRoot", title: "Add Root Folder…", key: "o", modifiers: [.shift, .command],
              menu: .sources),
        .init(id: "sources.addRepository", title: "Add Repository…", key: "r",
              modifiers: [.shift, .command], menu: .sources),
        .init(id: "sources.remove", title: "Remove Source", key: "", modifiers: [], menu: .sources),
        .init(id: "sources.baseBranch", title: "Set Base Branch…", key: "b",
              modifiers: [.shift, .command], menu: .sources),

        // Movement is arrows, and the modifier says what is being moved through (DEC-065): the
        // change inside a file, the file inside a repository, the repository inside the list.
        // Three nesting levels, three modifier tiers, one direction key.
        // DEC-062. In the Navigate menu rather than View: it is a way of getting somewhere, and
        // the results replace the file list until the reader clears them.
        .init(id: "search", title: "Find in Changed Files…", key: "f", modifiers: [.command],
              menu: .navigate),
        .init(id: "search.worktree", title: "Find in Whole Worktree…", key: "f",
              modifiers: [.shift, .command], menu: .navigate),

        .init(id: "search.next", title: "Next Hit", key: "g", modifiers: [.command], menu: .navigate),
        .init(id: "search.previous", title: "Previous Hit", key: "g",
              modifiers: [.shift, .command], menu: .navigate),

        .init(id: "change.next", title: "Next Change", key: "↓", modifiers: [.command],
              menu: .navigate, satisfies: .changeNavigation),
        .init(id: "change.previous", title: "Previous Change", key: "↑", modifiers: [.command],
              menu: .navigate, satisfies: .changeNavigation),
        .init(id: "expandAll", title: "Expand or Collapse All Ranges", key: "e", modifiers: [.command],
              menu: .navigate, satisfies: .expandCollapsed),
        .init(id: "file.next", title: "Next File", key: "↓", modifiers: [.option],
              menu: .navigate, satisfies: .moveBetweenFiles),
        .init(id: "file.previous", title: "Previous File", key: "↑", modifiers: [.option],
              menu: .navigate, satisfies: .moveBetweenFiles),
        .init(id: "repository.next", title: "Next Repository", key: "↓", modifiers: [.shift, .command],
              menu: .navigate, satisfies: .moveBetweenRepositories),
        .init(id: "repository.previous", title: "Previous Repository", key: "↑",
              modifiers: [.shift, .command], menu: .navigate, satisfies: .moveBetweenRepositories),
        .init(id: "focus.repositories", title: "Focus Repositories", key: "1",
              modifiers: [.option, .command], menu: .navigate, satisfies: .moveFocus),
        .init(id: "focus.files", title: "Focus Files", key: "2", modifiers: [.option, .command],
              menu: .navigate, satisfies: .moveFocus),
        .init(id: "focus.diff", title: "Focus Diff", key: "3", modifiers: [.option, .command],
              menu: .navigate, satisfies: .moveFocus),
        // `⌘O` is *Open…* everywhere in macOS, and this application has things to open — roots and
        // repositories, which hold ⇧⌘O and ⇧⌘R (DEC-065).
        .init(id: "openInEditor", title: "Open in Editor", key: "⏎", modifiers: [.command],
              menu: .navigate, satisfies: .openInEditor),

        // ---- version two (DEC-092) -----------------------------------------------------------
        //
        // Staging and unstaging are the pair OQ-056 sequenced first, and they are next to each
        // other on the keyboard for the same reason they are next to each other in the menu.
        .init(id: "git.stage", title: "Stage File", key: "s", modifiers: [.option, .command],
              menu: .repository, satisfies: .stageAndUnstage),
        .init(id: "git.unstage", title: "Unstage File", key: "u", modifiers: [.option, .command],
              menu: .repository, satisfies: .stageAndUnstage),
        .init(id: "git.stageAll", title: "Stage Everything", key: "s",
              modifiers: [.shift, .option, .command], menu: .repository),
        .init(id: "git.unstageAll", title: "Unstage Everything", key: "u",
              modifiers: [.shift, .option, .command], menu: .repository),
        // Discarding is the one operation in this menu that can lose work that is in no object
        // database anywhere, and it is deliberately without a keystroke — the same reasoning
        // `sources.remove` carries, and the check names both rather than making an exception.
        .init(id: "git.discard", title: "Discard Changes…", key: "", modifiers: [], menu: .repository),

        // `⌘⏎` belongs to *open in editor* (DEC-065) and keeps it. Inside the commit box it
        // commits, which is GitHub Desktop's own rule; ⇧⌘⏎ commits from anywhere, so the function
        // is reachable without the reader having to be standing in the right field.
        .init(id: "git.commit", title: "Commit", key: "⏎", modifiers: [.shift, .command],
              menu: .repository, satisfies: .commitChanges),
        .init(id: "git.focusSummary", title: "Write a Commit Message", key: "c",
              modifiers: [.option, .command], menu: .repository),
        .init(id: "git.undoCommit", title: "Undo Last Commit", key: "z",
              modifiers: [.option, .command], menu: .repository),

        .init(id: "git.branches", title: "Branches…", key: "b", modifiers: [.option, .command],
              menu: .repository, satisfies: .manageBranches),
        .init(id: "git.newBranch", title: "New Branch…", key: "n", modifiers: [.option, .command],
              menu: .repository, satisfies: .manageBranches),
        .init(id: "git.stash", title: "Stash Everything", key: "s", modifiers: [.shift, .command],
              menu: .repository),
        .init(id: "git.stashes", title: "Stashes…", key: "x", modifiers: [.option, .command],
              menu: .repository),
        .init(id: "git.worktrees", title: "Worktrees…", key: "w", modifiers: [.shift, .command],
              menu: .repository),
        .init(id: "git.tags", title: "Tags…", key: "t", modifiers: [.shift, .command], menu: .repository),
        .init(id: "git.bisect", title: "Bisect…", key: "y", modifiers: [.shift, .command],
              menu: .repository),

        .init(id: "git.revert", title: "Revert Commit", key: "v", modifiers: [.option, .command],
              menu: .repository, satisfies: .actOnCommit),
        .init(id: "git.cherryPick", title: "Cherry-pick Commit", key: "y",
              modifiers: [.option, .command], menu: .repository, satisfies: .actOnCommit),
        // Reset can discard a working tree, so it is the third deliberately unbound row.
        .init(id: "git.reset", title: "Reset to Commit…", key: "", modifiers: [], menu: .repository),

        .init(id: "git.fetch", title: "Fetch", key: "f", modifiers: [.option, .command],
              menu: .repository, satisfies: .syncWithRemote),
        .init(id: "git.push", title: "Push", key: "p", modifiers: [.command],
              menu: .repository, satisfies: .syncWithRemote),
        .init(id: "git.pull", title: "Pull", key: "p", modifiers: [.shift, .command],
              menu: .repository, satisfies: .syncWithRemote),
        // A force push can destroy work that was never on this machine. Fourth unbound row, and
        // the sheet behind it asks for the branch name to be typed (DEC-092 §5).
        .init(id: "git.forcePush", title: "Force Push (with lease)…", key: "", modifiers: [],
              menu: .repository),

        // The second half of the sentence that replaced *it never writes*: it shows you the
        // command it ran.
        .init(id: "git.record", title: "What DiffScope Ran…", key: "l", modifiers: [.option, .command],
              menu: .repository),
    ]

    /// The rows that are deliberately without a keystroke, each because handing it a single key
    /// would be handing a reader a way to lose work by mistyping. Named here rather than in the
    /// check, so the list and its reason travel together.
    public static let deliberatelyUnbound = ["sources.remove", "git.discard", "git.reset",
                                             "git.forcePush"]

    public static func bindings(in menu: KeyboardMenu) -> [KeyboardBinding] {
        bindings.filter { $0.menu == menu }
    }

    public static func binding(id: String) -> KeyboardBinding? {
        bindings.first { $0.id == id }
    }

    /// The rows of `12-…` §9 that nothing binds. Empty is the only acceptable value, and the check
    /// suite says so; it is returned rather than asserted here so the failure can name the row.
    ///
    /// Takes the list rather than reading the static one, so the check suite can hand it a map with
    /// a function deliberately removed and require that to be reported.
    public static func unboundFunctions(in bindings: [KeyboardBinding] = bindings) -> [KeyboardFunction] {
        KeyboardFunction.allCases.filter { function in
            !bindings.contains { $0.satisfies == function }
        }
    }

    /// Bindings sharing a key and modifier set. Two of these means one of them never fires, and the
    /// one that never fires is a function reachable only by pointer.
    public static func collisions(in bindings: [KeyboardBinding] = bindings) -> [(String, [KeyboardBinding])] {
        var byShortcut: [String: [KeyboardBinding]] = [:]
        for binding in bindings where !binding.key.isEmpty {
            byShortcut[binding.shortcut, default: []].append(binding)
        }
        return byShortcut.filter { $0.value.count > 1 }.map { ($0.key, $0.value) }
    }
}
