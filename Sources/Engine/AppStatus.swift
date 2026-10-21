import Darwin
import Foundation

/// What the running app is doing, for `jdspctl --status` / `--is-connected`. The app rewrites
/// `status.json` in Application Support whenever this changes (not on every stats tick); the CLI
/// trusts it only while the process that wrote it is alive. Settings, presets and rules need no
/// IPC: the app already watches those files.
public struct AppStatus: Codable, Equatable, Sendable {
    public var pid: Int32
    /// "processing", "bypassed", "off", "starting", "not processing", "permission problem", "failed"
    public var state: String
    public var detail: String
    public var output: String?
    public var sampleRate: Double?
    public var bufferFrames: UInt32?
    public var problems: [String]

    public init(pid: Int32, state: String, detail: String, output: String?, sampleRate: Double?, bufferFrames: UInt32?,
                problems: [String]) {
        self.pid = pid; self.state = state; self.detail = detail; self.output = output
        self.sampleRate = sampleRate; self.bufferFrames = bufferFrames; self.problems = problems
    }

    public static func url(_ library: FileLibrary = .standard) -> URL { library.root.appendingPathComponent("status.json") }

    public func write(_ library: FileLibrary = .standard) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.url(library), options: .atomic)
    }

    /// The status of a running app, or nil if none is running (no file, or its writer is gone).
    public static func read(_ library: FileLibrary = .standard) -> AppStatus? {
        guard let data = try? Data(contentsOf: url(library)),
              let status = try? JSONDecoder().decode(AppStatus.self, from: data),
              isApp(status.pid) else { return nil }
        return status
    }

    /// The pid is alive and is jdsp4mac (not a later process that reused the number).
    private static func isApp(_ pid: Int32) -> Bool {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix("/jdsp4mac")
    }

    public static func remove(_ library: FileLibrary = .standard) {
        try? FileManager.default.removeItem(at: url(library))
    }
}
