import Darwin
import Foundation

/// A child process on a real PTY. Measured in gate T0 before any of this shipped: see
/// `docs/22-experiment-log.md` → T0 for the four questions it had to answer first.
///
/// Bytes are handed out **as bytes**. Nothing here decodes UTF-8, because a multi-byte sequence
/// splits across `read` boundaries routinely and `String(decoding:)` would replace the halves with
/// U+FFFD — a product whose whole claim is that bytes are the source of truth cannot corrupt them
/// on the way to its own terminal.
public final class PtyProcess {
    public let pid: pid_t
    private let master: Int32
    private let lock = NSLock()
    private var finished = false

    /// Called on the reader thread, in arrival order.
    public var onOutput: (([UInt8]) -> Void)?
    /// Called once, on the reader thread, when the far side closes.
    public var onExit: (() -> Void)?

    public init?(command: String,
                 arguments: [String],
                 environment: [String: String],
                 workingDirectory: String,
                 columns: UInt16 = 80,
                 rows: UInt16 = 24) {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var descriptor: Int32 = -1

        // Everything the child touches between fork and exec is prepared here: after a fork only
        // async-signal-safe work is legal, and allocating in the Swift runtime is not.
        let argv: [UnsafeMutablePointer<CChar>?] = ([command] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let path = strdup(command)
        let directory = strdup(workingDirectory)

        let child = forkpty(&descriptor, nil, nil, &size)
        if child == 0 {
            if chdir(directory) != 0 { _exit(126) }
            execve(path, argv, envp)
            _exit(127)
        }

        for pointer in argv where pointer != nil { free(pointer) }
        for pointer in envp where pointer != nil { free(pointer) }
        free(path)
        free(directory)

        guard child > 0 else { return nil }
        pid = child
        master = descriptor

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "diffscope.pty"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, 16384) }
            guard count > 0 else {
                lock.lock(); finished = true; lock.unlock()
                onExit?()
                return
            }
            onOutput?(Array(buffer[0..<count]))
        }
    }

    public func write(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes {
                Darwin.write(master, $0.baseAddress! + offset, bytes.count - offset)
            }
            if written <= 0 { return }
            offset += written
        }
    }

    public func write(_ text: String) { write(Array(text.utf8)) }

    public func resize(columns: UInt16, rows: UInt16) {
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// What the far side believes its size to be — the only honest way to check a resize landed.
    public var windowSize: (columns: UInt16, rows: UInt16)? {
        var size = winsize()
        guard ioctl(master, TIOCGWINSZ, &size) == 0 else { return nil }
        return (size.ws_col, size.ws_row)
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished && kill(pid, 0) == 0
    }

    /// Asked to leave, then made to. A terminal that leaves its shell behind is a terminal that
    /// leaks a process per window.
    public func terminate() {
        kill(pid, SIGHUP)
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid {
                close(master)
                return
            }
            usleep(20_000)
        }
        kill(pid, SIGKILL)
        _ = waitpid(pid, &status, 0)
        close(master)
    }
}
