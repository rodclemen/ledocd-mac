import Foundation

/// A pinball machine's lamp map, loaded from a bundled `.csv` file. CSV rules are
/// transcribed from ledocd.awk: a line whose first comma-field is all digits is a
/// lamp (`number,label`); a lamp number < 11 means the board is Stern; the markers
/// `CAPCOM_A` / `CAPCOM_B` anywhere in the file select the Capcom matrix.
struct MachinePreset: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var manufacturer: OCDDevice.Manufacturer
    var lamps: [Lamp]
    var isCustom = false      // user-created (lives in the custom games folder)

    struct Lamp: Hashable { var number: Int; var label: String }

    var lampNumbers: [Int] { lamps.map(\.number) }

    static func == (a: MachinePreset, b: MachinePreset) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum Presets {

    /// Locate the bundled `data` directory (packaged app), falling back to the
    /// repo source tree for `swift run` development.
    private static func bundleDataDirectory() -> URL? {
        if let res = Bundle.main.resourceURL {
            let d = res.appendingPathComponent("data", isDirectory: true)
            if FileManager.default.fileExists(atPath: d.path) { return d }
        }
        let devPath = "/Users/rodclemen/Documents/Code/LEDOCD/data"
        if FileManager.default.fileExists(atPath: devPath) {
            return URL(fileURLWithPath: devPath, isDirectory: true)
        }
        return nil
    }

    /// The user's refreshed data directory, if a sync has ever run.
    private static func userDataDirectory() -> URL? {
        guard let d = DataSync.userDataDirectory(create: false),
              FileManager.default.fileExists(atPath: d.path) else { return nil }
        return d
    }

    /// True once a machine-data refresh has populated the user data directory.
    static var hasUserData: Bool {
        guard let d = userDataDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
        else { return false }
        return files.contains { $0.pathExtension.lowercased() == "csv" }
    }

    /// Built-in generic maps for when no machine is chosen.
    static func generics() -> [MachinePreset] {
        var wpc: [MachinePreset.Lamp] = []
        for col in 1...8 { for row in 1...8 { let n = col * 10 + row; wpc.append(.init(number: n, label: "Lamp \(n)")) } }
        var stern: [MachinePreset.Lamp] = []
        for n in 1...80 { stern.append(.init(number: n, label: "Lamp \(n)")) }
        return [
            MachinePreset(name: "— Generic WPC (8×8) —", manufacturer: .wpc, lamps: wpc),
            MachinePreset(name: "— Generic Stern (8×10) —", manufacturer: .stern, lamps: stern),
        ]
    }

    static func loadAll() -> [MachinePreset] {
        // Merge bundled data with any refreshed user data, keyed by filename so a
        // downloaded file overrides its bundled namesake while bundled-only files
        // (e.g. the `-Undefined` templates) are preserved.
        var byFile: [String: MachinePreset] = [:]
        func ingest(_ dir: URL?) {
            guard let dir,
                  let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                includingPropertiesForKeys: nil) else { return }
            for url in files where url.pathExtension.lowercased() == "csv" {
                if let p = parse(url: url) { byFile[url.lastPathComponent] = p }
            }
        }
        ingest(bundleDataDirectory())
        ingest(userDataDirectory())   // overrides bundled files on name collision

        let machines = byFile.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        // User-created games from their own folder — kept apart so a data refresh
        // can't clobber them, and listed first (the "Custom Games" dropdown group).
        var customs: [MachinePreset] = []
        if let dir = DataSync.customGamesDirectory(create: false),
           let files = try? FileManager.default.contentsOfDirectory(at: dir,
                            includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension.lowercased() == "csv" {
                if var p = parse(url: url) { p.isCustom = true; customs.append(p) }
            }
        }
        customs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return customs + generics() + machines
    }

    private static func parse(url: URL) -> MachinePreset? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var manufacturer: OCDDevice.Manufacturer = .wpc
        if text.contains("CAPCOM_A") { manufacturer = .capcomA }
        else if text.contains("CAPCOM_B") { manufacturer = .capcomB }

        var lamps: [MachinePreset.Lamp] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(separator: ",", maxSplits: 1,
                                       omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            let first = fields[0].trimmingCharacters(in: .whitespaces)
            guard !first.isEmpty, first.allSatisfy(\.isNumber), let n = Int(first) else { continue }
            if n < 11 { manufacturer = .stern }
            lamps.append(.init(number: n, label: fields[1].trimmingCharacters(in: .whitespaces)))
        }
        guard !lamps.isEmpty else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return MachinePreset(name: name, manufacturer: manufacturer, lamps: lamps)
    }
}
