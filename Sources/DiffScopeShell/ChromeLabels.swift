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

    /// The keystroke drawn on a pill (DEC-073), by the identifier of the binding that selects it.
    ///
    /// Empty for a binding the map does not have, which is the honest answer: a pill that printed a
    /// key nothing binds would teach a reader a keystroke that does nothing. The check suite asks
    /// for exactly that case.
    public static func pillHint(bindingID: String) -> String {
        KeyboardMap.binding(id: bindingID)?.shortcut ?? ""
    }

    /// The hints for a whole control, in the order its segments are drawn.
    public static func pillHints(bindingIDs: [String]) -> [String] {
        bindingIDs.map(pillHint(bindingID:))
    }

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

    /// Whether a header can be drawn in a collapsed pane at all. Stated as a function rather than
    /// left to the picture, because "it looked clipped" is not something a later reader can check —
    /// and because the failure it guards is a pane that says `REPOSITOR` and means nothing.
    public static func fitsCollapsedPane(_ text: PaneHeaderText) -> Bool {
        (text.caption + text.count).count <= collapsedHeaderLimit
    }
}
