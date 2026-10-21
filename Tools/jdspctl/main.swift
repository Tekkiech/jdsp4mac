// jdspctl: command-line control of jdsp4mac, with JDSP4Linux's remote options (`jamesdsp --help`).
//
// Settings, presets and preset rules are files the app watches (audio.conf, presets/, rules.json),
// so changing them here reaches the running app without IPC, and works while it is not running.
// --status and --is-connected read status.json, which the app keeps current.

import Config
import Engine
import Foundation

let usage = """
    usage: jdspctl <option> [argument]

      --is-connected               exit 0 if jdsp4mac is running, 1 if not
      --status                     show what jdsp4mac is doing
      --list-keys                  list audio.conf keys
      --get-all                    print every setting as key=value
      --get <key>                  print one setting
      --set <key=value>            change a setting (repeatable); the running app applies it
      --list-presets               list presets
      --load-preset <name>         make a preset the current settings
      --save-preset <name>         save the current settings as a preset
      --delete-preset <name>       delete a preset (and its rules)
      --list-devices               list output devices (id, channels, name; * = current)
      --list-preset-rules          list per-output preset rules
      --set-preset-rule <id=name>  load preset <name> whenever output <id> becomes active
      --delete-preset-rule <id>    remove the rule for output <id>
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("jdspctl: " + message + "\n").utf8))
    exit(code)
}

let settings = SettingsStore()
let presets = PresetStore(settings: settings)

func currentConf() -> AudioConf {
    (try? AudioConf(contentsOf: settings.url)) ?? AudioConf(text: DefaultSettings.text)
}

/// A value as audio.conf holds it, falling back to JDSP4Linux's default for a missing key.
func value(_ key: String, _ conf: AudioConf) -> String {
    conf.raw(key) ?? AudioConf(text: DefaultSettings.text).raw(key) ?? ""
}

func device(matching id: String) -> OutputDevice? {
    let devices = OutputDevices.list()
    return devices.first { $0.uid == id } ?? devices.first { $0.name == id }
}

func requirePreset(_ name: String) {
    guard presets.list().contains(name) else { fail("no preset named \"\(name)\" (see --list-presets)") }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let option = args.first else { print(usage); exit(0) }
let argument = args.count > 1 ? args[1] : nil
func needArgument(_ what: String) -> String {
    guard let argument else { fail("\(option) needs \(what)") }
    return argument
}

switch option {
case "-h", "--help":
    print(usage)

case "--is-connected":
    exit(AppStatus.read() == nil ? 1 : 0)

case "--status":
    guard let s = AppStatus.read() else { print("jdsp4mac is not running"); exit(1) }
    print("State:   \(s.state)")
    print("Detail:  \(s.detail)")
    if let output = s.output { print("Output:  \(output)") }
    if let rate = s.sampleRate, let frames = s.bufferFrames {
        print(String(format: "Format:  %.0f Hz, %u frames (%.2f ms)", rate, frames, Double(frames) / rate * 1000))
    }
    let preset = presets.list().first { presets.settings(of: [$0])[$0] == DSPSettings(conf: currentConf()) }
    print("Preset:  \(preset ?? "custom")")
    for p in s.problems { print("Problem: \(p)") }

case "--list-keys":
    DSPSettings.allKeys.forEach { print($0) }

case "--get-all":
    let conf = currentConf()
    for key in DSPSettings.allKeys { print("\(key)=\(value(key, conf))") }

case "--get":
    let key = needArgument("a key")
    guard DSPSettings.allKeys.contains(key) else { fail("unknown key \(key) (see --list-keys)") }
    print(value(key, currentConf()))

case "--set":
    // Every argument after --set is a key=value pair (one or more, written in one go).
    let pairs = Array(args.dropFirst())
    guard !pairs.isEmpty else { fail("--set needs key=value") }
    var conf = currentConf()
    for pair in pairs {
        do { try DSPSettings.set(pair, in: &conf) } catch { fail("\(error)") }
    }
    do { try conf.text.write(to: settings.url, atomically: true, encoding: .utf8) } catch { fail("\(error)") }

case "--list-presets":
    presets.list().forEach { print($0) }

case "--load-preset":
    let name = needArgument("a preset name")
    requirePreset(name)
    do {
        for note in try presets.load(name) { print("note: \(note)") }
    } catch { fail("\(error)") }

case "--save-preset":
    do { try presets.save(as: needArgument("a preset name")) } catch { fail("\(error)") }

case "--delete-preset":
    let name = needArgument("a preset name")
    requirePreset(name)
    do { try presets.delete(name) } catch { fail("\(error)") }

case "--list-devices":
    let current = OutputDevices.defaultUID()
    for d in OutputDevices.list() {
        print("\(d.uid == current ? "*" : " ") \(d.uid)\t\(d.channels) ch\t\(d.name)")
    }

case "--list-preset-rules":
    for r in presets.rules() { print("\(r.deviceUID)\t\(r.deviceName)\t\(r.preset)") }

case "--set-preset-rule":
    let pair = needArgument("deviceId=presetName")
    guard let eq = pair.lastIndex(of: "=") else { fail("expected deviceId=presetName") }
    let id = String(pair[..<eq]), name = String(pair[pair.index(after: eq)...])
    requirePreset(name)
    guard let d = device(matching: id) else { fail("no output device \"\(id)\" (see --list-devices)") }
    presets.setRule(deviceUID: d.uid, deviceName: d.name, preset: name)

case "--delete-preset-rule":
    let id = needArgument("a device id")
    guard let rule = presets.rules().first(where: { $0.deviceUID == id || $0.deviceName == id }) else {
        fail("no rule for \"\(id)\" (see --list-preset-rules)")
    }
    presets.setRule(deviceUID: rule.deviceUID, deviceName: rule.deviceName, preset: nil)

default:
    fail("unknown option \(option)\n\(usage)", code: 2)
}
