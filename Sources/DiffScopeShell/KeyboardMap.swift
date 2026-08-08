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
        }
    }
}

public struct KeyboardModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyboardModifiers(rawValue: 1 << 0)
    public static let shift = KeyboardModifiers(rawValue: 1 << 1)
    public static let option = KeyboardModifiers(rawValue: 1 << 2)

    /// `⌥⌘R` rather than `option+command+r`: this string is shown to a person in the tester packet
    /// and written into the documents, so it is composed once here.
    public var symbols: String {
        (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// Which menu a binding is drawn in. The menu bar is the keyboard map's visible form (DEC-016):
/// bindings live there so they are discoverable, and so macOS routes them whatever holds focus.
public enum KeyboardMenu: String, CaseIterable, Sendable {
    case application, view, sources, navigate

    public var title: String {
        switch self {
        case .application: return "DiffScope"
        case .view: return "View"
        case .sources: return "Sources"
        case .navigate: return "Navigate"
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

    public var shortcut: String { modifiers.symbols + key.uppercased() }
}

public enum KeyboardMap {
    /// The bindings, in menu order. Adding a function to the application means adding a row here;
    /// there is nowhere else to add it.
    public static let bindings: [KeyboardBinding] = [
        .init(id: "quit", title: "Quit DiffScope", key: "q", modifiers: [.command], menu: .application),

        .init(id: "mode.raw", title: "Raw", key: "1", modifiers: [.command], menu: .view,
              satisfies: .switchMode, tag: 0),
        .init(id: "mode.structural", title: "Structural", key: "2", modifiers: [.command], menu: .view,
              satisfies: .switchMode, tag: 1),
        .init(id: "mode.expanded", title: "Expanded", key: "3", modifiers: [.command], menu: .view,
              satisfies: .switchMode, tag: 2),
        // The control view of DEC-013, pointed at where the reader is standing rather than at the
        // whole file. Not a fourth mode: it switches to Raw and back, keeping the change stop.
        .init(id: "rawRegion", title: "Raw for Current Region", key: "v", modifiers: [.option, .command],
              menu: .view, satisfies: .rawForCurrentRegion, isToggle: true),
        .init(id: "terminal", title: "Terminal", key: "t", modifiers: [.option, .command],
              menu: .view, isToggle: true),
        .init(id: "terminal.raw", title: "Terminal Raw Mode", key: "r", modifiers: [.option, .command],
              menu: .view, isToggle: true),
        .init(id: "terminal.follow", title: "Terminal: Follow Selection", key: "k",
              modifiers: [.option, .command], menu: .view),
        .init(id: "wrap", title: "Wrap Long Lines", key: "w", modifiers: [.option, .command],
              menu: .view, isToggle: true),
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

        .init(id: "change.next", title: "Next Change", key: "n", modifiers: [.command],
              menu: .navigate, satisfies: .changeNavigation),
        .init(id: "change.previous", title: "Previous Change", key: "p", modifiers: [.command],
              menu: .navigate, satisfies: .changeNavigation),
        .init(id: "expandAll", title: "Expand All Collapsed Ranges", key: "e", modifiers: [.command],
              menu: .navigate, satisfies: .expandCollapsed),
        .init(id: "file.next", title: "Next File", key: "]", modifiers: [.command],
              menu: .navigate, satisfies: .moveBetweenFiles),
        .init(id: "file.previous", title: "Previous File", key: "[", modifiers: [.command],
              menu: .navigate, satisfies: .moveBetweenFiles),
        .init(id: "repository.next", title: "Next Repository", key: "]", modifiers: [.shift, .command],
              menu: .navigate, satisfies: .moveBetweenRepositories),
        .init(id: "repository.previous", title: "Previous Repository", key: "[",
              modifiers: [.shift, .command], menu: .navigate, satisfies: .moveBetweenRepositories),
        .init(id: "focus.repositories", title: "Focus Repositories", key: "1",
              modifiers: [.option, .command], menu: .navigate, satisfies: .moveFocus),
        .init(id: "focus.files", title: "Focus Files", key: "2", modifiers: [.option, .command],
              menu: .navigate, satisfies: .moveFocus),
        .init(id: "focus.diff", title: "Focus Diff", key: "3", modifiers: [.option, .command],
              menu: .navigate, satisfies: .moveFocus),
        .init(id: "openInEditor", title: "Open in Editor", key: "o", modifiers: [.command],
              menu: .navigate, satisfies: .openInEditor),
    ]

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
