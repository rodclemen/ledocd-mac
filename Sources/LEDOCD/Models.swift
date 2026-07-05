import Foundation

// MARK: - LED OCD configuration

struct LEDProfile: Identifiable {
    let id: Int          // 1...8
    var name: String
    var delay: Int       // 0...9
    var brightness: [Int] // 8 values, each 0...100
}

@MainActor
final class LEDConfig: ObservableObject {
    @Published var profiles: [LEDProfile]
    /// lamp number → profile (1...8)
    @Published var lampProfile: [Int: Int] = [:]
    /// When off, B2–B7 are auto-calculated from B1/B8.
    @Published var advanced = false

    init() {
        // Factory defaults transcribed from ledocd.awk.
        let defs: [(String, Int, [Int])] = [
            ("Incandes", 0, [30, 40, 50, 60, 70, 80, 84, 84]),
            ("LED 25%",  4, [4, 7, 10, 13, 16, 19, 22, 25]),
            ("LED 35%",  4, [4, 8, 12, 17, 21, 26, 30, 35]),
            ("LED 45%",  4, [6, 11, 17, 22, 28, 33, 39, 45]),
            ("LED 55%",  4, [8, 14, 21, 28, 34, 41, 48, 55]),
            ("LED 70%",  4, [10, 18, 27, 35, 44, 52, 61, 70]),
            ("LED 85%",  4, [10, 20, 30, 40, 50, 60, 70, 85]),
            ("LED 100%", 4, [20, 31, 42, 54, 65, 77, 88, 100]),
        ]
        profiles = defs.enumerated().map { i, d in
            LEDProfile(id: i + 1, name: d.0, delay: d.1, brightness: d.2)
        }
    }

    /// Ensure every lamp in the list has a profile assignment (default 7 = "LED 85%").
    func ensureLamps(_ lamps: [Int]) {
        for l in lamps where lampProfile[l] == nil { lampProfile[l] = 7 }
    }

    /// Apply a parsed `{ … }` read-settings frame from the board.
    func apply(frame f: [UInt8], manufacturer m: OCDDevice.Manufacturer) {
        guard f.count >= 2 else { return }
        let L = UInt8(ascii: "L"), P = UInt8(ascii: "P")
        let N = UInt8(ascii: "N"), D = UInt8(ascii: "D")
        let B = UInt8(ascii: "B"), V = UInt8(ascii: "V")
        switch f[1] {
        case L: // {L col row P profile}  size 7
            if f.count == 7, f[4] == P {
                let col = Int(f[2]), row = Int(f[3]), profile = Int(f[5]) + 1
                let lamp = (m == .stern) ? row * 8 + col + 1 : (col + 1) * 10 + (row + 1)
                lampProfile[lamp] = profile
            }
        case P:
            let p = Int(f[2]) + 1
            guard p >= 1, p <= 8 else { return }
            if f.count == 13, f[3] == N {                // profile name
                let bytes = f[4..<12].filter { $0 != 0 }
                profiles[p - 1].name = String(decoding: bytes, as: UTF8.self)
            } else if f.count == 6, f[3] == D {          // delay
                profiles[p - 1].delay = Int(f[4])
            } else if f.count == 8, f[3] == B, f[5] == V { // brightness
                let level = Int(f[4]) + 1
                if level >= 1, level <= 8 { profiles[p - 1].brightness[level - 1] = Int(f[6]) }
            }
        default: break
        }
    }
}

// MARK: - GI OCD configuration

struct GIString: Identifiable {
    let id: Int          // 1...6
    var input: Int       // 1...6
    var active: Bool
    var normal: [Int]    // 8 values 0...100
    var activeBright: [Int] // 8 values 0...100
}

@MainActor
final class GIConfig: ObservableObject {
    @Published var strings: [GIString]
    /// When off, B2–B7 are auto-calculated from B1/B8.
    @Published var advanced = false
    @Published var fadeMin: Int = 3        // 0...49
    @Published var fadeMax: Int = 10       // 0...49
    @Published var activityDuration: Int = 60 // 0...250
    @Published var fiftyHz: Bool = false
    @Published var outputFreq: Int = 1     // 1...3

    init() {
        // Factory defaults transcribed from giocd.awk.
        let inputs = [1, 2, 3, 4, 5, 1]
        let curveAF = [1, 2, 3, 5, 9, 20, 28, 35]   // strings 1-5
        let curve6  = [5, 7, 10, 16, 28, 57, 81, 100] // string 6
        strings = (1...6).map { s in
            let curve = (s == 6) ? curve6 : curveAF
            return GIString(id: s, input: inputs[s - 1], active: false,
                            normal: curve, activeBright: curve)
        }
    }

    func apply(frame f: [UInt8]) {
        guard f.count >= 2 else { return }
        let L = UInt8(ascii: "L"), P = UInt8(ascii: "P"), Aa = UInt8(ascii: "A")
        let Dd = UInt8(ascii: "D"), Ff = UInt8(ascii: "F"), Oo = UInt8(ascii: "O")
        let I = UInt8(ascii: "I"), B = UInt8(ascii: "B"), V = UInt8(ascii: "V")
        switch f[1] {
        case L:
            if f.count == 7, f[4] == Aa {              // string activity
                let s = Int(f[3]) + 1
                if s >= 1, s <= 6 { strings[s - 1].active = (f[5] != 0) }
            } else if f.count == 7, f[4] == I {        // string input
                let s = Int(f[3]) + 1
                if s >= 1, s <= 6 { strings[s - 1].input = Int(f[5]) + 1 }
            }
        case P:
            if f.count == 8, f[3] == B, f[5] == V {
                let idx = Int(f[2])
                let s = idx / 2 + 1
                let isActive = (idx % 2) == 1
                let level = Int(f[4]) + 1
                guard s >= 1, s <= 6, level >= 1, level <= 8 else { return }
                if isActive { strings[s - 1].activeBright[level - 1] = Int(f[6]) }
                else { strings[s - 1].normal[level - 1] = Int(f[6]) }
            }
        case Aa: if f.count == 4 { activityDuration = Int(f[2]) }
        case Dd: if f.count == 5 { fadeMin = Int(f[2]); fadeMax = Int(f[3]) }
        case Ff: if f.count == 4 { fiftyHz = (f[2] != 0) }
        case Oo: if f.count == 4 { outputFreq = Int(f[2]) }
        default: break
        }
    }
}
