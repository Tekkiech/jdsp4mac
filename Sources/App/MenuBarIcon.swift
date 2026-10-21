import AppKit

enum IconState { case on, bypassed, problem }

/// The menu bar glyph from the brand sheet (`Claude Design Branding/`, "Menu bar glyph"): a ring
/// with a three-bar waveform; bypassed adds a slash, problem replaces the waveform with "!".
/// Drawn from the design's 18 pt SVG geometry as a template image, so macOS tints it for the
/// menu bar's appearance.
enum MenuBarIcon {
    static func image(_ state: IconState) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, width: CGFloat) {
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x1, y: y1))
                p.line(to: NSPoint(x: x2, y: y2))
                p.lineWidth = width
                p.lineCapStyle = .round
                p.stroke()
            }
            let ring = NSBezierPath(ovalIn: NSRect(x: 9 - 7.3, y: 9 - 7.3, width: 14.6, height: 14.6))
            ring.lineWidth = 1.4
            ring.stroke()
            if state == .problem {
                line(9, 5.2, 9, 10, width: 1.6)
                NSBezierPath(ovalIn: NSRect(x: 9 - 0.95, y: 12.6 - 0.95, width: 1.9, height: 1.9)).fill()
            } else {
                line(6.5, 7.5, 6.5, 10.5, width: 1.5)
                line(9, 6, 9, 12, width: 1.5)
                line(11.5, 6.75, 11.5, 11.25, width: 1.5)
            }
            if state == .bypassed {
                // Knock a gap out of the drawing under the slash, then draw the slash.
                NSGraphicsContext.current?.compositingOperation = .clear
                line(2.5, 2.5, 15.5, 15.5, width: 4)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                line(2.5, 2.5, 15.5, 15.5, width: 1.5)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = switch state {
        case .on: "jdsp4mac: processing"
        case .bypassed: "jdsp4mac: bypassed"
        case .problem: "jdsp4mac: needs attention"
        }
        return image
    }
}
