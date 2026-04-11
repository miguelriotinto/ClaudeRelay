import Foundation
import CPTYShim
import ClaudeRelayKit

// MARK: - PTYSessionProtocol

public protocol PTYSessionProtocol: Actor {
    var sessionId: UUID { get }
    func startReading()
    func setOutputHandler(_ handler: @escaping @Sendable (Data) -> Void)
    func setExitHandler(_ handler: @escaping @Sendable () -> Void)
    func clearOutputHandler()
    func write(_ data: Data)
    func resize(cols: UInt16, rows: UInt16)
    func readBuffer() -> Data
    func terminate()
    func getActivityState() -> ActivityState
    func setActivityHandler(_ handler: @escaping @Sendable (ActivityState) -> Void)
    func recordInput()
}

// MARK: - PTYError

public enum PTYError: Error {
    case forkFailed(Int32)
}

// MARK: - ActivityCallbackBox

/// Thread-safe box that holds an activity-change callback.
/// Used to break the init-time `[weak self]` capture cycle: the monitor's
/// `onChange` closure captures this box (which is created before `self` is
/// fully initialized), and `PTYSession` writes the real handler into it later.
private final class ActivityCallbackBox: @unchecked Sendable {
    var handler: (@Sendable (ActivityState) -> Void)?
}

// MARK: - PTYSession Actor

public actor PTYSession: PTYSessionProtocol {
    public let sessionId: UUID

    private let masterFD: Int32
    private let childPID: Int32
    private var ringBuffer: RingBuffer
    private var readSource: DispatchSourceRead?
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var exitHandler: (@Sendable () -> Void)?
    private let activityMonitor: SessionActivityMonitor
    /// Shared box to bridge the monitor's synchronous onChange callback into the actor.
    /// The monitor captures this box (not `self`) so the closure doesn't require `self` to be fully initialized.
    private let activityCallbackBox = ActivityCallbackBox()
    private var activityHandler: (@Sendable (ActivityState) -> Void)?
    private var terminated: Bool = false

    // MARK: - Initialization

    /// Initialize: forkpty with given terminal size, spawn command in child.
    public init(
        sessionId: UUID,
        cols: UInt16,
        rows: UInt16,
        scrollbackSize: Int,
        command: String = "/opt/homebrew/bin/claude"
    ) throws {
        self.sessionId = sessionId
        self.ringBuffer = RingBuffer(capacity: scrollbackSize)

        var fd: Int32 = 0
        var ws = winsize()
        ws.ws_col = cols
        ws.ws_row = rows
        ws.ws_xpixel = 0
        ws.ws_ypixel = 0

        // Resolve home directory BEFORE fork — NSHomeDirectory() and other
        // ObjC/Foundation calls are NOT safe in a forked child process.
        let homeDir = strdup(NSHomeDirectory())

        let pid = relay_forkpty(&fd, &ws)

        if pid < 0 {
            free(homeDir)
            throw PTYError.forkFailed(errno)
        }

        if pid == 0 {
            // Child process — only use POSIX/C calls here (no ObjC/Foundation).
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1)
            if let homeDir = homeDir {
                chdir(homeDir)
            }

            // Use login -f to spawn shell with proper user context and permissions
            let username = getenv("USER") ?? getpwuid(getuid()).pointee.pw_name
            let usernameStr = strdup(username)
            let argv0 = strdup("login")
            let argv1 = strdup("-fp")
            let cArgs: [UnsafeMutablePointer<CChar>?] = [argv0, argv1, usernameStr, nil]
            _ = cArgs.withUnsafeBufferPointer { buf in
                execv("/usr/bin/login", buf.baseAddress)
            }

            // Fallback to direct zsh if login fails
            let fallbackArgv0 = strdup("-zsh")
            let fallbackArgs: [UnsafeMutablePointer<CChar>?] = [fallbackArgv0, nil]
            _ = fallbackArgs.withUnsafeBufferPointer { buf in
                execv("/bin/zsh", buf.baseAddress)
            }
            _exit(1)
        }

        free(homeDir)

        // Parent process
        self.masterFD = fd
        self.childPID = pid
        let box = self.activityCallbackBox
        self.activityMonitor = SessionActivityMonitor(
            silenceThreshold: 1.0,
            claudeSilenceThreshold: 2.0,
            onChange: { newState in
                box.handler?(newState)
            }
        )
    }

    /// Activate the dispatch source that reads PTY output.
    /// Must be called after init to avoid actor-initializer isolation warning (Swift 6).
    public func startReading() {
        guard readSource == nil else { return }
        let readSrc = Self.makeReadSource(fd: masterFD, session: self)
        self.readSource = readSrc
    }

    // MARK: - Read Source Setup

    /// Creates and activates a DispatchSourceRead for the master file descriptor.
    /// Bridges GCD callbacks into the actor context via unstructured Tasks.
    private static func makeReadSource(fd: Int32, session: PTYSession) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())

        // Persistent read buffer — reused across callbacks to avoid per-read allocation.
        var readBuffer = [UInt8](repeating: 0, count: 8192)

        source.setEventHandler { [weak source, session] in
            let estimated = max(Int(source?.data ?? 0), 256)
            if estimated > readBuffer.count {
                readBuffer = [UInt8](repeating: 0, count: min(estimated, 65536))
            }
            let bytesRead = read(fd, &readBuffer, readBuffer.count)

            if bytesRead > 0 {
                let data = Data(readBuffer[0..<bytesRead])
                Task {
                    await session.handleOutput(data)
                }
            } else {
                // EOF or error — cancel source to stop firing and close FD
                source?.cancel()
                Task {
                    await session.handleExit()
                }
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        return source
    }

    // MARK: - Internal Handlers

    /// Called from the read source when output data is available.
    /// Always writes to the ring buffer (for resume history) and
    /// additionally forwards to the live output handler if attached.
    private func handleOutput(_ data: Data) {
        ringBuffer.write(data)
        activityMonitor.processOutput(data)
        outputHandler?(data)
    }

    /// Called from the read source on EOF (child exited).
    private func handleExit() {
        exitHandler?()
    }

    // MARK: - Activity Monitoring

    /// Returns the current activity state of this session.
    public func getActivityState() -> ActivityState {
        activityMonitor.state
    }

    /// Set callback for activity state changes.
    public func setActivityHandler(_ handler: @escaping @Sendable (ActivityState) -> Void) {
        self.activityHandler = handler
        self.activityCallbackBox.handler = handler
    }

    /// Record that input was sent to this session.
    public func recordInput() {
        activityMonitor.recordInput()
    }

    // MARK: - Public API

    /// Set callback for PTY output (when client is attached).
    public func setOutputHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        self.outputHandler = handler
    }

    /// Set callback for process exit.
    public func setExitHandler(_ handler: @escaping @Sendable () -> Void) {
        self.exitHandler = handler
    }

    /// Clear output handler (when client detaches -- output goes to ring buffer).
    public func clearOutputHandler() {
        self.outputHandler = nil
    }

    /// Write data to PTY (terminal input from client).
    public func write(_ data: Data) {
        guard !terminated else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            let count = data.count
            while totalWritten < count {
                let written = Foundation.write(masterFD, ptr.advanced(by: totalWritten), count - totalWritten)
                if written > 0 {
                    totalWritten += written
                } else if written == 0 {
                    break
                } else {
                    let err = errno
                    if err == EAGAIN || err == EINTR {
                        continue
                    }
                    RelayLogger.log(.error, category: "session", "PTYSession \(sessionId) write error: errno \(err)")
                    break
                }
            }
        }
    }

    /// Resize the terminal.
    public func resize(cols: UInt16, rows: UInt16) {
        guard !terminated else { return }
        _ = relay_set_winsize(masterFD, rows, cols)
    }

    /// Read the ring buffer contents (for resume, send scrollback history to client).
    /// Does not clear — new output continues to accumulate for subsequent resumes.
    public func readBuffer() -> Data {
        return ringBuffer.read()
    }

    /// Clean up: kill child process, close fd.
    public func terminate() {
        guard !terminated else { return }
        terminated = true
        activityMonitor.cancel()

        // Cancel the read source (this also closes the fd via the cancel handler)
        readSource?.cancel()
        readSource = nil

        // Send SIGTERM to the child. SIGCHLD is set to SIG_IGN in main.swift,
        // so the kernel auto-reaps — no waitpid needed.
        let pid = childPID
        let sid = sessionId
        if kill(pid, SIGTERM) != 0 {
            RelayLogger.log(.error, category: "session", "PTYSession \(sid) SIGTERM failed for pid \(pid): errno \(errno)")
        }

        // Schedule SIGKILL after 5 seconds if the process hasn't exited
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
            // Check if process is still alive (kill with signal 0)
            if kill(pid, 0) == 0 {
                if kill(pid, SIGKILL) != 0 {
                    RelayLogger.log(.error, category: "session", "PTYSession \(sid) SIGKILL failed for pid \(pid): errno \(errno)")
                }
            }
        }
    }
}
