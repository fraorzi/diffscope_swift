import Foundation

/// One run of prompt text with the attributes it was drawn in (DEC-089).
///
/// The 16 ANSI colours carry the **token name** the page already resolves for xterm's own theme, so
/// the inline prompt and the grid cannot end up with two different reds. 256-colour and truecolor
/// carry a literal, because those are the shell's output rather than the design's palette — the same
/// line `24-design-contract.md` draws around repository content.
public struct PromptSegment: Equatable {
    public let text: String
    public let foreground: String?
    public let background: String?
    public let bold: Bool
    public let dim: Bool
    public let italic: Bool
    public let underline: Bool
    public let inverse: Bool

    public init(text: String, foreground: String? = nil, background: String? = nil,
                bold: Bool = false, dim: Bool = false, italic: Bool = false,
                underline: Bool = false, inverse: Bool = false) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
    }
}

/// What to do with the bytes between `OSC 133;A` and `OSC 133;B`.
public struct PromptDecision: Equatable {
    /// Bytes to hand to the grid **now**: everything up to and including the last newline. A
    /// two-line prompt keeps its first line where every other line of output lives and brings only
    /// its last line inline, which is what Warp does and what makes a `p10k` prompt work at all.
    public let released: [UInt8]
    /// Bytes still withheld — the last line — to be released when the line is submitted or when
    /// anything else needs the grid.
    public let withheld: [UInt8]
    /// The last line as spans, or `nil` when it cannot honestly be drawn as spans.
    public let inline: [PromptSegment]?

    public init(released: [UInt8], withheld: [UInt8], inline: [PromptSegment]?) {
        self.released = released
        self.withheld = withheld
        self.inline = inline
    }
}

/// The rules for turning a captured prompt into an inline one, as a pure function so the check
/// suite can exercise them without a shell (DEC-089).
///
/// **What may be drawn inline.** Plain text, `SGR` (`CSI … m`), and zero-width `OSC` — the
/// integration emits `OSC 7` *inside* the prompt span, so a rule of "SGR only" would refuse every
/// prompt this product itself installs. Anything else that is a `CSI` — cursor motion, erases, a
/// right-hand prompt drawn by column — is **refused**: a prompt that positions the cursor is not a
/// run of spans, and rendering it as one would move text the shell put somewhere specific.
///
/// A refusal is not a failure. The whole capture is released to the grid and the row falls back to
/// the layout it had before DEC-089, which is a state a check can name and a snapshot can show.
public enum PromptCapture {
    public static func decide(_ captured: [UInt8]) -> PromptDecision {
        // The head is every complete line but the last; only the last line can be inline, because
        // only the last line is the one the caret continues.
        let cut = captured.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let head = Array(captured[..<cut])
        let tail = Array(captured[cut...])

        guard let segments = segments(of: tail), !segments.isEmpty else {
            return PromptDecision(released: captured, withheld: [], inline: nil)
        }
        return PromptDecision(released: head, withheld: tail, inline: segments)
    }

    /// `nil` when the run carries something that cannot be a span.
    static func segments(of bytes: [UInt8]) -> [PromptSegment]? {
        var out: [PromptSegment] = []
        var text: [UInt8] = []
        var style = Style()

        func flush() {
            guard !text.isEmpty else { return }
            out.append(style.segment(String(decoding: text, as: UTF8.self)))
            text.removeAll(keepingCapacity: true)
        }

        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            guard byte == 0x1B else {
                // A carriage return inside the last line is the shell drawing rather than writing:
                // it means "go back and overprint", which is the thing spans cannot express.
                if byte == 0x0D { return nil }
                text.append(byte)
                index += 1
                continue
            }
            guard index + 1 < bytes.endIndex else { return nil }
            switch bytes[index + 1] {
            case UInt8(ascii: "["):
                var cursor = index + 2
                while cursor < bytes.endIndex, bytes[cursor] < 0x40 || bytes[cursor] > 0x7E {
                    cursor += 1
                }
                guard cursor < bytes.endIndex else { return nil }
                // **The whole of the refusal rule.** `m` is a change of ink; every other final byte
                // moves the cursor or erases with it.
                guard bytes[cursor] == UInt8(ascii: "m") else { return nil }
                flush()
                style.apply(String(decoding: bytes[(index + 2)..<cursor], as: UTF8.self))
                index = cursor + 1
            case UInt8(ascii: "]"):
                // Zero-width by construction: an OSC draws nothing, it tells the terminal something.
                // Ends at BEL or ST, and an unterminated one is a prompt we do not understand.
                var cursor = index + 2
                while cursor < bytes.endIndex, bytes[cursor] != 0x07 {
                    if bytes[cursor] == 0x1B, cursor + 1 < bytes.endIndex,
                       bytes[cursor + 1] == UInt8(ascii: "\\") {
                        cursor += 1
                        break
                    }
                    cursor += 1
                }
                guard cursor < bytes.endIndex else { return nil }
                index = cursor + 1
            default:
                return nil
            }
        }
        flush()
        return out
    }

    /// The attributes an `SGR` run can set. Deliberately the ones a prompt actually uses — a prompt
    /// that reaches for blink or conceal is a prompt this refuses rather than half-draws.
    struct Style {
        var foreground: String?
        var background: String?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false

        func segment(_ text: String) -> PromptSegment {
            PromptSegment(text: text, foreground: foreground, background: background,
                          bold: bold, dim: dim, italic: italic, underline: underline,
                          inverse: inverse)
        }

        mutating func apply(_ parameters: String) {
            // An empty parameter list is `SGR 0`, which is how `\e[m` resets.
            let fields = parameters.isEmpty ? ["0"] : parameters.split(separator: ";",
                                                                      omittingEmptySubsequences: false)
                .map(String.init)
            var index = 0
            while index < fields.count {
                let code = Int(fields[index]) ?? 0
                switch code {
                case 0: self = Style()
                case 1: bold = true
                case 2: dim = true
                case 3: italic = true
                case 4: underline = true
                case 7: inverse = true
                case 22: bold = false; dim = false
                case 23: italic = false
                case 24: underline = false
                case 27: inverse = false
                case 30...37: foreground = PromptCapture.token(code - 30, bright: false)
                case 39: foreground = nil
                case 40...47: background = PromptCapture.token(code - 40, bright: false)
                case 49: background = nil
                case 90...97: foreground = PromptCapture.token(code - 90, bright: true)
                case 100...107: background = PromptCapture.token(code - 100, bright: true)
                case 38, 48:
                    let extended = PromptCapture.extended(fields, from: index)
                    if code == 38 { foreground = extended.colour } else { background = extended.colour }
                    index = extended.next - 1
                default: break
                }
                index += 1
            }
        }
    }

    /// `--ds-term-*`, so the inline prompt and the grid draw one palette. The order is ANSI's.
    static func token(_ index: Int, bright: Bool) -> String? {
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        guard names.indices.contains(index) else { return nil }
        return "--ds-term-" + (bright ? "bright-" : "") + names[index]
    }

    /// `38;5;n` and `38;2;r;g;b`. Returns the colour and the index just past what it consumed.
    static func extended(_ fields: [String], from index: Int) -> (colour: String?, next: Int) {
        guard index + 1 < fields.count else { return (nil, index + 1) }
        switch fields[index + 1] {
        case "5":
            guard index + 2 < fields.count, let value = Int(fields[index + 2]) else {
                return (nil, index + 2)
            }
            // The first sixteen of the 256-colour cube *are* the ANSI sixteen, so they take the
            // token rather than a literal — otherwise the same red arrives two ways.
            if value < 8 { return (token(value, bright: false), index + 3) }
            if value < 16 { return (token(value - 8, bright: true), index + 3) }
            return (cube(value), index + 3)
        case "2":
            guard index + 4 < fields.count,
                  let r = Int(fields[index + 2]), let g = Int(fields[index + 3]),
                  let b = Int(fields[index + 4]) else { return (nil, index + 5) }
            return (String(format: "#%02x%02x%02x", clamp(r), clamp(g), clamp(b)), index + 5)
        default:
            return (nil, index + 2)
        }
    }

    private static func clamp(_ value: Int) -> Int { min(255, max(0, value)) }

    /// xterm's own 256-colour table: 16…231 is a 6×6×6 cube, 232…255 is a 24-step grey ramp.
    static func cube(_ value: Int) -> String? {
        if value >= 232 {
            let level = 8 + (value - 232) * 10
            return String(format: "#%02x%02x%02x", level, level, level)
        }
        guard value >= 16, value <= 231 else { return nil }
        let steps = [0, 95, 135, 175, 215, 255]
        let offset = value - 16
        return String(format: "#%02x%02x%02x",
                      steps[offset / 36], steps[(offset / 6) % 6], steps[offset % 6])
    }
}
