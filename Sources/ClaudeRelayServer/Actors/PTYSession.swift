import Foundation
import CPTYShim

// MARK: - PTYError

public enum PTYError: Error {
    case forkFailed(Int32)
}

// MARK: - PTYSession Actor

public actor PTYSession {
    public let sessionId: UUID

    private let masterFD: Int32
    private let childPID: Int32
    private var ringBuffer: RingBuffer
    private var readSource: DispatchSourceRead?
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var exitHandler: (@Sendable () -> Void)?
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

        let pid = relay_forkpty(&fd, &ws)

        if pid < 0 {
            throw PTYError.forkFailed(errno)
        }

        if pid == 0 {
            // Child process
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)
            chdir(NSHomeDirectory())
            let args = ["zsh", "-l", "-c", command]
            let cArgs = args.map { strdup($0) } + [nil]
            execv("/bin/zsh", cArgs)
            _exit(1)
        }

        // Parent process
        self.masterFD = fd
        self.childPID = pid

        // Start reading from the PTY in a nonisolated helper
        self.readSource = Self.makeReadSource(fd: fd, session: self)
    }

    // MARK: - Read Source Setup

    /// Creates and activates a DispatchSourceRead for the master file descriptor.
    /// Bridges GCD callbacks into the actor context via unstructured Tasks.
    private static func makeReadSource(fd: Int32, session: PTYSession) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())

        source.setEventHandler { [session] in
            let bufferSize = 8192
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            let bytesRead = read(fd, &buffer, bufferSize)

            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                Task {
                    await session.handleOutput(data)
                }
            } else {
                // EOF or error — child process exited
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
    private func handleOutput(_ data: Data) {
        if let handler = outputHandler {
            handler(data)
        } else {
            ringBuffer.write(data)
        }
    }

    /// Called from the read source on EOF (child exited).
    private func handleExit() {
        exitHandler?()
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
                if written <= 0 {
                    break
                }
                totalWritten += written
            }
        }
    }

    /// Resize the terminal.
    public func resize(cols: UInt16, rows: UInt16) {
        guard !terminated else { return }
        _ = relay_set_winsize(masterFD, rows, cols)
    }

    /// Flush the ring buffer (on resume, send buffered output to client).
    public func flushBuffer() -> Data {
        return ringBuffer.flush()
    }

    /// Clean up: kill child process, close fd.
    public func terminate() {
        guard !terminated else { return }
        terminated = true

        // Cancel the read source (this also closes the fd via the cancel handler)
        readSource?.cancel()
        readSource = nil

        // Send SIGTERM to the child
        kill(childPID, SIGTERM)

        // Schedule SIGKILL after 5 seconds if the process hasn't exited
        let pid = childPID
        DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == 0 {
                // Process still running, force kill
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
            }
        }
    }
}
