import Config
import Engine
import SwiftUI

/// `tone_eq` / `compander_response` values: n frequencies then n gains, ';'-separated.
enum Bands {
    static let eqFrequencies: [Double] = [25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000]
    static let companderFrequencies: [Double] = [95, 200, 400, 800, 1600, 3400, 7500]

    static func parse(_ text: String, count: Int, defaults: [Double]) -> (frequencies: [Double], gains: [Double]) {
        let v = text.split(separator: ";").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count == count * 2 else { return (defaults, Array(repeating: 0, count: count)) }
        return (Array(v[..<count]), Array(v[count...]))
    }

    static func join(_ frequencies: [Double], _ gains: [Double]) -> String {
        (frequencies + gains).map { $0 == $0.rounded() ? String(format: "%.1f", $0) : String(format: "%.2f", $0) }
            .joined(separator: ";")
    }
}

/// Every effect, in the order of the panel. `expanded` is the open row's id.
struct EffectList: View {
    @Bindable var controller: EngineController
    @Binding var expanded: String?
    var focused: String? = nil
    let openSettings: (String) -> Void

    /// Row order and each row's enable switch, for keyboard navigation.
    static let rows: [(id: String, enable: WritableKeyPath<DSPSettings, Bool>)] = [
        ("output", \.masterEnable), ("bass", \.bassEnable), ("eq", \.toneEnable), ("autoeq", \.graphicEQEnable),
        ("compander", \.companderEnable), ("reverb", \.reverbEnable), ("convolver", \.convolverEnable),
        ("crossfeed", \.crossfeedEnable), ("stereowide", \.stereowideEnable), ("ddc", \.ddcEnable),
        ("tube", \.tubeEnable), ("liveprog", \.liveprogEnable),
    ]

    /// Left/right on a focused row: nudges its inline control (`direction` is -1 or +1).
    @MainActor static func nudge(_ id: String, _ direction: Int, _ controller: EngineController) {
        let d = Double(direction)
        func step(_ v: Double, _ by: Double, _ r: ClosedRange<Double>) -> Double { min(max(v + by * d, r.lowerBound), r.upperBound) }
        controller.update { s in
            switch id {
            case "output": s.postGain = step(s.postGain, 0.5, -15...15)
            case "bass": s.bassMaxGain = step(s.bassMaxGain, 1, 3...15)
            case "stereowide": s.stereowideLevel = step(s.stereowideLevel, 5, 0...100)
            case "tube": s.tubePregain = step(s.tubePregain, 50, -300...1200)
            case "reverb":
                let i = ReverbPresets.closest(to: s).index + direction
                if ReverbPresets.names.indices.contains(i) { ReverbPresets.apply(i, to: &s) }
            case "crossfeed":
                let modes = crossfeedModes.map(\.0)
                let i = (modes.firstIndex(of: s.crossfeedMode) ?? 0) + direction
                if modes.indices.contains(i) { s.crossfeedMode = modes[i] }
            default: break
            }
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            output
            bass
            eq
            graphicEQ
            compander
            reverb
            convolver
            crossfeed
            stereoWidth
            ddc
            tube
            liveprog
        }
    }

    private func b<T: Equatable>(_ key: WritableKeyPath<DSPSettings, T>) -> Binding<T> { controller.binding(key) }
    private var s: DSPSettings { controller.settings }

    private func row<P: View, D: View>(_ id: String, _ title: String, _ symbol: String, _ enabled: Binding<Bool>,
                                         @ViewBuilder primary: () -> P, @ViewBuilder detail: () -> D) -> some View {
        EffectRow(title: title, symbol: symbol, enabled: enabled, isExpanded: expanded == id, isFocused: focused == id,
                  toggleExpanded: { expanded = expanded == id ? nil : id }, primary: primary, detail: detail)
            .id(id)
    }

    private static func db(_ v: Double) -> String { String(format: "%+.1f dB", v) }

    // MARK: Rows

    /// Post gain and limiter. Always active, so its switch is the master effects switch.
    private var output: some View {
        row("output", "Output", "gauge.with.dots.needle.67percent", b(\.masterEnable)) {
            InlineSlider(value: b(\.postGain), range: -15...15, step: 0.5, label: Self.db(s.postGain))
        } detail: {
            ValueSlider(title: "Post gain", value: b(\.postGain), range: -15...15, step: 0.5, format: Self.db)
            ValueSlider(title: "Limiter", value: b(\.limThreshold), range: -60...0, step: 0.5, format: Self.db)
            ValueSlider(title: "Release", value: b(\.limRelease), range: 2...500, step: 1, format: { String(format: "%.0f ms", $0) })
            Text("This switch turns all effects off and on (master_enable).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var bass: some View {
        row("bass", "Bass boost", "speaker.wave.3", b(\.bassEnable)) {
            InlineSlider(value: b(\.bassMaxGain), range: 3...15, step: 1, label: String(format: "%.0f dB", s.bassMaxGain))
        } detail: {
            ValueSlider(title: "Max gain", value: b(\.bassMaxGain), range: 3...15, step: 1, format: { String(format: "%.0f dB", $0) })
        }
    }

    private var eqBands: Binding<[Double]> {
        Binding(get: { Bands.parse(s.toneEQ, count: 15, defaults: Bands.eqFrequencies).gains },
                set: { gains in
                    let f = Bands.parse(s.toneEQ, count: 15, defaults: Bands.eqFrequencies).frequencies
                    controller.update { $0.toneEQ = Bands.join(f, gains) }
                })
    }

    private var eq: some View {
        row("eq", "Equalizer", "slider.vertical.3", b(\.toneEnable)) {
            EmptyView()
        } detail: {
            BandEditor(gains: eqBands, frequencies: Bands.parse(s.toneEQ, count: 15, defaults: Bands.eqFrequencies).frequencies,
                       range: -12...12)
            LabeledPicker(title: "Filter", selection: b(\.toneFilterType)) {
                Text("FIR minimum phase").tag(0)
                ForEach(1...5, id: \.self) { Text("IIR order \(2 + $0 * 2)").tag($0) }
            }
            if s.toneFilterType == 0 {
                LabeledPicker(title: "Interpolation", selection: b(\.toneInterpolation)) {
                    Text("PCHIP").tag(0)
                    Text("Modified Akima").tag(1)
                }
            }
            Button("Flat") { eqBands.wrappedValue = Array(repeating: 0, count: 15) }
                .controlSize(.small)
        }
    }

    private var graphicEQ: some View {
        row("autoeq", "AutoEQ", "headphones", b(\.graphicEQEnable)) {
            Text(controller.autoEQProfile?.name ?? GraphicEQ.summary(s.graphicEQParam))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .trailing)
        } detail: {
            if let p = controller.autoEQProfile {
                Text("\(p.name), measured by \(p.detail)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Arbitrary-response EQ from an AutoEQ GraphicEQ or ParametricEQ file, or from AutoEq's published results.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Import File…") { controller.importGraphicEQ() }
                Button("Find Headphones…") { openSettings("autoeq") }
            }
            .controlSize(.small)
        }
    }

    private var companderBands: Binding<[Double]> {
        Binding(get: { Bands.parse(s.companderResponse, count: 7, defaults: Bands.companderFrequencies).gains },
                set: { gains in
                    let f = Bands.parse(s.companderResponse, count: 7, defaults: Bands.companderFrequencies).frequencies
                    controller.update { $0.companderResponse = Bands.join(f, gains) }
                })
    }

    private var compander: some View {
        row("compander", "Compander", "rectangle.compress.vertical", b(\.companderEnable)) {
            EmptyView()
        } detail: {
            BandEditor(gains: companderBands,
                       frequencies: Bands.parse(s.companderResponse, count: 7, defaults: Bands.companderFrequencies).frequencies,
                       range: -1.2...1.2, format: { String(format: "%+.1f", $0) })
            ValueSlider(title: "Time constant", value: b(\.companderTimeConstant), range: 0.22...0.3, step: 0.01,
                        format: { String(format: "%.2f s", $0) })
            LabeledPicker(title: "Granularity", selection: b(\.companderGranularity)) {
                ForEach(2...4, id: \.self) { Text("\($0)").tag($0) }
            }
            LabeledPicker(title: "Transform", selection: b(\.companderTransforms)) {
                Text("STFT").tag(0)
                Text("Continuous wavelet").tag(1)
                Text("Pseudo multi-resolution").tag(2)
                Text("Time domain").tag(3)
            }
        }
    }

    private var reverbPreset: Binding<Int> {
        Binding(get: { ReverbPresets.closest(to: s).index },
                set: { i in controller.update { ReverbPresets.apply(i, to: &$0) } })
    }

    private var reverb: some View {
        row("reverb", "Reverb", "building.columns", b(\.reverbEnable)) {
            Text(ReverbPresets.closest(to: s).exact ? ReverbPresets.names[reverbPreset.wrappedValue] : "Custom")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } detail: {
            LabeledPicker(title: "Preset", selection: reverbPreset) {
                ForEach(ReverbPresets.names.indices, id: \.self) { Text(ReverbPresets.names[$0]).tag($0) }
            }
            ValueSlider(title: "Decay", value: b(\.reverbDecay), range: 0.1...30, step: 0.1, format: { String(format: "%.1f s", $0) })
            ValueSlider(title: "Wet", value: b(\.reverbWet), range: -70...10, step: 0.5, format: Self.db)
            ValueSlider(title: "Dry", value: b(\.reverbFinalDry), range: -70...10, step: 0.5, format: Self.db)
            ValueSlider(title: "Width", value: b(\.reverbWidth), range: 0...1, step: 0.01, format: { String(format: "%.0f %%", $0 * 100) })
            ValueSlider(title: "Pre-delay", value: b(\.reverbDelay), range: -500...500, step: 1, format: { String(format: "%.0f ms", $0) })
        }
    }

    private var convolver: some View {
        row("convolver", "Convolver", "waveform.path", b(\.convolverEnable)) {
            LibraryFileMenu(kind: .impulseResponse, file: b(\.convolverFile))
        } detail: {
            LabeledPicker(title: "Optimisation", selection: b(\.convolverOptimizationMode)) {
                Text("Original").tag(0)
                Text("Shrink").tag(1)
                Text("Minimum phase + shrink").tag(2)
            }
            Text("Long impulse responses cost more CPU: about 13 % for 5 s, 25 % for 20 s.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static let crossfeedModes: [(Int, String)] = [
        (0, "BS2B weak"), (1, "BS2B strong"), (99, "BS2B custom"), (2, "Out of head"),
        (3, "Surround 1"), (4, "Surround 2"), (5, "Realistic surround"),
    ]

    private var crossfeed: some View {
        row("crossfeed", "Crossfeed", "arrow.left.arrow.right", b(\.crossfeedEnable)) {
            Text(Self.crossfeedModes.first { $0.0 == s.crossfeedMode }?.1 ?? "Mode \(s.crossfeedMode)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } detail: {
            LabeledPicker(title: "Mode", selection: b(\.crossfeedMode)) {
                ForEach(Self.crossfeedModes, id: \.0) { Text($0.1).tag($0.0) }
            }
            if s.crossfeedMode == 99 {
                ValueSlider(title: "Cut-off", value: Binding(get: { Double(s.crossfeedFcut) }, set: { v in controller.update { $0.crossfeedFcut = Int(v) } }),
                            range: 300...2000, step: 10, format: { String(format: "%.0f Hz", $0) })
                ValueSlider(title: "Feed", value: Binding(get: { Double(s.crossfeedFeed) / 10 }, set: { v in controller.update { $0.crossfeedFeed = Int((v * 10).rounded()) } }),
                            range: 1...15, step: 0.1, format: { String(format: "%.1f dB", $0) })
            }
        }
    }

    private var stereoWidth: some View {
        row("stereowide", "Stereo width", "arrow.left.and.right", b(\.stereowideEnable)) {
            InlineSlider(value: b(\.stereowideLevel), range: 0...100, step: 1, label: String(format: "%.0f %%", s.stereowideLevel))
        } detail: {
            ValueSlider(title: "Level", value: b(\.stereowideLevel), range: 0...100, step: 1, format: { String(format: "%.0f %%", $0) })
        }
    }

    private var ddc: some View {
        row("ddc", "ViPER-DDC", "dial.medium", b(\.ddcEnable)) {
            LibraryFileMenu(kind: .ddc, file: b(\.ddcFile))
        } detail: {
            Text("Headphone correction from a ViPER4Android .vdc file.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tube: some View {
        let dB = Binding(get: { s.tubePregain / 100 }, set: { v in controller.update { $0.tubePregain = (v * 100).rounded() } })
        return row("tube", "Tube", "flame", b(\.tubeEnable)) {
            InlineSlider(value: dB, range: -3...12, step: 0.1, label: Self.db(s.tubePregain / 100))
        } detail: {
            ValueSlider(title: "Drive", value: dB, range: -3...12, step: 0.1, format: Self.db)
        }
    }

    private var liveprog: some View {
        row("liveprog", "Liveprog", "chevron.left.forwardslash.chevron.right", b(\.liveprogEnable)) {
            LibraryFileMenu(kind: .liveprog, file: b(\.liveprogFile))
        } detail: {
            Text("EEL2 scripts, compatible with JamesDSP. Edit a script in Settings; saving it reloads it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Edit Script…") { openSettings("liveprog") }.controlSize(.small)
        }
    }
}

/// GraphicEQ strings ("GraphicEQ: f g; f g; ...").
enum GraphicEQ {
    static func summary(_ text: String) -> String {
        let points = text.split(separator: ";").count
        let flat = text.split(separator: ";").allSatisfy { pair in
            pair.split(separator: " ").last.flatMap { Double($0) } == 0
        }
        return flat ? "Flat" : "\(points) points"
    }
}
