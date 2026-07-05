import SwiftUI

/// Owns a serial connection for the duration of an interactive Manual Test
/// session. All port access is funneled through a private serial queue so live
/// per-lamp edits (which fire as the user drags a stepper) can't race. Kept off
/// the main actor deliberately so it can hold the `SerialPort` safely.
final class ManualSession {
    private let path: String
    private let manufacturer: OCDDevice.Manufacturer
    private let queue = DispatchQueue(label: "com.rodclemen.ledocd.manual")
    private var port: SerialPort?
    var onError: ((String) -> Void)?   // invoked on the main queue

    init(path: String, manufacturer: OCDDevice.Manufacturer) {
        self.path = path
        self.manufacturer = manufacturer
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?("✗ Manual test: \(error)") }
    }

    /// Open the port and put the board in manual mode.
    func enter(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let p = SerialPort(path: self.path)
                try p.open()
                try OCDDevice(port: p).setManualMode()
                self.port = p
                DispatchQueue.main.async { completion(true) }
            } catch {
                self.report(error)
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// Light a single LED-OCD lamp at hardware level 0…8 (0 = off, 8 = max).
    func setLED(lamp: Int, level: Int) {
        let cr = OCDDevice.colRow(forLamp: lamp, manufacturer: manufacturer)
        let relay = manufacturer.needsRelayPrefix
        queue.async { [weak self] in
            guard let self, let p = self.port else { return }
            do { try OCDDevice(port: p).setLampBrightness(col: cr.col, row: cr.row, bright: level, relay: relay) }
            catch { self.report(error) }
        }
    }

    /// Light a GI-OCD string at test level 0…8.
    func setGI(string: Int, level: Int) {
        queue.async { [weak self] in
            guard let self, let p = self.port else { return }
            do { try OCDDevice(port: p).setTestBrightness(string: string, bright: level) }
            catch { self.report(error) }
        }
    }

    /// Draw a checkerboard using the already-open session port (avoids opening a
    /// second connection to the same device while a session is active).
    func checkerboard(isGI: Bool) {
        queue.async { [weak self] in
            guard let self, let p = self.port else { return }
            do {
                if isGI { try OCDDevice(port: p).drawGICheckerboard() }
                else { try OCDDevice(port: p).drawCheckerboard(manufacturer: self.manufacturer) }
            } catch { self.report(error) }
        }
    }

    /// Leave the session: optionally return the board to normal play, then close.
    /// Captures self STRONGLY: the Controller drops its reference right after
    /// calling this, and a weak capture would let the session deallocate before
    /// the block runs — silently skipping the return-to-normal command (the
    /// board then stays in manual mode with all lamps off).
    func exit(returnToNormal: Bool, completion: @escaping () -> Void) {
        queue.async {
            if let p = self.port {
                if returnToNormal { try? OCDDevice(port: p).setNormalMode() }
                p.close()
            }
            self.port = nil
            DispatchQueue.main.async { completion() }
        }
    }
}

struct ManualTestView: View {
    @ObservedObject var c: Controller
    @Environment(\.dismiss) private var dismiss

    private var isGI: Bool { c.effectiveBoard == .giOCD }
    private var lamps: [MachinePreset.Lamp] { c.selectedPreset?.lamps ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Manual Test — \(c.effectiveBoard.rawValue)").font(.title3).bold()
                if !c.manualActive { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("Set each \(isGI ? "string" : "lamp") to a hardware level (0 = off … 8 = max). "
                 + "Changes light the board live. 'Reset (All Off)' clears everything.")
                .font(.callout).foregroundStyle(.secondary)

            ScrollView {
                if isGI {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(1...6, id: \.self) { s in
                            HStack {
                                Text(s <= 5 ? "String \(s)" : "Mod Control")
                                    .frame(width: 96, alignment: .leading)
                                stepperRow(get: { c.manualLevels[s] ?? 0 },
                                           set: { c.manualSetGI(string: s, level: $0) })
                            }
                        }
                    }.padding(6)
                } else if lamps.isEmpty {
                    Text("Choose a machine first to load its lamp list.")
                        .foregroundStyle(.secondary).padding(6)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        // Profiles — set every lamp assigned to a profile at once.
                        Text("Profiles").font(.headline)
                        columnMajorGrid(count: c.led.profiles.count, cols: 3) { i in
                            profileCell(c.led.profiles[i])
                        }
                        Divider()
                        // Individual lamps, filled DOWN each column, not across.
                        Text("Lamps").font(.headline)
                        columnMajorGrid(count: lamps.count, cols: 3) { i in
                            lampCell(lamps[i])
                        }
                    }.padding(6)
                }
            }
            .frame(minHeight: 260)

            Divider()
            HStack(spacing: 10) {
                Button("Reset (All Off)") { c.manualAllOff() }
                Button("Checkerboard") { c.manualCheckerboard() }
                Spacer()
                Button("Keep Lit & Close") {
                    c.endManualTest(returnToNormal: false); dismiss()
                }
                Button("Return to Normal") {
                    c.endManualTest(returnToNormal: true); dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { c.startManualTest() }
        .onDisappear {
            // Closing the window by ANY means (Escape, toolbar toggle, dismiss)
            // returns the board to its normal/demo mode. "Keep Lit & Close" already
            // ended the session (manualActive == false), so it's preserved.
            if c.manualActive { c.endManualTest(returnToNormal: true) }
        }
    }

    /// A 0…8 stepper wired to arbitrary get/set closures.
    private func stepperRow(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Text("\(get())")
                .font(.system(.body, design: .monospaced))
                .frame(width: 18)
            Stepper("", value: Binding(get: get, set: { set(min(max($0, 0), 8)) }), in: 0...8)
                .labelsHidden()
        }
        .disabled(!c.manualActive)
    }

    private func lampCell(_ lamp: MachinePreset.Lamp) -> some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", lamp.number))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
            Text(lamp.label).lineLimit(1).frame(width: 110, alignment: .leading)
            stepperRow(get: { c.manualLevels[lamp.number] ?? 0 },
                       set: { c.manualSetLED(lamp: lamp.number, level: $0) })
        }
    }

    private func profileCell(_ prof: LEDProfile) -> some View {
        HStack(spacing: 6) {
            Text("\(prof.id)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
            Text(prof.name).lineLimit(1).frame(width: 110, alignment: .leading)
            stepperRow(get: { c.manualProfileLevel[prof.id] ?? 0 },
                       set: { c.manualSetProfile(profile: prof.id, level: $0) })
        }
    }

    /// A grid whose items fill DOWN each column (column-major), with blank cells
    /// padding the last column so nothing shifts.
    @ViewBuilder
    private func columnMajorGrid<Cell: View>(count: Int, cols: Int,
                                             @ViewBuilder cell: @escaping (Int) -> Cell) -> some View {
        let rows = max(1, (count + cols - 1) / cols)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: cols),
                  alignment: .leading, spacing: 6) {
            ForEach(0..<(rows * cols), id: \.self) { pos in
                let idx = (pos % cols) * rows + (pos / cols)
                if idx < count {
                    cell(idx)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
        }
    }
}
