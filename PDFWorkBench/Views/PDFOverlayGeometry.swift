import CoreGraphics

/// Geometry is independent of NSView/UIView, event handling and drawing state.
/// All coordinates are already in the reader's unflipped page/overlay space.
nonisolated enum PDFOverlayGeometry {
    static func dogearFold(in bounds: CGRect, size: CGFloat = 34) -> CGRect {
        CGRect(x: bounds.maxX - size, y: bounds.maxY - size, width: size, height: size)
    }

    static func dogearTriangle(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 4))
        path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.maxY - 4))
        path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 4))
        path.closeSubpath()
        return path
    }

    static func dogearCrease(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 4))
        path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 4))
        return path
    }

    static func marginConnector(from start: CGPoint, to end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        let elbowX = max(start.x + 8, end.x - 14)
        path.move(to: start)
        path.addLine(to: CGPoint(x: elbowX, y: start.y))
        path.addLine(to: CGPoint(x: elbowX, y: end.y))
        path.addLine(to: end)
        return path
    }

    static func marginCard(in rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil)
    }
}
