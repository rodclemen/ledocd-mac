import Foundation
import Darwin

/// Low-level serial port wrapper, mirroring the termios setup in the original
/// `ledocd_cli`/`giocd_cli` C code (9600 baud, 8N1, no flow control, raw mode).
final class SerialPort {

    enum SerialError: Error, CustomStringConvertible {
        case open(String, Int32)
        case configure(String)
        case notOpen

        var description: String {
            switch self {
            case .open(let path, let err):
                return "Unable to open \(path): \(String(cString: strerror(err))) (errno \(err))"
            case .configure(let msg):
                return "Unable to configure port: \(msg)"
            case .notOpen:
                return "Port is not open"
            }
        }
    }

    /// Opening this pseudo-path puts the port in no-op "simulated" mode so the UI
    /// can be exercised without a real OCD board attached.
    static let simulatedPath = "Simulator"

    private(set) var path: String
    private var fd: Int32 = -1
    private var simulated = false

    var isOpen: Bool { fd >= 0 || simulated }

    init(path: String) {
        self.path = path
    }

    deinit {
        close()
    }

    /// Enumerate candidate FTDI / USB serial devices. We list the `cu.*` callout
    /// devices (macOS equivalent of Linux `/dev/ttyUSB*`), excluding the built-in
    /// Bluetooth/debug ports.
    static func availablePorts() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/dev") else { return [] }
        return entries
            .filter { $0.hasPrefix("cu.") }
            .filter { !$0.contains("Bluetooth") && !$0.contains("debug-console") }
            .map { "/dev/\($0)" }
            .sorted()
    }

    func open() throws {
        close()
        if path == Self.simulatedPath { simulated = true; return }   // no hardware
        // Non-blocking open so a missing DCD line on the cu device can't hang us,
        // then switch the descriptor back to blocking for the configured VTIME reads.
        // Retry briefly: when one session (e.g. a live preview) is releasing the
        // port, the kernel may still report it busy for a few tens of ms.
        var handle: Int32 = -1
        var lastErrno: Int32 = 0
        for attempt in 0..<5 {
            handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            if handle >= 0 { break }
            lastErrno = errno
            if attempt < 4 { usleep(40_000) }
        }
        if handle < 0 {
            throw SerialError.open(path, lastErrno)
        }
        // Clear O_NONBLOCK: reads now honor VMIN/VTIME.
        _ = fcntl(handle, F_SETFL, 0)
        fd = handle
        do {
            try configureUart()
        } catch {
            close()
            throw error
        }
    }

    func close() {
        simulated = false
        if fd >= 0 {
            // Block until queued output is actually transmitted, otherwise a final
            // command written right before close (e.g. <T0> "return to normal") can
            // be discarded and the board is left stuck in its previous mode.
            tcdrain(fd)
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Port setup transcribed from `ConfigureUart()` in the C source: 9600 8N1,
    /// no parity, one stop bit, no hardware flow control, fully raw I/O.
    private func configureUart() throws {
        guard fd >= 0 else { throw SerialError.notOpen }

        var options = termios()
        if tcgetattr(fd, &options) != 0 {
            throw SerialError.configure("tcgetattr failed")
        }

        cfsetispeed(&options, speed_t(B9600))
        cfsetospeed(&options, speed_t(B9600))

        // Input: ignore parity errors, no other input processing.
        options.c_iflag = tcflag_t(IGNPAR)

        // Control flags.
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)   // ignore modem lines, enable receiver
        options.c_cflag &= ~tcflag_t(CRTSCTS)         // no hardware flow control
        options.c_cflag &= ~tcflag_t(PARENB)          // no parity
        options.c_cflag &= ~tcflag_t(CSTOPB)          // 1 stop bit
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)              // 8 data bits

        // Raw output and raw local handling.
        options.c_oflag = 0
        options.c_lflag = 0

        // VMIN=0, VTIME=4 -> read() returns after up to 0.4s of inter-byte idle.
        withUnsafeMutablePointer(to: &options.c_cc) { ccPtr in
            ccPtr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 4
            }
        }

        tcflush(fd, TCIFLUSH)

        if tcsetattr(fd, TCSANOW, &options) != 0 {
            throw SerialError.configure("tcsetattr failed")
        }
    }

    /// Write raw bytes to the port. Unlike the quirky byte-sliding loop in the
    /// original C `SendMessage`, we write the framed message exactly once — the
    /// board parses `<...>` frames, so a clean single write is the correct intent.
    @discardableResult
    func write(_ bytes: [UInt8]) throws -> Int {
        if simulated { return bytes.count }
        guard fd >= 0 else { throw SerialError.notOpen }
        var total = 0
        try bytes.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            while total < bytes.count {
                let n = Darwin.write(fd, base + total, bytes.count - total)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SerialError.configure("write failed: \(String(cString: strerror(errno)))")
                }
                total += n
            }
        }
        return total
    }

    /// Read up to `max` bytes, retrying while data keeps arriving — mirrors the
    /// read loop in the C code (VTIME gives each read() a ~0.4s idle timeout, and
    /// we keep going until a read comes back empty or we hit `max`).
    func read(max: Int = 4096, idleRetries: Int = 10) -> [UInt8] {
        if simulated { return [] }
        guard fd >= 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: max)
        var total = 0
        var remaining = idleRetries
        while remaining > 0 && total < max {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress! + total, max - total)
            }
            if n > 0 {
                total += n
                remaining = 2          // got data: keep draining
            } else {
                remaining -= 1
            }
        }
        return Array(buffer.prefix(total))
    }
}
