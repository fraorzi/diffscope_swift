import Foundation

/// What the application needs to read out of the byte stream to know where it stands.
public enum TerminalEvent {
    case promptStart          // OSC 133;A
    case promptEnd            // OSC 133;B
    case commandStart         // OSC 133;C
    case commandEnd(Int?)     // OSC 133;D;<exit>
    case note(String)         // OSC 133;X;… — the integration's own side channel
    case alternateScreen(Bool)
    case query(String)
}

public struct TimedEvent {
    public let event: TerminalEvent
    public let at: Date

    public init(event: TerminalEvent, at: Date) {
        self.event = event
        self.at = at
    }
}

/// A terminal that answers nothing looks broken to a full-screen program: `vim` asks who it is
/// talking to and waits. Gate T0 measured this with no emulator behind it and had to answer by
/// hand, which is what `onReply` is for.
///
/// **In the application `onReply` stays nil.** xterm.js is a real emulator and answers these
/// itself, through the same keystroke path as the user; a second answer from here would put
/// duplicate replies on the wire and the program would read the extra one as input.
private let deviceAttributes1 = "\u{1b}[?1;2c"
private let deviceAttributes2 = "\u{1b}[>1;95;0c"

/// Incremental, because a mark can and does arrive split across two `read` calls.
public final class TerminalScanner {
    private enum State { case ground, escape, csi, string, stringEscape }
    private enum StringKind { case osc, dcs }

    private var state: State = .ground
    private var stringKind: StringKind = .osc
    private var collected: [UInt8] = []

    public var onEvent: ((TerminalEvent) -> Void)?
    /// Only for a scanner with no emulator behind it. See the note above.
    public var onReply: ((String) -> Void)?

    public init() {}

    public func feed(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes { step(byte) }
    }

    private func step(_ byte: UInt8) {
        switch state {
        case .ground:
            if byte == 0x1B { state = .escape; collected.removeAll(keepingCapacity: true) }
        case .escape:
            switch byte {
            case UInt8(ascii: "["): state = .csi; collected.removeAll(keepingCapacity: true)
            case UInt8(ascii: "]"): state = .string; stringKind = .osc; collected.removeAll(keepingCapacity: true)
            case UInt8(ascii: "P"): state = .string; stringKind = .dcs; collected.removeAll(keepingCapacity: true)
            case 0x1B: state = .escape
            default: state = .ground
            }
        case .csi:
            if byte >= 0x40, byte <= 0x7E {
                finishControlSequence(final: byte)
                state = .ground
            } else {
                collected.append(byte)
                if collected.count > 256 { state = .ground }
            }
        case .string:
            if byte == 0x07 {
                finishString()
                state = .ground
            } else if byte == 0x1B {
                state = .stringEscape
            } else {
                collected.append(byte)
                if collected.count > 4096 { state = .ground }
            }
        case .stringEscape:
            if byte == UInt8(ascii: "\\") {
                finishString()
                state = .ground
            } else {
                collected.append(0x1B)
                collected.append(byte)
                state = .string
            }
        }
    }

    private func finishControlSequence(final: UInt8) {
        let parameters = String(decoding: collected, as: UTF8.self)
        switch (parameters, Character(UnicodeScalar(final))) {
        case ("?1049", "h"), ("?1047", "h"), ("?47", "h"):
            onEvent?(.alternateScreen(true))
        case ("?1049", "l"), ("?1047", "l"), ("?47", "l"):
            onEvent?(.alternateScreen(false))
        case ("", "c"), ("0", "c"):
            onEvent?(.query("DA1"))
            onReply?(deviceAttributes1)
        case (">", "c"), (">0", "c"):
            onEvent?(.query("DA2"))
            onReply?(deviceAttributes2)
        case ("5", "n"):
            onEvent?(.query("DSR-status"))
            onReply?("\u{1b}[0n")
        case ("6", "n"):
            onEvent?(.query("DSR-cursor"))
            onReply?("\u{1b}[1;1R")
        case ("?6", "n"):
            onEvent?(.query("DECXCPR"))
            onReply?("\u{1b}[?1;1R")
        case ("?", "u"):
            onEvent?(.query("kitty-keyboard"))
            onReply?("\u{1b}[?0u")
        case (">0", "q"), (">", "q"):
            onEvent?(.query("XTVERSION"))
            onReply?("\u{1b}P>|diffscope\u{1b}\\")
        default:
            break
        }
    }

    private func finishString() {
        let text = String(decoding: collected, as: UTF8.self)
        switch stringKind {
        case .dcs:
            if text.hasPrefix("+q") {
                onEvent?(.query("XTGETTCAP"))
                onReply?("\u{1b}P0+r\u{1b}\\")
            }
        case .osc:
            guard text.hasPrefix("133;") else { return }
            let body = String(text.dropFirst(4))
            let fields = body.split(separator: ";", omittingEmptySubsequences: false)
            switch fields.first.map(String.init) {
            case "A": onEvent?(.promptStart)
            case "B": onEvent?(.promptEnd)
            case "C": onEvent?(.commandStart)
            case "D": onEvent?(.commandEnd(fields.count > 1 ? Int(fields[1]) : nil))
            case "X": onEvent?(.note(fields.dropFirst().joined(separator: ";")))
            default: break
            }
        }
    }
}

extension Array where Element == TimedEvent {
    public func contains(_ match: (TerminalEvent) -> Bool) -> Bool {
        contains { match($0.event) }
    }

    /// Everything after the last event satisfying `match` — how a scenario asks "and *then*".
    public func after(_ match: (TerminalEvent) -> Bool) -> [TimedEvent] {
        guard let index = lastIndex(where: { match($0.event) }) else { return [] }
        return Array(self[(index + 1)...])
    }

    public var queries: [String] {
        compactMap { if case let .query(name) = $0.event { return name } else { return nil } }
    }
}

public func isPromptStart(_ event: TerminalEvent) -> Bool { if case .promptStart = event { return true }; return false }
public func isPromptEnd(_ event: TerminalEvent) -> Bool { if case .promptEnd = event { return true }; return false }
public func isCommandStart(_ event: TerminalEvent) -> Bool { if case .commandStart = event { return true }; return false }
public func isCommandEnd(_ event: TerminalEvent) -> Bool { if case .commandEnd = event { return true }; return false }

public func commandEnded(with code: Int) -> (TerminalEvent) -> Bool {
    { event in
        if case let .commandEnd(reported) = event { return reported == code }
        return false
    }
}
