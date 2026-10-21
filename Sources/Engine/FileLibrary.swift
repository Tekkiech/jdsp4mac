import Foundation

/// Where impulse responses, ViPER DDC files and liveprog scripts live, and how preset paths are
/// resolved. Presets from JDSP4Linux carry Linux paths (e.g.
/// /home/user/.config/jamesdsp/irs/x.wav); if a path does not exist here, the file is looked up by
/// name in our folders, which mirror the Linux layout (irs/, vdc/, liveprog/).
public struct FileLibrary: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case impulseResponse = "irs"
        case ddc = "vdc"
        case liveprog = "liveprog"
    }

    public let root: URL

    public static let standard = FileLibrary(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jdsp4mac", isDirectory: true))

    public init(root: URL) {
        self.root = root
        for kind in Kind.allCases {
            try? FileManager.default.createDirectory(at: folder(kind), withIntermediateDirectories: true)
        }
    }

    public func folder(_ kind: Kind) -> URL {
        root.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    public static func extensions(_ kind: Kind) -> Set<String> {
        switch kind {
        case .impulseResponse: ["wav", "flac", "mp3", "irs"]
        case .ddc: ["vdc"]
        case .liveprog: ["eel"]
        }
    }

    /// File names in a library folder, sorted as Finder does.
    public func files(_ kind: Kind) -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder(kind), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { Self.extensions(kind).contains($0.pathExtension.lowercased()) }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Copies a file into its library folder (replacing one of the same name); returns its name.
    @discardableResult
    public func add(_ source: URL, kind: Kind) throws -> String {
        let dest = folder(kind).appendingPathComponent(source.lastPathComponent)
        if source.standardizedFileURL != dest.standardizedFileURL {
            _ = try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: source, to: dest)
        }
        return dest.lastPathComponent
    }

    /// The file a preset refers to, or nil. Empty paths resolve to nil.
    public func resolve(_ path: String, kind: Kind) -> URL? {
        guard !path.isEmpty else { return nil }
        let direct = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if FileManager.default.isReadableFile(atPath: direct.path) { return direct }
        let byName = folder(kind).appendingPathComponent(direct.lastPathComponent)
        if FileManager.default.isReadableFile(atPath: byName.path) { return byName }
        return nil
    }
}
