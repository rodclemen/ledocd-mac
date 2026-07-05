import SwiftUI
import AppKit

struct LEDView: View {
    @ObservedObject var config: LEDConfig
    let presets: [MachinePreset]
    @Binding var selectedPreset: MachinePreset?
    let actions: AnyView
    let live: LiveControl
    let matrix: MatrixControl
    let editor: GameEditor
    let hintArea: Binding<String?>   // hover-hint text shown under the action buttons

    /// When off (default), B2–B7 are auto-calculated from B1/B8 and locked.
    private var advanced: Bool { config.advanced }

    /// Rows shown in the lamp table — the draft's lamps while adding a game,
    /// otherwise the selected game's lamps.
    private var lamps: [MachinePreset.Lamp] {
        editor.active ? editor.lamps.wrappedValue : (selectedPreset?.lamps ?? [])
    }

    /// Two-way binding to a draft lamp's insert name (looked up by lamp number).
    private func draftLabel(_ number: Int) -> Binding<String> {
        Binding(
            get: { editor.lamps.wrappedValue.first { $0.number == number }?.label ?? "" },
            set: { v in
                if let i = editor.lamps.wrappedValue.firstIndex(where: { $0.number == number }) {
                    editor.lamps[i].label.wrappedValue = v
                }
            })
    }

    // MARK: - Column sorting

    enum SortColumn { case lamp, insert, select }
    @State private var sortColumn: SortColumn = .lamp
    @State private var sortAscending = true

    /// Which editable brightness cell has focus (profileIndex*8 + bIndex), so that
    /// clicking into a B field selects/shows it during Live Mode.
    @FocusState private var focusedBrightness: Int?

    /// The lamp list reordered by the active column header.
    private var sortedLamps: [MachinePreset.Lamp] {
        switch sortColumn {
        case .lamp:
            return lamps.sorted { sortAscending ? $0.number < $1.number : $0.number > $1.number }
        case .insert:
            return lamps.sorted {
                let r = $0.label.localizedCaseInsensitiveCompare($1.label)
                if r != .orderedSame { return sortAscending ? r == .orderedAscending : r == .orderedDescending }
                return $0.number < $1.number
            }
        case .select:
            return lamps.sorted {
                let p0 = config.lampProfile[$0.number] ?? 7
                let p1 = config.lampProfile[$1.number] ?? 7
                if p0 != p1 { return sortAscending ? p0 < p1 : p0 > p1 }
                return $0.number < $1.number   // lamp number within each profile group
            }
        }
    }

    private func toggleSort(_ col: SortColumn) {
        if sortColumn == col { sortAscending.toggle() }
        else { sortColumn = col; sortAscending = true }
    }

    @ViewBuilder
    private func sortableHeader(_ title: String, _ col: SortColumn) -> some View {
        HStack(spacing: 2) {
            Text(title)
            Image(systemName: sortColumn == col
                  ? (sortAscending ? "arrow.up" : "arrow.down")
                  : "arrow.up.arrow.down")
                .font(.system(size: 8))
                .opacity(sortColumn == col ? 1 : 0.3)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleSort(col) }
        .hint("Sort the lamp list by \(title.lowercased()) — click again to reverse.", hintArea)
    }

    // MARK: - Brightness interpolation

    /// Truncated linear ramp between B1 and B8, matching the original tool:
    /// `Bn = B1 + (B8 - B1) * (n-1) / 7` (integer division), for n = 2…7.
    private func recomputeMidLevels(_ p: Int) {
        let b1 = config.profiles[p].brightness[0]
        let b8 = config.profiles[p].brightness[7]
        for n in 2...7 {
            config.profiles[p].brightness[n - 1] = b1 + (b8 - b1) * (n - 1) / 7
        }
    }

    /// Binding for a brightness cell. Editing an endpoint (B1/B8) while not in
    /// Advanced mode re-derives the middle values.
    private func brightnessBinding(_ p: Int, _ i: Int) -> Binding<Int> {
        Binding(
            get: { config.profiles[p].brightness[i] },
            set: { newValue in
                config.profiles[p].brightness[i] = min(max(newValue, 0), 100)
                if !advanced && (i == 0 || i == 7) { recomputeMidLevels(p) }
            }
        )
    }

    // Shared column widths.
    private let wLamp: CGFloat = 44
    private let wInsert: CGFloat = 180
    private let wProfile: CGFloat = 84
    private let wSelect: CGFloat = 56
    // Trailing column: shows a 0…8 brightness chevron per lamp while Live Mode is on.
    private let wLive: CGFloat = 50
    // Fixed overall width for the lamp table. The Live column is always reserved
    // (wLive) so the table is a bit wider and the chevron can appear on Live Mode
    // without shifting Lamp/Insert/Profile/Select.
    private var tableWidth: CGFloat { wLamp + wProfile + wSelect + wLive + wInsert + 16 }

    private let wIdx: CGFloat = 16
    private let wName: CGFloat = 104
    private let wB: CGFloat = 36
    private let wDelay: CGFloat = 40
    private let colGap: CGFloat = 6

    /// The right edge of the profiles table's Delay column (from the left edge).
    private var delayColumnRight: CGFloat {
        wIdx + colGap + wName + colGap + 8 * (wB + colGap) + wDelay
    }

    var body: some View {
        // Fill the window when there's room; scroll (both axes) when the window
        // is too small to show everything. The lamp list keeps its own vertical
        // scroll; the right column gets one so its buttons are always reachable.
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 24) {
                    lampTable
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 16) {
                            matrixPills
                            // Fixed height so the row doesn't grow when the edit bar
                            // (text field + buttons) replaces the picker.
                            gameSelect.frame(height: 26)
                            profilesTable
                            HStack(alignment: .top, spacing: 0) {
                                actions   // 240-wide button column
                                // Advanced on the Read/Import row; right-align it so the
                                // last "d" in the label lands on the Delay column's right edge.
                                Toggle("Advanced", isOn: $config.advanced)
                                    .help("When off, B2–B7 are auto-calculated from B1 and B8.")
                                    .hint("Unlock hand-editing of every brightness step (B2–B7). Off = set B1 and B8, the steps between are filled in for you.", hintArea)
                                    .fixedSize()
                                    .frame(width: delayColumnRight - 240, alignment: .trailing)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.bottom, 4)
                    }
                }
                .padding(16)
                .frame(height: geo.size.height, alignment: .top)
            }
        }
    }

    /// Use the newer SF Symbols 6 name on macOS 15+, else the classic equivalent.
    private func sfSymbol(_ modern: String, fallback: String) -> String {
        if #available(macOS 15.0, *) { return modern } else { return fallback }
    }

    // MARK: - Matrix filter pills

    private enum MFamily { case wpc, stern, capcom, other }
    private func family(_ m: OCDDevice.Manufacturer?) -> MFamily {
        switch m {
        case .wpc: return .wpc
        case .stern: return .stern
        case .capcomA, .capcomB: return .capcom
        default: return .other
        }
    }

    /// True for the pill of the selected game's manufacturer when its family
    /// differs from the board's registered matrix (→ tint that pill red).
    private func pillWrong(for f: MFamily) -> Bool {
        let reg = family(matrix.registered), sel = family(selectedPreset?.manufacturer)
        guard matrix.registered != nil, selectedPreset != nil,
              reg != .other, sel != .other, reg != sel else { return false }
        return f == sel
    }

    private var matrixPills: some View {
        HStack(spacing: 6) {
            MatrixPill(title: "WPC", registered: matrix.registered == .wpc,
                       enabled: matrix.isEnabled(.wpc),
                       wrong: pillWrong(for: .wpc)) { matrix.toggle(.wpc) }
                .hint("Show WPC games (Williams / Bally / Data East) in the game list.", hintArea)
            MatrixPill(title: "Stern", registered: matrix.registered == .stern,
                       enabled: matrix.isEnabled(.stern),
                       wrong: pillWrong(for: .stern)) { matrix.toggle(.stern) }
                .hint("Show Stern games in the game list.", hintArea)
            Divider().frame(height: 14)
            MatrixPill(title: "Capcom",
                       registered: matrix.registered == .capcomA || matrix.registered == .capcomB,
                       enabled: matrix.isEnabled(.capcomA) || matrix.isEnabled(.capcomB),
                       wrong: pillWrong(for: .capcom)) { matrix.toggleCapcomGroup() }
                .hint("Show Capcom games in the game list.", hintArea)
            MatrixPill(title: "A", registered: matrix.registered == .capcomA,
                       enabled: matrix.isEnabled(.capcomA), compact: true,
                       wrong: pillWrong(for: .capcom)) { matrix.toggle(.capcomA) }
                .hint("Show Capcom matrix-A games.", hintArea)
            MatrixPill(title: "B", registered: matrix.registered == .capcomB,
                       enabled: matrix.isEnabled(.capcomB), compact: true,
                       wrong: pillWrong(for: .capcom)) { matrix.toggle(.capcomB) }
                .hint("Show Capcom matrix-B games (needs the relay board).", hintArea)
            Spacer(minLength: 0)
        }
        .padding(.leading, wIdx + colGap)   // align with Game Select
    }

    // MARK: - Game select

    @ViewBuilder private var gameSelect: some View {
        if editor.active {
            HStack(spacing: 8) {
                Text("New Game").font(.subheadline)
                TextField("Game name", text: editor.name)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                ChevronPicker(selection: editor.manufacturer,
                              options: [.wpc, .stern, .capcomA, .capcomB],
                              label: { $0.rawValue }, width: 120)
                    .hint("The lamp matrix this game uses — decides the lamp numbering.", hintArea)
                Button("Save") { editor.save() }.buttonStyle(.borderedProminent)
                    .hint("Save this game to your custom games.", hintArea)
                Button("Cancel") { editor.cancel() }
                    .hint("Discard this game without saving.", hintArea)
                Spacer(minLength: 0)
            }
            .padding(.leading, wIdx + colGap)
        } else {
            HStack(spacing: 8) {
                Text("Game Select").font(.subheadline)
                ChevronPicker(selection: $selectedPreset,
                              options: [Optional<MachinePreset>.none] + presets.map { Optional($0) },
                              label: { $0?.name ?? "- Select game -" },
                              width: 260,
                              // Group into Custom/Default sections (only when any custom exists).
                              section: presets.contains(where: \.isCustom)
                                  ? { $0.map { $0.isCustom ? "Custom Games" : "Default Games" } }
                                  : nil)
                    .hint("Pick your machine — loads its insert names into the lamp list.", hintArea)
                Button { editor.startNew() } label: {
                    Image(systemName: sfSymbol("document.badge.plus", fallback: "doc.badge.plus"))
                }
                .buttonStyle(.borderless).help("New game")
                .hint("Create a new custom game from a blank lamp list.", hintArea)
                if editor.canClone {
                    Button { editor.clone() } label: {
                        Image(systemName: sfSymbol("document.on.document", fallback: "doc.on.doc"))
                    }
                    .buttonStyle(.borderless).help("Clone the selected game")
                    .hint("Copy the selected game as the starting point for a custom game.", hintArea)
                }
                if selectedPreset?.isCustom == true {
                    Button { editor.rename() } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("Rename this custom game")
                        .hint("Rename this custom game.", hintArea)
                    Button { editor.delete() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete this custom game")
                        .hint("Delete this custom game — default games are never affected.", hintArea)
                }
                Spacer(minLength: 0)
            }
            // Line up "Game Select" with the "Profile Name" column below it.
            .padding(.leading, wIdx + colGap)
        }
    }

    // MARK: - Lamp table (left)

    private var lampTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sortableHeader("Lamp", .lamp).frame(width: wLamp, alignment: .leading)
                sortableHeader("Insert", .insert).frame(maxWidth: .infinity, alignment: .leading)
                Text("Profile").frame(width: wProfile, alignment: .leading)
                sortableHeader("Select", .select).frame(width: wSelect, alignment: .leading)
                if live.active {
                    Text("Live").frame(width: wLive, alignment: .leading)
                } else {
                    Color.clear.frame(width: wLive, height: 0)
                }
            }
            .font(.caption.bold()).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()

            if lamps.isEmpty {
                Text(editor.active ? "This matrix has no lamps." : "Choose a game to load its lamp list.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(sortedLamps.enumerated()), id: \.element.number) { idx, lamp in
                            lampRow(lamp, striped: idx.isMultiple(of: 2))
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: tableWidth)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    private func lampRow(_ lamp: MachinePreset.Lamp, striped: Bool) -> some View {
        HStack(spacing: 0) {
            Text(String(lamp.number))
                .font(.system(.callout, design: .monospaced))
                .frame(width: wLamp, alignment: .leading)
            // Insert column: editable while adding a game, otherwise plain text.
            if editor.active {
                TextField("insert name", text: draftLabel(lamp.number))
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                    .padding(.trailing, 4)
            } else {
                Text(lamp.label)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(profileName(forLamp: lamp.number))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: wProfile, alignment: .leading)
            ChevronPicker(selection: Binding(
                get: { config.lampProfile[lamp.number] ?? 7 },
                set: { config.lampProfile[lamp.number] = $0 }
            ), options: Array(1...8), label: { "\($0)" }, width: wSelect - 8)
                .frame(width: wSelect, alignment: .leading)
                .hint("Choose which brightness profile this lamp uses.", hintArea)
            // Live column: the wLive space is ALWAYS reserved (empty spacer when
            // inactive) so Insert can't expand into it and shove the other columns.
            if live.active {
                ChevronPicker(selection: Binding(
                    get: { live.lampLevel(lamp.number) },
                    set: { live.setLampLevel(lamp.number, $0) }
                ), options: Array(0...8), label: { "\($0)" }, width: wLive - 10)
                    .frame(width: wLive, alignment: .leading)
                    .hint("Light this lamp right now (0 = off … 8 = max).", hintArea)
            } else {
                Color.clear.frame(width: wLive, height: 0)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(striped ? Color.gray.opacity(0.06) : Color.clear)
    }

    private func profileName(forLamp n: Int) -> String {
        let p = config.lampProfile[n] ?? 7
        return (p >= 1 && p <= 8) ? config.profiles[p - 1].name : "—"
    }

    /// Does any lamp in the current game use this profile? (💡 is only clickable if so.)
    private func profileHasLamps(_ pid: Int) -> Bool {
        lamps.contains { (config.lampProfile[$0.number] ?? 7) == pid }
    }

    // MARK: - Profiles table (right)

    private var profilesTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Min / Brightness / Max caption row.
            HStack(spacing: colGap) {
                Color.clear.frame(width: wIdx, height: 0)
                Color.clear.frame(width: wName, height: 0)
                Text("Min").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: wB)
                Text("Brightness").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 6 * wB + 5 * colGap)
                Text("Max").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: wB)
                Color.clear.frame(width: wDelay, height: 0)
            }
            // B1…B8 + Delay header row.
            HStack(spacing: colGap) {
                Color.clear.frame(width: wIdx, height: 0)
                Text("Profile Name").font(.caption).foregroundStyle(.secondary)
                    .frame(width: wName, alignment: .leading)
                ForEach(1...8, id: \.self) { b in
                    Text("B\(b)").font(.caption).foregroundStyle(.secondary).frame(width: wB)
                }
                Text("Delay").font(.caption).foregroundStyle(.secondary).frame(width: wDelay)
            }

            ForEach(config.profiles.indices, id: \.self) { p in
                let pid = config.profiles[p].id
                // Live Mode + this profile's 💡 on: editing a B value drives its lamps
                // in real time (and highlights the one currently shown).
                let liveOn: Bool = live.active && live.profileActiveB(pid) != nil
                HStack(spacing: colGap) {
                    Text("\(pid)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: wIdx, alignment: .trailing)
                    TextField("name", text: $config.profiles[p].name)
                        .frame(width: wName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(liveOn)
                    ForEach(0..<8, id: \.self) { i in
                        bCell(p, i, liveOn: liveOn)
                    }
                    NumBox(value: $config.profiles[p].delay, range: 0...9, width: wDelay)
                        .disabled(liveOn)
                    PreviewButton(isActive: liveOn, enabled: live.active && profileHasLamps(pid)) {
                        live.toggleProfile(pid)
                    }
                    .hint(live.active
                          ? "Light every lamp that uses this profile — then edit or click the B values to preview brightness."
                          : "Turn on Live Mode to light this profile's lamps.", hintArea)
                }
            }
        }
        // Clicking into an editable B field shows that B on the lamps. Deferred so
        // the highlight updates on this render pass, not one behind.
        .onChange(of: focusedBrightness) { key in
            guard let key else { return }
            DispatchQueue.main.async { live.showProfileB(config.profiles[key / 8].id, key % 8) }
        }
    }

    /// A single B-brightness cell. In Live Mode (profile 💡 on) editable cells update
    /// the lamps as you type; locked mid cells (Advanced off) are click-to-preview.
    @ViewBuilder
    private func bCell(_ p: Int, _ i: Int, liveOn: Bool) -> some View {
        let pid = config.profiles[p].id
        let editable = advanced || i == 0 || i == 7
        // Highlight the B the lamps are showing. Also read the focus state directly:
        // focus updates re-render immediately, so a clicked cell yellows on the same
        // click instead of one render behind (the deferred onChange then syncs lamps).
        let shown = liveOn && (live.profileActiveB(pid) == i || focusedBrightness == p * 8 + i)
        if liveOn && editable {
            // Plain style (not roundedBorder) so the yellow highlight shows through;
            // editing or clicking drives the lamps live.
            TextField("", value: Binding(
                get: { config.profiles[p].brightness[i] },
                set: { v in
                    config.profiles[p].brightness[i] = min(max(v, 0), 100)
                    if !advanced && (i == 0 || i == 7) { recomputeMidLevels(p) }
                    live.showProfileB(pid, i)
                }), format: .number)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .frame(width: wB).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(shown ? Color.yellow.opacity(0.35) : Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(shown ? Color.yellow : Color.primary.opacity(0.22), lineWidth: 1))
                .focused($focusedBrightness, equals: p * 8 + i)
        } else if liveOn {
            // Locked middle value (Advanced off): tap to preview it on the lamps.
            // Drop any editable-cell focus so its yellow doesn't linger alongside.
            Button { focusedBrightness = nil; live.showProfileB(pid, i) } label: {
                Text("\(config.profiles[p].brightness[i])")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: wB).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(shown ? Color.yellow.opacity(0.35) : Color.clear))
            }
            .buttonStyle(.plain)
        } else {
            NumBox(value: brightnessBinding(p, i), range: 0...100, width: wB, locked: !editable)
                .disabled(!editable)
                .opacity(editable ? 1 : 0.8)
        }
    }
}
