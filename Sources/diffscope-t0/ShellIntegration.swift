import Foundation

/// A generated `ZDOTDIR` — the whole point being that nothing of the user's is ever written to.
///
/// `.zshenv` must *not* restore the user's `ZDOTDIR`: zsh re-reads the variable before each startup
/// file, so restoring it there would send zsh to the user's `.zshrc` instead of this one. The
/// restore belongs in `.zshrc`, after ours has been loaded.
struct ShellIntegration {
    /// The second style exists to be *shown failing*. The hazard recorded in the T0 probe — that a
    /// plain `precmd` assignment silently replaces the user's own — is worth more as a measurement
    /// than as a warning, so the probe installs the wrong version deliberately and watches the
    /// branch disappear from the prompt.
    enum Style {
        case addZshHook
        case naivePrecmdAssignment
    }

    let directory: URL

    static func generate(style: Style = .addZshHook) throws -> ShellIntegration {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diffscope-t0-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try zshenv.write(to: directory.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        let body = style == .addZshHook ? zshrc : naiveZshrc
        try body.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        return ShellIntegration(directory: directory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func environment(userZdotdir: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ZDOTDIR"] = directory.path
        environment["DIFFSCOPE_USER_ZDOTDIR"] = userZdotdir
        environment["TERM"] = "xterm-256color"
        environment["COLUMNS"] = nil
        environment["LINES"] = nil
        return environment
    }

    private static let zshenv = """
    [ -f "${DIFFSCOPE_USER_ZDOTDIR:-$HOME}/.zshenv" ] && source "${DIFFSCOPE_USER_ZDOTDIR:-$HOME}/.zshenv"
    """

    // `add-zsh-hook`, never `precmd() { … }`: ~/.zshrc:16 defines its own `precmd`, and an
    // assignment would replace it and silently strip vcs_info out of the user's prompt.
    //
    // `__ds_status`, never `status`: in zsh `$status` is a synonym for `$?`.
    //
    // The B mark is wrapped in %{ %}, or zsh counts the escape as visible width and its own line
    // editing goes wrong on a full line.
    private static let zshrc = """
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

    private static let naiveZshrc = """
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
