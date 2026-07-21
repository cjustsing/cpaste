import CoreGraphics

public enum PanelPlacement {
    public static func targetScreenIndex(
        for mouseLocation: CGPoint,
        screenFrames: [CGRect],
        fallbackIndex: Int = 0
    ) -> Int? {
        guard !screenFrames.isEmpty else {
            return nil
        }

        if let index = screenFrames.firstIndex(where: { contains(mouseLocation, in: $0) }) {
            return index
        }

        return screenFrames.indices.contains(fallbackIndex) ? fallbackIndex : 0
    }

    public static func panelFrame(on screenFrame: CGRect, height: CGFloat) -> CGRect {
        CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: height
        )
    }

    public static func requiresWindowRecreation(
        currentScreenFrame: CGRect?,
        currentBackingScaleFactor: CGFloat?,
        targetScreenFrame: CGRect,
        targetBackingScaleFactor: CGFloat
    ) -> Bool {
        guard let currentScreenFrame, let currentBackingScaleFactor else {
            return true
        }

        return currentScreenFrame != targetScreenFrame
            || currentBackingScaleFactor != targetBackingScaleFactor
    }

    private static func contains(_ point: CGPoint, in frame: CGRect) -> Bool {
        point.x >= frame.minX
            && point.x < frame.maxX
            && point.y >= frame.minY
            && point.y < frame.maxY
    }
}
