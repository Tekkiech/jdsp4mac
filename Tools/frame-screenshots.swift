// Frames raw app renders (from `jdsp4mac --screenshots`) for the README and posts: rounded
// corners, a hairline edge and a soft shadow on the brand sheet's background (macOS system greys).
// Files with "dark" in the name get the dark background. Also makes two side-by-side heroes.
// Run: swift Tools/frame-screenshots.swift <raw dir> <out dir>
import AppKit

let args = CommandLine.arguments
let raw = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func load(_ name: String) -> CGImage {
    let rep = NSBitmapImageRep(data: try! Data(contentsOf: raw.appendingPathComponent(name)))!
    return rep.cgImage!
}

/// Draws `images` side by side on one canvas and writes a PNG. Sizes are in pixels (2x).
func frame(_ images: [CGImage], dark: Bool, to name: String, padding: CGFloat = 120, gap: CGFloat = 96) {
    let width = images.reduce(0) { $0 + CGFloat($1.width) } + gap * CGFloat(images.count - 1) + padding * 2
    let height = CGFloat(images.map(\.height).max()!) + padding * 2
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Background: the brand sheet's system greys, a slight vertical gradient.
    let top = dark ? color(0x2c2c2e) : color(0xf5f5f7), bottom = dark ? color(0x0b0b0c) : color(0xe3e3e8)
    let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
    var x = padding
    for image in images {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rect = CGRect(x: x, y: (height - h) / 2, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: 24, cornerHeight: 24, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 60, color: color(0, dark ? 0.7 : 0.22))
        ctx.addPath(path)
        ctx.setFillColor(dark ? color(0x1c1c1e) : color(0xffffff))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(dark ? color(0xffffff, 0.12) : color(0, 0.08))
        ctx.setLineWidth(2)
        ctx.strokePath()
        x += w + gap
    }
    let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    try! png.write(to: out.appendingPathComponent(name))
    print("wrote \(name) \(Int(width))x\(Int(height))")
}

let names = try FileManager.default.contentsOfDirectory(atPath: raw.path).filter { $0.hasSuffix(".png") }.sorted()
for name in names {
    frame([load(name)], dark: name.contains("dark"), to: name)
}
// Heroes: the panel next to a settings tab.
frame([load("panel-dark-eq.png"), load("settings-autoeq-dark.png")], dark: true, to: "hero-dark.png")
frame([load("panel-light-autoeq.png"), load("settings-apps-light.png")], dark: false, to: "hero-light.png")
