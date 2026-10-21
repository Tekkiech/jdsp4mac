import Config
import Foundation

/// Presets (JDSP4Linux format, `presets/<name>.conf`), import/export of other JamesDSP apps'
/// presets, and per-output-device rules. Loading a preset copies it over the live audio.conf, so
/// it reaches the engine the same way as any other edit (SettingsStore watches that file).
public final class PresetStore: @unchecked Sendable {
    public enum ExportFormat: Sendable { case linux, rootless }

    public struct Rule: Codable, Equatable, Sendable {
        public var deviceUID: String
        public var deviceName: String
        public var preset: String
    }

    public let folder: URL
    private let settings: SettingsStore
    private let library: FileLibrary
    private let rulesURL: URL

    public init(settings: SettingsStore, library: FileLibrary = .standard) {
        self.settings = settings
        self.library = library
        folder = library.root.appendingPathComponent("presets", isDirectory: true)
        rulesURL = library.root.appendingPathComponent("rules.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    public func list() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "conf" }.map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Parsed settings of each preset (to show which one is active).
    public func settings(of names: [String]) -> [String: DSPSettings] {
        var out: [String: DSPSettings] = [:]
        for name in names {
            if let text = try? String(contentsOf: url(name), encoding: .utf8) { out[name] = DSPSettings(conf: AudioConf(text: text)) }
        }
        return out
    }

    private func url(_ name: String) -> URL { folder.appendingPathComponent(name + ".conf") }

    /// Saves the current settings as a preset (overwrites one of the same name).
    public func save(as name: String) throws {
        settings.flush()
        let text = try String(contentsOf: settings.url, encoding: .utf8)
        try text.write(to: url(Self.safe(name)), atomically: true, encoding: .utf8)
    }

    /// Makes a preset the live settings. Returns notes about files it refers to that are missing.
    @discardableResult
    public func load(_ name: String) throws -> [String] {
        settings.flush()
        let text = try String(contentsOf: url(name), encoding: .utf8)
        try text.write(to: settings.url, atomically: true, encoding: .utf8)
        return missingFiles(DSPSettings(conf: AudioConf(text: text)))
    }

    /// Makes the stock JDSP4Linux default.conf (all effects off) the live settings.
    public func loadDefaults() throws {
        settings.flush()
        try DefaultSettings.text.write(to: settings.url, atomically: true, encoding: .utf8)
    }

    public func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: url(name))
        setRules(rules().filter { $0.preset != name })
    }

    /// Imports a preset file from any supported app. Format by extension: .conf/.jdsp/.txt
    /// (JDSP4Linux, foobar2000), .tar (RootlessJamesDSP), .xml (JamesDSP for Android, one output
    /// profile file). Returns the preset name and notes (what did not map, missing files).
    public func importPreset(from source: URL) throws -> (name: String, notes: [String]) {
        let data = try Data(contentsOf: source)
        var imported: ImportedPreset
        switch source.pathExtension.lowercased() {
        case "tar":
            imported = try PresetConversion.importRootless(data)
        case "xml":
            imported = try PresetConversion.importAndroid(data)
        default:
            guard let text = String(data: data, encoding: .utf8) else { throw LiveError("not a text preset") }
            imported = ImportedPreset(conf: AudioConf(text: text), bundledFiles: [], notes: [])
            let unknown = AudioConf(text: text).keys.filter { !DSPSettings.allKeys.contains($0) }
            if !unknown.isEmpty {
                imported.notes.append("Keys not used by this version, kept in the file: \(unknown.joined(separator: ", "))")
            }
        }
        // Store bundled files (Rootless liveprog scripts) in the library without overwriting a
        // different file of the same name.
        var s = DSPSettings(conf: imported.conf)
        for file in imported.bundledFiles where file.kind == "liveprog" {
            let stored = store(file.data, named: file.name, in: library.folder(.liveprog))
            if stored != file.name {
                s.liveprogFile = stored
                imported.notes.append("Bundled liveprog script saved as \"\(stored)\" (a different \"\(file.name)\" already exists)")
            }
        }
        s.write(into: &imported.conf)
        var name = Self.safe(source.deletingPathExtension().lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: url(name).path) {
            name = Self.safe(source.deletingPathExtension().lastPathComponent) + " \(n)"
            n += 1
        }
        try imported.conf.text.write(to: url(name), atomically: true, encoding: .utf8)
        return (name, imported.notes + missingFiles(s))
    }

    /// Exports a preset. Returns notes about anything the target format cannot express.
    public func export(_ name: String, to destination: URL, format: ExportFormat) throws -> [String] {
        let text = try String(contentsOf: url(name), encoding: .utf8)
        let s = DSPSettings(conf: AudioConf(text: text))
        switch format {
        case .linux:
            try text.write(to: destination, atomically: true, encoding: .utf8)
            let referenced = [(s.convolverEnable, s.convolverFile, "irs"), (s.ddcEnable, s.ddcFile, "vdc"),
                              (s.liveprogEnable, s.liveprogFile, "liveprog")].filter { $0.0 && !$0.1.isEmpty }
            return referenced.map {
                "JDSP4Linux needs \"\(($0.1 as NSString).lastPathComponent)\" in ~/.config/jamesdsp/\($0.2)/ and the full path in the preset"
            }
        case .rootless:
            let script = s.liveprogEnable ? library.resolve(s.liveprogFile, kind: .liveprog).flatMap { try? Data(contentsOf: $0) } : nil
            let (archive, notes) = PresetConversion.exportRootless(s, liveprogScript: script)
            try archive.write(to: destination)
            return notes
        }
    }

    // MARK: Per-device rules (JDSP4Linux --set-preset-rule equivalent)

    public func rules() -> [Rule] {
        guard let data = try? Data(contentsOf: rulesURL) else { return [] }
        return (try? JSONDecoder().decode([Rule].self, from: data)) ?? []
    }

    public func rule(forDevice uid: String) -> Rule? { rules().first { $0.deviceUID == uid } }

    public func setRule(deviceUID: String, deviceName: String, preset: String?) {
        var all = rules().filter { $0.deviceUID != deviceUID }
        if let preset { all.append(Rule(deviceUID: deviceUID, deviceName: deviceName, preset: preset)) }
        setRules(all)
    }

    private func setRules(_ all: [Rule]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(all) { try? data.write(to: rulesURL, options: .atomic) }
    }

    // MARK: Helpers

    private func missingFiles(_ s: DSPSettings) -> [String] {
        [(s.convolverEnable, s.convolverFile, FileLibrary.Kind.impulseResponse),
         (s.ddcEnable, s.ddcFile, .ddc), (s.liveprogEnable, s.liveprogFile, .liveprog)]
            .filter { $0.0 && !$0.1.isEmpty && library.resolve($0.1, kind: $0.2) == nil }
            .map { "Missing file \"\(($0.1 as NSString).lastPathComponent)\": add it to \(library.folder($0.2).path)" }
    }

    /// Writes data under `name` unless a different file has that name; then uses "name 2.ext" etc.
    private func store(_ data: Data, named name: String, in dir: URL) -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name, n = 2
        while true {
            let target = dir.appendingPathComponent(candidate)
            if let existing = try? Data(contentsOf: target) {
                if existing == data { return candidate }
            } else {
                try? data.write(to: target, options: .atomic)
                return candidate
            }
            candidate = "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            n += 1
        }
    }

    private static func safe(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Preset" : cleaned
    }
}
