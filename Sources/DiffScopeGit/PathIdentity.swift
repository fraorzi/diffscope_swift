import Foundation

/// When two paths name the same directory (DEC-069).
///
/// **Asked of the filesystem, never guessed.** Two spellings of one directory differ in more ways
/// than the obvious one, and both occur on a stock macOS:
///
/// - **Case.** The default volume is case-insensitive; Swift's `String ==` is not.
/// - **Symlinked ancestors.** `NSTemporaryDirectory()` returns `/var/folders/…` while
///   `contentsOfDirectory` returns `/private/var/folders/…` for the same file, and
///   `standardizedFileURL` resolves neither.
///
/// A rule written in string arithmetic has to anticipate both, and would still be wrong on a
/// case-**sensitive** volume, where folding merges two directories that really are different.
/// Asking the filesystem answers all of it at once and stays right on every volume.
///
/// **Normalisation needs nothing here, and that is measured rather than assumed** (M9-F): Swift's
/// `==`, `hasPrefix` and `Set` membership are canonical equivalence, so NFC and NFD forms of one
/// name already compare and hash equal. The suite asserts it, because this is the second time this
/// project has depended on those semantics — the first (M6-C) was a defect.
public enum PathIdentity {
    /// **Equality.** Device and inode where the path exists, which is the filesystem's own answer to
    /// *are these the same file*; a folded string where it does not, because DEC-052 keeps a
    /// configured source that has gone missing and its identity still has to be decidable.
    ///
    /// The same mechanism `ScopeReader.FileStamp` already uses, for the same reason.
    public static func of(_ path: String) -> String {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let device = number(attributes[.systemNumber]),
           let inode = number(attributes[.systemFileNumber]) {
            return "\(device):\(inode)"
        }
        // No inode to ask, so this is the one place a rule is applied instead. Lowercasing is wrong
        // on a case-sensitive volume — and reaches only paths that do not exist, where the only
        // consequence is that two missing sources are reported as one.
        return URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
    }

    public static func same(_ a: String, _ b: String) -> Bool { of(a) == of(b) }

    /// **Containment.** An inode answers *the same file* and cannot answer *underneath*, so a prefix
    /// test needs a path — the filesystem's own spelling of one. `resolvingSymlinksInPath` returns
    /// the canonical case and resolves symlinked ancestors, which is exactly the pair of differences
    /// above, expressed as a string.
    public static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func number(_ value: Any?) -> UInt64? {
        (value as? UInt64) ?? (value as? Int).map(UInt64.init)
    }
}
