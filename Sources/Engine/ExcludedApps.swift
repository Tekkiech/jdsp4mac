import CoreAudio
import Foundation

/// The per-app exclusion list: `excluded-apps.txt` in Application Support, one bundle ID per line
/// (lines starting with # are comments). Watched like audio.conf, so edits from anywhere apply live.
public final class ExcludedApps: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "tech.tekkiech.jdsp4mac.excluded-apps")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var last: [String]?
    private var onChange: (@Sendable ([String]) -> Void)?

    public init(library: FileLibrary = .standard) {
        url = library.root.appendingPathComponent("excluded-apps.txt")
    }

    public func load() -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public func save(_ bundleIDs: [String]) {
        let text = bundleIDs.joined(separator: "\n") + (bundleIDs.isEmpty ? "" : "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Calls `onChange` (private queue) with the list whenever the file changes.
    public func watch(onChange: @escaping @Sendable ([String]) -> Void) {
        queue.async {
            self.onChange = onChange
            self.last = self.load()
            self.attach()
        }
    }

    private func attach() {
        sources.forEach { $0.cancel() }
        // Folder: atomic saves (rename). File: in-place writes; truncation reports only .attrib.
        sources = [url.deletingLastPathComponent().path, url.path].compactMap { path in
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete],
                                                                queue: queue)
            src.setEventHandler { [weak self] in self?.reload() }
            src.setCancelHandler { close(fd) }
            src.resume()
            return src
        }
    }

    private func reload() {
        attach()
        let now = load()
        guard now != last else { return }
        last = now
        onChange?(now)
    }
}

/// Processes that have used audio since they started (helpers included): bundle ID, the app
/// responsible for them if different, and whether each is playing now. For the exclusion picker.
public enum AudioClients {
    /// Watches for processes starting or stopping audio (Core Audio's process list) and calls
    /// `onChange` on the main queue. Keep the returned token; `stopObserving` removes it.
    public static func observe(_ onChange: @escaping @Sendable () -> Void) -> AnyObject {
        let token = Observer(onChange)
        var addr = HAL.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(HAL.system, &addr, .main, token.block)
        return token
    }

    public static func stopObserving(_ token: AnyObject) {
        guard let token = token as? Observer else { return }
        var addr = HAL.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(HAL.system, &addr, .main, token.block)
    }

    private final class Observer {
        let block: AudioObjectPropertyListenerBlock
        init(_ onChange: @escaping @Sendable () -> Void) { block = { _, _ in onChange() } }
    }

    public static func list() -> [(bundleID: String, owner: String?, playing: Bool)] {
        let me = getpid()
        return HAL.audioProcesses().filter { $0.pid != me && !$0.bundleID.isEmpty }.map { ($0.bundleID, $0.owner, $0.playing) }
    }
}
