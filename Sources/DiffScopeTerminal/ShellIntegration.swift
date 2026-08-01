import Foundation

/// Which shell this session drives, and therefore how it is told to mark its prompts.
///
/// Anything that is not zsh or bash runs **without** integration rather than with a guess: an
/// unrecognised shell gets a plain terminal and the session says so. Detection that cannot be
/// relied on is not quietly pretended — `26-terminal-plan.md` §3 states the same for the case where
/// marks stop arriving at all.
public enum ShellKind: String {
    case zsh
    case bash
    case unknown

    public static func of(path: String) -> ShellKind {
        switch (path as NSString).lastPathComponent {
        case "zsh": return .zsh
        case "bash": return .bash
        default: return .unknown
        }
    }

    public var marksPrompts: Bool { self != .unknown }
}

/// A generated startup directory — the whole point being that nothing of the user's is ever written
/// to. Proved by hashing their rc files around a real session, which is R-8's pattern pointed at
/// the home directory (`docs/22-experiment-log.md` → T0, S9).
public struct ShellIntegration {
    /// The second style exists to be *shown failing*. The hazard T0 found — a plain `precmd`
    /// assignment silently replacing the user's own — is worth more as a measurement than as a
    /// warning, so gate T0 installs the wrong version deliberately and watches the branch disappear
    /// from the prompt. **The application must never select it**, and a check enforces that.
    public enum Style {
        case hooks
        case naiveAssignmentControl
    }

    public let directory: URL
    public let kind: ShellKind

    public static func generate(for kind: ShellKind, style: Style = .hooks) throws -> ShellIntegration {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diffscope-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch kind {
        case .zsh:
            try zshenv.write(to: directory.appendingPathComponent(".zshenv"),
                             atomically: true, encoding: .utf8)
            let body = style == .hooks ? zshrc : naiveZshrcControl
            try body.write(to: directory.appendingPathComponent(".zshrc"),
                           atomically: true, encoding: .utf8)
        case .bash:
            try bashrc.write(to: directory.appendingPathComponent("bashrc"),
                             atomically: true, encoding: .utf8)
        case .unknown:
            break
        }
        return ShellIntegration(directory: directory, kind: kind)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// What makes the shell interactive and points it at the generated files.
    public var arguments: [String] {
        switch kind {
        case .zsh, .unknown: return ["-i"]
        case .bash: return ["-i", "--rcfile", directory.appendingPathComponent("bashrc").path]
        }
    }

    public func environment(base: [String: String], userZdotdir: String) -> [String: String] {
        var environment = base
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "DiffScope"
        environment["COLUMNS"] = nil
        environment["LINES"] = nil
        switch kind {
        case .zsh:
            environment["ZDOTDIR"] = directory.path
            environment["DIFFSCOPE_USER_ZDOTDIR"] = userZdotdir
        case .bash, .unknown:
            break
        }
        return environment
    }

    /// `.zshenv` must **not** restore the user's `ZDOTDIR`: zsh re-reads the variable before each
    /// startup file, so restoring it here sends zsh to their `.zshrc` instead of ours and the
    /// integration silently does nothing. The restore belongs in `.zshrc`, after ours has loaded.
    public static let zshenv = """
    [ -f "${DIFFSCOPE_USER_ZDOTDIR:-$HOME}/.zshenv" ] && source "${DIFFSCOPE_USER_ZDOTDIR:-$HOME}/.zshenv"
    """

    // `add-zsh-hook`, never `precmd() { … }`: a plain assignment replaces a `precmd` the user has
    // already defined. Measured in T0 (S6b) rather than assumed — the naive version installs
    // cleanly, marks perfectly, and strips the branch out of their prompt.
    //
    // `__ds_status`, never `status`: in zsh `$status` is a synonym for `$?`.
    //
    // The B mark is wrapped in %{ %}, or zsh counts the escape as visible width and its own line
    // editing goes wrong on a full line.
    public static let zshrc = """
    ZDOTDIR="${DIFFSCOPE_USER_ZDOTDIR:-$HOME}"
    export ZDOTDIR
    [ -f "$ZDOTDIR/.zshrc" ] && source "$ZDOTDIR/.zshrc"

    autoload -Uz add-zsh-hook

    __diffscope_precmd() {
      local __ds_status=$?
      printf '\\033]133;D;%s\\a\\033]133;A\\a' "$__ds_status"
    }

    __diffscope_preexec() {
      printf '\\033]133;C\\a'
    }

    add-zsh-hook precmd __diffscope_precmd
    add-zsh-hook preexec __diffscope_preexec

    PROMPT="${PROMPT}"$'%{\\033]133;B\\a%}'

    [ -n "$SSH_AGENT_PID" ] && printf '\\033]133;X;agent=%s\\a' "$SSH_AGENT_PID"
    """

    // bash has no hook array, so the marks ride on PROMPT_COMMAND and a DEBUG trap — both
    // *appending* to whatever the user already had, for the same reason zsh uses add-zsh-hook.
    // \\[ \\] are bash's own non-printing brackets, the equivalent of zsh's %{ %}.
    public static let bashrc = """
    [ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"

    __diffscope_prompt() {
      local __ds_status=$?
      printf '\\033]133;D;%s\\a\\033]133;A\\a' "$__ds_status"
    }

    __diffscope_preexec() {
      [ -n "$COMP_LINE" ] && return
      [ "$BASH_COMMAND" = "__diffscope_prompt" ] && return
      printf '\\033]133;C\\a'
    }

    PROMPT_COMMAND="__diffscope_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
    trap '__diffscope_preexec' DEBUG
    PS1="${PS1}\\[\\033]133;B\\a\\]"
    """

    /// The control. Never selected by the application; see `Style`.
    public static let naiveZshrcControl = """
    ZDOTDIR="${DIFFSCOPE_USER_ZDOTDIR:-$HOME}"
    export ZDOTDIR
    [ -f "$ZDOTDIR/.zshrc" ] && source "$ZDOTDIR/.zshrc"

    precmd() {
      local __ds_status=$?
      printf '\\033]133;D;%s\\a\\033]133;A\\a' "$__ds_status"
    }

    [ -n "$SSH_AGENT_PID" ] && printf '\\033]133;X;agent=%s\\a' "$SSH_AGENT_PID"
    """
}
