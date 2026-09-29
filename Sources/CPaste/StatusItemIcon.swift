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
            context.translateBy(x: designSize / 2, y: designSize / 2)
            context.rotate(by: .pi / 15)
            context.translateBy(x: -designSize / 2, y: -designSize / 2)

            fillCard(
                in: context,
                rect: CGRect(x: 2.2, y: 5.8, width: 8.6, height: 10.2),
                opacity: 0.5
            )
            let front = CGPath(
                roundedRect: CGRect(x: 5.8, y: 2.2, width: 8.6, height: 10.2),
                cornerWidth: 1.8, cornerHeight: 1.8, transform: nil
            )
            context.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
            context.addPath(front)
            context.fillPath()
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.2)
            context.addPath(front)
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
