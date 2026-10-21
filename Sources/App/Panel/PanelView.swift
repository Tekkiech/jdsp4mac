import Engine
import SwiftUI

/// The menu bar popup: everything needed day to day. Layout from PLAN.md Phase 4.
struct PanelView: View {
    @Bindable var controller: EngineController
    @State private var expanded: String?
    /// Keyboard focus among the effect rows (arrow keys); separate from SwiftUI control focus.
    @State private var focusedRow: String?
    @FocusState private var listFocused: Bool
    /// The outline shows only once the keyboard is used, and hides again when the mouse moves.
    @State private var keyboardUsed = false
    @State private var listHeight: CGFloat = 0
    @Environment(\.openSettings) private var openSettings

    init(controller: EngineController, initialExpanded: String? = nil) {
        self.controller = controller
        _expanded = State(initialValue: initialExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(controller: controller)
            Divider()
            OutputRow(controller: controller)
            PresetRow(controller: controller)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    EffectList(controller: controller, expanded: $expanded,
                               focused: listFocused && keyboardUsed ? focusedRow : nil,
                               openSettings: { showSettings(tab: $0) })
                        .padding(.horizontal, -4)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                }
                // Scroll only when the list is taller than the screen allows; otherwise the panel
                // simply grows to fit.
                .scrollDisabled(listHeight <= maxListHeight)
                .scrollIndicators(listHeight > maxListHeight ? .automatic : .never)
                .frame(height: min(listHeight, maxListHeight))
                .onContinuousHover { phase in
                    if case .active = phase, keyboardUsed { keyboardUsed = false }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.upArrow) { move(-1, proxy) }
                .onKeyPress(.downArrow) { move(1, proxy) }
                .onKeyPress(.leftArrow) { nudge(-1) }
                .onKeyPress(.rightArrow) { nudge(1) }
                .onKeyPress(.space) { toggleFocused() }
                .onKeyPress(.return) { expandFocused(proxy) }
            }
            if !controller.problems.isEmpty || !controller.notices.isEmpty {
                MessageList(problems: controller.problems, notices: controller.notices)
                    .transition(.opacity)
            }
            Divider()
            Footer(showSettings: { showSettings() })
        }
        .padding(14)
        .frame(width: 380)
        // The menu bar window's own glass is very transparent on recent macOS: what is behind it
        // decides the contrast (white text over a light window in dark mode). A thick material
        // keeps the panel's own light or dark appearance, so the standard text styles stay legible.
        .background { Rectangle().fill(.thickMaterial).ignoresSafeArea() }
        .onAppear {
            controller.refreshOutputs()
            controller.refreshPresets()
            focusedRow = focusedRow ?? EffectList.rows.first?.id
            listFocused = true
            keyboardUsed = false
        }
        .onExitCommand { NSApp.keyWindow?.close() }
    }

    /// Room for the effect list: the screen's usable height minus the panel's other parts.
    private var maxListHeight: CGFloat {
        max(240, (NSScreen.main?.visibleFrame.height ?? 900) - 300)
    }

    // MARK: Keyboard

    private func move(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let ids = EffectList.rows.map(\.id)
        let i = focusedRow.flatMap { ids.firstIndex(of: $0) } ?? -1
        let next = keyboardUsed ? min(max(i + by, 0), ids.count - 1) : max(i, 0)
        keyboardUsed = true
        focusedRow = ids[next]
        withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(ids[next]) }
        return .handled
    }

    private func nudge(_ direction: Int) -> KeyPress.Result {
        guard let id = focusedRow else { return .ignored }
        keyboardUsed = true
        EffectList.nudge(id, direction, controller)
        return .handled
    }

    private func toggleFocused() -> KeyPress.Result {
        guard let row = EffectList.rows.first(where: { $0.id == focusedRow }) else { return .ignored }
        keyboardUsed = true
        controller.update { $0[keyPath: row.enable].toggle() }
        return .handled
    }

    private func expandFocused(_ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let id = focusedRow else { return .ignored }
        keyboardUsed = true
        withAnimation(.snappy(duration: 0.2)) { expanded = expanded == id ? nil : id }
        proxy.scrollTo(id, anchor: .top)
        return .handled
    }

    private func showSettings(tab: String? = nil) {
        if let tab { UserDefaults.standard.set(tab, forKey: "settingsTab") }
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}

/// Current problems (orange, until fixed) above one-off notices (fade after a few seconds).
private struct MessageList: View {
    let problems: [String]
    let notices: [EngineController.Notice]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems, id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(notices) { notice in
                Text(notice.text)
                    .foregroundStyle(notice.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .transition(.opacity)
            }
        }
        .font(.caption)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.4), value: notices)
        .animation(.easeOut(duration: 0.4), value: problems)
    }
}

/// Wordmark from the brand sheet: lowercase, the 4 in secondary grey.
struct Wordmark: View {
    var body: some View {
        (Text("jdsp").fontWeight(.semibold)
            + Text("4").fontWeight(.regular).foregroundColor(.secondary)
            + Text("mac").fontWeight(.semibold))
            .font(.system(size: 15))
            .kerning(-0.3)
    }
}

private struct Header: View {
    @Bindable var controller: EngineController

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Wordmark()
                Text(controller.status.text)
                    .font(.caption)
                    .foregroundStyle(controller.status.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("Power", isOn: $controller.isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(controller.isOn ? "Stop processing" : "Start processing system audio")
        }
    }
}

private struct OutputRow: View {
    @Bindable var controller: EngineController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hifispeaker")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Picker("Output", selection: Binding(get: { controller.outputUID ?? "" }, set: { controller.selectOutput($0) })) {
                if controller.outputUID == nil { Text("No output").tag("") }
                ForEach(controller.outputs) { device in
                    Text(device.channels > 2 ? "\(device.name) (\(device.channels) ch, not processed)" : device.name)
                        .tag(device.uid)
                }
            }
            .labelsHidden()
            .help("System output device")
        }
    }
}

private struct PresetRow: View {
    @Bindable var controller: EngineController
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Menu {
                ForEach(controller.presets, id: \.self) { name in
                    Button(name) { controller.loadPreset(name) }
                }
                if !controller.presets.isEmpty { Divider() }
                Button("Default Settings") { controller.loadDefaults() }
                Divider()
                Button("Save Current Settings…") { newName = controller.currentPreset ?? ""; naming = true }
                Button("Import…") { controller.importPreset() }
                Menu("Export") {
                    ForEach(controller.presets, id: \.self) { name in
                        Menu(name) {
                            Button("JDSP4Linux (.conf)…") { controller.exportPreset(name, rootless: false) }
                            Button("RootlessJamesDSP (.tar)…") { controller.exportPreset(name, rootless: true) }
                        }
                    }
                }
                .disabled(controller.presets.isEmpty)
                if let preset = controller.currentPreset, let output = controller.outputName {
                    Divider()
                    Toggle("Load \u{201C}\(preset)\u{201D} on \(output)", isOn: Binding(
                        get: { controller.ruleForOutput == preset },
                        set: { controller.setRuleForOutput($0 ? preset : nil) }))
                }
            } label: {
                Text(controller.currentPreset ?? "Custom")
            }
            if let rule = controller.ruleForOutput {
                Text("Auto")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
                    .help("\u{201C}\(rule)\u{201D} loads whenever \(controller.outputName ?? "this output") is the output")
            }
        }
        .popover(isPresented: $naming, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Save preset").font(.headline)
                TextField("Name", text: $newName)
                    .frame(width: 200)
                    .onSubmit(save)
                HStack {
                    Spacer()
                    Button("Cancel") { naming = false }.keyboardShortcut(.cancelAction)
                    Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(newName.isEmpty)
                }
            }
            .padding(12)
        }
    }

    private func save() {
        guard !newName.isEmpty else { return }
        controller.savePreset(newName)
        naming = false
    }
}

private struct Footer: View {
    let showSettings: () -> Void

    var body: some View {
        HStack {
            Button { showSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
                .keyboardShortcut(",")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .foregroundStyle(.secondary)
    }
}
