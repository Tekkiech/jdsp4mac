import AudioCore
import Config
import CoreAudio
import Foundation
import os

public enum LiveMode: Sendable {
    case passthrough  // tap -> output, no DSP
    case dsp          // tap -> libjamesdsp with the current settings -> output
}

public enum EngineState: Sendable, Equatable {
    case stopped(String)
    case starting(String)
    case waitingForPermission
    case running(output: String, sampleRate: Double, bufferFrames: UInt32)
    /// The output cannot be processed (v1 limits). No tap exists, so apps play directly.
    case passthrough(String)
    /// The tap kept delivering exact zeros after apps started playing, even after a rebuild.
    /// The tap is removed so apps play directly.
    case permissionProblem
    case failed(String)
}

extension JDLiveStats: @retroactive @unchecked Sendable {}
extension JDLiveInfo: @retroactive @unchecked Sendable {}

public struct EngineSnapshot: Sendable {
    public var state: EngineState
    public var stats: JDLiveStats?
    public var info: JDLiveInfo?
    public var rebuilds: Int
    public var lastRebuildReason: String
    public var othersPlaying: Bool
    /// Problems with the settings the live instance was built from (missing files, liveprog
    /// errors, malformed values). Replaced by every build, so a fixed problem disappears.
    public var problems: [String]
    /// Recent libjamesdsp / liveprog printf output, newest last.
    public var messages: [String]
    /// The system default output this snapshot refers to (also in passthrough), for preset rules.
    public var outputUID: String?
    public var outputName: String?
}

/// The real-time engine's control plane. Owns the tap, the private aggregate and the C IOProc.
/// All HAL lifecycle work runs on one serial queue, because several of those calls can block for a
/// long time (permission prompt, coreaudiod timeouts); the UI only ever sees published snapshots.
public final class AudioEngine: @unchecked Sendable {
    public static let aggregatePrefix = "jdsp4mac-"

    /// Unchecked Sendable: a graph has exactly one owner at a time. The engine queue owns the live
    /// graph; detachGraph() hands it over whole (to the reaper or to teardown), never shared.
    private struct Graph: @unchecked Sendable {
        var tap = AudioObjectID(kAudioObjectUnknown)
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var live: OpaquePointer?
        var defaultDevice = AudioObjectID(kAudioObjectUnknown)  // what the system reported
        var outputDevice = AudioObjectID(kAudioObjectUnknown)   // the real device we wrap
        var outputName = ""
        var info = JDLiveInfo()
        var slot: Int32 = -1  // crash-cleanup registry slot
        var generation = 0    // identifies this graph to DSP builds started for it
        var tapDescription: CATapDescription?  // kept to change the exclusion list live
        var selfObject = AudioObjectID(kAudioObjectUnknown)
    }

    private struct PermissionDenied: Error {}

    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let queue = DispatchQueue(label: "tech.tekkiech.jdsp4mac.engine", qos: .userInitiated)
    /// HAL listener blocks run here and only forward to `queue`. They must never run on `queue`
    /// itself: the engine queue blocks during builds, and a new tap is not usable in this process
    /// until the HAL has delivered its notifications (observed: tap format unreadable for as long
    /// as the listener queue was blocked).
    private let listenerQueue = DispatchQueue(label: "tech.tekkiech.jdsp4mac.hal-listeners")
    /// Old graphs are destroyed here after a make-before-break rebuild. Stopping an IOProc on a
    /// device macOS has just switched away from took 1.1-1.2 s (speakers -> headphones), which must
    /// not delay the new graph.
    private let reaper = DispatchQueue(label: "tech.tekkiech.jdsp4mac.reaper")
    /// Builds DSP instances for settings changes. Separate from the engine queue so a slow build
    /// (IR load, HRTF, liveprog compile) never delays device handling.
    private let builderQueue = DispatchQueue(label: "tech.tekkiech.jdsp4mac.dsp-builder", qos: .userInitiated)
    private let latestSettingsVersion = OSAllocatedUnfairLock(initialState: 0)
    private let library: FileLibrary
    private let publish: @Sendable (EngineSnapshot) -> Void
    private let statsLogEvery: Int
    private var testZeroInput: Bool

    // Engine-queue state.
    private var wantRunning = false
    private var sleeping = false  // torn down for system sleep; ignore HAL events until wake
    private var mode: LiveMode = .dsp
    private var bypass = false
    private var settings = DSPSettings.defaults
    private var settingsVersion = 0
    private var graphGeneration = 0
    private var messages: [String] = []
    private var problems: [String] = []
    /// Apps left out of the tap (they play directly, unprocessed), and their current processes.
    private var excludedBundleIDs: [String] = []
    private var excludedObjects: [AudioObjectID] = []
    private var excludedPIDs: Set<pid_t> = []
    private var pendingExclusionUpdate: DispatchWorkItem?
    private var effectiveBypass: Bool { bypass || !settings.masterEnable }
    private var currentOutput: (uid: String, name: String)?
    private var graph: Graph?
    private var unsupportedDefault: AudioObjectID?  // passthrough state: device we decided not to process
    private var state: EngineState = .stopped("not started")
    private var graphListeners: [Listener] = []
    private var systemListeners: [Listener] = []
    private var pendingCheck: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var rebuilds = 0
    private var retryCount = 0
    private var lastReason = ""
    private var ticks = 0
    private var lastCallbacks: UInt64 = 0
    private var stalledSeconds = 0
    private var lastStats: JDLiveStats?
    // Zeroed-tap watchdog.
    private var outputProcesses = Set<pid_t>()
    private var outputStarts: [pid_t: Date] = [:]
    private var zeroSince: Date?
    /// Set by the permission probe (or by real audio arriving). Capture permission is granted, so
    /// later all-zero episodes cannot be a denial, only the HAL glitch that a rebuild fixes.
    private var permissionConfirmed = false
    private var lastZeroRebuild = Date.distantPast
    private var othersPlaying = false
    // Blocking-call watchdog (touched from the engine queue and a global timer).
    private let blockedCall = OSAllocatedUnfairLock<UUID?>(initialState: nil)

    public init(statsLogEvery: Int = 10, testZeroInput: Bool = false, testSkipProbe: Bool = false,
                library: FileLibrary = .standard, publish: @escaping @Sendable (EngineSnapshot) -> Void) {
        self.library = library
        self.statsLogEvery = max(1, statsLogEvery)
        self.testZeroInput = testZeroInput
        self.permissionConfirmed = testSkipProbe  // test hook only
        self.publish = publish
        queue.async { self.installSystemListeners() }
    }

    // MARK: - Public API (any thread)

    /// Crash handlers and removal of aggregates left by a previous run. Call once at launch.
    public static func prepareProcess() {
        jd_cleanup_install()
        for device in (try? HAL.deviceList()) ?? [] {
            guard (try? HAL.u32(device, kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeAggregate,
                  let name = try? HAL.string(device, kAudioObjectPropertyName),
                  name.hasPrefix(aggregatePrefix) else { continue }
            let err = AudioHardwareDestroyAggregateDevice(device)
            Log.write("launch sweep: destroyed leftover aggregate \(name) (\(device)): \(err)")
        }
    }

    public func start(mode: LiveMode) {
        queue.async {
            self.wantRunning = true
            self.mode = mode
            self.rebuild(reason: "start")
        }
    }

    public func stop() {
        queue.async {
            self.wantRunning = false
            self.teardown(fade: true)
            self.unsupportedDefault = nil
            self.setState(.stopped("stopped"))
        }
    }

    /// Synchronous stop for quit, signals and sleep. Waits at most `timeout`.
    public func stopAndWait(timeout: TimeInterval, keepRunningIntent: Bool = false) {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            if keepRunningIntent { self.sleeping = true } else { self.wantRunning = false }
            self.pendingCheck?.cancel()
            self.teardown(fade: true)
            self.reaper.sync {}  // retired graphs too
            self.setState(keepRunningIntent ? .starting("paused (system sleep)") : .stopped("stopped"))
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            Log.write("stopAndWait timed out after \(timeout) s; panicking")
            jd_panic()
        }
    }

    public func setBypass(_ on: Bool) {
        queue.async {
            self.bypass = on
            if let live = self.graph?.live { jd_live_set_bypass(live, self.effectiveBypass ? 1 : 0) }
        }
    }

    /// Applies a full settings snapshot: builds a new DSP instance off the audio thread and lets
    /// the IOProc crossfade to it. Rapid calls coalesce; only the newest snapshot is built.
    public func apply(settings new: DSPSettings) {
        queue.async {
            guard new != self.settings else { return }
            self.settings = new
            if let live = self.graph?.live { jd_live_set_bypass(live, self.effectiveBypass ? 1 : 0) }
            self.scheduleDSPBuild()
        }
    }

    /// Rebuilds with the same settings, re-reading the liveprog script, impulse response and DDC.
    public func reloadFiles() {
        queue.async { self.scheduleDSPBuild() }
    }

    private func scheduleDSPBuild() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard mode == .dsp, let g = graph, g.live != nil else { return }
        settingsVersion += 1
        let version = settingsVersion, generation = g.generation
        let snapshot = settings, library = self.library
        let frames = g.info.bufferFrames, rate = g.info.sampleRate
        latestSettingsVersion.withLock { $0 = version }
        builderQueue.async { [weak self] in
            guard let self else { return }
            // Skip snapshots that were superseded while waiting.
            guard self.latestSettingsVersion.withLock({ $0 == version }) else { return }
            let built = DSPBuilder.build(snapshot, library: library, blockFrames: frames, sampleRate: rate)
            self.queue.async {
                let current = self.graph
                if let live = current?.live, current?.generation == generation, version == self.settingsVersion, let dsp = built.dsp {
                    jd_live_post_dsp(live, dsp)
                    Log.write(String(format: "settings v%d applied: DSP built in %.3f s", version, built.seconds))
                    self.setProblems(built.messages)
                } else {
                    if let dsp = built.dsp { jd_dsp_free(dsp) }  // graph changed or newer settings exist
                }
            }
        }
    }

    private func addMessages(_ new: [String]) {
        guard !new.isEmpty else { return }
        for m in new { Log.write("dsp: \(m)") }
        messages = Array((messages + new).suffix(20))
        publishSnapshot()
    }

    private func setProblems(_ notes: [String]) {
        for m in notes where !problems.contains(m) { Log.write("dsp: \(m)") }
        guard notes != problems else { return }
        if notes.isEmpty { Log.write("dsp: problems cleared") }
        problems = notes
        publishSnapshot()
    }

    /// Test hook: force the tap input to zeros (simulates a denied or broken tap).
    /// Apps (bundle IDs) to leave out of the tap; they play directly, unprocessed. A bundle ID also
    /// matches its helpers (`<id>.*`). Takes effect on the running tap without a rebuild.
    public func setExcludedApps(_ bundleIDs: [String]) {
        if !bundleIDs.isEmpty && !Responsibility.isAvailable {
            Log.write("exclusions: responsible-process lookup unavailable; matching by bundle ID only (WebKit apps such as Safari cannot be excluded)")
        }
        queue.async {
            guard bundleIDs != self.excludedBundleIDs else { return }
            self.excludedBundleIDs = bundleIDs
            self.updateExclusions()
        }
    }

    private func excludedProcesses() -> [(object: AudioObjectID, pid: pid_t, bundleID: String)] {
        guard !excludedBundleIDs.isEmpty else { return [] }
        let me = getpid()
        func matches(_ id: String?) -> Bool {
            guard let id, !id.isEmpty else { return false }
            return excludedBundleIDs.contains { id == $0 || id.hasPrefix($0 + ".") }
        }
        // A process belongs to an excluded app if it is the app or one of its helpers, or if the
        // app is responsible for it (Safari's com.apple.WebKit.GPU process).
        return HAL.audioProcesses().filter { p in
            p.pid != me && (matches(p.bundleID) || matches(p.owner))
        }.map { p in (p.object, p.pid, p.owner.map { "\(p.bundleID) for \($0)" } ?? p.bundleID) }
    }

    private func scheduleExclusionUpdate() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !excludedBundleIDs.isEmpty || !excludedObjects.isEmpty else { return }
        pendingExclusionUpdate?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.updateExclusions() }
        pendingExclusionUpdate = item
        queue.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    /// Rewrites the live tap's exclusion list if the excluded apps' processes changed. The tap
    /// description is settable on an existing tap (AudioHardware.h, kAudioTapPropertyDescription);
    /// if the HAL refuses, rebuild instead.
    private func updateExclusions() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard var g = graph, let description = g.tapDescription else { return }
        let excluded = excludedProcesses()
        let objects = excluded.map(\.object)
        guard Set(objects) != Set(excludedObjects) else { return }
        let t0 = Date()
        description.processes = [g.selfObject] + objects
        var addr = HAL.address(kAudioTapPropertyDescription)
        // The property's data is the description object reference itself (a CFTypeRef).
        var ref = Unmanaged.passUnretained(description).toOpaque()
        let err = AudioObjectSetPropertyData(g.tap, &addr, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &ref)
        excludedObjects = objects
        excludedPIDs = Set(excluded.map(\.pid))
        g.tapDescription = description
        graph = g
        let names = excluded.map(\.bundleID).joined(separator: ", ")
        if err == noErr {
            Log.write(String(format: "exclusions applied live in %.1f ms: %@", Date().timeIntervalSince(t0) * 1000,
                             names.isEmpty ? "none" : names))
        } else {
            rebuild(reason: "could not change the tap's exclusions live (\(err))")
        }
    }

    public func setTestZeroInput(_ on: Bool) {
        queue.async {
            self.testZeroInput = on
            if let live = self.graph?.live { jd_live_set_test_zero_input(live, on ? 1 : 0) }
            Log.write("TEST MODE: tap input forced to zero \(on ? "on" : "off")")
        }
    }

    public func systemDidWake() {
        queue.async {
            self.sleeping = false
            // Short delay for devices to come back; a build that fails anyway retries on its own.
            self.queue.asyncAfter(deadline: .now() + 0.2) {
                if self.wantRunning && !self.sleeping && self.graph == nil { self.rebuild(reason: "system wake") }
            }
        }
    }

    /// Destroys the tap and aggregate immediately (any thread), then cleans up on the queue.
    public func panic() {
        jd_panic()
        Log.write("panic: tap and aggregate destroyed")
        queue.async {
            self.wantRunning = false
            if let g = self.detachGraph(), let live = g.live { jd_live_destroy(live) }  // device already gone: just frees
            self.setState(.stopped("panic"))
        }
    }

    // MARK: - Build and teardown (engine queue)

    private func rebuild(reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingCheck?.cancel()
        pendingCheck = nil
        rebuilds += 1
        lastReason = reason
        Log.write("rebuild #\(rebuilds): \(reason)")
        // Make before break once permission is confirmed (a build then cannot sit behind a
        // permission prompt): fade the old graph to silence, build the new one, and destroy the
        // old one in the background. Otherwise tear down first.
        if permissionConfirmed && wantRunning, let old = detachGraph() {
            build(attempt: 0)
            let t0 = Date()
            reaper.async { Self.destroy(old, fade: true, label: "retired", since: t0) }
        } else {
            teardown(fade: true)
            guard wantRunning else { return }
            build(attempt: 0)
        }
    }

    private func build(attempt: Int) {
        unsupportedDefault = nil
        setState(.starting("building"))
        let t0 = Date()
        var g = Graph()
        do {
            g.defaultDevice = try HAL.defaultOutputDevice()
            if let uid = try? HAL.string(g.defaultDevice, kAudioDevicePropertyDeviceUID) {
                currentOutput = (uid, HAL.name(g.defaultDevice))
            }
            switch resolveOutput(g.defaultDevice) {
            case .failure(let why):
                unsupportedDefault = g.defaultDevice
                installUnsupportedListeners(g.defaultDevice)
                Log.write("not processing \"\(HAL.name(g.defaultDevice))\": \(why); apps play directly")
                setState(.passthrough(why.description))
                return
            case .success(let device):
                g.outputDevice = device
            }
            g.outputName = HAL.name(g.defaultDevice)
            let outputUID = try HAL.string(g.outputDevice, kAudioDevicePropertyDeviceUID)
            let transport = (try? HAL.u32(g.outputDevice, kAudioDevicePropertyTransportType)) ?? 0
            let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE

            // Our output goes through the aggregate, so exclude ourselves from the global tap or we
            // capture our own output (feedback). Refuse to run if we cannot identify ourselves.
            let selfObject = try HAL.processObject(pid: getpid())
            guard selfObject != kAudioObjectUnknown else {
                throw LiveError("no Core Audio process object for this process; refusing to tap (feedback risk)")
            }
            if !permissionConfirmed {
                try probePermission(outputUID: outputUID, selfObject: selfObject)
            }

            let excluded = excludedProcesses()
            let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObject] + excluded.map(\.object))
            g.tapDescription = tapDescription
            g.selfObject = selfObject
            excludedObjects = excluded.map(\.object)
            excludedPIDs = Set(excluded.map(\.pid))
            if !excluded.isEmpty { Log.write("excluding \(excluded.count) app process(es): \(excluded.map(\.bundleID).joined(separator: ", "))") }
            tapDescription.uuid = UUID()
            tapDescription.name = "jdsp4mac"
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .mutedWhenTapped
            var tap = AudioObjectID(kAudioObjectUnknown)
            let tapErr = AudioHardwareCreateProcessTap(tapDescription, &tap)
            guard tapErr == noErr else { throw LiveError("AudioHardwareCreateProcessTap failed: \(tapErr)") }
            g.tap = tap
            graph = g  // from here on, teardown() cleans up whatever exists

            // Defensive: a new tap's format was unreadable while HAL notifications could not be
            // delivered (root cause fixed: listeners have their own queue). Wait briefly anyway.
            var tapFormat = AudioStreamBasicDescription()
            let tapDeadline = Date().addingTimeInterval(2.0)
            var tapWaits = 0
            var lastTapError = ""
            while true {
                do {
                    try HAL.read(tap, kAudioTapPropertyFormat, &tapFormat)
                    if tapFormat.mSampleRate > 0 { break }
                    lastTapError = "sample rate 0"
                } catch {
                    lastTapError = "\(error)"
                }
                guard Date() < tapDeadline else { throw LiveError("tap format not readable after 2 s (\(lastTapError))") }
                tapWaits += 1
                usleep(20_000)
            }
            if tapWaits > 0 { Log.write("tap format readable after \(tapWaits * 20) ms") }

            let aggregateUID = Self.aggregatePrefix + UUID().uuidString
            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: aggregateUID,
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceClockDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: !isBluetooth,
                ]],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            let aggErr = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
            guard aggErr == noErr else { throw LiveError("AudioHardwareCreateAggregateDevice failed: \(aggErr)") }
            g.aggregate = aggregate
            g.slot = jd_cleanup_track(aggregate, tap)
            graph = g

            let deadline = Date().addingTimeInterval(2.0)
            while !HAL.isAlive(aggregate) {
                guard Date() < deadline else { throw LiveError("aggregate device not alive after 2 s") }
                usleep(10_000)
            }

            var dsp: OpaquePointer?
            if mode == .dsp {
                let rate = try HAL.f64(aggregate, kAudioDevicePropertyNominalSampleRate)
                let frames = try HAL.u32(aggregate, kAudioDevicePropertyBufferFrameSize)
                let built = DSPBuilder.build(settings, library: library, blockFrames: frames, sampleRate: rate)
                dsp = built.dsp
                Log.write(String(format: "DSP built in %.3f s for %.0f Hz / %u frames", built.seconds, rate, frames))
                setProblems(built.messages)
            }
            var err = [CChar](repeating: 0, count: 256)
            let live = jd_live_create(aggregate, tap, dsp, &err, err.count)
            guard let live else {
                throw LiveError("jd_live_create: " + String(decoding: err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            g.live = live
            graphGeneration += 1
            g.generation = graphGeneration
            jd_live_get_info(live, &g.info)
            jd_live_set_bypass(live, effectiveBypass ? 1 : 0)
            if testZeroInput { jd_live_set_test_zero_input(live, 1) }
            graph = g
            setState(.starting("starting audio"))

            let status = watchBlocking(after: 5.0, report: .starting("waiting for macOS audio service (another app capturing system audio, or permission just granted)")) {
                jd_live_start(live)
            }
            guard status == noErr else { throw LiveError("AudioDeviceStart failed: \(status)") }

            installGraphListeners(g)
            resetWatchdogs()
            startTimer()
            let i = g.info
            Log.write(String(format: "running on \"%@\"%@: %.0f Hz, %u frames, tap %u ch, drift comp %@, out latency %u + safety %u, in latency %u + safety %u, mode %@, built in %.3f s",
                             g.outputName, g.outputDevice == g.defaultDevice ? "" : " (via \"\(HAL.name(g.outputDevice))\")",
                             i.sampleRate, i.bufferFrames, i.tapChannels, isBluetooth ? "off" : "on",
                             i.outputLatencyFrames, i.outputSafetyOffsetFrames, i.inputLatencyFrames, i.inputSafetyOffsetFrames,
                             mode == .dsp ? "dsp" : "passthrough", Date().timeIntervalSince(t0)))
            retryCount = 0
            setState(.running(output: g.outputName, sampleRate: i.sampleRate, bufferFrames: i.bufferFrames))
        } catch is PermissionDenied {
            teardown(fade: false)
            Log.write("capture permission denied: not tapping, apps play directly")
            setState(.permissionProblem)
        } catch {
            Log.write("build failed (attempt \(attempt + 1)): \(error)")
            teardown(fade: false)
            // Observed on macOS 27: in the process where permission was just granted, coreaudiod
            // times out the first start. One full rebuild fixes it; a second failure is real.
            if attempt == 0 && wantRunning {
                usleep(500_000)
                build(attempt: 1)
            } else {
                setState(.failed("\(error)"))
                scheduleRetry()
            }
        }
    }

    /// After a failed build, try again later instead of waiting for some unrelated HAL event.
    private func scheduleRetry() {
        let delays: [Double] = [3, 10, 30]
        guard retryCount < delays.count else {
            Log.write("giving up after \(retryCount) retries; waiting for a device change or Start")
            return
        }
        let delay = delays[retryCount]
        retryCount += 1
        let generation = rebuilds
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantRunning, self.graph == nil, self.rebuilds == generation else { return }
            self.rebuild(reason: "retry \(self.retryCount) after failure")
        }
    }

    /// Detaches the current graph (listeners, timer) and asks its IOProc to fade to silence.
    private func detachGraph() -> Graph? {
        dispatchPrecondition(condition: .onQueue(queue))
        stopTimer()
        removeGraphListeners()
        guard let g = graph else { return nil }
        graph = nil
        if let live = g.live { jd_live_fade_out(live) }
        return g
    }

    private func teardown(fade: Bool) {
        guard let g = detachGraph() else { return }
        Self.destroy(g, fade: fade, label: "teardown", since: Date())
    }

    /// Destroys a detached graph. Engine queue (teardown) or reaper queue (retired graphs).
    private static func destroy(_ g: Graph, fade: Bool, label: String, since t0: Date) {
        if let live = g.live {
            if fade {
                let deadline = Date().addingTimeInterval(0.06)
                while jd_live_faded_out(live) == 0 && Date() < deadline { usleep(2_000) }
            }
            jd_live_destroy(live)  // AudioDeviceStop + AudioDeviceDestroyIOProcID
        }
        let t1 = Date()
        jd_cleanup_untrack(g.slot)
        if g.aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(g.aggregate) }
        let t2 = Date()
        if g.tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(g.tap) }
        let t3 = Date()
        Log.write(String(format: "%@: fade+IOProc %.1f ms, aggregate %.1f ms, tap %.1f ms", label,
                         t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, t3.timeIntervalSince(t2) * 1000))
    }

    /// Plays an inaudible tone through a private, unmuted tap of this process only and checks that
    /// the tap hears it. Exact zeros mean capture is denied. Never mutes other apps.
    private func probePermission(outputUID: String, selfObject: AudioObjectID) throws {
        let t0 = Date()
        let description = CATapDescription(stereoMixdownOfProcesses: [selfObject])
        description.uuid = UUID()
        description.name = "jdsp4mac probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(description, &tap)
        guard tapErr == noErr else { throw LiveError("probe tap failed: \(tapErr)") }
        defer { AudioHardwareDestroyProcessTap(tap) }
        let uid = Self.aggregatePrefix + "probe-" + UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: uid,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggErr == noErr else { throw LiveError("probe aggregate failed: \(aggErr)") }
        let slot = jd_cleanup_track(aggregate, tap)
        defer {
            jd_cleanup_untrack(slot)
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        let deadline = Date().addingTimeInterval(2.0)
        while !HAL.isAlive(aggregate) {
            guard Date() < deadline else { throw LiveError("probe aggregate not alive after 2 s") }
            usleep(10_000)
        }
        var status: OSStatus = noErr
        let testZero = testZeroInput
        // The first IOProc on a tap aggregate is where macOS shows the permission prompt.
        let peak = watchBlocking(after: 1.0, report: .waitingForPermission) {
            jd_probe_run(aggregate, 0.5, testZero ? 1 : 0, &status)
        }
        guard status == noErr else { throw LiveError("probe IO failed: \(status)") }
        Log.write(String(format: "permission probe: peak %.2e (%@) in %.3f s", peak,
                         peak > 0 ? "heard our -100 dBFS tone: granted" : "exact zeros: denied", Date().timeIntervalSince(t0)))
        guard peak > 0 else { throw PermissionDenied() }
        permissionConfirmed = true
    }

    /// The device to wrap, or why the default output cannot be processed in v1.
    private func resolveOutput(_ device: AudioObjectID) -> Result<AudioObjectID, LiveError> {
        var candidate = device
        if (try? HAL.u32(device, kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeAggregate {
            // Aggregates cannot be nested inside ours. Unwrap a single-output aggregate.
            let outputs = HAL.activeSubDevices(device).filter { HAL.outputChannels($0) > 0 }
            guard outputs.count == 1 else {
                return .failure(LiveError("output is an aggregate of \(outputs.count) output devices"))
            }
            candidate = outputs[0]
        }
        let channels = HAL.outputChannels(candidate)
        guard channels == 2 else { return .failure(LiveError("\(channels)-channel output (v1 processes stereo only)")) }
        guard HAL.outputIsFloat32(candidate) else { return .failure(LiveError("output format is not float32")) }
        return .success(candidate)
    }

    /// Runs a call that may block on coreaudiod; if it is still running after `after` seconds,
    /// publishes `report` so the UI can say why.
    private func watchBlocking<T>(after seconds: Double, report: EngineState, _ body: () -> T) -> T {
        let token = UUID()
        blockedCall.withLock { $0 = token }
        // Captured here, on the engine queue: the timer must not read engine state.
        let snap = EngineSnapshot(state: report, stats: nil, info: nil, rebuilds: rebuilds,
                                  lastRebuildReason: lastReason, othersPlaying: othersPlaying, problems: problems, messages: messages,
                                  outputUID: currentOutput?.uid, outputName: currentOutput?.name)
        let deliver = publish
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [blockedCall] in
            if blockedCall.withLock({ $0 == token }) {
                Log.write("still blocked after \(seconds) s: \(report)")
                DispatchQueue.main.async { deliver(snap) }
            }
        }
        defer { blockedCall.withLock { $0 = nil } }
        return body()
    }

    // MARK: - Change detection (engine queue)

    private func installSystemListeners() {
        addListener(HAL.system, kAudioHardwarePropertyDefaultOutputDevice, into: &systemListeners)
        addListener(HAL.system, kAudioHardwarePropertyDevices, into: &systemListeners)
    }

    private func installGraphListeners(_ g: Graph) {
        for device in Set([g.outputDevice, g.defaultDevice]) {
            addListener(device, kAudioDevicePropertyDeviceIsAlive, into: &graphListeners)
            addListener(device, kAudioDevicePropertyNominalSampleRate, into: &graphListeners)
            addListener(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput, into: &graphListeners)
            addListener(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, into: &graphListeners)
        }
        if g.defaultDevice != g.outputDevice {
            addListener(g.defaultDevice, kAudioAggregateDevicePropertyActiveSubDeviceList, into: &graphListeners)
        }
        addListener(g.aggregate, kAudioDevicePropertyDeviceIsAlive, into: &graphListeners)
        addListener(g.aggregate, kAudioDevicePropertyBufferFrameSize, into: &graphListeners)
        addListener(g.aggregate, kAudioDevicePropertyNominalSampleRate, into: &graphListeners)
        // Apps start and quit: keep excluded apps' processes out of the tap.
        addListener(HAL.system, kAudioHardwarePropertyProcessObjectList, into: &graphListeners) { engine in
            engine.scheduleExclusionUpdate()
        }
    }

    private func installUnsupportedListeners(_ device: AudioObjectID) {
        addListener(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput, into: &graphListeners)
        addListener(device, kAudioDevicePropertyDeviceIsAlive, into: &graphListeners)
    }

    /// `action` runs on the engine queue; by default a (debounced) graph validity check.
    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into list: inout [Listener],
                             action: (@Sendable (AudioEngine) -> Void)? = nil) {
        var addr = HAL.address(selector, scope)
        let engineQueue = queue
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let engine = self else { return }
            engineQueue.async {
                if let action { action(engine) } else { engine.scheduleCheck(cause: "\(HAL.fourCC(selector)) on \(object)") }
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &addr, listenerQueue, block) == noErr {
            list.append(Listener(object: object, address: addr, block: block))
        }
    }

    private func removeGraphListeners() {
        for var l in graphListeners {
            AudioObjectRemovePropertyListenerBlock(l.object, &l.address, listenerQueue, l.block)
        }
        graphListeners.removeAll()
    }

    /// Listener events only schedule a validity check (debounced). A rebuild happens only if the
    /// running graph no longer matches the system, so our own HAL activity cannot cause loops.
    private func scheduleCheck(cause: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.checkGraph(cause: cause) }
        pendingCheck = item
        queue.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func checkGraph(cause: String) {
        guard wantRunning, !sleeping else { return }
        let currentDefault = (try? HAL.defaultOutputDevice()) ?? AudioObjectID(kAudioObjectUnknown)
        if let unsupported = unsupportedDefault {
            if currentDefault != unsupported || !HAL.isAlive(unsupported)
                || resolveOutput(unsupported).isSuccess {
                rebuild(reason: "output changed (\(cause))")
            }
            return
        }
        guard let g = graph else {
            if case .permissionProblem = state { return }  // stay passive until the user acts
            rebuild(reason: "no graph (\(cause))")
            return
        }
        var why: String?
        if currentDefault != g.defaultDevice {
            why = "default output changed to \"\(HAL.name(currentDefault))\""
        } else if !HAL.isAlive(g.outputDevice) || !HAL.isAlive(g.aggregate) {
            why = "device no longer alive"
        } else if let rate = try? HAL.f64(g.outputDevice, kAudioDevicePropertyNominalSampleRate), rate != g.info.sampleRate {
            why = String(format: "sample rate changed %.0f -> %.0f", g.info.sampleRate, rate)
        } else if case .success(let device) = resolveOutput(g.defaultDevice), device == g.outputDevice {
            if let frames = try? HAL.u32(g.aggregate, kAudioDevicePropertyBufferFrameSize), frames != g.info.bufferFrames {
                why = "buffer size changed \(g.info.bufferFrames) -> \(frames)"
            }
        } else {
            why = "output layout or format changed"
        }
        if let why { rebuild(reason: "\(why) (\(cause))") }
    }

    // MARK: - Watchdogs (engine queue, 1 Hz)

    private func resetWatchdogs() {
        ticks = 0
        lastCallbacks = 0
        stalledSeconds = 0
        zeroSince = nil
        outputProcesses = HAL.processesRunningOutput(excluding: excludedPIDs.union([getpid()]))  // baseline, no start times
        outputStarts = [:]
        lastStats = nil
    }

    private func startTimer() {
        stopTimer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let g = graph, let live = g.live else { return }
        ticks += 1
        jd_live_collect_retired(live)
        drainLibraryMessages()
        var s = JDLiveStats()
        jd_live_read_stats(live, &s)
        let previous = lastStats ?? JDLiveStats()
        lastStats = s
        let newCallbacks = s.callbacks - previous.callbacks
        let newZeros = s.zeroInputCallbacks - previous.zeroInputCallbacks

        // Stall: with tapautostart off the IOProc runs continuously, so silence from it is a fault.
        if newCallbacks == 0 {
            stalledSeconds += 1
            if stalledSeconds >= 3 {
                rebuild(reason: "IOProc stalled for 3 s")
                return
            }
        } else {
            stalledSeconds = 0
        }

        // Zeroed tap: a process *starts* output, yet every tap buffer stays exactly 0.0 for 5 s.
        // Processes already playing when we built (e.g. com.apple.CoreSpeech, which keeps output
        // running while silent) are only a baseline and never trigger this.
        let now = Date()
        // Excluded apps are silent in the tap by design: they must not look like a zeroed tap.
        let outputs = HAL.processesRunningOutput(excluding: excludedPIDs.union([getpid()]))
        for pid in outputs.subtracting(outputProcesses) { outputStarts[pid] = now }
        for pid in outputProcesses.subtracting(outputs) { outputStarts[pid] = nil }
        outputProcesses = outputs
        othersPlaying = !outputs.isEmpty
        if newCallbacks > 0 && newZeros == newCallbacks {
            if zeroSince == nil { zeroSince = now.addingTimeInterval(-1) }
        } else if newCallbacks > 0 {
            zeroSince = nil
            if case .running = state {} else if case .starting = state {} else {
                setState(.running(output: g.outputName, sampleRate: g.info.sampleRate, bufferFrames: g.info.bufferFrames))
            }
        }
        if let since = zeroSince,
           let started = outputStarts.filter({ $0.value >= since.addingTimeInterval(-1.5) && now.timeIntervalSince($0.value) >= 5 }).first {
            let who = "pid \(started.key) (\(Self.processName(started.key)))"
            // Permission was confirmed by the probe before this graph was built, so this is not a
            // denial. Silent system services (com.apple.CoreSpeech starts and stops a silent output)
            // also land here: at most one rebuild per minute, never remove the tap.
            outputStarts[started.key] = nil
            if now.timeIntervalSince(lastZeroRebuild) >= 60 {
                lastZeroRebuild = now
                rebuild(reason: "tap delivered only zeros for 5 s after \(who) started output")
                return
            }
        }

        if ticks % statsLogEvery == 0 { logStats(s, g.info) }
        publishSnapshot()
    }

    static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "?" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// libjamesdsp / liveprog printf output, collected from the lock-free ring.
    private func drainLibraryMessages() {
        final class Box { var lines: [String] = [] }
        let box = Box()
        let dropped = jd_drain_messages({ text, context in
            guard let text, let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().lines.append(String(cString: text))
        }, Unmanaged.passUnretained(box).toOpaque())
        var lines = box.lines.map { "output: " + $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0 != "output: " }
        if dropped > 0 { lines.append("output: \(dropped) messages dropped (ring full)") }
        addMessages(lines)
    }

    private func logStats(_ s: JDLiveStats, _ info: JDLiveInfo) {
        let wall = max(s.lastHostSeconds - s.firstHostSeconds, 1e-9)
        Log.write(String(format: "stats fs=%.0f frames=%u bypass=%d cb=%llu outDisc=%llu inDisc=%llu overloads=%llu layoutErr=%llu zeroIn=%llu unprocessed=%llu cpu=%.3f%% maxCb=%.3fms lat=%.3fms maxLat=%.3fms inPeak=%.3f outPeak=%.3f maxStep=%.4f others=%d",
                         info.sampleRate, info.bufferFrames, bypass ? 1 : 0, s.callbacks, s.outputDiscontinuities, s.inputDiscontinuities,
                         s.overloads, s.layoutErrors, s.zeroInputCallbacks, s.unprocessedCallbacks, s.busySeconds / wall * 100,
                         s.maxCallbackSeconds * 1000, s.lastLatencySeconds * 1000, s.maxLatencySeconds * 1000,
                         s.inPeak, s.outPeak, s.maxOutputStep, othersPlaying ? 1 : 0))
    }

    // MARK: - Publishing

    private func setState(_ new: EngineState) {
        if new != state { Log.write("state: \(new)") }
        state = new
        publishSnapshot()
    }

    private func publishSnapshot() {
        dispatchPrecondition(condition: .onQueue(queue))
        let snap = EngineSnapshot(state: state, stats: lastStats, info: graph?.info, rebuilds: rebuilds,
                                  lastRebuildReason: lastReason, othersPlaying: othersPlaying, problems: problems, messages: messages,
                                  outputUID: currentOutput?.uid, outputName: currentOutput?.name)
        let deliver = publish
        DispatchQueue.main.async { deliver(snap) }
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}
