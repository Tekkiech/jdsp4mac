// Test fixture for Tests/exclusion.sh: an app whose audio comes from WebKit, like Safari's. It
// plays the wav given as the first argument in a WKWebView (off screen), so the sound comes out of
// a com.apple.WebKit.GPU process that this app is responsible for.
import AppKit
import WebKit

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wav = URL(fileURLWithPath: CommandLine.arguments[1])
        let dir = wav.deletingLastPathComponent()
        let page = dir.appendingPathComponent("webplayer.html")
        try? "<audio src=\"\(wav.lastPathComponent)\" autoplay loop></audio>".write(to: page, atomically: true, encoding: .utf8)
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
        window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 100, height: 100), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.contentView = web
        window.orderFrontRegardless()
        web.loadFileURL(page, allowingReadAccessTo: dir)
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
