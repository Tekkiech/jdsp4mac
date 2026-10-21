// jdspconf: inspect and edit JDSP4Linux-format presets (audio.conf).
//
//   jdspconf roundtrip <file>...      load and re-save; fails if the text changes
//   jdspconf show <file>              print the typed settings (defaults filled in)
//   jdspconf set <file> key=value...  change values in place (Linux formatting rules)
//   jdspconf defaults <file>          write JDSP4Linux's default.conf (all effects off)
//   jdspconf export-rootless <conf> <out.tar> [liveprog.eel]
//   jdspconf import-rootless <in.tar> <out.conf>
//   jdspconf import-android <james.dsp.headset.xml> <out.conf>
//   jdspconf render <preset> <in.wav> [out.wav] [--library dir]
//                                     build the DSP exactly as the app does and run a file through it

import Config
import Engine
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func load(_ path: String) -> (String, AudioConf) {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
        fail("cannot read \(path)")
    }
    return (text, AudioConf(text: text))
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "roundtrip":
    var failures = 0
    for path in args.dropFirst() {
        let (text, conf) = load(path)
        var rewritten = conf
        DSPSettings(conf: conf).write(into: &rewritten)
        let plain = conf.text == text
        // Writing typed settings back only adds keys that were missing; existing lines stay as they were.
        let existingUnchanged = conf.keys.allSatisfy { rewritten.raw($0) == conf.raw($0) }
        let reparsed = DSPSettings(conf: AudioConf(text: rewritten.text)) == DSPSettings(conf: conf)
        let ok = plain && existingUnchanged && reparsed
        print("\(ok ? "ok  " : "FAIL") \(path)  (text \(plain), existing lines \(existingUnchanged), typed \(reparsed), keys \(conf.keys.count))")
        if !ok { failures += 1 }
    }
    exit(failures == 0 ? 0 : 1)
case "defaults":
    guard args.count == 2 else { fail("defaults <file>") }
    let text = DefaultSettings.text.hasSuffix("\n") ? DefaultSettings.text : DefaultSettings.text + "\n"
    do { try text.write(toFile: args[1], atomically: true, encoding: .utf8) } catch { fail("\(error)") }
case "show":
    guard args.count == 2 else { fail("show <file>") }
    let settings = DSPSettings(conf: load(args[1]).1)
    for child in Mirror(reflecting: settings).children {
        print("\(child.label ?? "?") = \(child.value)")
    }
case "set":
    guard args.count >= 3 else { fail("set <file> key=value...") }
    var (_, conf) = load(args[1])
    for pair in args.dropFirst(2) {
        do { try DSPSettings.set(pair, in: &conf) } catch { fail("\(error)") }
    }
    // Write atomically so a watcher never sees a half-written file.
    do { try conf.text.write(toFile: args[1], atomically: true, encoding: .utf8) } catch { fail("\(error)") }
case "export-rootless":
    guard args.count >= 3 else { fail("export-rootless <conf> <out.tar> [liveprog.eel]") }
    let settings = DSPSettings(conf: load(args[1]).1)
    let script = args.count > 3 ? FileManager.default.contents(atPath: args[3]) : nil
    let (archive, notes) = PresetConversion.exportRootless(settings, liveprogScript: script)
    do { try archive.write(to: URL(fileURLWithPath: args[2])) } catch { fail("\(error)") }
    for n in notes { print("note: \(n)") }
case "import-rootless", "import-android":
    guard args.count == 3, let data = FileManager.default.contents(atPath: args[1]) else { fail("\(args[0]) <in> <out.conf>") }
    do {
        let imported = args[0] == "import-rootless" ? try PresetConversion.importRootless(data) : try PresetConversion.importAndroid(data)
        try imported.conf.text.write(toFile: args[2], atomically: true, encoding: .utf8)
        for f in imported.bundledFiles { print("bundled \(f.kind): \(f.name) (\(f.data.count) bytes)") }
        for n in imported.notes { print("note: \(n)") }
    } catch {
        fail("\(error)")
    }
case "render":
    var rest = Array(args.dropFirst())
    var library = FileLibrary.standard
    if let i = rest.firstIndex(of: "--library"), i + 1 < rest.count {
        library = FileLibrary(root: URL(fileURLWithPath: rest[i + 1]))
        rest.removeSubrange(i...(i + 1))
    }
    guard rest.count >= 2 else { fail("render <preset> <in.wav> [out.wav] [--library dir]") }
    let settings = DSPSettings(conf: load(rest[0]).1)
    do {
        let r = try OfflineRender.render(settings: settings, library: library, input: URL(fileURLWithPath: rest[1]),
                                         output: rest.count > 2 ? URL(fileURLWithPath: rest[2]) : nil)
        print(String(format: "build %.3f s, CPU %.2f%% of real time, longest block %.3f ms (budget %.2f ms), %@, in peak %.3f, out peak %.3f",
                     r.buildSeconds, r.processSeconds / r.audioSeconds * 100, r.maxBlockSeconds * 1000, 512.0 / 48.0,
                     r.finite ? "finite" : "NaN/Inf",
                     r.inPeak, r.outPeak))
        for m in r.messages { print("  message: \(m)") }
        exit(r.finite ? 0 : 1)
    } catch {
        fail("\(error)")
    }
default:
    fail("usage: jdspconf roundtrip <file>... | show <file> | set <file> key=value... | render <preset> <in.wav> [out.wav]")
}
