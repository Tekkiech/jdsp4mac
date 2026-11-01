import AppKit
import Engine
import Carbon.HIToolbox

/// Global keyboard shortcuts (Settings › General). Carbon hot keys work while another app is
/// frontmost and need no Accessibility permission. None are set until the user records one.
@MainActor
@Observable
final class Hotkeys {
    enum Action: String, CaseIterable, Identifiable {
        case toggleEffects, nextPreset, previousPreset
        var id: String { rawValue }
        var title: String {
            switch self {
            case .toggleEffects: "Turn effects on or off"
            case .nextPreset: "Next preset"
            case .previousPreset: "Previous preset"
            }
        }
    }

    struct Shortcut: Codable, Equatable {
        let keyCode: UInt32
        let modifiers: UInt32  // Carbon: cmdKey, optionKey, controlKey, shiftKey
        let display: String
    }

    private(set) var shortcuts: [Action: Shortcut] = [:]
    /// Actions whose shortcut another app already owns.
    private(set) var conflicts: Set<Action> = []

    @ObservationIgnored private var refs: [Action: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    /// What a pressed shortcut does; set by the owner.
    @ObservationIgnored var perform: ((Action) -> Void)?

    init() {
        for action in Action.allCases {
            if let data = UserDefaults.standard.data(forKey: "hotkey." + action.rawValue),
               let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) {
                shortcuts[action] = shortcut
            }
        }
    }

    func start() {
        installHandler()
        for (action, shortcut) in shortcuts { register(action, shortcut) }
    }

    func set(_ action: Action, _ shortcut: Shortcut?) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        conflicts.remove(action)
        shortcuts[action] = shortcut
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: "hotkey." + action.rawValue)
            register(action, shortcut)
        } else {
            UserDefaults.standard.removeObject(forKey: "hotkey." + action.rawValue)
        }
    }

    private static let signature: OSType = 0x4A44_5350  // 'JDSP'

    private func register(_ action: Action, _ shortcut: Shortcut) {
        let index = UInt32(Action.allCases.firstIndex(of: action)!)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: index),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[action] = ref
        } else {
            conflicts.insert(action)
            Log.write("hotkey \(shortcut.display) for \(action.rawValue) not registered: \(status)")
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == Hotkeys.signature, let context,
                  Int(id.id) < Action.allCases.count else { return OSStatus(eventNotHandledErr) }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            let action = Action.allCases[Int(id.id)]
            DispatchQueue.main.async { MainActor.assumeIsolated { hotkeys.perform?(action) } }
            return noErr
        }, 1, &spec, context, &handler)
    }

    // MARK: Recording

    /// A shortcut from a key press, or nil unless it uses Command, Control or Option.
    static func shortcut(from event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: carbon, display: symbols + keyName(event))
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        default:
            // Function-key codes are not contiguous, hence the table.
            let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            if let n = fKeys.firstIndex(of: Int(event.keyCode)) { return "F\(n + 1)" }
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}
