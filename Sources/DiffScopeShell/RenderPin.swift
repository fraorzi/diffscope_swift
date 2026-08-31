import Foundation

/// What the window is currently showing, as the four facts that decide whether it must be drawn
/// again.
///
/// The decision lives here, as a value and a pure function, for the reason `RefreshDebounce` and
/// `InputRouter` do: a rule that can only be exercised by driving a window is a rule that gets
/// checked once, by hand, and then drifts. This one can be asked every question it has.
public struct RenderPin: Equatable, Sendable {
    public let path: String
    public let mode: String
    public let oldHash: String
    public let newHash: String

    public init(path: String, mode: String, oldHash: String, newHash: String) {
        self.path = path
        self.mode = mode
        self.oldHash = oldHash
        self.newHash = newHash
    }
}

/// **Is there anything to draw?**
///
/// A refresh re-reads the file and re-pins it, and most refreshes find the same bytes: the reader
/// saved a different file, or an editor touched this one without changing it, or the app's own
/// `git diff` rewrote the index stat cache and the watcher reported it. When the two content hashes
/// and the mode all match what is on screen, every step that follows — the parse, the model, the
/// encode, the bridge crossing, the document replacement — produces the picture already there.
///
/// `push` has guarded the last of those steps since DEC-109 by comparing the serialised model, and
/// the UI audit of 2026-08-30 found that guard dead on the refresh path: the model carries
/// `restore`, which is computed from **where the reader is standing**, so a reader who had scrolled
/// since the previous refresh produced a different JSON every time. Comparing the bytes instead is
/// cheaper, is asked before the expensive work rather than after it, and cannot be defeated by the
/// reader moving.
///
/// - `restoringStop` is the stated exception. ⌥⌘V re-renders the *same* pair deliberately, to put
///   the reader back at a change stop after a mode change; skipping it would make the command do
///   nothing.
/// - No pin at all means nothing is known to be on screen, and the answer is always to draw. A
///   guard against redrawing is one line away from being a way never to draw, so the two halves are
///   stated together here and checked together.
public func renderIsRedundant(displayed: RenderPin?, wanted: RenderPin,
                              restoringStop: Int?) -> Bool {
    guard restoringStop == nil, let displayed else { return false }
    return displayed == wanted
}
