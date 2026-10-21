import AppKit
import Engine
import SwiftUI

/// One effect in the panel's list: symbol, name, an optional inline control, an enable switch,
/// and a detail area that expands inline (one row open at a time).
struct EffectRow<Primary: View, Detail: View>: View {
    let title: String
    let symbol: String
    @Binding var enabled: Bool
    let isExpanded: Bool
    var isFocused = false
    let toggleExpanded: () -> Void
    @ViewBuilder var primary: Primary
    @ViewBuilder var detail: Detail
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                Text(title)
                    .foregroundStyle(enabled ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                primary
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.65)
                Toggle(title, isOn: $enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { toggleExpanded() } }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? "Collapse" : "Show settings")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) { detail }
                    .padding(.leading, 48)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isExpanded ? 0.06 : hovering ? 0.04 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
        )
        .onHover { hovering = $0 }
    }
}

/// A labelled slider with its value. Values are shown and set in `unit` after `scale`
/// (e.g. tube pregain is stored in hundredths of a dB).
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var format: (Double) -> String = { String(format: "%.1f", $0) }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            slider
            Text(format(value))
                .font(.callout.monospacedDigit())
                .frame(width: 58, alignment: .trailing)
        }
    }

    /// Steps are applied by rounding, not with Slider(step:), which draws tick marks.
    private var slider: some View {
        Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                              set: { value = step > 0 ? ($0 / step).rounded() * step : $0 }),
               in: range)
            .controlSize(.small)
    }
}

/// Compact slider for a row's inline control.
struct InlineSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) },
                                  set: { value = step > 0 ? ($0 / step).rounded() * step : $0 }),
                   in: range)
                .controlSize(.mini)
                .frame(width: 90)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
    }
}

struct LabeledPicker<Value: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Picker(title, selection: $selection) { content }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            Spacer(minLength: 0)
        }
    }
}

/// Vertical band sliders (FIR EQ, compander response). `values` is the whole key: frequencies
/// first, then gains.
struct BandEditor: View {
    @Binding var gains: [Double]
    let frequencies: [Double]
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%+.0f", $0) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(gains.indices, id: \.self) { i in
                VStack(spacing: 4) {
                    Text(format(gains[i]))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                    VerticalSlider(value: Binding(get: { gains[i] }, set: { gains[i] = $0 }), range: range)
                        .frame(height: 96)
                    Text(Self.hz(frequencies[i]))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    static func hz(_ f: Double) -> String {
        f >= 1000 ? String(format: f.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0fk" : "%.1fk", f / 1000) : String(format: "%.0f", f)
    }
}

/// A native slider turned upright.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { value = $0 }), in: range)
                .controlSize(.mini)
                .frame(width: geo.size.height)
                .rotationEffect(.degrees(-90))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(minWidth: 14)
    }
}

/// Picks a file from one of the library folders (impulse responses, DDC, liveprog), or adds one.
struct LibraryFileMenu: View {
    let kind: FileLibrary.Kind
    @Binding var file: String
    var library: FileLibrary = .standard
    @State private var files: [String] = []

    var body: some View {
        Menu {
            ForEach(files, id: \.self) { name in
                Button { file = name } label: {
                    if name == current { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            if !files.isEmpty { Divider() }
            Button("Add File…") { add() }
            Button("Show in Finder") { NSWorkspace.shared.open(library.folder(kind)) }
        } label: {
            Text(current.isEmpty ? "None" : current)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 150)
        .onAppear { files = library.files(kind) }
    }

    /// Presets from Linux carry full paths; show and match by file name.
    private var current: String { (file as NSString).lastPathComponent }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a file to copy into \(library.folder(kind).lastPathComponent)/"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let name = try? library.add(url, kind: kind) else { return }
        files = library.files(kind)
        file = name
    }
}
