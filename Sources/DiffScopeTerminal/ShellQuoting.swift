import Foundation

/// The one place the application composes a command for the user's shell.
///
/// T3 lets the terminal follow the reader's selection, which means sending `cd` with a path that
/// came off the file system — and a directory may be named `'; rm -rf ~ #`. Nothing about that is
/// theoretical, so the quoting is one function with hostile fixtures rather than an interpolation
/// somewhere in the window code.
///
/// This is as close as the product has come to *the application running a command*. DEC-028 still
/// holds — nothing here is derived from repository **content** — but the boundary is thin enough
/// that it gets its own function, its own checks, and its own decision entry (DEC-056).
///
/// Single quotes, because inside them a POSIX shell expands nothing at all: no `$`, no backtick, no
/// `\`, no history. The only character that needs care is the single quote itself, which ends the
/// string and is re-opened after an escaped one.
public func shellSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// `cd -- <path>`: the `--` is not decoration. A directory whose name begins with `-` would
/// otherwise be read as options to `cd`.
public func changeDirectoryCommand(to path: String) -> String {
    "cd -- \(shellSingleQuoted(path))"
}
