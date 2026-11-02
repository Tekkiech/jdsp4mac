import Engine
import Foundation
import Observation

/// Asks GitHub for the latest release at launch and once a day, if enabled (Settings › General).
/// One unauthenticated request to the public releases API; nothing about the user or the Mac is
/// sent. Pre-releases and drafts are ignored. Installing one is UpdateInstaller's job.
@MainActor
@Observable
final class UpdateCheck {
    struct Release: Equatable {
        let version: String
        let url: URL
        /// The release's zip and .sha256 assets, when it has them.
        let zip: URL?
        let checksum: URL?
    }

    enum Install: Equatable {
        case idle
        case working(String)
        case failed(String)
    }

    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/Tekkiech/jdsp4mac/releases/latest")!

    /// A newer release than this build, if the last check found one.
    private(set) var available: Release?
    private(set) var lastChecked: Date?
    private(set) var lastError: String?
    private(set) var checking = false
    private(set) var install = Install.idle
    /// Hides the panel row until the next launch.
    var dismissed = false

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "checkForUpdates")
            if enabled { Task { await checkIfDue() } }
        }
    }

    /// The running build's version. Test hook: --test-update-version 0.0.9 pretends to be older.
    let currentVersion: String
    /// Test hook: --test-update-feed <url> reads a releases/latest JSON from elsewhere.
    let feed: URL

    @ObservationIgnored private var timer: Timer?

    init() {
        UserDefaults.standard.register(defaults: ["checkForUpdates": true])
        enabled = UserDefaults.standard.bool(forKey: "checkForUpdates")
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--test-update-version"), i + 1 < args.count {
            currentVersion = args[i + 1]
        } else {
            currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        }
        if let i = args.firstIndex(of: "--test-update-feed"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
            feed = url
        } else {
            feed = Self.latestReleaseAPI
        }
    }

    /// Checks now if due, then re-evaluates every hour (a check is due once a day).
    func start() {
        Task { await checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }

    private func checkIfDue() async {
        guard enabled else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 23 * 3600 { return }
        await checkNow()
    }

    func checkNow() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: feed, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            struct Latest: Decodable {
                let tag_name: String; let html_url: URL; let draft: Bool; let prerelease: Bool; let assets: [Asset]
            }
            let latest = try JSONDecoder().decode(Latest.self, from: data)
            lastChecked = Date()
            lastError = nil
            let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
            if !latest.draft, !latest.prerelease, Self.isNewer(version, than: currentVersion) {
                let zip = latest.assets.first { $0.name == "jdsp4mac-\(version)-arm64.zip" }?.browser_download_url
                let checksum = latest.assets.first { $0.name == "jdsp4mac-\(version)-arm64.zip.sha256" }?.browser_download_url
                available = Release(version: version, url: latest.html_url, zip: zip, checksum: checksum)
            } else {
                available = nil
            }
            Log.write("update check: latest \(latest.tag_name), this build \(currentVersion), \(available == nil ? "up to date" : "update available")")
            if CommandLine.arguments.contains("--test-install-update"), available != nil { installAvailable() }
        } catch {
            lastError = error.localizedDescription
            Log.write("update check failed: \(error)")
        }
    }

    /// Whether the panel can offer Install (otherwise it offers the release page).
    var canInstall: Bool {
        guard let available, available.zip != nil, available.checksum != nil, UpdateInstaller.blocker == nil else { return false }
        if case .failed = install { return false }
        return true
    }

    func installAvailable() {
        guard let available, let zip = available.zip, let checksum = available.checksum, install == .idle else { return }
        Task {
            do {
                try await UpdateInstaller.install(version: available.version, zip: zip, checksum: checksum) { self.install = .working($0) }
                UpdateInstaller.relaunch()
            } catch {
                Log.write("update: install of \(available.version) failed: \(error)")
                install = .failed(error.localizedDescription)
            }
        }
    }

    /// Numeric comparison of dotted versions: 0.10.0 > 0.9.1, 1.0 == 1.0.0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
