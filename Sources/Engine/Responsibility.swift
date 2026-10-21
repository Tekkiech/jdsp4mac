import Darwin
import Foundation

/// Which app is responsible for a process: WebKit's per-app GPU process, XPC services and helpers
/// run as separate processes, but macOS records the app they work for (Activity Monitor groups
/// them by it). The call is private (`responsibility_get_pid_responsible_for_pid` in libSystem), so
/// it is looked up at run time; without it, callers fall back to the process's own bundle ID.
enum Responsibility {
    private typealias Function = @convention(c) (pid_t) -> pid_t
    nonisolated(unsafe) private static let function: Function? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static var isAvailable: Bool { function != nil }

    /// Bundle ID of the app responsible for `pid`, if that is another process with a bundle.
    static func bundleID(responsibleFor pid: pid_t) -> String? {
        guard let function else { return nil }
        let owner = function(pid)
        guard owner > 0, owner != pid else { return nil }
        return bundleID(of: owner)
    }

    /// Bundle ID of the .app / .appex whose executable `pid` runs.
    static func bundleID(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        var url = URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        while url.path != "/" {
            if ["app", "appex"].contains(url.pathExtension) { return Bundle(url: url)?.bundleIdentifier }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
