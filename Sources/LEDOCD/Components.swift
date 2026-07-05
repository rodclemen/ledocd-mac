import SwiftUI
import AppKit

/// A compact clamped integer entry field with an attached stepper.
struct IntField: View {
    let title: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var width: CGFloat = 52

    init(_ title: String? = nil, value: Binding<Int>, range: ClosedRange<Int>, width: CGFloat = 52) {
        self.title = title
        self._value = value
        self.range = range
        self.width = width
    }

    var body: some View {
        HStack(spacing: 4) {
            if let title { Text(title).font(.caption).foregroundStyle(.secondary) }
            ChevronPicker(selection: $value, options: Array(range), label: { "\($0)" }, width: width)
        }
    }
}

/// A dropdown rendered with a single downward chevron rather than the default
/// pop-up `Picker`'s double up/down arrows. The system menu indicator is hidden
/// and we draw our own chevron, inside a control-styled bordered box. Pass
/// `width` for a fixed size (e.g. long machine names); otherwise it sizes to
/// its content.
/// Drives the inline "add / edit a game" UI on the LED page.
struct GameEditor {
    var active: Bool
    var canClone: Bool
    var name: Binding<String>
    var manufacturer: Binding<OCDDevice.Manufacturer>
    var lamps: Binding<[MachinePreset.Lamp]>
    var startNew: () -> Void
    var clone: () -> Void
    var save: () -> Void
    var cancel: () -> Void
    var rename: () -> Void   // custom games only
    var delete: () -> Void   // custom games only
}

extension View {
    /// Feed a hover-hint area: shows `text` while the pointer is over this view.
    /// Clears only if the area still shows this text, so moving directly onto
    /// another hinted control never blanks its fresh hint.
    func hint(_ text: String, _ target: Binding<String?>) -> some View {
        onHover { inside in
            if inside { target.wrappedValue = text }
            else if target.wrappedValue == text { target.wrappedValue = nil }
        }
    }
}

/// Drives the manufacturer filter pills above Game Select.
struct MatrixControl {
    var registered: OCDDevice.Manufacturer?              // the board-detected matrix → green
    var isEnabled: (OCDDevice.Manufacturer) -> Bool      // is this manufacturer's games shown?
    var toggle: (OCDDevice.Manufacturer) -> Void
    var toggleCapcomGroup: () -> Void
}

/// A small toggle "pill". Green when it's the board's registered matrix, grey
/// otherwise; filled when enabled (its games show), outlined when off.
struct MatrixPill: View {
    let title: String
    let registered: Bool
    let enabled: Bool
    var compact: Bool = false
    var wrong: Bool = false             // the selected game's (non-registered) manufacturer
    let action: () -> Void

    var body: some View {
        let amber = Color(red: 0.78, green: 0.60, blue: 0.16)
        let shape = RoundedRectangle(cornerRadius: 4)
        // Off = solid grey. On = accent (registered — matches Connect/Send), red (the
        // "wrong" selected one), or amber (any other enabled manufacturer).
        let fill: Color = !enabled ? Color(white: 0.40)
                        : registered ? .accentColor
                        : wrong ? .red
                        : amber
        let fg: Color = (enabled && !registered && !wrong) ? .black : .white
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, compact ? 6 : 9).padding(.vertical, 3)
                .foregroundStyle(fg)
                .background(shape.fill(fill))
        }
        .buttonStyle(.plain)
    }
}

/// A little lamp button that plays a brightness-fade preview on the board.
/// Lit (yellow, filled) while its preview is the one running.
struct PreviewButton: View {
    let isActive: Bool
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isActive ? "lightbulb.fill" : "lightbulb")
                .foregroundStyle(isActive ? Color.yellow
                                 : enabled ? Color.secondary
                                 : Color.secondary.opacity(0.3))   // clearly disabled
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(isActive ? "Turn this profile's lamps off" : "Light this profile's lamps")
    }
}

/// Native macOS dropdown (NSPopUpButton) wrapped for SwiftUI. Unlike SwiftUI's
/// `Menu`, an NSPopUpButton honors an explicit width — so two pickers given the
/// same `width` render at exactly the same size.
struct ChevronPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var minWidth: CGFloat = 44
    var width: CGFloat? = nil
    /// Optional section title per option. When consecutive options' titles differ,
    /// a disabled header row is inserted above the new section (nil = no header).
    var section: ((Value) -> String?)? = nil

    var body: some View {
        PopUpButton(
            entries: entries,
            selectedOption: Binding(
                get: { options.firstIndex(of: selection) ?? 0 },
                set: { idx in if options.indices.contains(idx) { selection = options[idx] } }))
            .frame(width: width)
            .frame(minWidth: width == nil ? minWidth : nil)
            .frame(height: 22)
    }

    private var entries: [PopUpEntry] {
        var out: [PopUpEntry] = []
        var lastGroup: String? = nil
        for (i, v) in options.enumerated() {
            if let g = section?(v) {
                if g != lastGroup { out.append(.header(g)) }
                lastGroup = g
            }
            out.append(.option(label(v), i))
        }
        return out
    }
}

enum PopUpEntry: Equatable {
    case header(String)          // disabled section title row
    case option(String, Int)     // title + index into the options array
}

private struct PopUpButton: NSViewRepresentable {
    let entries: [PopUpEntry]
    @Binding var selectedOption: Int

    func makeNSView(context: Context) -> NSPopUpButton {
        let b = NSPopUpButton(frame: .zero, pullsDown: false)
        b.target = context.coordinator
        b.action = #selector(Coordinator.changed(_:))
        b.autoenablesItems = false                                   // keep headers disabled
        b.setContentHuggingPriority(.defaultLow, for: .horizontal)   // let SwiftUI set width
        return b
    }

    func updateNSView(_ b: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.entries != entries {
            context.coordinator.entries = entries
            let menu = NSMenu()
            for e in entries {
                switch e {
                case .header(let title):
                    let it = NSMenuItem()
                    it.attributedTitle = NSAttributedString(string: title, attributes: [
                        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                        .foregroundColor: NSColor.secondaryLabelColor])
                    it.isEnabled = false
                    it.tag = -1
                    menu.addItem(it)
                case .option(let title, let idx):
                    let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    it.isEnabled = true
                    it.tag = idx
                    menu.addItem(it)
                }
            }
            b.menu = menu
        }
        if let item = b.menu?.items.first(where: { $0.tag == selectedOption && $0.isEnabled }) {
            b.select(item)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUpButton
        var entries: [PopUpEntry] = []
        init(_ p: PopUpButton) { parent = p }
        @objc func changed(_ sender: NSPopUpButton) {
            if let tag = sender.selectedItem?.tag, tag >= 0 { parent.selectedOption = tag }
        }
    }
}

/// A plain clamped numeric entry box — no stepper, no chevron. Matches the
/// typed number fields in the reference layout.
struct NumBox: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var width: CGFloat = 38
    var locked: Bool = false

    private var field: some View {
        TextField("", value: Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) }
        ), format: .number)
            .multilineTextAlignment(.center)
    }

    var body: some View {
        if locked {
            // Single custom outline (slightly darker) instead of the system border.
            field
                .textFieldStyle(.plain)
                .frame(width: width)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.primary.opacity(0.22), lineWidth: 1))
        } else {
            field
                .frame(width: width)
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// A row of the eight brightness-level fields (levels 1…8), each 0…100.
struct BrightnessRow: View {
    @Binding var values: [Int]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<8, id: \.self) { i in
                VStack(spacing: 2) {
                    Text("\(i + 1)").font(.system(size: 9)).foregroundStyle(.secondary)
                    TextField("", value: Binding(
                        get: { values[i] },
                        set: { values[i] = min(max($0, 0), 100) }
                    ), format: .number)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }
}
