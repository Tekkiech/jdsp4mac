import AppKit
import CryptoKit
import Engine
import Foundation
import Security

/// Installs a release over the running app: downloads the zip, checks it against its .sha256,
/// unpacks it next to the app, checks that the new app is signed with the same certificate as this
/// one (this app's designated requirement), swaps it in and relaunches. Files the app downloads
/// itself carry no quarantine flag, so the new version opens without the Open Anyway step.
enum UpdateInstaller {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Why this copy cannot update itself, or nil if it can.
    static let blocker: String? = {
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") { return "Move jdsp4mac to Applications to install updates from here." }
        guard ownRequirement() != nil else { return "This build is signed ad-hoc, so it cannot check an update's signature." }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path), fm.isWritableFile(atPath: app.path) else {
            return "No permission to replace \(app.path)."
        }
        return nil
    }()

    static func install(version: String, zip: URL, checksum: URL, status: @MainActor (String) -> Void) async throws {
        let app = Bundle.main.bundleURL
        let fm = FileManager.default
        // On the app's volume, so the swap is a rename.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? fm.removeItem(at: work) }

        await status("Downloading \(version)…")
        let (downloaded, response) = try await URLSession.shared.download(from: zip)
        try checkResponse(response)
        let archive = work.appendingPathComponent(zip.lastPathComponent)
        try fm.moveItem(at: downloaded, to: archive)
        let (sum, sumResponse) = try await URLSession.shared.data(from: checksum)
        try checkResponse(sumResponse)
        let expected = String(decoding: sum, as: UTF8.self).split(separator: " ").first.map { $0.lowercased() } ?? ""
        let actual = SHA256.hash(data: try Data(contentsOf: archive, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw Failure("The download does not match its checksum.") }

        await status("Installing \(version)…")
        let newApp = try await Task.detached { try unpackAndVerify(archive, into: work, version: version) }.value
        _ = try fm.replaceItemAt(app, withItemAt: newApp)
        Log.write("update: installed \(version) at \(app.path), relaunching")
    }

    /// Waits for this process to exit (quitting tears the tap down), then opens the app again.
    @MainActor static func relaunch() {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                           Bundle.main.bundlePath]
        do { try shell.run() } catch { Log.write("update: relaunch failed: \(error)") }
        NSApp.terminate(nil)
    }

    private static func unpackAndVerify(_ archive: URL, into work: URL, version: String) throws -> URL {
        let dest = work.appendingPathComponent("unpacked")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, dest.path]
        try ditto.run()
        ditto.waitUntilExit()
        let newApp = dest.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        guard ditto.terminationStatus == 0, let info = Bundle(url: newApp)?.infoDictionary else {
            throw Failure("The download has no \(Bundle.main.bundleURL.lastPathComponent) in it.")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else {
            throw Failure("The download is not jdsp4mac \(version).")
        }
        guard let requirement = ownRequirement() else { throw Failure("This build cannot check signatures.") }
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(newApp as CFURL, [], &code)
        if status == errSecSuccess, let code {
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
            status = SecStaticCodeCheckValidity(code, flags, requirement)
        }
        guard status == errSecSuccess else {
            Log.write("update: signature check failed: \(status)")
            throw Failure("The download is not signed by the jdsp4mac release certificate.")
        }
        // Extracted files can inherit the archive's quarantine flag; ours has none, but be sure.
        if let files = FileManager.default.enumerator(atPath: newApp.path) {
            removexattr(newApp.path, "com.apple.quarantine", XATTR_NOFOLLOW)
            for case let file as String in files {
                removexattr(newApp.appendingPathComponent(file).path, "com.apple.quarantine", XATTR_NOFOLLOW)
            }
        }
        return newApp
    }

    /// This app's designated requirement, or nil when it is signed ad-hoc (the requirement is then
    /// its own hash, which no other build can meet).
    private static func ownRequirement() -> SecRequirement? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32,
              flags & SecCodeSignatureFlags.adhoc.rawValue == 0,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }

    private static func checkResponse(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure("Download failed (HTTP \(http.statusCode)).")
        }
    }
}
