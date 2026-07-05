import SwiftUI

struct GIView: View {
    @ObservedObject var config: GIConfig
    let actions: AnyView
    let live: LiveControl
    let hintArea: Binding<String?>   // hover-hint text shown under the action buttons

    /// When off (default), B2–B7 are auto-calculated from B1/B8 and locked.
    private var advanced: Bool { config.advanced }

    // Shared column widths (mirrors the LED profiles table).
    private let wStr: CGFloat = 88
    private let wInput: CGFloat = 116
    private let wAct: CGFloat = 74
    private let wB: CGFloat = 36
    private let colGap: CGFloat = 6

    var body: some View {
        // Fill the window when there's room; scroll (both axes) when too small.
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                HStack(alignment: .top, spacing: 28) {
                    stringsTable
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 16) {
                        globalsColumn
                        actions
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(16)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
            }
        }
    }

    // MARK: - Globals (right column)

    private var globalsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Toggle("Advanced", isOn: $config.advanced)
                    .help("When off, B2–B7 are auto-calculated from B1 and B8.")
                    .hint("Unlock hand-editing of every brightness step (B2–B7). Off = set B1 and B8, the steps between are filled in for you.", hintArea)
                Spacer(minLength: 8)
                Toggle("50 Hz", isOn: $config.fiftyHz)
                    .hint("Turn on for machines running on 50 Hz mains power (avoids flicker).", hintArea)
                Text("Out freq").font(.caption).foregroundStyle(.secondary)
                ChevronPicker(selection: $config.outputFreq, options: Array(1...3),
                              label: { "\($0)" }, width: 46)
                    .help("GI LED PWM output frequency (1 = low … 3 = high).")
                    .hint("LED output frequency (1 = low … 3 = high) — higher means less visible flicker.", hintArea)
            }
            Divider()
            field("Fade delay min", numberFirst: true) { NumBox(value: $config.fadeMin, range: 0...49, width: 50) }
            field("Fade delay max", numberFirst: true) { NumBox(value: $config.fadeMax, range: 0...49, width: 50) }
            field("Activity duration", numberFirst: true) { NumBox(value: $config.activityDuration, range: 0...250, width: 54) }
        }
        .frame(width: 280, alignment: .leading)
    }

    private func field<V: View>(_ title: String, numberFirst: Bool = false,
                                @ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: 8) {
            if numberFirst {
                content()
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                content()
            }
        }
    }

    // MARK: - Strings table

    private var stringsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Min / Brightness / Max caption.
            HStack(spacing: colGap) {
                Color.clear.frame(width: wStr + wInput + wAct + 2 * colGap, height: 0)
                Text("Min").font(.caption2).foregroundStyle(.secondary).frame(width: wB)
                Text("Brightness").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 6 * wB + 5 * colGap)
                Text("Max").font(.caption2).foregroundStyle(.secondary).frame(width: wB)
            }
            // Column headers.
            HStack(spacing: colGap) {
                Text("String").font(.caption).foregroundStyle(.secondary)
                    .frame(width: wStr, alignment: .leading)
                Text("Controlled by").font(.caption).foregroundStyle(.secondary)
                    .frame(width: wInput, alignment: .leading)
                Text("Activity").font(.caption).foregroundStyle(.secondary)
                    .frame(width: wAct, alignment: .leading)
                ForEach(1...8, id: \.self) { b in
                    Text("B\(b)").font(.caption).foregroundStyle(.secondary).frame(width: wB)
                }
            }

            ForEach(config.strings.indices, id: \.self) { s in
                // Preview lamp lives to the RIGHT of both rows so it can't nudge
                // the brightness-box columns out of alignment.
                HStack(alignment: .center, spacing: colGap) {
                    VStack(spacing: 3) {
                        // Normal brightness row — carries the string label and input.
                        HStack(spacing: colGap) {
                            Text(config.strings[s].id <= 5 ? "String \(config.strings[s].id)" : "Mod Control")
                                .font(.callout).bold()
                                .frame(width: wStr, alignment: .leading)
                            ChevronPicker(selection: $config.strings[s].input, options: Array(1...6)) {
                                $0 == 6 ? "Always On" : "Input \($0)"
                            }
                            .frame(width: wInput, alignment: .leading)
                            .hint("Which game input drives this string ('Always On' ignores the game).", hintArea)
                            Color.clear.frame(width: wAct, height: 0)
                            brightnessBoxes(s, active: false)
                        }
                        // Active brightness row — carries the activity checkbox.
                        HStack(spacing: colGap) {
                            Color.clear.frame(width: wStr + wInput + colGap, height: 0)
                            Toggle("", isOn: $config.strings[s].active)
                                .labelsHidden()
                                .frame(width: wAct, alignment: .leading)
                                .hint("React to activity: rise to the Active brightness when the input fires, then fade back to Normal.", hintArea)
                            brightnessBoxes(s, active: true)
                        }
                    }
                    PreviewButton(isActive: live.giActive(config.strings[s].id),
                                  enabled: live.active) {
                        live.toggleGI(config.strings[s].id)
                    }
                    .hint(live.active
                          ? "Preview this string's fade on the board (plays 3×)."
                          : "Turn on Live Mode to preview this string's fade.", hintArea)
                }
                Divider()
            }
        }
    }

    private func brightnessBoxes(_ s: Int, active: Bool) -> some View {
        ForEach(0..<8, id: \.self) { i in
            let editable = advanced || i == 0 || i == 7
            NumBox(value: brightnessBinding(s, active, i), range: 0...100, width: wB, locked: !editable)
                .disabled(!editable)
                .opacity(editable ? 1 : 0.8)
        }
    }

    // MARK: - Brightness interpolation (same rule as LED profiles)

    private func recompute(_ s: Int, active: Bool) {
        let b1 = active ? config.strings[s].activeBright[0] : config.strings[s].normal[0]
        let b8 = active ? config.strings[s].activeBright[7] : config.strings[s].normal[7]
        for n in 2...7 {
            let v = b1 + (b8 - b1) * (n - 1) / 7
            if active { config.strings[s].activeBright[n - 1] = v }
            else { config.strings[s].normal[n - 1] = v }
        }
    }

    private func brightnessBinding(_ s: Int, _ active: Bool, _ i: Int) -> Binding<Int> {
        Binding(
            get: { active ? config.strings[s].activeBright[i] : config.strings[s].normal[i] },
            set: { newValue in
                let v = min(max(newValue, 0), 100)
                if active { config.strings[s].activeBright[i] = v }
                else { config.strings[s].normal[i] = v }
                if !advanced && (i == 0 || i == 7) { recompute(s, active: active) }
            }
        )
    }
}
