import AppKit

enum StatusItemIcon {
    private static let designSize: CGFloat = 18

    static func make() -> NSImage {
        let size = NSSize(width: designSize, height: designSize)
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }

            context.saveGState()
            defer { context.restoreGState() }
            context.scaleBy(
                x: bounds.width / designSize,
                y: bounds.height / designSize
            )
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)

            fillCard(
                in: context,
                rect: CGRect(x: 1.5, y: 7.2, width: 10.2, height: 7.1),
                opacity: 0.48
            )
            fillCard(
                in: context,
                rect: CGRect(x: 3.4, y: 5.4, width: 10.7, height: 7.7),
                opacity: 0.72
            )
            fillCard(
                in: context,
                rect: CGRect(x: 5.3, y: 3.5, width: 11.2, height: 8.2),
                opacity: 1
            )

            context.setBlendMode(.clear)
            context.setLineWidth(1.3)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: 7.5, y: 8.5))
            context.addLine(to: CGPoint(x: 14.3, y: 8.5))
            context.move(to: CGPoint(x: 7.5, y: 6.6))
            context.addLine(to: CGPoint(x: 12.8, y: 6.6))
            context.strokePath()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CPaste"
        return image
    }

    private static func fillCard(in context: CGContext, rect: CGRect, opacity: CGFloat) {
        context.setFillColor(NSColor.black.withAlphaComponent(opacity).cgColor)
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: 2,
            cornerHeight: 2,
            transform: nil
        ))
        context.fillPath()
    }
}
