import Config
import Engine
import Foundation
import Observation

/// Headphone search over AutoEq's published results (see Config/AutoEQ.swift). Network access only
/// when the user opens the AutoEQ tab or applies a profile; the index (refreshed weekly) and every
/// applied profile are cached in Application Support/jdsp4mac/autoeq/.
@MainActor
@Observable
final class AutoEQSearch {
    enum Phase: Equatable { case idle, loading, ready, failed(String) }

    /// Remembered between openings of the window.
    var query = UserDefaults.standard.string(forKey: "autoEQQuery") ?? "" {
        didSet { UserDefaults.standard.set(query, forKey: "autoEQQuery") }
    }
    private(set) var phase: Phase = .idle
    private(set) var entries: [AutoEQ.Entry] = []
    private(set) var applying: String?

    private let cache = FileLibrary.standard.root.appendingPathComponent("autoeq", isDirectory: true)
    private var indexFile: URL { cache.appendingPathComponent("INDEX.md") }

    /// Best matches first: every query word must appear; names starting with the query rank higher.
    var results: [AutoEQ.Entry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let q = query.lowercased()
        return entries
            .filter { e in let n = e.name.lowercased(); return words.allSatisfy { n.contains($0) } }
            .sorted { a, b in
                let pa = a.name.lowercased().hasPrefix(q), pb = b.name.lowercased().hasPrefix(q)
                return pa != pb ? pa : a.name.count < b.name.count
            }
            .prefix(100).map { $0 }
    }

    func loadIndex() async {
        guard phase != .loading, entries.isEmpty || isStale else { return }
        phase = .loading
        if let text = try? String(contentsOf: indexFile, encoding: .utf8), !isStale {
            entries = AutoEQ.parseIndex(text)
            phase = .ready
            return
        }
        Log.write("autoeq: downloading the index")
        do {
            let (data, response) = try await URLSession.shared.data(from: AutoEQ.indexURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
                throw URLError(.badServerResponse)
            }
            let parsed = AutoEQ.parseIndex(text)
            guard !parsed.isEmpty else { throw URLError(.cannotParseResponse) }
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? data.write(to: indexFile)
            entries = parsed
            phase = .ready
            Log.write("autoeq: index loaded, \(parsed.count) profiles")
        } catch {
            Log.write("autoeq: index download failed: \(error)")
            // Fall back to an old cached index rather than nothing.
            if let text = try? String(contentsOf: indexFile, encoding: .utf8) {
                entries = AutoEQ.parseIndex(text)
                phase = .ready
            } else {
                phase = .failed("Could not load the AutoEq index: \(error.localizedDescription)")
            }
        }
    }

    private var isStale: Bool {
        let date = (try? indexFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return date.map { Date().timeIntervalSince($0) > 7 * 24 * 3600 } ?? true
    }

    /// Downloads (or reads the cached) GraphicEQ for `entry` and applies it.
    func apply(_ entry: AutoEQ.Entry, to controller: EngineController) async {
        applying = entry.id
        defer { applying = nil }
        let file = cache.appendingPathComponent(entry.path.replacingOccurrences(of: "/", with: " - ").removingPercentEncoding ?? entry.name)
            .appendingPathExtension("txt")
        var text = try? String(contentsOf: file, encoding: .utf8)
        if text == nil {
            do {
                let (data, response) = try await URLSession.shared.data(from: entry.graphicEQURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
                text = String(data: data, encoding: .utf8)
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try? data.write(to: file)
            } catch {
                controller.notify("Could not download \(entry.name): \(error.localizedDescription)", isError: true)
                return
            }
        }
        guard let line = text.flatMap(AutoEQ.graphicEQLine) else {
            controller.notify("\(entry.name): no GraphicEQ curve in the download", isError: true)
            return
        }
        controller.applyGraphicEQ(line, profile: AutoEQProfile(entry))
    }
}

/// What an applied curve came from, shown in the panel.
struct AutoEQProfile: Codable, Equatable {
    let name: String
    let source: String
    let rig: String?
    var detail: String { rig.map { "\(source) on \($0)" } ?? source }

    init(_ entry: AutoEQ.Entry) { name = entry.name; source = entry.source; rig = entry.rig }
    init(name: String, source: String) { self.name = name; self.source = source; rig = nil }
}
