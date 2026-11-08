import Darwin
import Foundation

public enum TerminalError: Error, CustomStringConvertible {
    case notATTY
    case termios(String)

    public var description: String {
        switch self {
        case .notATTY:
            return "The interactive UI needs a TTY. Run `hn front` for line output."
        case .termios(let message):
            return "Could not configure the terminal: \(message)"
        }
    }
}

public final class Terminal: @unchecked Sendable {
    private var originalTermios: termios?
    private var active = false
    public private(set) var width: Int = 80
    public private(set) var height: Int = 24

    public init() {
        refreshSize()
    }

    public static var isTTY: Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }

    public func start() throws {
        guard Self.isTTY else { throw TerminalError.notATTY }
        guard !active else { return }

        var term = termios()
        guard tcgetattr(STDIN_FILENO, &term) == 0 else {
            throw TerminalError.termios(String(cString: strerror(errno)))
        }
        originalTermios = term

        var raw = term
        cfmakeraw(&raw)
        raw.c_oflag |= tcflag_t(OPOST)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
            throw TerminalError.termios(String(cString: strerror(errno)))
        }

        active = true
        refreshSize()
        write("\u{001B}[?1049h\u{001B}[?25l\u{001B}[?2004h\u{001B}[?1000h\u{001B}[?1006h\u{001B}[2J\u{001B}[H")
    }

    public func stop() {
        guard active else { return }
        write("\u{001B}[?1006l\u{001B}[?1000l\u{001B}[?2004l\u{001B}[?25h\u{001B}[?1049l")
        if let originalTermios {
            var term = originalTermios
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)
        }
        active = false
    }

    public func suspend() {
        stop()
    }

    public func resume() throws {
        try start()
    }

    public func write(_ string: String) {
        var data = Data(string.utf8)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }

    public func clearScreen() {
        write("\u{001B}[2J\u{001B}[H")
    }

    public func refreshSize() {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 {
            if size.ws_col > 0, size.ws_row > 0 {
                width = max(20, Int(size.ws_col))
                height = max(8, Int(size.ws_row))
                return
            }
        }

        width = max(20, Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "") ?? 80)
        height = max(8, Int(ProcessInfo.processInfo.environment["LINES"] ?? "") ?? 24)
    }
}

public final class TerminalInput: @unchecked Sendable {
    public typealias KeyHandler = @Sendable (KeyEvent) -> Void
    public typealias ResizeHandler = @Sendable (Int, Int) -> Void
    public typealias EOFHandler = @Sendable () -> Void

    private let terminal: Terminal
    private let onKey: KeyHandler
    private let onResize: ResizeHandler
    private let onEOF: EOFHandler
    private let queue = DispatchQueue(label: "hn.tui.input")
    private var readSource: DispatchSourceRead?
    private var resizeSource: DispatchSourceSignal?
    private var parser = InputParser()
    private var pendingEscape: DispatchWorkItem?

    public init(
        terminal: Terminal,
        onKey: @escaping KeyHandler,
        onResize: @escaping ResizeHandler,
        onEOF: @escaping EOFHandler
    ) {
        self.terminal = terminal
        self.onKey = onKey
        self.onResize = onResize
        self.onEOF = onEOF
    }

    public func start() {
        let readSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        readSource.resume()
        self.readSource = readSource

        signal(SIGWINCH, SIG_IGN)
        let resizeSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: queue)
        resizeSource.setEventHandler { [weak self] in
            guard let self else { return }
            self.terminal.refreshSize()
            self.onResize(self.terminal.width, self.terminal.height)
        }
        resizeSource.resume()
        self.resizeSource = resizeSource
    }

    public func stop() {
        pendingEscape?.cancel()
        pendingEscape = nil
        readSource?.cancel()
        readSource = nil
        resizeSource?.cancel()
        resizeSource = nil
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count > 0 {
            pendingEscape?.cancel()
            pendingEscape = nil
            let events = parser.feed(Data(buffer[0..<count]))
            for event in events {
                onKey(event)
            }
            if parser.hasPendingEscape {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    for event in self.parser.flushPendingEscape() {
                        self.onKey(event)
                    }
                }
                pendingEscape = work
                queue.asyncAfter(deadline: .now() + 0.03, execute: work)
            }
        } else if count == 0 {
            onEOF()
        } else if errno != EINTR && errno != EAGAIN {
            onEOF()
        }
    }
}
