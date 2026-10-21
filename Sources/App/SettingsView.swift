import Config
import Engine
import ServiceManagement
import SwiftUI

/// The small settings window: things that do not fit in the panel.
struct SettingsView: View {
    @Bindable var controller: EngineController
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            AppsTab(controller: controller)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }.tag("apps")
            AutoEQTab(controller: controller)
                .tabItem { Label("AutoEQ", systemImage: "headphones") }.tag("autoeq")
            LiveprogTab(controller: controller)
                .tabItem { Label("Liveprog", systemImage: "chevron.left.forwardslash.chevron.right") }.tag("liveprog")
            DiagnosticsTab(controller: controller)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag("diagnostics")
        }
        .frame(width: 600, height: 460)
    }
}

/// Apps left out of the effects: they play directly, unprocessed.
private struct AppsTab: View {
    @Bindable var controller: EngineController
    @State private var candidates: [AppInfo] = []
    @State private var observer: AnyObject?

    var body: some View {
        Form {
            Section {
                if controller.excludedApps.isEmpty {
                    Text("No apps excluded. Every app's sound goes through the effects.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.excludedApps, id: \.self) { id in
                    let app = AppInfo(bundleID: id)
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                            Text(id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { controller.includeApp(id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Send this app through the effects again")
                    }
                }
            } header: {
                Text("Apps without effects")
            } footer: {
                Text("These apps play directly to the output, without effects: useful for calls, or for music software with its own processing. Changes apply at once. Helper processes count for their app, including the WebKit process Safari and other web-based apps play through.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                HStack {
                    Menu("Add App Using Audio") {
                        ForEach(candidates) { app in
                            Button(app.playing ? "\(app.name) (playing)" : app.name) { controller.excludeApp(app.bundleID) }
                        }
                        if candidates.isEmpty { Text("No other apps are using audio") }
                    }
                    .fixedSize()
                    Button("Choose App…") { chooseApp() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refresh()
            // Apps that start (or stop) using audio while the tab is open appear (or go) at once.
            observer = AudioClients.observe { DispatchQueue.main.async { refresh() } }
        }
        .onDisappear {
            if let observer { AudioClients.stopObserving(observer) }
            observer = nil
        }
        .onChange(of: controller.excludedApps) { refresh() }
    }

    /// Running regular apps that have used audio (helpers such as com.google.Chrome.helper, and
    /// processes the app is responsible for such as Safari's WebKit GPU process, count for their
    /// app), minus those already excluded and jdsp4mac itself.
    private func refresh() {
        let clients = AudioClients.list()
        let me = Bundle.main.bundleIdentifier ?? ""
        var seen = Set<String>()
        candidates = NSWorkspace.shared.runningApplications.compactMap { running -> AppInfo? in
            guard running.activationPolicy == .regular, let id = running.bundleIdentifier, id != me,
                  !controller.excludedApps.contains(id), seen.insert(id).inserted else { return nil }
            let mine = clients.filter { $0.bundleID == id || $0.bundleID.hasPrefix(id + ".") || $0.owner == id }
            guard !mine.isEmpty else { return nil }
            var info = AppInfo(bundleID: id)
            info.playing = mine.contains { $0.playing }
            return info
        }
        .sorted { ($0.playing ? 0 : 1, $0.name) < ($1.playing ? 0 : 1, $1.name) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose an app to play without effects"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        controller.excludeApp(id)
    }
}

private struct AppInfo: Identifiable {
    let bundleID: String
    var playing = false
    var id: String { bundleID }

    init(bundleID: String) { self.bundleID = bundleID }

    private var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var name: String { url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID }
    var icon: NSImage {
        url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
    }
}

private struct GeneralTab: View {
    @Bindable var controller: EngineController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var rules: [PresetStore.Rule] = []

    var body: some View {
        Form {
            Section {
                Toggle("Open jdsp4mac at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                Text("Processing starts by itself if it was on when you quit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Presets per output") {
                if rules.isEmpty {
                    Text("None. In the panel's preset menu, choose “Load … on <output>”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rules, id: \.deviceUID) { rule in
                    HStack {
                        Text(rule.deviceName)
                        Spacer()
                        Text(rule.preset).foregroundStyle(.secondary)
                        Button { controller.removeRule(deviceUID: rule.deviceUID); rules = controller.rules() } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this rule")
                    }
                }
            }
            Section("Files") {
                HStack {
                    Text("Impulse responses, DDC files, scripts and presets live in Application Support.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(FileLibrary.standard.root) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { rules = controller.rules() }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS refused: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginError = "Allow jdsp4mac in System Settings › General › Login Items."
        }
    }
}

private struct AutoEQTab: View {
    @Bindable var controller: EngineController
    @State private var search = AutoEQSearch()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search headphones, e.g. HD 600", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                Button("Import File…") { controller.importGraphicEQ() }
            }
            switch search.phase {
            case .idle, .loading:
                ProgressView("Loading the AutoEq index…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let why):
                VStack(spacing: 8) {
                    Text(why).foregroundStyle(.orange)
                    Button("Try Again") { Task { await search.loadIndex() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                List(search.results) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                            Text(entry.rig.map { "\(entry.source) · \($0)" } ?? entry.source)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if search.applying == entry.id {
                            ProgressView().controlSize(.small)
                        } else if controller.autoEQProfile == AutoEQProfile(entry) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        } else {
                            Button("Apply") { Task { await search.apply(entry, to: controller) } }
                                .controlSize(.small)
                        }
                    }
                }
                .overlay {
                    if search.results.isEmpty {
                        Text(search.query.isEmpty ? "\(search.entries.count) profiles" : "No matches")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Profiles from the AutoEq project (github.com/jaakkopasanen/AutoEq), fetched only while this tab is open or when you apply one, then cached. Measurements by the source shown under each name.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .task { await search.loadIndex() }
    }
}

private struct LiveprogTab: View {
    @Bindable var controller: EngineController
    @State private var files: [String] = []
    @State private var selected = ""
    @State private var text = ""
    @State private var saved = ""
    private let library = FileLibrary.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Script", selection: $selected) {
                    ForEach(files, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 280)
                Button("New") { newScript() }
                Spacer()
                Button("Use in Panel") {
                    controller.update { $0.liveprogFile = selected; $0.liveprogEnable = true }
                }
                .disabled(selected.isEmpty)
                Button("Save") { save() }
                    .keyboardShortcut("s")
                    .disabled(text == saved || selected.isEmpty)
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .border(Color.secondary.opacity(0.3))
            if let error = controller.problems.first(where: { $0.hasPrefix("Liveprog") }) {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Text("Saving the script that is in use reloads it at once. Errors appear here and in the panel.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear {
            files = library.files(.liveprog)
            let current = (controller.settings.liveprogFile as NSString).lastPathComponent
            selected = files.contains(current) ? current : files.first ?? ""
            open(selected)
        }
        .onChange(of: selected) { _, name in open(name) }
    }

    private func url(_ name: String) -> URL { library.folder(.liveprog).appendingPathComponent(name) }

    private func open(_ name: String) {
        guard !name.isEmpty else { text = ""; saved = ""; return }
        text = (try? String(contentsOf: url(name), encoding: .utf8)) ?? ""
        saved = text
    }

    private func save() {
        do {
            try text.write(to: url(selected), atomically: true, encoding: .utf8)
            saved = text
        } catch { controller.notify("Could not save \(selected): \(error.localizedDescription)", isError: true) }
    }

    private func newScript() {
        var n = 1
        while files.contains("script\(n).eel") { n += 1 }
        let name = "script\(n).eel"
        try? "desc: New script\n@init\ngain = 1;\n@sample\nspl0 = spl0 * gain;\nspl1 = spl1 * gain;\n"
            .write(to: url(name), atomically: true, encoding: .utf8)
        files = library.files(.liveprog)
        selected = name
    }
}

/// Engine numbers and file locations (what the Phase 1-3 test panel showed).
private struct DiagnosticsTab: View {
    @Bindable var controller: EngineController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(controller.statusText).font(.callout)
            ForEach(controller.lines, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
            Divider()
            ForEach(controller.problems, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(controller.history.suffix(8).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack {
                Button("Panic") { controller.panic() }
                    .help("Remove the tap immediately; apps play directly")
                Spacer()
            }
            Text("Settings: \(controller.settingsPath)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Log: \(Log.url.path)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(20)
    }
}
