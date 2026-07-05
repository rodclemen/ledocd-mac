import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    static let refreshMachineData = Notification.Name("RefreshMachineData")
}

/// Our own help window (replaces the system Help menu, which AppKit clutters
/// with a Search field and "Send Feedback to Apple").
@MainActor func showLEDOCDInfo() { HelpWindowController.shared.show() }


@main
struct LEDOCDApp: App {
    @StateObject private var controller = Controller()
    @AppStorage("showLog") private var showLog = true
    @AppStorage("showMatrix") private var showMatrix = false

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        // Escape and Return drop focus while editing a text field. Excludes
        // panels (e.g. the rename alert), where Return must press the default
        // button. Return is consumed after unfocusing so it can't also trigger
        // the Connect button's default-action shortcut.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76,  // Esc, Return, Enter
               let window = NSApp.keyWindow, !(window is NSPanel),
               window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
                return nil
            }
            return event
        }
        // Clicking anywhere that isn't a text field drops focus. Done as an
        // event monitor (which always passes the event through) instead of a
        // SwiftUI tap gesture — a window-wide gesture competes with buttons
        // for their clicks and once froze the whole UI.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let window = event.window, !(window is NSPanel),
               window.firstResponder is NSTextView {
                let hit = window.contentView?.hitTest(event.locationInWindow)
                if !(hit is NSTextView) && !(hit is NSTextField) {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    var body: some Scene {
        WindowGroup("LED OCD") {
            ContentView()
                .environmentObject(controller)
                // Open at a comfortable size, but allow shrinking well below it so
                // the editors' scrollbars can take over on small screens/windows.
                .frame(minWidth: 640, idealWidth: 1080, minHeight: 420, idealHeight: 720)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About LED OCD") {
                    // The standard panel always pins NSHumanReadableCopyright to the
                    // very bottom, below the credits. To keep the copyright directly
                    // under the version (like a stock About box), put it at the top of
                    // the credits block instead, centered, with the attribution below.
                    let para = NSMutableParagraphStyle()
                    para.alignment = .center
                    let credits = NSAttributedString(
                        string: "Copyright © 2026 Rod Clemen\n\n"
                              + "Entirely built on the foundation of Harold Toler's LED & GI OCD.",
                        attributes: [
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .font: NSFont.systemFont(ofSize: 11),
                            .paragraphStyle: para
                        ])
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "LED OCD",
                        .credits: credits
                    ])
                }
            }
            CommandGroup(replacing: .help) {
                Button("LED OCD Help…") { showLEDOCDInfo() }
                Button("LED OCD website") {
                    if let url = URL(string: "https://ledocd.com") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            CommandMenu("Advanced") {
                Toggle("Show Log", isOn: $showLog)
                Toggle("Show Matrix Override", isOn: $showMatrix)
                    .help("Reveal a manual Matrix picker in the header (normally set by Connect/Read or the selected game).")
                Toggle("Simulate Board", isOn: Binding(
                    get: { controller.simulated },
                    set: { _ in controller.toggleSimulate() }))
                    .help("Debug: pretend an OCD board is connected so you can test the UI without hardware.")
                Divider()
                Toggle("Passthrough", isOn: Binding(
                    get: { controller.activeMode == .passthrough },
                    set: { _ in controller.togglePassthrough() }))
                Divider()
                Button("Refresh Machine Data") {
                    NotificationCenter.default.post(name: .refreshMachineData, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class Controller: ObservableObject {
    // Connection
    @Published var ports: [String] = []
    @Published var selectedPort: String = ""
    @Published var versionInfo: OCDDevice.VersionInfo?
    @Published var boardOverride: OCDDevice.Board?
    @Published var manufacturerOverride: OCDDevice.Manufacturer?
    @Published var isBusy = false
    @Published var log: String = ""

    // Data
    let led = LEDConfig()
    let gi = GIConfig()
    @Published var presets: [MachinePreset] = []
    @Published var selectedPreset: MachinePreset?
    @Published var isSyncing = false
    @Published var syncStatus = ""

    var effectiveBoard: OCDDevice.Board { boardOverride ?? versionInfo?.board ?? .ledOCD }
    var effectiveManufacturer: OCDDevice.Manufacturer {
        manufacturerOverride ?? versionInfo?.manufacturer ?? .wpc
    }

    /// Manufacturers whose games appear in the Game Select dropdown — driven by the
    /// matrix pills. Empty = no filter (all games, all pills grey/unselected).
    @Published var enabledMatrices: Set<OCDDevice.Manufacturer> = []

    var gamesForMatrix: [MachinePreset] {
        guard !enabledMatrices.isEmpty else { return presets }
        return presets.filter { enabledMatrices.contains($0.manufacturer) }
    }

    func toggleMatrix(_ m: OCDDevice.Manufacturer) {
        if enabledMatrices.contains(m) { enabledMatrices.remove(m) } else { enabledMatrices.insert(m) }
    }

    /// After a real Connect/Read detects the board, light its matrix pill (green)
    /// and narrow the game list to it. Not used by Simulate — pills stay manual there.
    func narrowMatrixToDetected() {
        guard let m = versionInfo?.manufacturer, m != .unknown else { return }
        enabledMatrices = [m]
    }

    /// The "Capcom" group pill: turning it on defaults to A; turning it off clears both.
    func toggleCapcomGroup() {
        if enabledMatrices.contains(.capcomA) || enabledMatrices.contains(.capcomB) {
            enabledMatrices.remove(.capcomA); enabledMatrices.remove(.capcomB)
        } else {
            enabledMatrices.insert(.capcomA)
        }
    }

    /// True while the app holds edits the board hasn't received yet.
    /// Regular mode: tints Send green. Live Mode: tints Commit Changes red.
    /// Starts neutral; the first actual edit flips it.
    @Published var hasUnsentChanges = false
    /// True after a successful Send whose settings haven't been persisted with
    /// Save yet — tints the Save button red (regular mode).
    @Published var hasUnsavedSends = false
    private var dirtyObservers: Set<AnyCancellable> = []

    init() {
        presets = Presets.loadAll()
        // Restore the last game used; otherwise leave it on the "- Select game -"
        // placeholder (nil) so nothing is auto-picked on first launch.
        let lastGame = UserDefaults.standard.string(forKey: "lastGame")
        selectedPreset = lastGame.flatMap { name in presets.first { $0.name == name } }
        syncStatus = Presets.hasUserData ? "Machine data: refreshed copy" : "Machine data: bundled"
        syncLampsToPreset()
        markClean()
        // After any config write, compare against the last clean state. Comparing
        // (not just observing) matters: text fields write their own value back
        // when first focused, and identical write-backs must NOT turn Send green.
        // Bonus: manually reverting an edit turns it back off.
        let recheck: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let dirty = self.fingerprint() != self.cleanFingerprint
                if self.hasUnsentChanges != dirty { self.hasUnsentChanges = dirty }
            }
        }
        led.objectWillChange.sink { _ in recheck() }.store(in: &dirtyObservers)
        gi.objectWillChange.sink { _ in recheck() }.store(in: &dirtyObservers)
    }

    /// Canonical serialization of everything Send writes to the board — the
    /// export XML built from current state. Equal fingerprints = nothing unsent.
    private func fingerprint() -> String {
        let numbers = (selectedPreset?.lampNumbers ?? Array(led.lampProfile.keys)).sorted()
        let lampProfiles = numbers.map { (number: $0, profile: led.lampProfile[$0] ?? 7) }
        let ledXML = ConfigIO.exportLEDXML(title: "", advanced: led.advanced,
                                           lampProfiles: lampProfiles, profiles: led.profiles)
        let giXML = ConfigIO.exportGIXML(advanced: gi.advanced, fadeMin: gi.fadeMin,
                                         fadeMax: gi.fadeMax, actDuration: gi.activityDuration,
                                         fiftyHz: gi.fiftyHz, strings: gi.strings)
        return ledXML + giXML
    }
    private var cleanFingerprint = ""

    /// Mark the current state as matching the board (after Send / Read / launch).
    private func markClean() {
        cleanFingerprint = fingerprint()
        hasUnsentChanges = false
    }

    /// Pull the current machine CSVs from ledocd.com into Application Support and
    /// reload the picker, preserving the current selection by name.
    func refreshMachineData() {
        guard !isSyncing else { return }
        isSyncing = true
        syncStatus = "Contacting ledocd.com…"
        append("▶︎ Refreshing machine data from ledocd.com…")
        let prevName = selectedPreset?.name
        Task {
            do {
                let result = try await DataSync.sync { done, total in
                    Task { @MainActor in self.syncStatus = "Downloading \(done)/\(total)…" }
                }
                self.presets = Presets.loadAll()
                // Keep the current game by name; stay on the placeholder if none.
                self.selectedPreset = prevName.flatMap { name in
                    self.presets.first { $0.name == name }
                }
                self.syncLampsToPreset()
                let fails = result.failed.isEmpty ? "" : ", \(result.failed.count) failed"
                self.syncStatus = "Updated \(result.downloaded), \(result.skipped) unchanged"
                if result.downloaded == 0 && result.failed.isEmpty {
                    self.append("✓ Machine data already up to date (\(result.skipped) games, nothing to download).")
                } else {
                    self.append("✓ Machine data: \(result.downloaded) downloaded, \(result.skipped) unchanged\(fails).")
                }
            } catch {
                self.syncStatus = "Refresh failed"
                self.append("✗ Refresh failed: \(error)")
            }
            self.isSyncing = false
        }
    }

    func append(_ s: String) { log += (log.isEmpty ? "" : "\n") + s }

    func refreshPorts() {
        ports = SerialPort.availablePorts()
        if selectedPort.isEmpty || !ports.contains(selectedPort) {
            selectedPort = ports.first ?? ""
        }
        append(ports.isEmpty
            ? "No USB serial ports found. Plug in the board's FTDI cable, then Refresh."
            : "Ports: \(ports.joined(separator: ", "))")
    }

    func syncLampsToPreset() {
        if let p = selectedPreset { led.ensureLamps(p.lampNumbers) }
    }

    /// Choose a game and adopt its matrix. The CSV is authoritative about a
    /// game's lamp matrix (incl. Capcom A/B, which the firmware can't detect),
    /// so selecting a game sets the Matrix to match — keeping lamp col/row
    /// mapping correct for Send/Read.
    func selectPreset(_ p: MachinePreset?) {
        selectedPreset = p
        syncLampsToPreset()
        if let m = p?.manufacturer, m != .unknown {
            manufacturerOverride = m
        }
        UserDefaults.standard.set(p?.name, forKey: "lastGame")   // remember for next launch
    }

    // MARK: - Add / edit a game (writes a user CSV)

    @Published var editingGame = false
    @Published var draftName = ""
    @Published var draftManufacturer: OCDDevice.Manufacturer = .wpc
    @Published var draftLamps: [MachinePreset.Lamp] = []

    /// The lamp template for a matrix: WPC/Capcom = 11…88 (8×8), Stern = 01…80 (8×10).
    private func templateLamps(_ m: OCDDevice.Manufacturer) -> [MachinePreset.Lamp] {
        if m == .stern { return (1...80).map { .init(number: $0, label: "") } }
        var l: [MachinePreset.Lamp] = []
        for col in 1...8 { for row in 1...8 { l.append(.init(number: col * 10 + row, label: "")) } }
        return l
    }

    func startNewGame() {
        draftManufacturer = effectiveManufacturer == .unknown ? .wpc : effectiveManufacturer
        draftName = ""
        draftLamps = templateLamps(draftManufacturer)
        editingGame = true
    }

    func cloneCurrentGame() {
        guard let p = selectedPreset else { startNewGame(); return }
        draftManufacturer = p.manufacturer == .unknown ? .wpc : p.manufacturer
        draftName = p.name + " copy"
        draftLamps = p.lamps
        editingGame = true
    }

    /// Switch the draft's matrix, keeping any insert names on overlapping lamp numbers.
    func setDraftManufacturer(_ m: OCDDevice.Manufacturer) {
        guard m != draftManufacturer else { return }
        let kept = Dictionary(draftLamps.map { ($0.number, $0.label) }, uniquingKeysWith: { a, _ in a })
        draftManufacturer = m
        draftLamps = templateLamps(m).map { .init(number: $0.number, label: kept[$0.number] ?? "") }
    }

    func setDraftLamp(_ number: Int, label: String) {
        if let i = draftLamps.firstIndex(where: { $0.number == number }) { draftLamps[i].label = label }
    }

    func cancelGameEdit() { editingGame = false }

    func saveGame() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { append("Enter a game name first."); return }
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard let dir = DataSync.customGamesDirectory(create: true) else {
            append("✗ Could not open the custom games folder."); return
        }
        var lines: [String] = []
        if draftManufacturer == .capcomA { lines.append("CAPCOM_A") }
        if draftManufacturer == .capcomB { lines.append("CAPCOM_B") }
        for lamp in draftLamps.sorted(by: { $0.number < $1.number }) {
            lines.append("\(String(format: "%02d", lamp.number)),\(lamp.label)")
        }
        let csv = lines.joined(separator: "\n") + "\n"
        do {
            try csv.write(to: dir.appendingPathComponent(safe + ".csv"), atomically: true, encoding: .utf8)
            editingGame = false
            presets = Presets.loadAll()
            enabledMatrices.insert(draftManufacturer)   // make sure its pill shows it
            // Same name may exist as a default game — select the custom one.
            selectPreset(presets.first { $0.isCustom && $0.name == safe })
            append("✓ Saved custom game \"\(safe)\" (\(draftLamps.count) lamps).")
        } catch {
            append("✗ Save failed: \(error.localizedDescription)")
        }
    }

    /// Trash button: delete the selected custom game's CSV (with confirmation).
    func deleteCustomGame() {
        guard let p = selectedPreset, p.isCustom,
              let dir = DataSync.customGamesDirectory(create: false) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(p.name)\u{201D}?"
        alert.informativeText = "This removes the custom game from your library. Default games are not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(p.name + ".csv"))
        } catch {
            append("✗ Delete failed: \(error.localizedDescription)"); return
        }
        presets = Presets.loadAll()
        selectPreset(nil)
        append("✓ Deleted custom game \u{201C}\(p.name)\u{201D}.")
    }

    /// Pencil button: rename the selected custom game (renames its CSV file).
    func renameCustomGame() {
        guard let p = selectedPreset, p.isCustom,
              let dir = DataSync.customGamesDirectory(create: false) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \u{201C}\(p.name)\u{201D}"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = p.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw != p.name else { return }
        let safe = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let dst = dir.appendingPathComponent(safe + ".csv")
        guard !FileManager.default.fileExists(atPath: dst.path) else {
            append("✗ A custom game named \u{201C}\(safe)\u{201D} already exists."); return
        }
        do {
            try FileManager.default.moveItem(at: dir.appendingPathComponent(p.name + ".csv"), to: dst)
        } catch {
            append("✗ Rename failed: \(error.localizedDescription)"); return
        }
        presets = Presets.loadAll()
        selectPreset(presets.first { $0.isCustom && $0.name == safe })
        append("✓ Renamed custom game to \u{201C}\(safe)\u{201D}.")
    }

    // MARK: - Generic serial runner for fire-and-forget actions

    private func runSerial(_ label: String,
                           onDone: ((Bool) -> Void)? = nil,
                           _ body: @escaping (OCDDevice, OCDDevice.Manufacturer) throws -> String) {
        guard !selectedPort.isEmpty else { append("Select a port first."); onDone?(false); return }
        endLive(returnToNormal: true)   // free the port if manual preview holds it
        let path = selectedPort
        let manu = effectiveManufacturer
        isBusy = true
        append("▶︎ \(label)…")
        Task.detached { [weak self] in
            var msg: String
            var ok = true
            do {
                let port = SerialPort(path: path)
                try port.open()
                defer { port.close() }
                msg = try body(OCDDevice(port: port), manu)
            } catch { msg = "✗ \(error)"; ok = false }
            let out = msg
            let success = ok
            await MainActor.run { [weak self] in
                self?.append(out); self?.isBusy = false; onDone?(success)
            }
        }
    }

    // MARK: - Debug / simulation

    /// Pretend an OCD board is connected (no hardware) so the UI can be exercised.
    @Published var simulated = false

    func toggleSimulate() {
        if simulated {
            simulated = false
            versionInfo = nil
            ports = SerialPort.availablePorts()
            selectedPort = ports.first ?? ""
            append("• Simulation off.")
            return
        }
        endLive(returnToNormal: true)
        simulated = true
        if !ports.contains(SerialPort.simulatedPath) { ports.append(SerialPort.simulatedPath) }
        selectedPort = SerialPort.simulatedPath
        versionInfo = OCDDevice.VersionInfo(board: effectiveBoard, version: 30,
                                            manufacturer: effectiveManufacturer)
        append("✓ Simulated OCD board connected (no hardware) — try Live Mode, Send, etc.")
    }

    // MARK: - Version

    func readVersion() {
        guard !selectedPort.isEmpty else { append("Select a port first."); return }
        if simulated {
            versionInfo = OCDDevice.VersionInfo(board: effectiveBoard, version: 30,
                                                manufacturer: effectiveManufacturer)
            append("✓ Simulated board (firmware v30).")
            return
        }
        endLive(returnToNormal: true)
        let path = selectedPort
        isBusy = true
        append("▶︎ Read firmware version…")
        Task.detached { [weak self] in
            var info: OCDDevice.VersionInfo?
            var msg: String
            do {
                let port = SerialPort(path: path)
                try port.open()
                defer { port.close() }
                let v = try OCDDevice(port: port).readVersion()
                info = v
                msg = "✓ \(v.board.rawValue) firmware v\(v.version) — matrix: \(v.manufacturer.rawValue)"
            } catch { msg = "✗ \(error)" }
            let out = msg
            let captured = info
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let captured {
                    self.versionInfo = captured
                    self.boardOverride = nil
                    self.manufacturerOverride = nil
                    self.narrowMatrixToDetected()
                }
                self.append(out)
                self.isBusy = false
                // A successful Connect flows straight into reading the board's
                // settings, so the app immediately mirrors what's on it.
                if captured != nil { self.readSettings() }
            }
        }
    }

    // MARK: - Read settings

    func readSettings() {
        guard !selectedPort.isEmpty else { append("Select a port first."); return }
        endLive(returnToNormal: true)
        let path = selectedPort
        let board = effectiveBoard
        let manu = effectiveManufacturer
        isBusy = true
        append("▶︎ Read settings from board…")
        Task.detached { [weak self] in
            var frames: [[UInt8]] = []
            var msg: String
            do {
                let port = SerialPort(path: path)
                try port.open()
                defer { port.close() }
                frames = try OCDDevice(port: port).readSettingsFrames()
                msg = "✓ Read \(frames.count) settings frames."
            } catch { msg = "✗ \(error)"; frames = [] }
            let out = msg
            let captured = frames
            await MainActor.run { [weak self] in
                guard let self else { return }
                // The <Q> stream also carries the firmware frame — capture the board's
                // matrix from it so Read is self-correcting. Keep a game-selected matrix
                // override (it's more specific, e.g. Capcom A vs B).
                let boardInfo = captured.compactMap { OCDDevice.versionFromFrame($0) }.first
                if let boardInfo { self.versionInfo = boardInfo; self.narrowMatrixToDetected() }
                let decodeBoard = boardInfo?.board ?? board
                let decodeManu = self.manufacturerOverride ?? boardInfo?.manufacturer ?? manu
                for f in captured {
                    if decodeBoard == .giOCD { self.gi.apply(frame: f) }
                    else { self.led.apply(frame: f, manufacturer: decodeManu) }
                }
                if let boardInfo {
                    self.append("  matrix: \(boardInfo.manufacturer.rawValue) (firmware v\(boardInfo.version))")
                }
                // After a successful read the app mirrors the board — nothing unsent.
                if !captured.isEmpty { self.markClean() }
                self.append(out)
                self.isBusy = false
            }
        }
    }

    // MARK: - Apply settings (send everything)

    func applySettings(andSave: Bool = false) {
        if effectiveBoard == .giOCD { applyGI(andSave: andSave) } else { applyLED(andSave: andSave) }
    }

    /// Snapshot the LED settings into a self-contained serial write program,
    /// runnable on any open session (a fresh one, or the Live Mode session).
    private func ledProgram(andSave: Bool) -> (OCDDevice) throws -> Void {
        let profiles = led.profiles.map { (name: $0.name, delay: $0.delay, brightness: $0.brightness) }
        let manu = effectiveManufacturer
        let relay = manu.needsRelayPrefix
        let lampAssignments: [(col: Int, row: Int, profile: Int)] =
            (selectedPreset?.lamps ?? []).map { lamp in
                let cr = OCDDevice.colRow(forLamp: lamp.number, manufacturer: manu)
                return (cr.col, cr.row, led.lampProfile[lamp.number] ?? 7)
            }
        return { dev in
            for (i, p) in profiles.enumerated() {
                let n = i + 1
                try dev.setProfileName(profile: n, name: p.name, relay: relay)
                for level in 1...8 {
                    try dev.setProfileBrightness(profile: n, level: level, value: p.brightness[level - 1], relay: relay)
                }
                try dev.setProfileDelay(profile: n, delay: p.delay, relay: relay)
            }
            for a in lampAssignments where a.col >= 1 && a.col <= 8 && a.row >= 1 && a.row <= 10 {
                try dev.setLampProfile(col: a.col, row: a.row, profile: a.profile, relay: relay)
            }
            if andSave { try dev.save() }
        }
    }

    private func applyLED(andSave: Bool = false) {
        let program = ledProgram(andSave: andSave)
        let count = selectedPreset?.lamps.count ?? 0
        runSerial("Apply LED OCD settings (8 profiles, \(count) lamps)",
                  onDone: { [weak self] ok in
                      if ok { self?.markClean(); self?.hasUnsavedSends = !andSave }
                  }) { dev, _ in
            try program(dev)
            return andSave ? "✓ Sent and saved — settings stored permanently on the board."
                           : "✓ Applied all LED OCD settings. Use Save to persist them on the board."
        }
    }

    /// Snapshot the GI settings into a self-contained serial write program.
    private func giProgram(andSave: Bool) -> (OCDDevice) throws -> Void {
        let strings = gi.strings.map { (input: $0.input, active: $0.active, normal: $0.normal, activeBright: $0.activeBright) }
        let fadeMin = gi.fadeMin, fadeMax = gi.fadeMax
        let actDur = gi.activityDuration, fifty = gi.fiftyHz, outFreq = gi.outputFreq
        return { dev in
            for (i, s) in strings.enumerated() {
                let n = i + 1
                try dev.setStringInput(string: n, input: s.input)
                try dev.setStringActivity(string: n, active: s.active)
                for level in 1...8 {
                    try dev.setStringBrightness(string: n, active: false, level: level, value: s.normal[level - 1])
                    try dev.setStringBrightness(string: n, active: true, level: level, value: s.activeBright[level - 1])
                }
            }
            try dev.setFadeDelay(min: fadeMin, max: fadeMax)
            try dev.setActivityDuration(actDur)
            try dev.set50Hz(fifty)
            try dev.setOutputFrequency(outFreq)
            if andSave { try dev.save() }
        }
    }

    private func applyGI(andSave: Bool = false) {
        let program = giProgram(andSave: andSave)
        runSerial("Apply GI OCD settings (6 strings + globals)",
                  onDone: { [weak self] ok in
                      if ok { self?.markClean(); self?.hasUnsavedSends = !andSave }
                  }) { dev, _ in
            try program(dev)
            return andSave ? "✓ Sent and saved — settings stored permanently on the board."
                           : "✓ Applied all GI OCD settings. Use Save to persist them on the board."
        }
    }

    // MARK: - Simple actions

    /// The Save button. In Live Mode you've already seen the settings on the
    /// playfield, so one press sends everything AND stores it (the board's Save
    /// command can only persist what it was last sent) — through the live
    /// session's open port, so Live Mode stays on and you can keep tuning.
    /// In regular mode it just persists the last Send (gated on hasUnsentChanges).
    func saveAction() {
        if liveMode { liveSendAndSave() } else { save() }
    }

    private func liveSendAndSave() {
        guard let player = previewPlayer else { applySettings(andSave: true); return }
        let program = effectiveBoard == .giOCD ? giProgram(andSave: true)
                                               : ledProgram(andSave: true)
        isBusy = true
        append("▶︎ Send + save (staying in Live Mode)…")
        player.run(program) { [weak self] ok in
            guard let self else { return }
            self.isBusy = false
            if ok {
                self.markClean()
                self.hasUnsavedSends = false
                self.append("✓ Sent and saved — settings stored on the board. Live Mode still on.")
            }
        }
    }

    func save() {
        runSerial("Save settings to board",
                  onDone: { [weak self] ok in if ok { self?.hasUnsavedSends = false } }) { d, _ in
            try d.save(); return "✓ Settings saved on board."
        }
    }

    // MARK: - Import / Export (Windows-app-compatible XML)

    func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        let xml: String
        if effectiveBoard == .giOCD {
            panel.nameFieldStringValue = "gi-ocd.xml"
            xml = ConfigIO.exportGIXML(advanced: gi.advanced, fadeMin: gi.fadeMin,
                                       fadeMax: gi.fadeMax, actDuration: gi.activityDuration,
                                       fiftyHz: gi.fiftyHz, strings: gi.strings)
        } else {
            panel.nameFieldStringValue = "\(selectedPreset?.name ?? "led-ocd").xml"
            let numbers = (selectedPreset?.lampNumbers ?? Array(led.lampProfile.keys)).sorted()
            let lampProfiles = numbers.map { (number: $0, profile: led.lampProfile[$0] ?? 7) }
            xml = ConfigIO.exportLEDXML(title: selectedPreset?.name ?? "", advanced: led.advanced,
                                        lampProfiles: lampProfiles, profiles: led.profiles)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try xml.data(using: .utf8)?.write(to: url)
            append("✓ Exported to \(url.lastPathComponent)")
        } catch {
            append("✗ Export failed: \(error.localizedDescription)")
        }
    }

    func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        // Auto-detect the file type (GI files carry <delaymin>; LED files carry <profileN>).
        if let giParsed = ConfigIO.parseGIXML(data) {
            boardOverride = .giOCD
            applyParsedGI(giParsed)
            append("✓ Imported GI OCD config from \(url.lastPathComponent). Press Send to write it to the board.")
        } else if let ledParsed = ConfigIO.parseLEDXML(data) {
            boardOverride = .ledOCD
            applyParsedLED(ledParsed)
            append("✓ Imported \(url.lastPathComponent) — “\(ledParsed.title)”. Press Send to write it to the board.")
        } else {
            append("✗ Import failed: not a valid LED OCD or GI OCD export file.")
        }
    }

    private func applyParsedLED(_ parsed: ConfigIO.ParsedLED) {
        if let match = presets.first(where: { $0.name == parsed.title }) {
            selectPreset(match)
        }
        led.advanced = parsed.advanced
        for (i, pr) in parsed.profiles.enumerated() where i < led.profiles.count {
            led.profiles[i].name = pr.name
            led.profiles[i].brightness = pr.brightness
            led.profiles[i].delay = pr.delay
        }
        for (number, profile) in parsed.lampProfiles { led.lampProfile[number] = profile }
    }

    private func applyParsedGI(_ parsed: ConfigIO.ParsedGI) {
        gi.advanced = parsed.advanced
        gi.fadeMin = parsed.fadeMin
        gi.fadeMax = parsed.fadeMax
        gi.activityDuration = parsed.actDuration
        gi.fiftyHz = parsed.fiftyHz
        for (i, s) in parsed.strings.enumerated() where i < gi.strings.count {
            gi.strings[i].input = s.input
            gi.strings[i].active = s.active
            gi.strings[i].normal = s.normal
            gi.strings[i].activeBright = s.activeBright
        }
    }

    // MARK: - Board modes (toggle: press to enter, press again → Normal)

    enum BoardMode: Equatable {
        case none, manual, passthrough, checkerboard
        var label: String {
            switch self {
            case .none: return ""
            case .manual: return "LIVE"
            case .passthrough: return "PASSTHROUGH"
            case .checkerboard: return "CHECKERBOARD"
            }
        }
    }
    @Published var activeMode: BoardMode = .none

    /// Return the board to normal play and clear the active mode.
    func goNormal() {
        activeMode = .none
        runSerial("Normal mode") { d, _ in try d.setNormalMode(); return "✓ Board in normal OCD mode." }
    }

    private func setMode(_ mode: BoardMode, label: String,
                         _ body: @escaping (OCDDevice, OCDDevice.Manufacturer) throws -> String) {
        if activeMode == mode { goNormal(); return }
        let previous = activeMode
        activeMode = mode
        runSerial(label, onDone: { [weak self] ok in if !ok { self?.activeMode = previous } }, body)
    }

    func togglePassthrough() {
        setMode(.passthrough, label: "Passthrough") { d, _ in
            try d.setPassthroughMode(); return "✓ Passthrough mode."
        }
    }

    func toggleCheckerboard() {
        let isGI = effectiveBoard == .giOCD
        setMode(.checkerboard, label: "Checkerboard") { d, manu in
            if isGI { try d.drawGICheckerboard() } else { try d.drawCheckerboard(manufacturer: manu) }
            return "✓ Checkerboard drawn."
        }
    }

    /// Exit manual mode from the toolbar toggle, whether or not a live session exists.
    func exitManual() {
        if manualSession != nil { endManualTest(returnToNormal: true) }
        else { goNormal() }
    }

    // MARK: - Live Mode (inline manual control)

    /// One persistent manual-mode session. The board is put in manual mode once
    /// and stays open while Live Mode is on — the LED chevrons and profile
    /// buttons write directly to it; no per-press mode churn.
    @Published var liveMode = false
    @Published var previewTarget: PreviewKey? = nil    // GI: which string is fading
    @Published var liveLampLevel: [Int: Int] = [:]     // LED lamp# -> 0…8 chevron value
    @Published var liveProfileB: [Int: Int] = [:]      // LED profile 1…8 -> active B index 0…7
    private var previewPlayer: PreviewPlayer?
    private var previewGen = 0

    var liveEnabled: Bool { liveMode && !isBusy }

    /// Enter/leave Live Mode.
    func toggleLiveMode() {
        if liveMode {
            endLive(returnToNormal: true)
            append("• Live Mode off — board returned to normal.")
            return
        }
        guard !selectedPort.isEmpty else { append("Select a port first."); return }
        guard !isBusy else { return }
        let player = PreviewPlayer(path: selectedPort)
        player.onError = { [weak self] m in self?.append(m) }
        player.onFinish = { [weak self] gen in self?.previewDidFinish(gen) }
        previewPlayer = player
        liveMode = true
        activeMode = .manual
        liveLampLevel = [:]
        liveProfileB = [:]
        liveStringSel = [:]
        append("▶︎ Live Mode on.")
        player.begin { [weak self] ok in
            guard let self else { return }
            if ok { self.allLiveOff() }            // clean slate
            else { self.liveMode = false; self.activeMode = .none; self.previewPlayer = nil }
        }
    }

    /// Leave Live Mode (also called by any real serial op that needs the port).
    func endLive(returnToNormal: Bool) {
        guard previewPlayer != nil || liveMode else { return }
        if returnToNormal { previewPlayer?.end() }
        previewPlayer = nil
        liveMode = false
        previewTarget = nil
        liveLampLevel = [:]
        liveProfileB = [:]
        liveStringSel = [:]
        if activeMode == .manual { activeMode = .none }
    }

    /// Everything off for the current board type when a live session starts.
    private func allLiveOff() {
        if effectiveBoard == .giOCD {
            for s in 1...6 { setString(s, level: 0) }
        } else {
            allLampsOffLive()
        }
    }

    // MARK: LED live controls

    func liveSetLamp(_ lamp: Int, level: Int) {
        liveLampLevel[lamp] = level
        let cr = OCDDevice.colRow(forLamp: lamp, manufacturer: effectiveManufacturer)
        let relay = effectiveManufacturer.needsRelayPrefix
        previewPlayer?.setLevel { try $0.setLampBrightness(col: cr.col, row: cr.row, bright: level, relay: relay) }
    }

    private func allLampsOffLive() {
        for l in (selectedPreset?.lampNumbers ?? []) { liveSetLamp(l, level: 0) }
    }

    private func lampsUsing(profile p: Int) -> [Int] {
        led.lampProfile.filter { $0.value == p }.map(\.key).sorted()
    }

    private func setProfileLamps(_ p: Int, toLevel level: Int) {
        let manu = effectiveManufacturer, relay = manu.needsRelayPrefix
        let coords = lampsUsing(profile: p).map { OCDDevice.colRow(forLamp: $0, manufacturer: manu) }
        previewPlayer?.setLevel { dev in
            for c in coords { try dev.setLampBrightness(col: c.col, row: c.row, bright: level, relay: relay) }
        }
    }

    private func returnProfileLampsToChevron(_ p: Int) {
        let manu = effectiveManufacturer, relay = manu.needsRelayPrefix
        let items = lampsUsing(profile: p).map {
            (OCDDevice.colRow(forLamp: $0, manufacturer: manu), liveLampLevel[$0] ?? 0)
        }
        previewPlayer?.setLevel { dev in
            for (c, lvl) in items { try dev.setLampBrightness(col: c.col, row: c.row, bright: lvl, relay: relay) }
        }
    }

    /// 💡 toggle: on → light all its lamps at B8; off → return them to their chevron.
    func liveToggleProfile(_ p: Int) {
        guard liveMode else { return }
        if liveProfileB[p] != nil {
            liveProfileB[p] = nil
            returnProfileLampsToChevron(p)
        } else {
            guard !lampsUsing(profile: p).isEmpty else { append("No lamps use profile \(p) yet."); return }
            liveProfileB[p] = 7
            setProfileLamps(p, toLevel: manualLevel(led.profiles[p - 1].brightness[7]))
        }
    }

    /// Drive an active profile's lamps to its B[b] brightness right now — called as
    /// you click or edit a brightness cell so the change is visible in real time.
    func liveShowProfileB(_ p: Int, _ b: Int) {
        guard liveMode, liveProfileB[p] != nil else { return }
        liveProfileB[p] = b
        setProfileLamps(p, toLevel: manualLevel(led.profiles[p - 1].brightness[b]))
    }

    // MARK: GI live controls (mirrors the LED profile 💡 + B-click behavior)

    /// Which B a lit string is showing: the row (normal/active) and index 0…7.
    struct GIStringSel: Equatable { var active: Bool; var b: Int }
    @Published var liveStringSel: [Int: GIStringSel] = [:]   // string id → shown B

    private func setString(_ id: Int, level: Int) {
        previewPlayer?.setLevel { try $0.setTestBrightness(string: id, bright: level) }
    }

    /// 💡 toggle: on → light the string at its Normal B8; off → string off.
    func liveToggleString(_ id: Int) {
        guard liveMode else { return }
        if liveStringSel[id] != nil {
            liveStringSel[id] = nil
            setString(id, level: 0)
        } else {
            liveStringSel[id] = .init(active: false, b: 7)
            setString(id, level: manualLevel(gi.strings[id - 1].normal[7]))
        }
    }

    /// Drive a lit string to a specific B (normal or active row) right now —
    /// called on B-clicks and live edits, same as the LED page.
    func liveShowStringB(_ id: Int, active: Bool, _ b: Int) {
        guard liveMode, liveStringSel[id] != nil else { return }
        liveStringSel[id] = .init(active: active, b: b)
        let str = gi.strings[id - 1]
        setString(id, level: manualLevel(active ? str.activeBright[b] : str.normal[b]))
    }

    // MARK: GI fade preview (legacy path, no longer wired to the UI)

    func togglePreview(_ key: PreviewKey) {
        guard liveMode, let player = previewPlayer else { append("Turn on Live Mode first."); return }
        if previewTarget == key { player.cancelFade(); previewTarget = nil; return }
        guard let program = previewProgram(for: key) else { return }
        previewTarget = key
        append("▶︎ Preview: \(key.logLabel) (3×)")
        previewGen = player.play(program)
    }

    private func previewDidFinish(_ gen: Int) {
        guard gen == previewGen else { return }
        previewTarget = nil
    }

    /// Build the background fade closure for a preview target, on the main actor
    /// (reads config), capturing only value types the closure can use off-thread.
    private func previewProgram(for key: PreviewKey) -> ((OCDDevice, () -> Bool) throws -> Void)? {
        let manu = effectiveManufacturer
        let relay = manu.needsRelayPrefix
        switch key {
        case .lamp(let n):
            let prof = led.profiles[(led.lampProfile[n] ?? 7) - 1]
            let seq = sweepSequence(curve: prof.brightness, step: ledStep(delay: prof.delay))
            let cr = OCDDevice.colRow(forLamp: n, manufacturer: manu)
            return { dev, cancelled in
                try runFade(seq, cycles: 3, isCancelled: cancelled) { lvl in
                    try dev.setLampBrightness(col: cr.col, row: cr.row, bright: lvl, relay: relay)
                }
                try? dev.setLampBrightness(col: cr.col, row: cr.row, bright: 0, relay: relay)
            }

        case .profile(let p):
            let lamps = led.lampProfile.filter { $0.value == p }.map(\.key).sorted()
            guard !lamps.isEmpty else {
                append("No lamps use profile \(p) yet — assign it to a lamp first.")
                return nil
            }
            let prof = led.profiles[p - 1]
            let seq = sweepSequence(curve: prof.brightness, step: ledStep(delay: prof.delay))
            let coords = lamps.map { OCDDevice.colRow(forLamp: $0, manufacturer: manu) }
            return { dev, cancelled in
                try runFade(seq, cycles: 3, isCancelled: cancelled) { lvl in
                    for c in coords { try dev.setLampBrightness(col: c.col, row: c.row, bright: lvl, relay: relay) }
                }
                for c in coords { try? dev.setLampBrightness(col: c.col, row: c.row, bright: 0, relay: relay) }
            }

        case .giString(let s):
            let str = gi.strings[s - 1]
            let step = giStep(fadeMin: gi.fadeMin, fadeMax: gi.fadeMax)
            let seq: [(level: Int, hold: TimeInterval)]
            if str.active {
                // Real activity behaviour: rest at normal → up to active → hold → back.
                let nL = manualLevel(str.normal[7]), aL = manualLevel(str.activeBright[7])
                var s2: [(level: Int, hold: TimeInterval)] = [(nL, step)]
                s2 += ramp(from: nL, to: aL, hold: step)
                s2.append((aL, giHold(activityDuration: gi.activityDuration)))
                s2 += ramp(from: aL, to: nL, hold: step)
                seq = s2
            } else {
                seq = sweepSequence(curve: str.normal, step: step)
            }
            return { dev, cancelled in
                try runFade(seq, cycles: 3, isCancelled: cancelled) { lvl in
                    try dev.setTestBrightness(string: s, bright: lvl)
                }
                try? dev.setTestBrightness(string: s, bright: 0)
            }
        }
    }

    // MARK: - Manual Test session

    @Published var manualActive = false
    @Published var manualLevels: [Int: Int] = [:]   // lamp# (LED) or string# (GI) -> level 0…8
    private var manualSession: ManualSession?

    func startManualTest() {
        guard !selectedPort.isEmpty else { append("Select a port first."); return }
        endLive(returnToNormal: true)
        manualLevels = [:]
        manualActive = false
        let session = ManualSession(path: selectedPort, manufacturer: effectiveManufacturer)
        session.onError = { [weak self] msg in self?.append(msg) }
        manualSession = session
        append("▶︎ Manual Test: entering manual mode…")
        session.enter { [weak self] ok in
            guard let self else { return }
            self.manualActive = ok
            if ok {
                self.activeMode = .manual
                self.manualAllOff()   // start from a clean slate — no stray lit lamps
            }
            self.append(ok ? "✓ In manual mode. Set levels (0 = off … 8 = max)."
                           : "✗ Could not enter manual mode.")
        }
    }

    func manualSetLED(lamp: Int, level: Int) {
        manualLevels[lamp] = level
        manualSession?.setLED(lamp: lamp, level: level)
    }

    /// Set every lamp that uses profile `p` to `level` (Manual Test profile row).
    @Published var manualProfileLevel: [Int: Int] = [:]
    func manualSetProfile(profile p: Int, level: Int) {
        manualProfileLevel[p] = level
        for l in (selectedPreset?.lampNumbers ?? []) where (led.lampProfile[l] ?? 7) == p {
            manualSetLED(lamp: l, level: level)
        }
    }

    func manualSetGI(string: Int, level: Int) {
        manualLevels[string] = level
        manualSession?.setGI(string: string, level: level)
    }

    func manualCheckerboard() {
        manualSession?.checkerboard(isGI: effectiveBoard == .giOCD)
        // Reflect the resulting pattern in the panel's level displays.
        if effectiveBoard == .giOCD {
            for s in 1...6 { manualLevels[s] = ((8 + s) % 2) * 8 }
        } else {
            for l in (selectedPreset?.lampNumbers ?? []) {
                let cr = OCDDevice.colRow(forLamp: l, manufacturer: effectiveManufacturer)
                manualLevels[l] = ((cr.col + cr.row) % 2) * 8
            }
        }
        append("• Manual Test: checkerboard.")
    }

    func manualAllOff() {
        if effectiveBoard == .giOCD {
            for s in 1...6 { manualSetGI(string: s, level: 0) }
        } else {
            for l in (selectedPreset?.lampNumbers ?? []) { manualSetLED(lamp: l, level: 0) }
        }
        append("• Manual Test: all off.")
    }

    func endManualTest(returnToNormal: Bool) {
        manualSession?.exit(returnToNormal: returnToNormal) { [weak self] in
            self?.append(returnToNormal ? "✓ Returned to normal mode."
                                        : "✓ Left board in manual mode (pattern kept).")
        }
        manualActive = false
        manualSession = nil
        activeMode = returnToNormal ? .none : .manual
    }
}

struct ContentView: View {
    @EnvironmentObject private var c: Controller
    @AppStorage("showLog") private var showLog = true
    @AppStorage("showMatrix") private var showMatrix = false
    @State private var showManualTest = false
    @State private var buttonHint: String?   // shown in the area under Manual Test

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editor
            if showLog { logPane }
        }
        .background(Color.black.opacity(0.06))
        .overlay(alignment: .topTrailing) {
            // No overlay for .manual (Live Mode / Manual Test) — their green
            // buttons already show the state; keep it for PASSTHROUGH etc.
            if c.activeMode != .none && c.activeMode != .manual {
                Text(c.activeMode.label)
                    .font(.headline).bold()
                    .foregroundStyle(.red)
                    .padding(.top, 14).padding(.trailing, 18)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("LED/GI OCD Configuration v\(appVersion)")
        .onReceive(NotificationCenter.default.publisher(for: .refreshMachineData)) { _ in
            c.refreshMachineData()
        }
        .onAppear {
            c.refreshPorts()
            DispatchQueue.main.async {
                // Don't let macOS auto-focus the first text field (the Incandes name).
                NSApp.keyWindow?.makeFirstResponder(nil)
                ensureWindowFitsContent()
            }
        }
        .sheet(isPresented: $showManualTest) {
            ManualTestView(c: c)
        }
    }

    /// On first launch, make sure the window is big enough to show everything.
    private func ensureWindowFitsContent() {
        guard let w = NSApp.keyWindow ?? NSApp.windows.first else { return }
        var f = w.frame
        let minW: CGFloat = 1080, minH: CGFloat = 720
        guard f.width < minW || f.height < minH else { return }
        f.size.width = max(f.width, minW)
        f.size.height = max(f.height, minH)
        if let vis = w.screen?.visibleFrame {
            f.size.width = min(f.width, vis.width)
            f.size.height = min(f.height, vis.height)
        }
        w.setFrame(f, display: true)
        w.center()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("COM Select").frame(width: 84, alignment: .leading)
                ChevronPicker(selection: $c.selectedPort,
                              options: c.ports.isEmpty ? [""] : c.ports,
                              label: { $0.isEmpty ? "—" : $0 },
                              width: 230)
                    .hint("The USB serial port your OCD board is plugged into.", $buttonHint)
                Button("Connect") { c.readVersion() }
                    .keyboardShortcut(.defaultAction)
                    .hint("Talk to the board — detects whether it's LED or GI OCD and loads the settings currently on it.", $buttonHint)
                Button("Scan") { c.refreshPorts() }
                    .hint("Rescan for USB serial ports.", $buttonHint)
                if c.isBusy { ProgressView().controlSize(.small) }
                Spacer(minLength: 12)
                if c.simulated {
                    Text("SIMULATED").font(.caption.bold()).foregroundStyle(.red)
                }
            }
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("Board").frame(width: 84, alignment: .leading)
                    ChevronPicker(selection: Binding(
                        get: { c.effectiveBoard }, set: { c.boardOverride = $0 }),
                        options: [.ledOCD, .giOCD], label: { $0.rawValue }, width: 230)
                        .hint("Which board's page to show — set automatically by Connect; switch by hand to work offline.", $buttonHint)
                }
                if showMatrix {
                    HStack(spacing: 6) {
                        Text("Matrix")
                        ChevronPicker(selection: Binding(
                            get: { c.effectiveManufacturer }, set: { c.manufacturerOverride = $0 }),
                            options: OCDDevice.Manufacturer.allCases, label: { $0.rawValue }, width: 130)
                            .hint("Force the lamp matrix — normally set by Connect or the selected game.", $buttonHint)
                    }
                }
                Spacer(minLength: 12)
                if let v = c.versionInfo {
                    Text("Detected: ")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(white: 0.80))
                    + Text("\(v.board.rawValue) v\(v.version)")
                        .font(.system(size: 15, weight: .thin))   // weight 200
                }
            }
        }
        .padding(16)
    }

    private var liveControl: LiveControl {
        LiveControl(
            active: c.liveMode,
            lampLevel: { c.liveLampLevel[$0] ?? 0 },
            setLampLevel: { c.liveSetLamp($0, level: $1) },
            profileActiveB: { c.liveProfileB[$0] },
            toggleProfile: { c.liveToggleProfile($0) },
            showProfileB: { c.liveShowProfileB($0, $1) },
            stringActive: { c.liveStringSel[$0] != nil },
            stringShownB: { c.liveStringSel[$0].map { (active: $0.active, b: $0.b) } },
            toggleString: { c.liveToggleString($0) },
            showStringB: { c.liveShowStringB($0, active: $1, $2) })
    }

    @ViewBuilder private var editor: some View {
        if c.effectiveBoard == .giOCD {
            GIView(config: c.gi,
                   actions: AnyView(actionsColumn(hintWidth: 280, hintHeight: 44)),
                   live: liveControl,
                   hintArea: $buttonHint)
        } else {
            LEDView(config: c.led, presets: c.gamesForMatrix,
                    selectedPreset: Binding(
                        get: { c.selectedPreset },
                        set: { c.selectPreset($0) }),
                    actions: AnyView(actionsColumn(hintWidth: 470, hintHeight: 30)),
                    live: liveControl,
                    matrix: MatrixControl(
                        registered: c.versionInfo?.manufacturer,
                        isEnabled: { c.enabledMatrices.contains($0) },
                        toggle: { c.toggleMatrix($0) },
                        toggleCapcomGroup: { c.toggleCapcomGroup() }),
                    editor: GameEditor(
                        active: c.editingGame,
                        canClone: c.selectedPreset != nil,
                        name: Binding(get: { c.draftName }, set: { c.draftName = $0 }),
                        manufacturer: Binding(get: { c.draftManufacturer }, set: { c.setDraftManufacturer($0) }),
                        lamps: Binding(get: { c.draftLamps }, set: { c.draftLamps = $0 }),
                        startNew: { c.startNewGame() },
                        clone: { c.cloneCurrentGame() },
                        save: { c.saveGame() },
                        cancel: { c.cancelGameEdit() },
                        rename: { c.renameCustomGame() },
                        delete: { c.deleteCustomGame() }),
                    hintArea: $buttonHint)
        }
    }

    private func actionsColumn(hintWidth: CGFloat, hintHeight: CGFloat) -> some View {
        let needsBoard = c.isBusy || c.selectedPort.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 20) {
                Button { c.readSettings() } label: { Text("Read").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).disabled(needsBoard)
                    .hint("Fetch the settings currently stored on the board.", $buttonHint)
                Button { c.importConfig() } label: { Text("Import").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .hint("Load a configuration you exported to a file earlier.", $buttonHint)
            }
            HStack(spacing: 20) {
                // Send: green while there are unsent changes (regular mode only).
                Group {
                    if !c.liveMode && c.hasUnsentChanges {
                        Button { c.applySettings() } label: { Text("Send").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).tint(.green)
                            .disabled(needsBoard)
                    } else {
                        Button { c.applySettings() } label: { Text("Send").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                            .disabled(needsBoard || c.liveMode)
                    }
                }
                .hint(c.liveMode
                      ? "Disabled in Live Mode — Commit Changes sends and saves in one step."
                      : c.hasUnsentChanges
                      ? "You have unsent changes — press to write them to the board."
                      : "Write your settings to the board so you can see them right away.", $buttonHint)
                Button { c.exportConfig() } label: { Text("Export").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .hint("Back your whole setup up to a file.", $buttonHint)
            }
            // Save (regular; red after a Send until stored) /
            // Commit Changes (Live Mode; red while uncommitted).
            Group {
                if c.liveMode ? c.hasUnsentChanges : c.hasUnsavedSends {
                    Button { c.saveAction() } label: {
                        Text(c.liveMode ? "Commit Changes" : "Save").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(needsBoard)
                } else {
                    Button { c.saveAction() } label: {
                        Text(c.liveMode ? "Commit Changes" : "Save").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(needsBoard)
                }
            }
            .hint(c.liveMode
                  ? (c.hasUnsentChanges
                     ? "You have uncommitted changes — press to send and store them on the board (Live Mode stays on)."
                     : "Everything is committed. Edit a value and this lights up red until you commit again.")
                  : c.hasUnsavedSends
                  ? "The board received settings that aren't stored yet — press to make them permanent."
                  : "Store the settings on the board permanently — they survive power-off.", $buttonHint)
            modeButton("Live Mode", active: c.liveMode) {
                c.toggleLiveMode()
            }
            .disabled(needsBoard)
            .hint("Tune profile brightness while watching the real lamps update live.", $buttonHint)
            modeButton("Manual Test", active: c.manualActive) {
                if c.manualActive { c.exitManual() } else { showManualTest = true }
            }
            .disabled(needsBoard)
            .hint("Light each lamp by hand to test wiring or find a lamp on the playfield.", $buttonHint)

            // Hover-hint area. Fixed size so the layout never shifts; the width is
            // per-page (LED overflows into empty space to the right; GI stays
            // narrow and wraps instead, so it can't get clipped at the window edge).
            Text(buttonHint ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: hintWidth, height: hintHeight, alignment: .topLeading)
                .padding(.top, 2)
        }
        .frame(width: 240, alignment: .leading)
    }

    @ViewBuilder
    private func modeButton(_ title: String, active: Bool, tint: Color = .green,
                            fullWidth: Bool = true, _ action: @escaping () -> Void) -> some View {
        Group {
            if active {
                Button(action: action) { Text(title).frame(maxWidth: fullWidth ? .infinity : nil) }
                    .buttonStyle(.borderedProminent).tint(tint)
            } else {
                Button(action: action) { Text(title).frame(maxWidth: fullWidth ? .infinity : nil) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var logPane: some View {
        GroupBox {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(c.log.isEmpty ? "Ready." : c.log)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(6)
                    // Invisible anchor pinned to the end; we scroll to it on new output.
                    Color.clear.frame(height: 1).id("logBottom")
                }
                .frame(height: 120)
                .onChange(of: c.log) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
}
