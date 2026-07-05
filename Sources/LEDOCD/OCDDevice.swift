import Foundation

/// High-level protocol logic for talking to an LED OCD / GI OCD board, ported
/// message-for-message from the original `ledocd_cli` / `giocd_cli` C sources.
///
/// All multi-byte "frames" look like `<Hdr …payload… >`. Payload bytes are raw
/// small integers (often 0-based), so a frame may legitimately contain NUL and
/// other control bytes — the board reads fixed-length framed messages. The one
/// collision the firmware can't tolerate is a payload byte equal to `>` (62),
/// which we bump to 63 exactly as the C code does.
struct OCDDevice {

    enum Board: String {
        case ledOCD = "LED OCD"
        case giOCD = "GI OCD"
    }

    /// Lamp-matrix family. Inferred from firmware version like the C `main()`
    /// switch, but can be overridden by the user (needed for Capcom A vs B, and
    /// when a board reports an unrecognized version).
    enum Manufacturer: String, CaseIterable, Identifiable {
        case wpc = "WPC"          // Williams / Data East / Spooky
        case stern = "STERN"
        case capcomA = "CAPCOMA"
        case capcomB = "CAPCOMB"
        case system11 = "SYSTEM11" // GI OCD only
        case unknown = "UNKNOWN"
        var id: String { rawValue }

        /// Stern uses a 10-row lamp matrix; everyone else 8.
        var maxRow: Int { self == .stern ? 10 : 8 }
        /// Capcom matrix B needs a `<1>` relay prefix before every message.
        var needsRelayPrefix: Bool { self == .capcomB }
    }

    struct VersionInfo {
        var board: Board
        var version: Int
        var manufacturer: Manufacturer
    }

    let port: SerialPort

    // MARK: - Framing helpers

    private static let lt = UInt8(ascii: "<")
    private static let gt = UInt8(ascii: ">")

    /// Clamp a payload byte away from the `>` frame terminator, mirroring the
    /// `if(value == 62) value = 63;` guard in the C code.
    private static func safe(_ v: Int) -> UInt8 { UInt8(v == 62 ? 63 : v) }

    /// Send a framed message. For Capcom matrix B we prefix `<1>` (the relay
    /// select) exactly as the C `SendMessage` does for `isCapcomB`.
    private func send(_ bytes: [UInt8], relayPrefix: Bool = false) throws {
        if relayPrefix {
            try port.write([Self.lt, UInt8(ascii: "1"), Self.gt])
            usleep(40_000)
        }
        try port.write(bytes)
        usleep(40_000)
    }

    // MARK: - Version query

    func readVersion() throws -> VersionInfo {
        try port.write(Array("<V>".utf8))
        let reply = port.read(max: 64, idleRetries: 10)
        guard reply.count >= 5 else { throw Failure.noReply(reply) }
        return try Self.parseVersion(reply)
    }

    private static func parseVersion(_ reply: [UInt8]) throws -> VersionInfo {
        guard reply.count >= 5,
              reply[0] == UInt8(ascii: "{"), reply[4] == UInt8(ascii: "}") else {
            throw Failure.badReply(reply)
        }
        let kindByte = reply[1]
        let version = Int(reply[2] - UInt8(ascii: "0")) * 10
                    + Int(reply[3] - UInt8(ascii: "0"))
        let board: Board = (kindByte == UInt8(ascii: "G")) ? .giOCD : .ledOCD
        return VersionInfo(board: board,
                           version: version,
                           manufacturer: manufacturer(forVersion: version, board: board))
    }

    /// If this `<Q>` read-stream frame is the `{V dd}` / `{G dd}` firmware frame,
    /// decode it into VersionInfo (same format as the `<V>` reply); else nil.
    static func versionFromFrame(_ f: [UInt8]) -> VersionInfo? {
        guard f.count == 5,
              f[1] == UInt8(ascii: "V") || f[1] == UInt8(ascii: "G") else { return nil }
        return try? parseVersion(f)
    }

    /// Version → manufacturer, copied from the switch statements in both CLIs.
    static func manufacturer(forVersion v: Int, board: Board) -> Manufacturer {
        if board == .giOCD {
            switch v {
            case 1, 2, 3, 4, 5, 6, 7, 9: return .wpc
            case 8: return .system11
            default: return .unknown
            }
        }
        switch v {
        case 14, 21, 23, 24, 28, 29, 30, 31, 35, 36: return .wpc
        case 15, 25, 32, 33: return .stern
        case 22, 26, 27, 34: return .capcomA   // A vs B chosen by user
        default: return .unknown
        }
    }

    // MARK: - Modes (shared)

    func setMode(_ mode: UInt8) throws {   // 0 normal, 1 manual, 2 passthrough
        try send([Self.lt, UInt8(ascii: "T"), mode, Self.gt])
    }
    func setNormalMode() throws { try setMode(0) }
    func setManualMode() throws { try setMode(1) }
    func setPassthroughMode() throws { try setMode(2) }
    func save() throws { try send(Array("<S>".utf8)) }

    // MARK: - LED OCD write commands

    /// `<P{p-1}N{8 chars}>` — profile name, padded to 8 bytes with NUL.
    func setProfileName(profile p: Int, name: String, relay: Bool) throws {
        var chars = Array(name.utf8.prefix(8)).map { $0 == Self.gt ? Self.safe(Int($0)) : $0 }
        while chars.count < 8 { chars.append(0) }
        try send([Self.lt, UInt8(ascii: "P"), UInt8(p - 1), UInt8(ascii: "N")] + chars + [Self.gt],
                 relayPrefix: relay)
    }

    /// `<P{p-1}B{b}V{v}>` — profile brightness. `b` 1-8, `v` 0-100.
    func setProfileBrightness(profile p: Int, level b: Int, value v: Int, relay: Bool) throws {
        try send([Self.lt, UInt8(ascii: "P"), UInt8(p - 1),
                  UInt8(ascii: "B"), UInt8(b),
                  UInt8(ascii: "V"), Self.safe(v), Self.gt], relayPrefix: relay)
    }

    /// `<P{p-1}D{d}>` — profile fade delay. `d` 0-9.
    func setProfileDelay(profile p: Int, delay d: Int, relay: Bool) throws {
        try send([Self.lt, UInt8(ascii: "P"), UInt8(p - 1),
                  UInt8(ascii: "D"), UInt8(d), Self.gt], relayPrefix: relay)
    }

    /// `<L{col-1}{row-1}P{profile-1}>` — assign a lamp to a profile.
    func setLampProfile(col: Int, row: Int, profile: Int, relay: Bool) throws {
        try send([Self.lt, UInt8(ascii: "L"), UInt8(col - 1), UInt8(row - 1),
                  UInt8(ascii: "P"), UInt8(profile - 1), Self.gt], relayPrefix: relay)
    }

    /// `<L{col-1}{row-1}B{bright}>` — direct lamp brightness (manual mode). 0-8.
    func setLampBrightness(col: Int, row: Int, bright: Int, relay: Bool) throws {
        try send([Self.lt, UInt8(ascii: "L"), UInt8(col - 1), UInt8(row - 1),
                  UInt8(ascii: "B"), UInt8(bright), Self.gt], relayPrefix: relay)
    }

    /// Convert a printed lamp number to matrix col/row for the given family.
    static func colRow(forLamp lamp: Int, manufacturer m: Manufacturer) -> (col: Int, row: Int) {
        if m == .stern {
            return (col: ((lamp - 1) % 8) + 1, row: ((lamp - 1) / 8) + 1)
        }
        return (col: lamp / 10, row: lamp % 10)
    }

    /// Draw a checkerboard in manual mode — a clearly visible comms confirmation.
    func drawCheckerboard(manufacturer m: Manufacturer) throws {
        try setManualMode()
        let relay = m.needsRelayPrefix
        for col in 1...8 {
            for row in 1...m.maxRow {
                try setLampBrightness(col: col, row: row, bright: ((col + row) % 2) * 8, relay: relay)
            }
        }
    }

    // MARK: - GI OCD write commands

    /// `<L\0{str-1}I{input-1}>` — string input source. str/input 1-6.
    func setStringInput(string s: Int, input: Int) throws {
        try send([Self.lt, UInt8(ascii: "L"), 0, UInt8(s - 1),
                  UInt8(ascii: "I"), UInt8(input - 1), Self.gt])
    }

    /// `<L\0{str-1}A{v}>` — string activity flag. v 0/1.
    func setStringActivity(string s: Int, active: Bool) throws {
        try send([Self.lt, UInt8(ascii: "L"), 0, UInt8(s - 1),
                  UInt8(ascii: "A"), active ? 1 : 0, Self.gt])
    }

    /// `<P{2*(str-1)+type}B{b}V{v}>` — string brightness. type 0 normal, 1 active.
    func setStringBrightness(string s: Int, active: Bool, level b: Int, value v: Int) throws {
        let idx = 2 * (s - 1) + (active ? 1 : 0)
        try send([Self.lt, UInt8(ascii: "P"), UInt8(idx),
                  UInt8(ascii: "B"), UInt8(b),
                  UInt8(ascii: "V"), Self.safe(v), Self.gt])
    }

    /// `<D{min}{max}>` — fade delay. 0-49.
    func setFadeDelay(min: Int, max: Int) throws {
        try send([Self.lt, UInt8(ascii: "D"), UInt8(min), UInt8(max), Self.gt])
    }

    /// `<A{v}>` — activity duration. 0-250.
    func setActivityDuration(_ v: Int) throws {
        try send([Self.lt, UInt8(ascii: "A"), Self.safe(v), Self.gt])
    }

    /// `<F{v}>` — 50 Hz mode. 0/1.
    func set50Hz(_ on: Bool) throws {
        try send([Self.lt, UInt8(ascii: "F"), on ? 1 : 0, Self.gt])
    }

    /// `<O{v}>` — output frequency. 1-3.
    func setOutputFrequency(_ v: Int) throws {
        try send([Self.lt, UInt8(ascii: "O"), UInt8(v), Self.gt])
    }

    /// `<L\0{str-1}B{v}>` — test brightness in manual mode. 0-8.
    func setTestBrightness(string s: Int, bright: Int) throws {
        try send([Self.lt, UInt8(ascii: "L"), 0, UInt8(s - 1),
                  UInt8(ascii: "B"), UInt8(bright), Self.gt])
    }

    func drawGICheckerboard() throws {
        try setManualMode()
        for col in 1...8 {
            for row in 1...6 {
                try setTestBrightness(string: row, bright: ((col + row) % 2) * 8)
            }
        }
    }

    // MARK: - Read settings

    /// Send `<Q>`, collect the reply, and split it into `{ … }` frames.
    func readSettingsFrames() throws -> [[UInt8]] {
        try port.write(Array("<Q>".utf8))
        let reply = port.read(max: 4096, idleRetries: 12)
        return Self.splitFrames(reply)
    }

    /// Extract `{ … }` frames (max 20 bytes each), mirroring the sync scan in the C code.
    static func splitFrames(_ data: [UInt8]) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        var start = -1
        let open = UInt8(ascii: "{"), close = UInt8(ascii: "}")
        for i in 0..<data.count {
            if start == -1 {
                if data[i] == open { start = i }
            } else if data[i] == close {
                frames.append(Array(data[start...i]))
                start = -1
            }
            if start >= 0 && i - start + 1 >= 20 { start = -1 }
        }
        return frames
    }

    enum Failure: Error, CustomStringConvertible {
        case noReply([UInt8])
        case badReply([UInt8])
        var description: String {
            switch self {
            case .noReply(let b):
                return "No reply from board (read \(b.count) bytes). Check the cable, the selected port, and that the board is powered."
            case .badReply(let b):
                let hex = b.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                return "Unexpected reply from board: \(hex)"
            }
        }
    }
}
