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

    /// Whether a header can be drawn in a collapsed pane at all. Stated as a function rather than
    /// left to the picture, because "it looked clipped" is not something a later reader can check —
    /// and because the failure it guards is a pane that says `REPOSITOR` and means nothing.
    public static func fitsCollapsedPane(_ text: PaneHeaderText) -> Bool {
        (text.caption + text.count).count <= collapsedHeaderLimit
    }
}
