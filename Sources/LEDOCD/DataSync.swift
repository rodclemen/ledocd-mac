import Foundation

/// Downloads the machine-map CSVs from ledocd.com into a writable Application
/// Support directory. Incremental: the Apache listing exposes each file's
/// last-modified date, which we cache in a manifest and compare on each refresh,
/// so only new/changed files are actually downloaded. The server rejects
/// requests lacking browser-like headers (HTTP 406), so every request carries a
/// User-Agent / Accept set.
enum DataSync {

    static let indexURL = URL(string: "https://ledocd.com/software/ledocd_data/")!
    private static let manifestName = "sync-manifest.json"

    struct SyncResult {
        var downloaded: Int
        var skipped: Int
        var failed: [String]
        var directory: URL
    }

    enum SyncError: Error, CustomStringConvertible {
        case http(Int, String)
        case emptyIndex
        case noDataDir
        var description: String {
            switch self {
            case .http(let code, let what): return "HTTP \(code) fetching \(what)."
            case .emptyIndex: return "No CSV files found in the site listing."
            case .noDataDir: return "Couldn't create the Application Support data folder."
            }
        }
    }

    private struct Entry { let url: URL; let name: String; let modified: String }

    private static func makeRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                     + "(KHTML, like Gecko) Chrome/126.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 30
        return req
    }

    static func userDataDirectory(create: Bool = false) -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                in: .userDomainMask, appropriateFor: nil, create: create) else { return nil }
        let dir = base.appendingPathComponent("LED OCD/data", isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// User-created games live apart from the synced `data` folder, so a machine-data
    /// refresh can never overwrite them and the originals stay available alongside.
    static func customGamesDirectory(create: Bool = false) -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                in: .userDomainMask, appropriateFor: nil, create: create) else { return nil }
        let dir = base.appendingPathComponent("LED OCD/custom", isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Parse the Apache autoindex: each row carries the `*.csv` link followed by a
    /// `YYYY-MM-DD HH:MM` last-modified timestamp.
    private static func fetchIndex() async throws -> [Entry] {
        let (data, resp) = try await URLSession.shared.data(for: makeRequest(indexURL))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw SyncError.http(code, "listing") }
        let html = String(decoding: data, as: UTF8.self)

        let hrefRE = try NSRegularExpression(pattern: #"href="([^"]+\.csv)""#, options: [.caseInsensitive])
        let dateRE = try NSRegularExpression(pattern: #"(\d{4}-\d{2}-\d{2} \d{2}:\d{2})"#)

        var entries: [Entry] = []
        var seen = Set<String>()
        for rawLine in html.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard let h = hrefRE.firstMatch(in: line, range: range),
                  let hr = Range(h.range(at: 1), in: line) else { continue }
            let href = String(line[hr])
            guard let u = URL(string: href, relativeTo: indexURL)?.absoluteURL else { continue }
            let name = u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent
            let modified: String
            if let d = dateRE.firstMatch(in: line, range: range), let dr = Range(d.range(at: 1), in: line) {
                modified = String(line[dr])
            } else {
                modified = ""
            }
            if seen.insert(name).inserted { entries.append(Entry(url: u, name: name, modified: modified)) }
        }
        return entries
    }

    private static func looksLikeCSV(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let first = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            return !first.isEmpty && first.allSatisfy(\.isNumber)
        }
    }

    private static func loadManifest(_ dir: URL) -> [String: String] {
        let url = dir.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return obj
    }

    private static func saveManifest(_ manifest: [String: String], _ dir: URL) {
        let url = dir.appendingPathComponent(manifestName)
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    /// Fetch the listing and download only files that are new or whose modified
    /// date changed since the last sync.
    static func sync(progress: @Sendable @escaping (Int, Int) -> Void) async throws -> SyncResult {
        let entries = try await fetchIndex()
        guard !entries.isEmpty else { throw SyncError.emptyIndex }
        guard let dir = userDataDirectory(create: true) else { throw SyncError.noDataDir }

        let fm = FileManager.default
        var manifest = loadManifest(dir)
        var downloaded = 0, skipped = 0
        var failed: [String] = []

        for (idx, entry) in entries.enumerated() {
            let dest = dir.appendingPathComponent(entry.name)
            let unchanged = !entry.modified.isEmpty
                && manifest[entry.name] == entry.modified
                && fm.fileExists(atPath: dest.path)
            if unchanged {
                skipped += 1
                progress(idx + 1, entries.count)
                continue
            }
            do {
                let (data, resp) = try await URLSession.shared.data(for: makeRequest(entry.url))
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard code == 200, looksLikeCSV(String(decoding: data, as: UTF8.self)) else {
                    throw SyncError.http(code, entry.name)
                }
                try data.write(to: dest)
                manifest[entry.name] = entry.modified
                downloaded += 1
            } catch {
                failed.append(entry.name)
            }
            progress(idx + 1, entries.count)
        }

        saveManifest(manifest, dir)
        return SyncResult(downloaded: downloaded, skipped: skipped, failed: failed, directory: dir)
    }
}
