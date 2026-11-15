import AppKit
import SwiftUI

/// The settings window's tab bar: a glass selector that slides between tabs and can be dragged by
/// hand, settling on the nearest tab when released. ⌘1…⌘n switch tabs. On macOS before 26 the
/// selector is frosted material instead of Liquid Glass.
///
/// One gesture handles clicks and drags: per-tab buttons would take the mouse before a drag could
/// start, so the selector never moved under the pointer.
struct GlassTabBar: View {
    struct Tab: Identifiable {
        let id: String
        let title: String
        let symbol: String
    }

    let tabs: [Tab]
    @Binding var selection: String
    /// Where the selector's leading edge is while a drag is in progress.
    @State private var dragX: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let itemWidth = geo.size.width / CGFloat(max(tabs.count, 1))
            let index = CGFloat(tabs.firstIndex { $0.id == selection } ?? 0)
            ZStack(alignment: .leading) {
                selector
                    .frame(width: itemWidth, height: geo.size.height)
                    .scaleEffect(dragX == nil ? 1 : 1.08)
                    .offset(x: dragX ?? index * itemWidth)
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        label(tab)
                            .frame(width: itemWidth, height: geo.size.height)
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard dragX != nil || abs(value.translation.width) > 3 else { return }
                        withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.85)) {
                            dragX = clamp(value.location.x - itemWidth / 2, geo.size.width - itemWidth)
                        }
                    }
                    .onEnded { value in
                        // A click lands where it was made; a drag lands where it was heading.
                        let x = dragX == nil ? value.location.x : value.predictedEndLocation.x
                        let i = Int((clamp(x - itemWidth / 2, geo.size.width - itemWidth) / itemWidth).rounded())
                        withAnimation(slide) {
                            selection = tabs[min(max(i, 0), tabs.count - 1)].id
                            dragX = nil
                        }
                    })
        }
        .frame(height: 52)
        .padding(4)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .background { shortcuts }
        .accessibilityRepresentation {
            Picker("Settings section", selection: $selection) {
                ForEach(tabs) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func clamp(_ x: CGFloat, _ upper: CGFloat) -> CGFloat { min(max(x, 0), max(upper, 0)) }

    private var slide: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.4, dampingFraction: 0.72) }

    @ViewBuilder private var selector: some View {
        if #available(macOS 26.0, *) {
            Capsule().fill(Color.accentColor.opacity(0.12))
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.25)).interactive(), in: Capsule())
        } else {
            Capsule().fill(.regularMaterial)
                .overlay(Capsule().fill(Color.accentColor.opacity(0.15)))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        }
    }

    private func label(_ tab: Tab) -> some View {
        VStack(spacing: 3) {
            Image(systemName: tab.symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(height: 20)
            Text(tab.title)
                .font(.caption)
        }
        .foregroundStyle(tab.id == selection ? Color.primary : Color.secondary)
    }

    /// ⌘1…⌘n, as invisible buttons (the labels themselves take no clicks).
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                Button("") { withAnimation(slide) { selection = tab.id } }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// The settings window, owned by the app rather than a SwiftUI Settings scene so it can float above
/// other apps' windows and come forward every time it is opened. The app has no Dock icon and no
/// ⌘-Tab entry, so a window behind others is otherwise hard to find. (Approach after BrightIntosh's
/// SettingsWindowController, GPL-3.0; written for this app.)
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(_ controller: EngineController) {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "jdsp4mac Settings"
            // One surface: the content runs up behind a see-through title bar.
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.collectionBehavior.insert(.moveToActiveSpace)
            w.contentView = NSHostingView(rootView: SettingsView(controller: controller))
            w.setContentSize(w.contentView?.fittingSize ?? NSSize(width: 600, height: 660))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
