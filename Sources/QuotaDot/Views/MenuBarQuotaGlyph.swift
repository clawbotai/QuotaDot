import AppKit
import SwiftUI

struct MenuBarQuotaGlyph: View {
    var body: some View {
        Image(nsImage: Self.templateImage)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }

    private static let templateImage: NSImage = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let quotaRing = NSBezierPath(
                ovalIn: NSRect(
                    x: rect.midX - 5.05,
                    y: rect.midY - 4.55,
                    width: 9.4,
                    height: 9.4
                )
            )
            quotaRing.lineWidth = 1.9
            quotaRing.lineCapStyle = .round
            quotaRing.lineJoinStyle = .round
            quotaRing.stroke()

            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: rect.midX + 1.45, y: rect.midY - 1.75))
            tail.line(to: NSPoint(x: rect.midX + 4.65, y: rect.midY - 4.95))
            tail.lineWidth = 1.9
            tail.lineCapStyle = .round
            tail.lineJoinStyle = .round
            tail.stroke()

            NSBezierPath(
                ovalIn: NSRect(
                    x: rect.midX + 4.05,
                    y: rect.midY + 3.85,
                    width: 2.4,
                    height: 2.4
                )
            ).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
