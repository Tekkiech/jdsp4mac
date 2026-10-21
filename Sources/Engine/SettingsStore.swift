import Config
import Foundation

/// The live settings file (`audio.conf` in the app's support folder, same format as JDSP4Linux's
/// ~/.config/jamesdsp/audio.conf). Changes made by anyone (our UI, `jdspconf set`, a text editor,
/// copying a preset over it) are picked up and reported. Two kinds of watcher are needed: folders
/// catch atomic saves (the file is replaced by a rename), the file itself catches in-place writes
/// (`cp`, some editors), which change no folder entry.
///
/// The files the enabled effects refer to (liveprog script, impulse response, DDC) are watched the
/// same way, so saving a script in an editor reloads it, as JDSP4Linux does.
public final class SettingsStore: @unchecked Sendable {
    public let url: URL
    private let library: FileLibrary
    private let queue = DispatchQueue(label: "tech.tekkiech.jdsp4mac.settings")
    private var folderSources: [DispatchSourceFileSystemObject] = []
    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var lastText: String?
    private var lastStamps: [String] = []
    private var pending: DispatchWorkItem?
    private var pendingSave: DispatchWorkItem?
    private var onChange: (@Sendable (DSPSettings, Bool) -> Void)?

    public init(library: FileLibrary = .standard) {
        self.library = library
        url = library.root.appendingPathComponent("audio.conf")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? DefaultSettings.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func load() -> (DSPSettings, String) {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let settings = DSPSettings(conf: AudioConf(text: text))
        let stamps = self.stamps(settings)
        queue.sync { lastText = text; lastStamps = stamps }
        return (settings, text)
    }

    /// Calls `onChange` (on a private queue) whenever the file's text changes, or a file an enabled
    /// effect refers to changes. The Bool is true when only such a file changed (the settings are
    /// the same, but the instance must be rebuilt to re-read it).
    public func watch(onChange: @escaping @Sendable (DSPSettings, Bool) -> Void) {
        queue.async {
            self.onChange = onChange
            let folders = [self.library.root] + FileLibrary.Kind.allCases.map(self.library.folder)
            self.folderSources = folders.compactMap { self.makeSource(path: $0.path, events: [.write, .rename, .delete]) }
            self.watchFiles(DSPSettings(conf: AudioConf(text: self.lastText ?? "")))
        }
    }

    /// Writes settings changed in our UI. Only lines whose value changed are touched, so comments
    /// and unknown keys survive. Coalesced (a slider drag writes once it pauses for 0.2 s) and not
    /// reported back through `watch`, since the caller already has these settings.
    public func save(_ settings: DSPSettings) {
        queue.async {
            self.pendingSave?.cancel()
            let item = DispatchWorkItem {
                var conf = (try? AudioConf(contentsOf: self.url)) ?? AudioConf(text: DefaultSettings.text)
                settings.write(into: &conf)
                let text = conf.text
                guard text != self.lastText else { return }
                do {
                    try text.write(to: self.url, atomically: true, encoding: .utf8)
                    self.lastText = text
                    self.lastStamps = self.stamps(settings)
                } catch { Log.write("could not save settings: \(error)") }
            }
            self.pendingSave = item
            self.queue.asyncAfter(deadline: .now() + 0.2, execute: item)
        }
    }

    /// Writes a pending `save` now. Call before anything that reads or replaces the file (preset
    /// save/load), so an unsaved UI change neither goes missing nor reverts a loaded preset.
    public func flush() {
        queue.sync {
            guard let item = pendingSave else { return }
            pendingSave = nil
            item.perform()
            item.cancel()
        }
    }

    private func makeSource(path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }

    private func referencedFiles(_ s: DSPSettings) -> [(String, FileLibrary.Kind)] {
        var files: [(String, FileLibrary.Kind)] = []
        if s.liveprogEnable { files.append((s.liveprogFile, .liveprog)) }
        if s.convolverEnable { files.append((s.convolverFile, .impulseResponse)) }
        if s.ddcEnable { files.append((s.ddcFile, .ddc)) }
        return files
    }

    /// Identity of each referenced file's current contents (path, size, modification time), or
    /// "missing" so that the file appearing later also counts as a change.
    private func stamps(_ s: DSPSettings) -> [String] {
        referencedFiles(s).map { path, kind in
            guard let file = library.resolve(path, kind: kind),
                  let a = try? FileManager.default.attributesOfItem(atPath: file.path) else { return "missing \(path)" }
            let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(file.path) \(a[.size] ?? 0) \(mtime)"
        }
    }

    /// (Re)attaches to audio.conf and the referenced files. After an atomic save the old
    /// descriptor points at the replaced file, so every reload re-opens them.
    private func watchFiles(_ s: DSPSettings) {
        fileSources.forEach { $0.cancel() }
        let paths = [url.path] + referencedFiles(s).compactMap { library.resolve($0.0, kind: $0.1)?.path }
        fileSources = paths.compactMap { makeSource(path: $0, events: [.write, .extend, .attrib, .delete, .rename]) }
    }

    private func scheduleReload() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let text = try? String(contentsOf: self.url, encoding: .utf8) else { return }
            let settings = DSPSettings(conf: AudioConf(text: text))
            let stamps = self.stamps(settings)
            self.watchFiles(settings)
            let textChanged = text != self.lastText
            guard textChanged || stamps != self.lastStamps else { return }
            self.lastText = text
            self.lastStamps = stamps
            self.onChange?(settings, !textChanged)
        }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.05, execute: item)
    }
}
