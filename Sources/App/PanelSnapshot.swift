import AppKit
import SwiftUI

/// Test hook (`--snapshot-panel <dir>`): renders the panel in light and dark, collapsed and with a
/// row expanded, to PNGs, then quits. The app draws its own window, so no screen-recording
/// permission is needed; window vibrancy is not captured (the menu bar shows it on a material).
@MainActor
enum PanelSnapshot {
    static func write(controller: EngineController, to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let variants: [(String, NSAppearance.Name, String?)] = [
            ("light", .aqua, nil), ("dark", .darkAqua, nil),
            ("light-eq", .aqua, "eq"), ("dark-reverb", .darkAqua, "reverb"), ("dark-output", .darkAqua, "output"),
        ]
        for (name, appearance, expanded) in variants {
            await render(PanelView(controller: controller, initialExpanded: expanded), "panel-\(name)", appearance, dir, wait: 0.4)
        }
        for tab in ["general", "apps", "autoeq", "liveprog", "diagnostics"] {
            UserDefaults.standard.set(tab, forKey: "settingsTab")
            await render(SettingsView(controller: controller), "settings-\(tab)", .darkAqua, dir, wait: tab == "autoeq" ? 15 : 0.6)
        }
    }

    /// Marketing screenshots: panel and settings tabs, light and dark, at the screen's backing
    /// scale. The settings tabs are rendered on their own (no window toolbar).
    static func writeScreenshots(controller: EngineController, to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let panels: [(String, NSAppearance.Name, String?)] = [
            ("panel-dark", .darkAqua, nil), ("panel-light", .aqua, nil),
            ("panel-dark-eq", .darkAqua, "eq"), ("panel-light-autoeq", .aqua, "autoeq"),
        ]
        for (name, appearance, expanded) in panels {
            await render(PanelView(controller: controller, initialExpanded: expanded), name, appearance, dir, wait: 0.8)
        }
        let defaults = UserDefaults.standard
        let savedQuery = defaults.string(forKey: "autoEQQuery")
        defaults.set("HD 600", forKey: "autoEQQuery")
        let tabs: [(String, NSAppearance.Name, AnyView)] = [
            ("settings-autoeq-dark", .darkAqua, AnyView(AutoEQTab(controller: controller))),
            ("settings-autoeq-light", .aqua, AnyView(AutoEQTab(controller: controller))),
            ("settings-apps-light", .aqua, AnyView(AppsTab(controller: controller))),
            ("settings-apps-dark", .darkAqua, AnyView(AppsTab(controller: controller))),
            ("settings-liveprog-dark", .darkAqua, AnyView(LiveprogTab(controller: controller))),
        ]
        for (name, appearance, view) in tabs {
            await render(view.frame(width: 600, height: 460), name, appearance, dir, wait: name.contains("autoeq") ? 3 : 0.8)
        }
        if let savedQuery { defaults.set(savedQuery, forKey: "autoEQQuery") } else { defaults.removeObject(forKey: "autoEQQuery") }
    }

    /// Waits asynchronously (not RunLoop.run), so main-actor work such as downloads can finish.
    private static func render(_ root: some View, _ name: String, _ appearance: NSAppearance.Name, _ dir: URL, wait: TimeInterval) async {
        let view = root.background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        // Key, as an open panel is: otherwise switches and sliders draw in their inactive grey.
        let window = KeyWindow(contentRect: NSRect(x: -10000, y: 0, width: 380, height: 800), styleMask: [.borderless],
                               backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.setContentSize(host.fittingSize)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)  // no focused text field with selected text
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(wait))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}

/// A borderless window that may become key (borderless windows refuse by default).
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
