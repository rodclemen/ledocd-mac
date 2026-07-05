import Foundation

/// Reads/writes the LED OCD `<settings>` XML used by the Windows app, so configs
/// are interchangeable between the two.
enum ConfigIO {

    // MARK: - Export

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Produces output byte-identical to the Windows app: UTF-8 BOM, CRLF line
    /// endings, and no trailing newline.
    static func exportLEDXML(title: String, advanced: Bool,
                             lampProfiles: [(number: Int, profile: Int)],
                             profiles: [LEDProfile]) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"no\"?>")
        lines.append("<settings>")
        lines.append("  <title>\(esc(title))</title>")
        lines.append("  <advanced>\(advanced)</advanced>")
        for (number, profile) in lampProfiles.sorted(by: { $0.number < $1.number }) {
            let tag = String(format: "lamp%02d", number)
            lines.append("  <\(tag)>")
            lines.append("    <profile>\(profile)</profile>")
            lines.append("  </\(tag)>")
        }
        for p in profiles {
            lines.append("  <profile\(p.id)>")
            lines.append("    <name>\(esc(p.name))</name>")
            for i in 0..<8 { lines.append("    <b\(i + 1)>\(p.brightness[i])</b\(i + 1)>") }
            lines.append("    <delay>\(p.delay)</delay>")
            lines.append("  </profile\(p.id)>")
        }
        lines.append("</settings>")
        return "\u{FEFF}" + lines.joined(separator: "\r\n")
    }

    // MARK: - Import

    struct ParsedLED {
        var title: String
        var advanced: Bool
        var lampProfiles: [Int: Int]                 // lamp number → profile (1…8)
        var profiles: [(name: String, brightness: [Int], delay: Int)]  // profile 1…8 in order
    }

    static func parseLEDXML(_ data: Data) -> ParsedLED? {
        guard let doc = try? XMLDocument(data: data),
              let root = doc.rootElement(), root.name == "settings" else { return nil }

        func text(_ el: XMLElement, _ name: String) -> String? {
            el.elements(forName: name).first?.stringValue
        }

        let title = text(root, "title") ?? ""
        let advanced = (text(root, "advanced") ?? "false").lowercased() == "true"

        var lampProfiles: [Int: Int] = [:]
        for child in root.children ?? [] {
            guard let el = child as? XMLElement, let name = el.name,
                  name.hasPrefix("lamp"), let num = Int(name.dropFirst(4)) else { continue }
            if let p = text(el, "profile"), let pv = Int(p) { lampProfiles[num] = pv }
        }

        var profiles: [(String, [Int], Int)] = []
        for i in 1...8 {
            guard let el = root.elements(forName: "profile\(i)").first else { continue }
            let name = text(el, "name") ?? ""
            var b = [Int](repeating: 0, count: 8)
            for j in 1...8 { b[j - 1] = Int(text(el, "b\(j)") ?? "0") ?? 0 }
            let delay = Int(text(el, "delay") ?? "0") ?? 0
            profiles.append((name, b, delay))
        }
        guard profiles.count == 8 else { return nil }
        return ParsedLED(title: title, advanced: advanced, lampProfiles: lampProfiles, profiles: profiles)
    }

    // MARK: - GI OCD

    /// String tags in the GI `<settings>` file: strings 1–5 then the 6th "mod".
    private static let giTags = ["string1", "string2", "string3", "string4", "string5", "mod"]

    static func exportGIXML(advanced: Bool, fadeMin: Int, fadeMax: Int,
                            actDuration: Int, fiftyHz: Bool, strings: [GIString]) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"no\"?>")
        lines.append("<settings>")
        lines.append("  <advanced>\(advanced)</advanced>")
        lines.append("  <delaymin>\(fadeMin)</delaymin>")
        lines.append("  <delaymax>\(fadeMax)</delaymax>")
        lines.append("  <actduration>\(actDuration)</actduration>")
        // Not in the Windows format; extra field the Windows app ignores on import.
        lines.append("  <fiftyhz>\(fiftyHz)</fiftyhz>")
        for (idx, s) in strings.enumerated() where idx < giTags.count {
            let tag = giTags[idx]
            lines.append("  <\(tag)>")
            lines.append("    <input>\(s.input - 1)</input>")   // model 1-based → file 0-based
            lines.append("    <activity>\(s.active)</activity>")
            for i in 0..<8 { lines.append("    <b\(i + 1)>\(s.normal[i])</b\(i + 1)>") }
            for i in 0..<8 { lines.append("    <b\(i + 1)active>\(s.activeBright[i])</b\(i + 1)active>") }
            lines.append("  </\(tag)>")
        }
        lines.append("</settings>")
        return "\u{FEFF}" + lines.joined(separator: "\r\n")
    }

    struct ParsedGI {
        var advanced: Bool
        var fadeMin: Int
        var fadeMax: Int
        var actDuration: Int
        var fiftyHz: Bool
        /// 6 entries, in order string1…string5, mod.
        var strings: [(input: Int, active: Bool, normal: [Int], activeBright: [Int])]
    }

    static func parseGIXML(_ data: Data) -> ParsedGI? {
        guard let doc = try? XMLDocument(data: data),
              let root = doc.rootElement(), root.name == "settings" else { return nil }

        func text(_ el: XMLElement, _ name: String) -> String? {
            el.elements(forName: name).first?.stringValue
        }
        // Distinguish from a LED file: GI files carry <delaymin>.
        guard let minStr = text(root, "delaymin") else { return nil }

        let advanced = (text(root, "advanced") ?? "false").lowercased() == "true"
        let fadeMin = Int(minStr) ?? 0
        let fadeMax = Int(text(root, "delaymax") ?? "0") ?? 0
        let actDuration = Int(text(root, "actduration") ?? "0") ?? 0
        // Only present in files this app writes; absent (Windows files) → leave off.
        let fiftyHz = (text(root, "fiftyhz") ?? "false").lowercased() == "true"

        var strings: [(Int, Bool, [Int], [Int])] = []
        for tag in giTags {
            guard let el = root.elements(forName: tag).first else { return nil }
            let input = (Int(text(el, "input") ?? "0") ?? 0) + 1   // file 0-based → model 1-based
            let active = (text(el, "activity") ?? "false").lowercased() == "true"
            var normal = [Int](repeating: 0, count: 8)
            var activeB = [Int](repeating: 0, count: 8)
            for j in 1...8 {
                normal[j - 1] = Int(text(el, "b\(j)") ?? "0") ?? 0
                activeB[j - 1] = Int(text(el, "b\(j)active") ?? "0") ?? 0
            }
            strings.append((input, active, normal, activeB))
        }
        guard strings.count == 6 else { return nil }
        return ParsedGI(advanced: advanced, fadeMin: fadeMin, fadeMax: fadeMax,
                        actDuration: actDuration, fiftyHz: fiftyHz, strings: strings)
    }
}
