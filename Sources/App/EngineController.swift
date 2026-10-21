import AppKit
import AudioCore
import Config
import Engine
import Observation
import SwiftUI

/// Bridges the engine to SwiftUI and to process events (sleep/wake, quit, signals).
@MainActor
@Observable
final class EngineController {
    var mode: LiveMode = .dsp
    var bypass = false { didSet { engine.setBypass(bypass) } }
    private(set) var statusText = "Stopped"
    private(set) var lines: [String] = []
    private(set) var isActive = false
    /// What the panel shows and edits. Mirrors audio.conf: UI edits are applied to the engine at
    /// once and written to the file shortly after; edits to the file (presets, an editor) land here.
    private(set) var settings = DSPSettings.defaults
    private(set) var outputs: [OutputDevice] = []
    private(set) var iconState: IconState = .bypassed
    /// One-line status for the panel header, and whether it is a problem the user must act on.
    private(set) var status = (text: "Off", isProblem: false)
    /// Last state of the power switch, restored at launch.
    private var engineOn: Bool {
        get { UserDefaults.standard.bool(forKey: "engineOn") }
        set { UserDefaults.standard.set(newValue, forKey: "engineOn") }
    }

    @ObservationIgnored private var engine: AudioEngine!
    @ObservationIgnored private let settingsStore = SettingsStore()
    @ObservationIgnored private let excludedStore = ExcludedApps()
    /// Bundle IDs left out of the tap (they play unprocessed). Mirrors excluded-apps.txt.
    private(set) var excludedApps: [String] = []
    @ObservationIgnored private lazy var presetStore = PresetStore(settings: settingsStore)
    @ObservationIgnored private var lastOutputUID: String?
    /// Problems with the current settings, from the live instance's build (missing files, liveprog
    /// errors). Shown until a build no longer reports them.
    private(set) var problems: [String] = []
    /// One-off messages (applied, saved, a failed download). Each fades after a few seconds.
    private(set) var notices: [Notice] = []
    /// Everything said recently, for the Diagnostics tab.
    private(set) var history: [String] = []
    private(set) var presets: [String] = []
    private(set) var outputName: String?
    private(set) var outputUID: String?
    var selectedPreset = ""
    /// The preset whose settings match the current ones exactly, if any.
    private(set) var currentPreset: String?
    @ObservationIgnored private var presetSettings: [String: DSPSettings] = [:]
    /// The preset rule for the current output. Stored (not read from disk on each render) so the
    /// panel's toggle refreshes when it changes.
    private(set) var ruleForOutput: String?
    var settingsPath: String { settingsStore.url.path }
    @ObservationIgnored private var signalSources: [DispatchSourceSignal] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        AudioEngine.prepareProcess()
        Log.write("launch pid \(getpid()) build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?")")
        // Test hooks for scripted gate runs: --autostart eq|passthrough, --bypass, --stats-every N,
        // --test-zero-input (simulates a tap that delivers only zeros), --test-skip-probe.
        let args = CommandLine.arguments
        var statsEvery = 10
        if let i = args.firstIndex(of: "--stats-every"), i + 1 < args.count, let n = Int(args[i + 1]) { statsEvery = n }
        let testZero = args.contains("--test-zero-input")
        if testZero { Log.write("TEST MODE: tap input forced to zero") }
        let skipProbe = args.contains("--test-skip-probe")
        if skipProbe { Log.write("TEST MODE: permission probe skipped") }
        engine = AudioEngine(statsLogEvery: statsEvery, testZeroInput: testZero, testSkipProbe: skipProbe) { [weak self] snapshot in
            MainActor.assumeIsolated { self?.apply(snapshot) }
        }

        let (initial, _) = settingsStore.load()
        settings = initial
        engine.apply(settings: initial)
        excludedApps = excludedStore.load()
        engine.setExcludedApps(excludedApps)
        excludedStore.watch { [weak self] list in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.excludedApps = list
                    self?.engine.setExcludedApps(list)
                }
            }
        }
        Log.write("settings: \(settingsStore.url.path)")
        settingsStore.watch { [weak self] settings, onlyFilesChanged in
            if onlyFilesChanged {
                Log.write("a liveprog/impulse response/DDC file changed")
                DispatchQueue.main.async { self?.engine.reloadFiles() }
            } else {
                Log.write("settings file changed")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self?.demoMode == false else { return }  // screenshots keep the demo
                        self?.settings = settings
                        self?.updateIcon()
                        self?.updateCurrentPreset()
                        self?.engine.apply(settings: settings)
                    }
                }
            }
        }

        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    Log.write("signal \(sig): tearing down")
                    self?.engine.stopAndWait(timeout: 3)
                    AppStatus.remove()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
        signal(SIGUSR2, SIG_IGN)  // test hook: toggle simulated zero tap input
        var zeroOn = testZero
        let zeroSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        zeroSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                zeroOn.toggle()
                self?.engine.setTestZeroInput(zeroOn)
            }
        }
        zeroSource.resume()
        signalSources.append(zeroSource)
        signal(SIGUSR1, SIG_IGN)
        let panicSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        panicSource.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.panic() } }
        panicSource.resume()
        signalSources.append(panicSource)

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.write("system will sleep")
                self?.engine.stopAndWait(timeout: 3, keepRunningIntent: true)
            }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.write("system did wake")
                self?.engine.systemDidWake()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engine.stopAndWait(timeout: 3)
                AppStatus.remove()
            }
        })

        // Test hook: post the real sleep/wake notifications (2 s apart) after N seconds.
        if let i = args.firstIndex(of: "--test-sleep-after"), i + 1 < args.count, let delay = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Log.write("TEST MODE: posting willSleep / didWake")
                ws.post(name: NSWorkspace.willSleepNotification, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    ws.post(name: NSWorkspace.didWakeNotification, object: nil)
                }
            }
        }

        if let i = args.firstIndex(of: "--autostart"), i + 1 < args.count {
            mode = args[i + 1] == "passthrough" ? .passthrough : .dsp
            bypass = args.contains("--bypass")
            start()
        } else if engineOn, !Self.renderingOnly {
            start()
        }
        refreshOutputs()
        refreshPresets()

        if let i = args.firstIndex(of: "--snapshot-panel"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                await PanelSnapshot.write(controller: self, to: dir)
                exit(0)
            }
        }
        // Marketing screenshots (scripts/screenshots.sh): real processing, demo settings in memory.
        if let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                showDemo()
                start()
                for _ in 0..<150 where status.text != "Processing" { try? await Task.sleep(for: .seconds(0.1)) }
                await PanelSnapshot.writeScreenshots(controller: self, to: dir)
                engine.stopAndWait(timeout: 3)
                exit(0)
            }
        }
    }

    func start() {
        engine.setBypass(bypass)
        engine.start(mode: mode)
    }

    func stop() { engine.stop() }

    /// The panel's power switch: on means capturing and processing, and is remembered.
    var isOn: Bool {
        get { isActive }
        set {
            engineOn = newValue
            newValue ? start() : stop()
        }
    }

    // MARK: Settings

    func update(_ change: (inout DSPSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        settings = s
        updateIcon()
        updateCurrentPreset()
        engine.apply(settings: s)
        settingsStore.save(s)
    }

    func binding<T: Equatable>(_ key: WritableKeyPath<DSPSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: key] }, set: { value in self.update { $0[keyPath: key] = value } })
    }

    // MARK: Outputs

    /// Refreshes the device list, and the current output while the engine is off (when running,
    /// engine snapshots keep it current).
    func refreshOutputs() {
        outputs = OutputDevices.list()
        if !isActive, let uid = OutputDevices.defaultUID() {
            setOutput(uid: uid, name: outputs.first { $0.uid == uid }?.name)
        }
    }

    private func setOutput(uid: String?, name: String?) {
        defer { writeStatus() }
        outputName = name
        if outputUID != uid {
            outputUID = uid
            ruleForOutput = uid.flatMap { presetStore.rule(forDevice: $0)?.preset }
        }
    }

    func selectOutput(_ uid: String) {
        guard uid != outputUID else { return }
        OutputDevices.setDefault(uid: uid)
        refreshOutputs()
    }

    func panic() { engine.panic() }

    // MARK: Presets

    func refreshPresets() {
        presets = presetStore.list()
        if !presets.contains(selectedPreset) { selectedPreset = presets.first ?? "" }
        presetSettings = presetStore.settings(of: presets)
        updateCurrentPreset()
        // Rules can change outside the app (jdspctl --set-preset-rule).
        ruleForOutput = outputUID.flatMap { presetStore.rule(forDevice: $0)?.preset }
    }

    private func updateCurrentPreset() {
        guard !demoMode else { return }
        currentPreset = presets.first { presetSettings[$0] == settings }
    }

    /// Imports an AutoEQ GraphicEQ.txt or ParametricEQ.txt (Equalizer APO format) into the
    /// arbitrary-response EQ.
    func importGraphicEQ() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        panel.message = "An AutoEQ GraphicEQ.txt or ParametricEQ.txt"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let line = AutoEQ.graphicEQLine(text) ?? AutoEQ.graphicEQ(fromParametric: text) else {
            note("\(url.lastPathComponent) has no GraphicEQ line or parametric filters", isError: true)
            return
        }
        applyGraphicEQ(line, profile: AutoEQProfile(name: url.deletingPathExtension().lastPathComponent, source: "file"))
    }

    func applyGraphicEQ(_ line: String, profile: AutoEQProfile) {
        update { $0.graphicEQParam = line; $0.graphicEQEnable = true }
        if let data = try? JSONEncoder().encode(StoredProfile(param: line, profile: profile)) {
            UserDefaults.standard.set(data, forKey: "autoEQProfile")
        }
        note("AutoEQ: \(profile.name) (\(profile.detail)) applied")
    }

    /// The profile the current GraphicEQ curve came from, if it was applied here.
    var autoEQProfile: AutoEQProfile? {
        if let demoProfile { return demoProfile }
        guard let data = UserDefaults.standard.data(forKey: "autoEQProfile"),
              let stored = try? JSONDecoder().decode(StoredProfile.self, from: data),
              stored.param == settings.graphicEQParam else { return nil }
        return stored.profile
    }

    private struct StoredProfile: Codable { let param: String; let profile: AutoEQProfile }

    func notify(_ text: String, isError: Bool = false) { note(text, isError: isError) }

    @ObservationIgnored private var engineOutput: [String] = []

    private func isActiveState(_ state: EngineState) -> Bool {
        switch state {
        case .running, .starting: true
        default: false
        }
    }

    func loadPreset(_ name: String) {
        do {
            for n in try presetStore.load(name) { note(n, isError: true) }
            note("Loaded preset \"\(name)\"")
        } catch { note("Could not load \"\(name)\": \(error.localizedDescription)", isError: true) }
    }

    func loadDefaults() {
        do {
            try presetStore.loadDefaults()
            note("Loaded default settings (all effects off)")
        } catch { note("Could not load defaults: \(error.localizedDescription)", isError: true) }
    }

    func savePreset(_ name: String) {
        do {
            try presetStore.save(as: name)
            refreshPresets()
            selectedPreset = name
            note("Saved preset \"\(name)\"")
        } catch { note("Could not save: \(error.localizedDescription)", isError: true) }
    }

    func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "JDSP4Linux .conf / .jdsp, RootlessJamesDSP .tar, or JamesDSP for Android james.dsp.<output>.xml"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let (name, notes) = try presetStore.importPreset(from: url)
            refreshPresets()
            selectedPreset = name
            note("Imported \"\(name)\"")
            notes.forEach { note($0) }
        } catch { note("Import failed: \(error)", isError: true) }
    }

    func exportPreset(_ name: String, rootless: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + (rootless ? ".tar" : ".conf")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let notes = try presetStore.export(name, to: url, format: rootless ? .rootless : .linux)
            note("Exported \"\(name)\" to \(url.lastPathComponent)")
            notes.forEach { note($0) }
        } catch { note("Export failed: \(error)", isError: true) }
    }

    func rules() -> [PresetStore.Rule] { presetStore.rules() }

    // MARK: Excluded apps

    func excludeApp(_ bundleID: String) {
        guard !excludedApps.contains(bundleID) else { return }
        setExcludedApps(excludedApps + [bundleID])
    }

    func includeApp(_ bundleID: String) {
        setExcludedApps(excludedApps.filter { $0 != bundleID })
    }

    private func setExcludedApps(_ list: [String]) {
        excludedApps = list
        excludedStore.save(list)
        engine.setExcludedApps(list)
    }

    func removeRule(deviceUID: String) {
        guard let rule = presetStore.rule(forDevice: deviceUID) else { return }
        presetStore.setRule(deviceUID: deviceUID, deviceName: rule.deviceName, preset: nil)
        if deviceUID == outputUID { ruleForOutput = nil }
    }

    func setRuleForOutput(_ preset: String?) {
        guard let uid = outputUID else { return }
        presetStore.setRule(deviceUID: uid, deviceName: outputName ?? uid, preset: preset)
        ruleForOutput = preset
        note(preset.map { "\"\($0)\" will load whenever \(outputName ?? uid) becomes the output" } ?? "No preset rule for \(outputName ?? uid)")
    }

    @ObservationIgnored private var state: EngineState = .stopped("")
    @ObservationIgnored private var lastStatus: AppStatus?
    /// Off for --snapshot-panel runs, which must not replace a running app's status.
    @ObservationIgnored private let writesStatus = !EngineController.renderingOnly

    /// Runs that only render images (--snapshot-panel, --screenshots): never autostart from the
    /// saved power state, never write status.json.
    static let renderingOnly = CommandLine.arguments.contains("--snapshot-panel") || CommandLine.arguments.contains("--screenshots")

    // MARK: Screenshot demo

    @ObservationIgnored private var demoMode = false
    @ObservationIgnored private var demoProfile: AutoEQProfile?

    /// --screenshots only: a tidy setup shown and processed but never saved (audio.conf, presets,
    /// excluded-apps.txt and preferences stay as they are).
    private func showDemo() {
        var s = settings
        s.masterEnable = true
        s.postGain = 0
        s.bassEnable = true; s.bassMaxGain = 6
        s.toneEnable = true; s.toneFilterType = 0
        s.toneEQ = Bands.join(Bands.eqFrequencies, [4, 3.5, 3, 2, 1, 0, -1, -1.5, -1, 0, 1, 2, 3, 3.5, 3])
        s.graphicEQEnable = true
        s.companderEnable = false
        s.reverbEnable = false
        s.convolverEnable = false; s.convolverFile = ""
        s.crossfeedEnable = true; s.crossfeedMode = 2
        s.stereowideEnable = false
        s.ddcEnable = false; s.ddcFile = ""
        s.tubeEnable = false
        s.liveprogEnable = false; s.liveprogFile = "dynamicbass.eel"
        demoMode = true
        settings = s
        currentPreset = "Everyday"
        ruleForOutput = "Everyday"
        demoProfile = AutoEQProfile(name: "Sennheiser HD 600", source: "oratory1990")
        excludedApps = ["com.apple.Music", "com.apple.FaceTime"]
        engine.apply(settings: s)
        updateIcon()
    }
    @ObservationIgnored private var info: JDLiveInfo?

    /// Keeps status.json (read by jdspctl) in step with what the panel shows.
    private func writeStatus() {
        guard writesStatus else { return }
        let name: String = switch state {
        case .stopped: "off"
        case .starting: "starting"
        case .running: settings.masterEnable ? "processing" : "bypassed"
        case .passthrough: "not processing"
        case .waitingForPermission, .permissionProblem: "permission problem"
        case .failed: "failed"
        }
        var running = false
        if case .running = state { running = true }
        let status = AppStatus(pid: getpid(), state: name, detail: status.text, output: outputName,
                               sampleRate: running ? info?.sampleRate : nil, bufferFrames: running ? info?.bufferFrames : nil,
                               problems: problems)
        guard status != lastStatus else { return }
        lastStatus = status
        status.write()
    }

    private func updateIcon() {
        defer { writeStatus() }
        switch state {
        case .stopped:
            iconState = .bypassed; status = ("Off", false)
        case .starting:
            iconState = settings.masterEnable ? .on : .bypassed; status = ("Starting…", false)
        case .running:
            iconState = settings.masterEnable ? .on : .bypassed
            status = settings.masterEnable ? ("Processing", false) : ("Bypassed: effects off", false)
        case .passthrough(let why):
            iconState = .bypassed; status = ("Not processing: \(why)", false)
        case .waitingForPermission:
            iconState = .problem; status = ("Waiting for the audio-capture permission prompt", true)
        case .permissionProblem:
            iconState = .problem
            status = ("No audio from the tap. Allow jdsp4mac in System Settings › Privacy & Security › Screen & System Audio Recording.", true)
        case .failed(let why):
            iconState = .problem; status = ("Stopped: \(why)", true)
        }
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    /// Shows a one-off message: 4 s for confirmations, 8 s for errors.
    private func note(_ text: String, isError: Bool = false) {
        Log.write("ui: \(text)")
        history = Array((history + [text]).suffix(30))
        let notice = Notice(text: text, isError: isError)
        notices = Array((notices + [notice]).suffix(3))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 8 : 4))
            self?.notices.removeAll { $0.id == notice.id }
        }
    }

    private func apply(_ snap: EngineSnapshot) {
        info = snap.info
        // Problems belong to a live instance; when not processing there is none.
        let current = isActiveState(snap.state) ? snap.problems : []
        if current != problems { problems = current }
        let output = snap.messages.suffix(10)
        if Array(output) != engineOutput {
            engineOutput = Array(output)
            history = Array((history.filter { !$0.hasPrefix("output: ") } + engineOutput).suffix(30))
        }
        if snap.outputUID != nil { setOutput(uid: snap.outputUID, name: snap.outputName) }
        if let uid = snap.outputUID, uid != lastOutputUID {
            lastOutputUID = uid
            // Render-only runs must not write anything, so no preset rules there.
            if !Self.renderingOnly, let rule = presetStore.rule(forDevice: uid) {
                note("Output \(snap.outputName ?? uid): loading its preset \"\(rule.preset)\"")
                loadPreset(rule.preset)
            }
        }
        state = snap.state
        switch snap.state {
        case .stopped(let why): statusText = "Stopped (\(why))"; isActive = false
        case .starting(let what): statusText = "Starting: \(what)"; isActive = true
        case .waitingForPermission: statusText = "Waiting for audio-capture permission (see the macOS prompt)"; isActive = true
        case .running(let output, _, _): statusText = "Running (\(mode == .dsp ? "DSP" : "passthrough")) on \(output)"; isActive = true
        case .passthrough(let why): statusText = "Not processing: \(why)"; isActive = true
        case .permissionProblem: statusText = "No audio from the tap: check System Settings > Privacy & Security > Screen & System Audio Recording"; isActive = true
        case .failed(let why): statusText = "Failed: \(why)"; isActive = false
        }
        updateIcon()
        guard let s = snap.stats, let info = snap.info else {
            lines = ["rebuilds \(snap.rebuilds)" + (snap.lastRebuildReason.isEmpty ? "" : " (last: \(snap.lastRebuildReason))")]
            return
        }
        let wall = max(s.lastHostSeconds - s.firstHostSeconds, 1e-9)
        lines = [
            String(format: "%.0f Hz, %u frames (%.2f ms), tap %u ch", info.sampleRate, info.bufferFrames,
                   Double(info.bufferFrames) / info.sampleRate * 1000, info.tapChannels),
            "callbacks \(s.callbacks)  discontinuities \(s.outputDiscontinuities)/\(s.inputDiscontinuities)  overloads \(s.overloads)",
            String(format: "IOProc CPU %.2f%%  max %.3f ms  tap→out %.1f ms", s.busySeconds / wall * 100,
                   s.maxCallbackSeconds * 1000, s.lastLatencySeconds * 1000),
            String(format: "peak in %.3f out %.3f  others playing: %@", s.inPeak, s.outPeak, snap.othersPlaying ? "yes" : "no"),
            "rebuilds \(snap.rebuilds)" + (snap.lastRebuildReason.isEmpty ? "" : " (last: \(snap.lastRebuildReason))"),
        ]
    }
}
