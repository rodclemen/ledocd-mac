import Foundation

/// Identifies which "play the fade" button is currently running, so the UI can
/// highlight it and a second press can stop it.
enum PreviewKey: Equatable {
    case lamp(Int)        // a single LED-OCD lamp (uses its assigned profile)
    case profile(Int)     // all lamps assigned to LED profile 1…8
    case giString(Int)    // a GI-OCD string 1…6

    var logLabel: String {
        switch self {
        case .lamp(let n):    return "lamp \(n)"
        case .profile(let p): return "profile \(p)"
        case .giString(let s): return "string \(s)"
        }
    }
}

/// Passed down into LEDView / GIView so the Live Mode controls can drive the
/// controller without those views needing the whole Controller.
struct LiveControl {
    var active: Bool                        // Live Mode on?
    // LED — per-lamp brightness chevron
    var lampLevel: (Int) -> Int             // current 0…8 for a lamp
    var setLampLevel: (Int, Int) -> Void
    // LED — per-profile activation
    var profileActiveB: (Int) -> Int?       // active B index 0…7, or nil
    var toggleProfile: (Int) -> Void        // 💡 on/off (lights lamps at B8 / returns to chevron)
    var showProfileB: (Int, Int) -> Void    // drive lamps to profile p's B[b] (click or live edit)
    // GI — per-string activation, mirroring the LED profile behavior
    var stringActive: (Int) -> Bool                        // string lit?
    var stringShownB: (Int) -> (active: Bool, b: Int)?     // which B it's showing
    var toggleString: (Int) -> Void                        // 💡 on/off
    var showStringB: (Int, Bool, Int) -> Void              // show B (row, index)
}

// MARK: - Fade math (pure, reused by every preview)

/// Map a 0…100 brightness percentage onto the board's 9 manual levels (0…8).
func manualLevel(_ percent: Int) -> Int {
    min(8, max(0, Int((Double(percent) / 100.0 * 8.0).rounded())))
}

/// Steps from level `a` (already showing) up/down to level `b`, inclusive of `b`.
func ramp(from a: Int, to b: Int, hold: TimeInterval) -> [(level: Int, hold: TimeInterval)] {
    guard a != b else { return [] }
    let dir = b > a ? 1 : -1
    return stride(from: a + dir, through: b, by: dir).map { (level: $0, hold: hold) }
}

/// A min→max→min sweep of a brightness curve, timed by `step` per level.
func sweepSequence(curve: [Int], step: TimeInterval) -> [(level: Int, hold: TimeInterval)] {
    guard curve.count >= 8 else { return [] }
    let lo = manualLevel(curve[0]), hi = manualLevel(curve[7])
    var seq: [(level: Int, hold: TimeInterval)] = [(lo, step)]
    seq += ramp(from: lo, to: hi, hold: step)
    seq += ramp(from: hi, to: lo, hold: step)
    return seq
}

/// LED delay 0…9 → seconds per level step (a faithful-ish, tunable mapping;
/// the board's true PWM fade is smoother than 9 manual levels allow).
func ledStep(delay: Int) -> TimeInterval { 0.05 + Double(delay) * 0.045 }

/// GI fade delay min/max 0…49 → seconds per level step (uses the average).
func giStep(fadeMin: Int, fadeMax: Int) -> TimeInterval {
    0.03 + (Double(fadeMin + fadeMax) / 2.0) / 49.0 * 0.40
}

/// GI activity duration 0…250 → hold time at the active level (capped for a preview).
func giHold(activityDuration: Int) -> TimeInterval { min(Double(activityDuration) * 0.02, 3.0) }

/// Run a fade program on a background thread: write each level, sleep its hold,
/// bail immediately when `isCancelled` flips. Not main-actor isolated on purpose.
func runFade(_ seq: [(level: Int, hold: TimeInterval)], cycles: Int,
             isCancelled: () -> Bool, write: (Int) throws -> Void) throws {
    for _ in 0..<cycles {
        for step in seq {
            if isCancelled() { return }
            try write(step.level)
            Thread.sleep(forTimeInterval: step.hold)
        }
    }
}

// MARK: - Preview player

/// Owns a single serial connection reused across previews. Programs run on a
/// private serial queue; a generation counter lets a new program (or a stop)
/// pre-empt whatever is currently fading without reopening the port.
final class PreviewPlayer {
    private let path: String
    private let queue = DispatchQueue(label: "com.rodclemen.ledocd.preview")
    private let lock = NSLock()
    private var _generation = 0
    private var port: SerialPort?
    var onError: ((String) -> Void)?           // main queue
    var onFinish: ((Int) -> Void)?             // (generation), main queue

    init(path: String) { self.path = path }

    private var generation: Int { lock.lock(); defer { lock.unlock() }; return _generation }
    private func bump() -> Int { lock.lock(); defer { lock.unlock() }; _generation += 1; return _generation }

    /// Open the port and enter manual mode once, up front. Idempotent.
    func begin(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.port != nil { DispatchQueue.main.async { completion(true) }; return }
            do {
                let p = SerialPort(path: self.path)
                try p.open()
                try OCDDevice(port: p).setManualMode()
                self.port = p
                DispatchQueue.main.async { completion(true) }
            } catch {
                DispatchQueue.main.async { self.onError?("✗ Manual mode: \(error)"); completion(false) }
            }
        }
    }

    /// Enqueue a fade program on the already-open manual session. Returns its
    /// generation. A newer program (or a cancel) pre-empts an older one. Does
    /// NOT open or close the port or change the board mode.
    @discardableResult
    func play(_ program: @escaping (OCDDevice, () -> Bool) throws -> Void) -> Int {
        let myGen = bump()
        queue.async { [weak self] in
            guard let self, let p = self.port else { return }
            do { try program(OCDDevice(port: p)) { self.generation != myGen } }
            catch { DispatchQueue.main.async { self.onError?("✗ Preview: \(error)") } }
            DispatchQueue.main.async { self.onFinish?(myGen) }
        }
        return myGen
    }

    /// Write an immediate level (or several) on the open session — used by the
    /// LED live chevrons and profile B-clicks. Pre-empts any running fade.
    func setLevel(_ body: @escaping (OCDDevice) throws -> Void) {
        _ = bump()
        queue.async { [weak self] in
            guard let self, let p = self.port else { return }
            do { try body(OCDDevice(port: p)) }
            catch { DispatchQueue.main.async { self.onError?("✗ Live: \(error)") } }
        }
    }

    /// Run a write program on the open session (pre-empting any fade) and
    /// report completion on the main queue. Used by Live Mode's Save to send
    /// settings + <S> WITHOUT leaving manual mode — the session stays live.
    func run(_ body: @escaping (OCDDevice) throws -> Void,
             completion: @escaping (Bool) -> Void) {
        _ = bump()
        queue.async {
            guard let p = self.port else { DispatchQueue.main.async { completion(false) }; return }
            do {
                try body(OCDDevice(port: p))
                DispatchQueue.main.async { completion(true) }
            } catch {
                DispatchQueue.main.async { self.onError?("✗ Send+save: \(error)"); completion(false) }
            }
        }
    }

    /// Stop the current fade (lamps off) but stay open in manual mode.
    func cancelFade() { _ = bump() }

    /// Leave manual mode: pre-empt any fade, return the board to normal, close.
    /// Strong self on purpose — the Controller nils its reference immediately
    /// after calling end(); a weak capture could deallocate the player before
    /// this runs, leaving the board stuck in manual mode (lamps off).
    func end() {
        _ = bump()
        queue.async {
            guard let p = self.port else { return }
            try? OCDDevice(port: p).setNormalMode()
            p.close()
            self.port = nil
        }
    }
}
