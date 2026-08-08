import Foundation

/// Where a keystroke goes, decided in one place.
///
/// The input line exists because a shell's own line editor cannot be driven with the macOS text
/// motions (OQ-055). Replacing that editor means owning the decisions it used to make — so they live
/// here, as a pure function over (mode, key, line), rather than scattered through the page where
/// only an eye could check them.
///
/// **JS owns text editing; this owns routing.** Ordinary typing and caret motion never reach here:
/// the browser does them, which is the whole point, and T0 measured that a `<textarea>` performs all
/// six motions identically to `NSTextView`.
public enum InputMode: Equatable {
    /// At a prompt, editing locally.
    case local
    /// A program is running: every key goes to it, byte for byte.
    case program
    /// The reader forced raw through the escape hatch, and only the reader takes it off again.
    case forcedRaw
    /// A key the shell must handle itself — Tab, ⌃R — handed the line over. Raw until the next
    /// prompt mark arrives.
    case handedOver

    public var isRaw: Bool { self != .local }

    /// What the mode chip says. It reports the mode the code is actually in, never the one the
    /// reader selected — the diff's mode chip got that wrong and it is a recorded weakness.
    public var label: String {
        switch self {
        case .local: return "prompt"
        case .program: return "program"
        case .forcedRaw: return "raw — forced"
        case .handedOver: return "raw — the shell has the line"
        }
    }
}

public struct InputKey: Equatable {
    public let name: String
    public let control: Bool
    public let alt: Bool
    public let meta: Bool
    public let shift: Bool

    public init(_ name: String, control: Bool = false, alt: Bool = false,
                meta: Bool = false, shift: Bool = false) {
        self.name = name
        self.control = control
        self.alt = alt
        self.meta = meta
        self.shift = shift
    }
}

public enum InputAction: Equatable {
    /// Send the line and a carriage return; clear the field; remember it.
    case submit(String)
    /// Send the typed text, then the key's own bytes, and let the shell take over until the next
    /// prompt. This is how completion and reverse search keep working without being reimplemented.
    case handOver(text: String, key: [UInt8])
    case sendRaw([UInt8])
    case recall(offset: Int)
    /// What `recall` becomes once the session has resolved it against the history it holds.
    case setLine(String)
    case clearLine
    case releaseForcedRaw
    /// Not ours: the field keeps it. Nothing is ever swallowed silently.
    case editLocally
}

public struct InputRouter {
    /// The authority for which keys the page intercepts. The page is *told* this list rather than
    /// carrying its own copy, because two copies of a keyboard map drift and the drift is invisible.
    public static let interceptedKeys = ["Enter", "Tab", "ArrowUp", "ArrowDown", "Escape",
                                         "ctrl-c", "ctrl-d", "ctrl-r"]

    public init() {}

    public func route(key: InputKey, line: String, mode: InputMode) -> InputAction {
        // In every raw mode the grid holds focus and xterm encodes the keys itself — it already has
        // a tested encoder for arrows, modifiers and escape sequences, and writing a second one
        // would be reimplementing the part of xterm that works.
        if mode.isRaw {
            if key.name == "Escape", mode == .forcedRaw { return .releaseForcedRaw }
            return .editLocally
        }

        if key.control {
            switch key.name.lowercased() {
            case "c":
                // Whatever is wedged gets the interrupt, and the half-typed line goes with it.
                return .sendRaw([0x03])
            case "d":
                // Only on an empty line: EOF over typed text would close the shell while the reader
                // was looking at a command they had not run yet.
                return line.isEmpty ? .sendRaw([0x04]) : .editLocally
            case "r":
                return .handOver(text: line, key: [0x12])
            default:
                return .editLocally
            }
        }

        switch key.name {
        case "Enter":
            return .submit(line)
        case "Tab":
            return .handOver(text: line, key: [0x09])
        case "ArrowUp":
            return .recall(offset: -1)
        case "ArrowDown":
            return .recall(offset: 1)
        case "Escape":
            return .clearLine
        default:
            return .editLocally
        }
    }
}

/// The lines submitted in *this session*, for ↑/↓.
///
/// `~/.zsh_history` is deliberately not read. Showing a reader what they just typed is not the same
/// act as opening their private history file, and the shell's own history stays one ⌃R away — at the
/// shell, where it belongs.
public struct SessionHistory {
    private var lines: [String] = []
    private var cursor: Int = 0

    public init() {}

    public var count: Int { lines.count }

    public mutating func remember(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        cursor = lines.count
        guard !trimmed.isEmpty else { return }
        // A command repeated twice in a row is one entry, the way every shell does it.
        if lines.last == trimmed {
            cursor = lines.count
            return
        }
        lines.append(trimmed)
        cursor = lines.count
    }

    /// `nil` means "stay where you are": walking past the newest entry returns the empty line, and
    /// walking past the oldest does nothing rather than wrapping around silently.
    public mutating func recall(offset: Int) -> String? {
        guard !lines.isEmpty else { return nil }
        let target = cursor + offset
        if target < 0 { cursor = 0; return lines.first }
        if target >= lines.count { cursor = lines.count; return "" }
        cursor = target
        return lines[target]
    }
}
