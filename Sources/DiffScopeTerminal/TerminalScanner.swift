import Foundation

/// What the application needs to read out of the byte stream to know where it stands.
public enum TerminalEvent {
    case promptStart          // OSC 133;A
    case promptEnd            // OSC 133;B
    case commandStart         // OSC 133;C
    case commandEnd(Int?)     // OSC 133;D;<exit>
    case note(String)         // OSC 133;X;… — the integration's own side channel
    /// OSC 7 — where the shell says it is. The standard mechanism every terminal uses for this, so
    /// the product reads a shell's own report rather than guessing from where it was started.
    case workingDirectory(String)
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
    /// Where the sequence being read began, as an offset into the slice currently being fed.
    private var sequenceStart: Int?
    /// The range the event about to be emitted occupies. Set immediately before a `finish…` call so
    /// the emitter does not have to be threaded through every branch.
    private var sequenceRange: Range<Int> = 0..<0

    public var onEvent: ((TerminalEvent) -> Void)?
    /// The same events, with **where they were** — the byte range of the whole escape sequence
    /// within the slice just fed (DEC-089).
    ///
    /// `TerminalEvent` is deliberately not widened to carry this. It is `Equatable` and the check
    /// suite compares it by value in dozens of places; a payload that differs per call site would
    /// make every one of those comparisons about an offset. A caller that needs the offsets asks
    /// for them, and `TerminalSession` is the only one that does.
    ///
    /// A sequence split across two reads reports `0` as its lower bound in the second — it covers
    /// that slice from its first byte, which is what a caller splitting the stream needs to know.
    public var onEventRange: ((TerminalEvent, Range<Int>) -> Void)?
    /// Only for a scanner with no emulator behind it. See the note above.
    public var onReply: ((String) -> Void)?

    public init() {}

    public func feed(_ bytes: ArraySlice<UInt8>) {
        // A sequence that began in an earlier read covers this one from its first byte.
        if state != .ground { sequenceStart = 0 }
        for (offset, byte) in bytes.enumerated() { step(byte, at: offset) }
    }

    private func emit(_ event: TerminalEvent) {
        onEvent?(event)
        onEventRange?(event, sequenceRange)
    }

    private func step(_ byte: UInt8, at offset: Int) {
        switch state {
        case .ground:
            if byte == 0x1B {
                state = .escape
                sequenceStart = offset
                collected.removeAll(keepingCapacity: true)
            }
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
                sequenceRange = (sequenceStart ?? 0)..<(offset + 1)
                finishControlSequence(final: byte)
                state = .ground
            } else {
                collected.append(byte)
                if collected.count > 256 { state = .ground }
            }
        case .string:
            if byte == 0x07 {
                sequenceRange = (sequenceStart ?? 0)..<(offset + 1)
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
                sequenceRange = (sequenceStart ?? 0)..<(offset + 1)
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
            emit(.alternateScreen(true))
        case ("?1049", "l"), ("?1047", "l"), ("?47", "l"):
            emit(.alternateScreen(false))
        case ("", "c"), ("0", "c"):
            emit(.query("DA1"))
            onReply?(deviceAttributes1)
        case (">", "c"), (">0", "c"):
            emit(.query("DA2"))
            onReply?(deviceAttributes2)
        case ("5", "n"):
            emit(.query("DSR-status"))
            onReply?("\u{1b}[0n")
        case ("6", "n"):
            emit(.query("DSR-cursor"))
            onReply?("\u{1b}[1;1R")
        case ("?6", "n"):
            emit(.query("DECXCPR"))
            onReply?("\u{1b}[?1;1R")
        case ("?", "u"):
            emit(.query("kitty-keyboard"))
            onReply?("\u{1b}[?0u")
        case (">0", "q"), (">", "q"):
            emit(.query("XTVERSION"))
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
                emit(.query("XTGETTCAP"))
                onReply?("\u{1b}P0+r\u{1b}\\")
            }
        case .osc:
            // OSC 7 carries `file://host/path`, and some shells omit the host entirely. Anything
            // that is not a local path is ignored rather than guessed at: a directory the
            // application cannot reach is not a directory it should claim to be showing.
            if text.hasPrefix("7;") {
                let body = String(text.dropFirst(2))
                guard let range = body.range(of: "file://") else { return }
                let rest = String(body[range.upperBound...])
                guard let slash = rest.firstIndex(of: "/") else { return }
                let encoded = String(rest[slash...])
                emit(.workingDirectory(encoded.removingPercentEncoding ?? encoded))
                return
            }
            guard text.hasPrefix("133;") else { return }
            let body = String(text.dropFirst(4))
            let fields = body.split(separator: ";", omittingEmptySubsequences: false)
            switch fields.first.map(String.init) {
            case "A": emit(.promptStart)
            case "B": emit(.promptEnd)
            case "C": emit(.commandStart)
            case "D": emit(.commandEnd(fields.count > 1 ? Int(fields[1]) : nil))
            case "X": emit(.note(fields.dropFirst().joined(separator: ";")))
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
