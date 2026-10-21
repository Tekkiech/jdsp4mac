import Foundation

/// A preset converted to our canonical audio.conf, plus files it carried and everything that did
/// not map cleanly (never dropped silently). Mapping tables: docs/preset-formats.md.
public struct ImportedPreset: Sendable {
    public var conf: AudioConf
    /// Files bundled in the preset (RootlessJamesDSP carries the liveprog script): (kind, name, contents).
    public var bundledFiles: [BundledFile]
    public var notes: [String]

    public init(conf: AudioConf, bundledFiles: [BundledFile], notes: [String]) {
        self.conf = conf
        self.bundledFiles = bundledFiles
        self.notes = notes
    }

    public struct BundledFile: Sendable {
        public let kind: String  // "liveprog"
        public let name: String
        public let data: Data
    }
}

public enum PresetConversion {
    // MARK: RootlessJamesDSP

    /// Rootless's own defaults (`JamesDspBaseEngine.kt` cache.get defaults), used for keys a preset lacks.
    private static let rootlessDefaults: [String: String] = [
        "output_postgain": "0", "limiter_threshold": "-0.1", "limiter_release": "60",
        "compander_enable": "false", "compander_timeconstant": "0.22", "compander_granularity": "2",
        "compander_tftransforms": "0", "compander_response": "95.0;200.0;400.0;800.0;1600.0;3400.0;7500.0;0;0;0;0;0;0;0",
        "bass_enable": "false", "bass_max_gain": "5",
        "eq_enable": "false", "eq_filter_type": "0", "eq_interpolation": "0",
        "eq_bands": "25.0;40.0;63.0;100.0;160.0;250.0;400.0;630.0;1000.0;1600.0;2500.0;4000.0;6300.0;10000.0;16000.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0",
        "geq_enable": "false", "geq_nodes": "GraphicEQ: 0.0 0.0;",
        "reverb_enable": "false", "reverb_preset": "0",
        "stereowide_enable": "false", "stereowide_mode": "60",
        "bs2b_crossfeed_enable": "false", "bs2b_crossfeed_mode": "0",
        "tube_enable": "false", "tube_drive": "2",
        "ddc_enable": "false", "ddc_file": "",
        "liveprog_enable": "false", "liveprog_file": "",
        "convolver_enable": "false", "convolver_file": "", "convolver_mode": "0", "convolver_adv_imp": "-80;-100;0;0;0;0",
    ]

    private static let rootlessKnown: Set<String> = Set(rootlessDefaults.keys).union(
        ["peq_enable", "peq_bands", "peq_preamp", "liveprog_params", "liveprog_edit",
         "convolver_sample_rate_files", "convolver_processing_rate"])

    public static func importRootless(_ archive: Data) throws -> ImportedPreset {
        let entries = try Tar.read(archive)
        var metadata: [String: String] = [:]
        if let meta = entries.first(where: { $0.name == "metadata" }) {
            for line in String(decoding: meta.data, as: UTF8.self).split(separator: "\n") {
                if let eq = line.firstIndex(of: "=") { metadata[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
            }
        }
        if metadata["is_backup"] == "true" {
            throw ConversionError("this is a RootlessJamesDSP backup, not a preset")
        }
        var prefs: [String: SharedPreferences.Value] = [:]
        var notes: [String] = []
        for entry in entries where entry.name.hasPrefix("dsp_") && entry.name.hasSuffix(".xml") {
            for (key, value) in try SharedPreferences.parse(entry.data) { prefs[key] = value }
        }
        guard !prefs.isEmpty else { throw ConversionError("no RootlessJamesDSP settings (dsp_*.xml) in this archive") }

        func raw(_ key: String) -> String { prefs[key]?.text ?? rootlessDefaults[key] ?? "" }
        func bool(_ key: String) -> Bool { raw(key) == "true" }
        func double(_ key: String) -> Double { Double(raw(key)) ?? 0 }
        func int(_ key: String) -> Int { Int(raw(key)) ?? Int(double(key)) }
        func fileName(_ key: String) -> String { (raw(key) as NSString).lastPathComponent }

        var s = DSPSettings.defaults
        s.postGain = double("output_postgain")
        s.limThreshold = double("limiter_threshold")
        s.limRelease = double("limiter_release")
        s.bassEnable = bool("bass_enable")
        s.bassMaxGain = double("bass_max_gain")
        s.companderEnable = bool("compander_enable")
        s.companderTimeConstant = double("compander_timeconstant")
        s.companderGranularity = int("compander_granularity")
        s.companderTransforms = int("compander_tftransforms")
        s.companderResponse = raw("compander_response")
        s.toneEnable = bool("eq_enable")
        s.toneEQ = raw("eq_bands")
        s.toneFilterType = int("eq_filter_type")
        s.toneInterpolation = int("eq_interpolation")
        s.graphicEQEnable = bool("geq_enable")
        s.graphicEQParam = raw("geq_nodes")
        s.reverbEnable = bool("reverb_enable")
        let preset = int("reverb_preset")
        if preset < 0 || preset >= ReverbPresets.rows.count { notes.append("Reverb preset \(preset) unknown; used Default") }
        ReverbPresets.apply(preset, to: &s)
        s.stereowideEnable = bool("stereowide_enable")
        s.stereowideLevel = double("stereowide_mode")
        s.crossfeedEnable = bool("bs2b_crossfeed_enable")
        s.crossfeedMode = int("bs2b_crossfeed_mode")
        s.tubeEnable = bool("tube_enable")
        s.tubePregain = double("tube_drive")
        s.ddcEnable = bool("ddc_enable")
        s.ddcFile = fileName("ddc_file")
        s.liveprogEnable = bool("liveprog_enable")
        s.liveprogFile = fileName("liveprog_file")
        s.convolverEnable = bool("convolver_enable")
        s.convolverFile = fileName("convolver_file")
        s.convolverOptimizationMode = int("convolver_mode")
        s.convolverWaveformEdit = raw("convolver_adv_imp")

        if prefs["peq_enable"]?.text == "true" {
            notes.append("Parametric EQ is on in this preset; audio.conf (and this app) has no parametric EQ, so it was not imported")
        }
        if let params = prefs["liveprog_params"]?.text, !params.isEmpty {
            notes.append("Liveprog script parameters (liveprog_params) are Rootless-only and were not imported")
        }
        let unknown = prefs.keys.filter { !rootlessKnown.contains($0) }.sorted()
        if !unknown.isEmpty { notes.append("Unknown Rootless keys ignored: \(unknown.joined(separator: ", "))") }
        if s.convolverEnable && !s.convolverFile.isEmpty {
            notes.append("Convolver uses \"\(s.convolverFile)\": Rootless presets do not include impulse responses, put it in the irs folder")
        }
        if s.ddcEnable && !s.ddcFile.isEmpty {
            notes.append("DDC uses \"\(s.ddcFile)\": Rootless presets do not include .vdc files, put it in the vdc folder")
        }

        var bundled: [ImportedPreset.BundledFile] = []
        if let script = entries.first(where: { $0.name == "liveprog" }) {
            let name = s.liveprogFile.isEmpty ? "imported.eel" : s.liveprogFile
            if s.liveprogFile.isEmpty { s.liveprogFile = name }
            bundled.append(.init(kind: "liveprog", name: name, data: script.data))
        }
        var conf = AudioConf(text: DefaultSettings.text)
        s.write(into: &conf)
        return ImportedPreset(conf: conf, bundledFiles: bundled, notes: notes)
    }

    /// Writes a RootlessJamesDSP preset (.tar) that Rootless's loader accepts (version 3,
    /// min_version_code 26). Returns the archive and what could not be expressed.
    public static func exportRootless(_ s: DSPSettings, liveprogScript: Data?) -> (Data, [String]) {
        typealias V = SharedPreferences.Value
        var notes: [String] = []
        let reverb = ReverbPresets.closest(to: s)
        if s.reverbEnable && !reverb.exact {
            notes.append("Reverb: Rootless only has presets; exported the closest one, \"\(ReverbPresets.names[reverb.index])\"")
        }
        var crossfeedMode = s.crossfeedMode
        if crossfeedMode == 99 || crossfeedMode < 0 || crossfeedMode > 5 {
            if s.crossfeedEnable {
                notes.append("Crossfeed: custom BS2B (fcut \(s.crossfeedFcut) Hz, feed \(s.crossfeedFeed)) is not in Rootless presets; exported as BS2B strong")
            }
            crossfeedMode = 1
        }
        if !s.masterEnable {
            notes.append("Master switch is off here; Rootless presets do not carry its power switch")
        }
        func path(_ folder: String, _ file: String) -> String {
            file.isEmpty ? "" : folder + "/" + (file as NSString).lastPathComponent
        }
        let files: [(String, [(String, V)])] = [
            ("dsp_output_control.xml", [("output_postgain", .float(s.postGain)), ("limiter_threshold", .float(s.limThreshold)),
                                        ("limiter_release", .float(s.limRelease))]),
            ("dsp_bass.xml", [("bass_enable", .bool(s.bassEnable)), ("bass_max_gain", .float(s.bassMaxGain))]),
            ("dsp_compander.xml", [("compander_enable", .bool(s.companderEnable)), ("compander_timeconstant", .float(s.companderTimeConstant)),
                                   ("compander_granularity", .float(Double(s.companderGranularity))),
                                   ("compander_tftransforms", .string(String(s.companderTransforms))),
                                   ("compander_response", .string(s.companderResponse))]),
            ("dsp_equalizer.xml", [("eq_enable", .bool(s.toneEnable)), ("eq_filter_type", .string(String(s.toneFilterType))),
                                   ("eq_interpolation", .string(String(s.toneInterpolation))), ("eq_bands", .string(s.toneEQ))]),
            ("dsp_graphiceq.xml", [("geq_enable", .bool(s.graphicEQEnable)), ("geq_nodes", .string(s.graphicEQParam))]),
            ("dsp_parametriceq.xml", [("peq_enable", .bool(false))]),
            ("dsp_reverb.xml", [("reverb_enable", .bool(s.reverbEnable)), ("reverb_preset", .string(String(reverb.index)))]),
            ("dsp_stereowide.xml", [("stereowide_enable", .bool(s.stereowideEnable)), ("stereowide_mode", .float(s.stereowideLevel))]),
            ("dsp_crossfeed.xml", [("bs2b_crossfeed_enable", .bool(s.crossfeedEnable)), ("bs2b_crossfeed_mode", .string(String(crossfeedMode)))]),
            ("dsp_tube.xml", [("tube_enable", .bool(s.tubeEnable)), ("tube_drive", .float(s.tubePregain))]),
            ("dsp_ddc.xml", [("ddc_enable", .bool(s.ddcEnable)), ("ddc_file", .string(path("DDC", s.ddcFile)))]),
            ("dsp_liveprog.xml", [("liveprog_enable", .bool(s.liveprogEnable)), ("liveprog_file", .string(path("Liveprog", s.liveprogFile)))]),
            ("dsp_convolver.xml", [("convolver_enable", .bool(s.convolverEnable)), ("convolver_file", .string(path("Convolver", s.convolverFile))),
                                   ("convolver_mode", .string(String(s.convolverOptimizationMode))),
                                   ("convolver_adv_imp", .string(s.convolverWaveformEdit))]),
        ]
        var entries = files.map { Tar.Entry(name: $0.0, data: SharedPreferences.write($0.1)) }
        if s.convolverEnable && !s.convolverFile.isEmpty {
            notes.append("Convolver: copy \"\((s.convolverFile as NSString).lastPathComponent)\" into Rootless's Convolver folder (presets do not carry IRs)")
        }
        if s.ddcEnable && !s.ddcFile.isEmpty {
            notes.append("DDC: copy \"\((s.ddcFile as NSString).lastPathComponent)\" into Rootless's DDC folder (presets do not carry .vdc files)")
        }
        let includeScript = liveprogScript != nil && !s.liveprogFile.isEmpty
        if let script = liveprogScript, includeScript { entries.append(Tar.Entry(name: "liveprog", data: script)) }
        let metadata = ["version=3", "app_version=jdsp4mac", "app_flavor=jdsp4mac",
                        "liveprog_included=\(includeScript)", "min_version_code=26"].joined(separator: "\n")
        entries.append(Tar.Entry(name: "metadata", data: Data(metadata.utf8)))
        return (Tar.write(entries), notes)
    }

    // MARK: JamesDSP for Android (root, DSPManager)

    /// Android's own defaults (`HeadsetService.java` getString defaults).
    private static let androidDefaults: [String: String] = [
        "dsp.masterswitch.limthreshold": "-0.1", "dsp.masterswitch.limrelease": "60", "dsp.masterswitch.postgain": "0",
        "dsp.compression.timeconstant": "0.22", "dsp.compression.granularity": "4", "dsp.compression.tfresolution": "0",
        "dsp.compression.eq.custom": "95.0;200.0;400.0;800.0;1600.0;3400.0;7500.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0",
        "dsp.bass.maxgain": "5",
        "dsp.tone.eq.custom": "25.0;40.0;63.0;100.0;160.0;250.0;400.0;630.0;1000.0;1600.0;2500.0;4000.0;6300.0;10000.0;16000.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0;0.0",
        "dsp.tone.filtertype": "3", "dsp.tone.interpolation": "0",
        "dsp.streq.stringp": "GraphicEQ: 0.0 0.0; ", "dsp.headphone.preset": "0", "dsp.stereowide.mode": "60",
        "dsp.bs2b.mode": "0", "dsp.analogmodelling.tubedrive": "2",
        "dsp.convolver.files": "", "dsp.convolver.mode": "0", "dsp.convolver.advimp": "-80;-100;23;12;17;28",
        "dsp.ddc.files": "", "dsp.liveprog.files": "",
    ]

    /// Imports one output profile (james.dsp.speaker.xml / headset.xml / bluetooth.xml).
    public static func importAndroid(_ xml: Data) throws -> ImportedPreset {
        let prefs = try SharedPreferences.parse(xml)
        guard prefs.keys.contains(where: { $0.hasPrefix("dsp.") }) else {
            throw ConversionError("no JamesDSP settings (dsp.*) in this file")
        }
        func raw(_ key: String) -> String { prefs[key]?.text ?? androidDefaults[key] ?? "" }
        func bool(_ key: String) -> Bool { raw(key) == "true" }
        func double(_ key: String) -> Double { Double(raw(key)) ?? 0 }
        func int(_ key: String) -> Int { Int(raw(key)) ?? Int(double(key)) }
        func fileName(_ key: String) -> String { (raw(key) as NSString).lastPathComponent }
        var notes: [String] = []

        var s = DSPSettings.defaults
        s.masterEnable = bool("dsp.masterswitch.enable")
        s.limThreshold = double("dsp.masterswitch.limthreshold")
        s.limRelease = double("dsp.masterswitch.limrelease")
        s.postGain = double("dsp.masterswitch.postgain")
        s.bassEnable = bool("dsp.bass.enable")
        s.bassMaxGain = double("dsp.bass.maxgain")
        s.companderEnable = bool("dsp.compression.enable")
        s.companderTimeConstant = double("dsp.compression.timeconstant")
        s.companderGranularity = int("dsp.compression.granularity")
        s.companderTransforms = int("dsp.compression.tfresolution")
        s.companderResponse = raw("dsp.compression.eq.custom")
        s.toneEnable = bool("dsp.tone.enable")
        s.toneEQ = raw("dsp.tone.eq.custom")
        s.toneFilterType = int("dsp.tone.filtertype")
        s.toneInterpolation = int("dsp.tone.interpolation")
        s.graphicEQEnable = bool("dsp.streq.enable")
        s.graphicEQParam = raw("dsp.streq.stringp")
        s.reverbEnable = bool("dsp.headphone.enable")
        ReverbPresets.apply(int("dsp.headphone.preset"), to: &s)
        s.stereowideEnable = bool("dsp.stereowide.enable")
        s.stereowideLevel = double("dsp.stereowide.mode")
        s.crossfeedEnable = bool("dsp.bs2b.enable")
        s.crossfeedMode = int("dsp.bs2b.mode")
        s.tubeEnable = bool("dsp.analogmodelling.enable")
        s.tubePregain = double("dsp.analogmodelling.tubedrive") * 100  // Android: dB; audio.conf: dB x 100
        s.convolverEnable = bool("dsp.convolver.enable")
        s.convolverFile = fileName("dsp.convolver.files")
        s.convolverOptimizationMode = int("dsp.convolver.mode")
        s.convolverWaveformEdit = raw("dsp.convolver.advimp")
        s.ddcEnable = bool("dsp.ddc.enable")
        s.ddcFile = fileName("dsp.ddc.files")
        s.liveprogEnable = bool("dsp.liveprog.enable")
        s.liveprogFile = fileName("dsp.liveprog.files")
        for (enabled, file, folder) in [(s.convolverEnable, s.convolverFile, "irs"), (s.ddcEnable, s.ddcFile, "vdc"),
                                        (s.liveprogEnable, s.liveprogFile, "liveprog")] where enabled && !file.isEmpty {
            notes.append("Uses \"\(file)\": Android presets do not include it, put it in the \(folder) folder")
        }
        if prefs["dsp.convolver.resampler"] != nil { notes.append("dsp.convolver.resampler has no audio.conf equivalent; ignored") }
        var conf = AudioConf(text: DefaultSettings.text)
        s.write(into: &conf)
        return ImportedPreset(conf: conf, bundledFiles: [], notes: notes)
    }
}
