// Renders the app icon from the brand sheet ("Claude Design Branding/", component "Icon", dark
// variant) into Sources/App/Assets.xcassets/AppIcon.appiconset. Same geometry as the design's
// 1024-unit SVG; below 64 pt the tick scale and ring drop out and the waveform thickens.
// Run: swift Tools/make-app-icon.swift
import AppKit

let out = URL(fileURLWithPath: "Sources/App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func render(points: Int, scale: Int) -> Data {
    let px = points * scale
    let detail = points >= 64
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // SVG coordinates: 1024 units, y down.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: CGFloat(px) / 1024, y: -CGFloat(px) / 1024)

    func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: w), cornerWidth: r, cornerHeight: r, transform: nil)
    }
    func vertical(_ path: CGPath, _ top: CGColor, _ bottom: CGColor, from y0: CGFloat, to y1: CGFloat, stroke: CGFloat? = nil) {
        ctx.saveGState()
        ctx.addPath(path)
        if let w = stroke { ctx.setLineWidth(w); ctx.replacePathWithStrokedPath() }
        ctx.clip()
        let g = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    func line(_ a: CGPoint, _ b: CGPoint, _ c: CGColor, _ w: CGFloat) {
        ctx.setStrokeColor(c); ctx.setLineWidth(w); ctx.setLineCap(.round)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
    }
    func pt(_ deg: CGFloat, _ r: CGFloat) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: 512 + r * sin(a), y: 512 - r * cos(a))
    }

    ctx.setFillColor(color(0, 0.10)); ctx.addPath(rounded(104, 124, 816, 184)); ctx.fillPath()
    ctx.setFillColor(color(0, 0.14)); ctx.addPath(rounded(100, 114, 824, 186)); ctx.fillPath()
    vertical(rounded(100, 100, 824, 186), color(0x3a3a3c), color(0x141415), from: 100, to: 924)
    // Rim: white at 0.28 fading to nothing 30 % of the way down.
    vertical(rounded(102, 102, 820, 184), color(0xffffff, 0.28), color(0xffffff, 0), from: 102, to: 102 + 820 * 0.3, stroke: 4)
    if detail {
        for t in 0...10 {
            let d = -135 + CGFloat(t) * 27
            line(pt(d, 300), pt(d, 330), color(0xffffff, 0.45), 8)
        }
    }
    ctx.setFillColor(color(0, 0.4)); ctx.fillEllipse(in: CGRect(x: 512 - 272, y: 530 - 272, width: 544, height: 544))
    vertical(CGPath(ellipseIn: CGRect(x: 240, y: 240, width: 544, height: 544), transform: nil), color(0xf2f2f7), color(0x9a9aa0), from: 240, to: 784)
    if detail {
        ctx.setStrokeColor(color(0xffffff)); ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(x: 512 - 244, y: 512 - 244, width: 488, height: 488))
    }
    line(pt(40, detail ? 196 : 180), pt(40, 236), color(0x0a84ff), detail ? 14 : 22)
    let heights: [CGFloat] = detail ? [70, 140, 200, 120, 76] : [90, 180, 240, 150, 96]
    let bw: CGFloat = detail ? 22 : 34, step: CGFloat = detail ? 40 : 52
    ctx.setFillColor(color(0x3a3a3c))
    for (i, h) in heights.enumerated() {
        let cx = 512 + CGFloat(i - 2) * step
        ctx.addPath(CGPath(roundedRect: CGRect(x: cx - bw / 2, y: 512 - h / 2, width: bw, height: h), cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil))
        ctx.fillPath()
    }
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(points: points, scale: scale).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
let catalog: [String: Any] = ["info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted])
    .write(to: out.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(out.path)")
