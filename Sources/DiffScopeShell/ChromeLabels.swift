import Foundation

/// What the window says about itself, composed where a check can read it (DEC-071).
///
/// The same reasoning that put `KeyboardMap` in this target: a sentence the interface makes is a
/// claim, and a claim that only exists inside an `NSTextField` can only be verified by looking. This
/// target holds no AppKit, so `diffscope-verify` links the very file the window draws from.
///
/// The rule for what belongs here: **anything the chrome says about its own state.** Facts about a
/// *diff* are composed in the engine (`ChangeCount.text`, `fallbackNotice`) and facts about a
/// *repository* in the Git layer (`comparisonDescription`, `baseSummary`), for the same reason — the
/// layer that knows the fact is the layer that words it.
public enum ChromeLabels {
    /// A pane header: what the pane is, and how many things are in it.
    public struct PaneHeaderText: Equatable, Sendable {
        public let caption: String
        public let count: String

        public init(caption: String, count: String) {
            self.caption = caption
            self.count = count
        }
    }

    /// How many characters a collapsed pane can show. The rail is 44 pt and the spine 34 pt
    /// (DEC-060), less the row's own leading inset, which is about four characters of the 10 pt
    /// monospace face the headers are set in.
    public static let collapsedHeaderLimit = 4

    /// `999+` rather than a five-digit number the label would clip. A clipped count is a number
    /// that lies about its own magnitude; `999+` says exactly what is known.
    public static func compactCount(_ count: Int) -> String {
        count > 999 ? "999+" : String(count)
    }

    /// The exact figure, for the tooltip that stands behind a collapsed pane's short form
    /// (DEC-098). The rail can hold two characters; the number of repositories is not bounded by
    /// two characters, so the shortened form on screen has to have somewhere to point.
    public static func paneCountTooltip(count: Int, noun: String, plural: String) -> String {
        "\(count) \(count == 1 ? noun : plural)"
    }

    /// The repositories list. Its count is drawn **only when collapsed**: expanded, the design gives
    /// that end of the header to the `+`, and the repository rows are individually visible anyway.
    public static func repositoriesHeader(count: Int, collapsed: Bool) -> PaneHeaderText {
        collapsed
            ? PaneHeaderText(caption: compactCount(count), count: "")
            : PaneHeaderText(caption: "REPOSITORIES", count: "")
    }

    /// The changed-file list. The count is the number of **files**, not of drawn rows: the rows
    /// include the group headers DEC-033 puts between them, and a reader comparing this number with
    /// the status line's would otherwise find two different answers to one question.
    public static func changedFilesHeader(count: Int, collapsed: Bool) -> PaneHeaderText {
        collapsed
            ? PaneHeaderText(caption: "", count: compactCount(count))
            : PaneHeaderText(caption: "CHANGED FILES", count: compactCount(count))
    }

    /// A block in the chrome: a caption, the fact, and the keystroke that changes it (DEC-072).
    ///
    /// `dashed` is part of the text because it is part of the statement: a dashed rim says *this is
    /// a different kind of thing from its neighbours*, which is the same sentence `PillControl`
    /// says about a scope that cannot be chosen and `ChipView` says about a count that is unknown.
    /// Deciding it here makes it a claim the suite can ask about rather than a branch in a `draw`.
    public struct BlockText: Equatable, Sendable {
        public let caption: String
        public let detail: String
        public let shortcut: String
        public let dashed: Bool

        public init(caption: String, detail: String, shortcut: String, dashed: Bool) {
            self.caption = caption
            self.detail = detail
            self.shortcut = shortcut
            self.dashed = dashed
        }
    }

    /// The scope row's own caption.
    public static let scopeCaption = "SCOPE"

    /// A scope that is available and empty (DEC-073): `Staged — nothing staged`.
    ///
    /// **The same shape as the unavailable state** the window already draws — `title — reason` — so
    /// the two read as two answers to one question rather than as two different kinds of message.
    /// Both halves come from `ComparisonScope`; this is only the join, and it exists so that the
    /// join is a claim rather than a `+` in a view.
    public static func scopeState(shortTitle: String, emptyDescription: String) -> String {
        "\(shortTitle) — \(emptyDescription)"
    }

    /// The base block at the right end of the scope row. `detail` is `baseDetail` from the Git
    /// layer — the ref, whether the reader chose it, and the age of its newest commit.
    ///
    /// **Dashed unless the base is what is being compared.** `newest commit 9 weeks old` beside
    /// `HEAD ↔ working tree` reads as a statement about what is on screen, and it is not one: it is
    /// a fact about a ref nothing on screen is currently compared against.
    public static func baseBlock(detail: String, comparingAgainstBase: Bool) -> BlockText {
        BlockText(caption: "Base", detail: detail,
                  // From the map, never typed here (DEC-071): this string is a keystroke a reader
                  // is about to press.
                  shortcut: KeyboardMap.binding(id: "sources.baseBranch")?.shortcut ?? "",
                  dashed: !comparingAgainstBase)
    }

    /// What the watcher is doing (DEC-075). Three states, because *not watching* has two causes a
    /// reader would act on differently: it never started, or it stopped because the repository moved.
    public enum WatchState: Equatable, Sendable {
        case watching
        case unavailable(String)
        case stopped(String)
    }

    /// `● Watching · refreshed 4s ago`, or `○ Not watching — <reason>`.
    ///
    /// **The dot is filled or hollow**, not green or grey: the distinction has to survive greyscale
    /// like every other one in this window (DEC-035). The age is absent rather than zero before the
    /// first refresh — *refreshed 0s ago* on a window that has never refreshed is a false sentence
    /// about the thing this field exists to make honest.
    public static func watcherStatus(_ state: WatchState, refreshedSecondsAgo: Int?) -> String {
        let age = refreshedSecondsAgo.map { " · refreshed \(refreshedAgo(seconds: $0))" } ?? ""
        switch state {
        case .watching: return "● Watching\(age)"
        case let .unavailable(reason): return "○ Not watching — \(reason)\(age)"
        case let .stopped(reason): return "○ Watching stopped — \(reason)\(age)"
        }
    }

    /// How long ago, in the units a reader watching a window cares about. `stalenessDescription` in
    /// the Git layer answers the same question for a base ref and starts at *today*, which is the
    /// right granularity there and useless here.
    public static func refreshedAgo(seconds: Int) -> String {
        switch seconds {
        case ..<0: return "just now"
        case 0...2: return "just now"
        // **DEC-086: no per-second wording.** The status line was rewritten once a second — *4s
        // ago*, *5s ago*, *6s* — in the corner of the eye, forever, and the owner reported the
        // flicker while wanting to keep the fact. Static was rejected (a stale *2s ago* is a false
        // sentence, and DEC-075 exists so a window that has stopped following the disk says so) and
        // so was a longer redraw interval (the same flicker, less often, and wrong in between).
        // Coarser wording is the only one of the three where the sentence is never false and the
        // pixels change rarely.
        case 3..<60: return "under a minute ago"
        case 60..<3600: return "\(seconds / 60)m ago"
        case 3600..<86_400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    /// The wrap toggle's own words (`12-…`, DEC-065's ⌥⌘W).
    public static let wrapTitle = "Wrap long lines"

    /// The two layouts (DEC-059), as words rather than glyphs: this project has no icon set, and a
    /// glyph a reader cannot name is worse than a word.
    public static let layoutTitles = ["Unified", "Side by side"]

    /// Whether a header can be drawn in a collapsed pane at all. Stated as a function rather than
    /// left to the picture, because "it looked clipped" is not something a later reader can check —
    /// and because the failure it guards is a pane that says `REPOSITOR` and means nothing.
    public static func fitsCollapsedPane(_ text: PaneHeaderText) -> Bool {
        (text.caption + text.count).count <= collapsedHeaderLimit
    }
}
