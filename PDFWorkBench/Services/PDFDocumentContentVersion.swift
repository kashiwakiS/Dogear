import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

#if canImport(AppKit)
import AppKit
private typealias ContentVersionColor = NSColor
typealias PDFContentVersionPath = NSBezierPath
#elseif canImport(UIKit)
import UIKit
private typealias ContentVersionColor = UIColor
typealias PDFContentVersionPath = UIBezierPath
#endif

/// Semantic PDF revision used by write permits and retrieval caches. Preserve
/// the macOS v1 encoding so extracting this boundary does not invalidate caches
/// or change stale-write protection. Local display/print flags are excluded.
@MainActor
enum PDFDocumentContentVersion {
    static func value(of document: PDFDocument) -> String {
        var values = ["dogear-source-v1", String(document.pageCount)]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            values += [page.string ?? "", String(page.rotation)]
            for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                values.append(rectVersion(page.bounds(for: box)))
            }
            for annotation in page.annotations {
                values.append(annotation.type ?? "")
                values.append(rectVersion(annotation.bounds))
                values.append(annotation.contents ?? "")
                values.append(annotation.userName ?? "")
                values.append(annotation.modificationDate.map { String($0.timeIntervalSince1970) } ?? "")
                values.append(colorVersion(annotation.color))
                values.append(colorVersion(annotation.interiorColor))
                values.append(annotation.font?.fontName ?? "")
                values.append(String(describing: annotation.font?.pointSize ?? 0))
                values.append(colorVersion(annotation.fontColor))
                values.append(String(annotation.alignment.rawValue))
                values.append(String(describing: annotation.border?.lineWidth ?? 0))
                values.append(String(annotation.border?.style.rawValue ?? 0))
                values.append(annotation.border?.dashPattern?.map { String(describing: $0) }.joined(separator: ",") ?? "")
                values.append(annotation.quadrilateralPoints?.map { pointVersion(point(in: $0)) }.joined(separator: ",") ?? "")
                values.append(annotation.paths?.map(inkPathValue).joined(separator: "|") ?? "")
            }
        }
        let encoded = values.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func rectVersion(_ rect: CGRect) -> String {
        #if canImport(AppKit)
        NSStringFromRect(rect)
        #else
        NSCoder.string(for: rect)
        #endif
    }

    private static func point(in value: NSValue) -> CGPoint {
        #if canImport(AppKit)
        value.pointValue
        #else
        value.cgPointValue
        #endif
    }

    private static func pointVersion(_ point: CGPoint) -> String {
        #if canImport(AppKit)
        NSStringFromPoint(point)
        #else
        NSCoder.string(for: point)
        #endif
    }

    private static func colorVersion(_ color: ContentVersionColor?) -> String {
        #if canImport(AppKit)
        guard let color = color?.usingColorSpace(.deviceRGB) else { return "" }
        return "\(color.redComponent),\(color.greenComponent),\(color.blueComponent),\(color.alphaComponent)"
        #else
        guard let color else { return "" }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "" }
        return "\(red),\(green),\(blue),\(alpha)"
        #endif
    }

    /// The native ink encoding is independently checkable because CGPath and
    /// NSBezierPath assign different numeric codes to the same curve kinds.
    static func inkPathValue(_ path: PDFContentVersionPath) -> String {
        var parts: [String] = []
        #if canImport(AppKit)
        // NSBezierPath's existing order, raw values and point formatting are
        // part of the persisted macOS v1 revision contract.
        for element in 0..<path.elementCount {
            var points = [NSPoint](repeating: .zero, count: 3)
            let kind = path.element(at: element, associatedPoints: &points)
            let count = kind == .cubicCurveTo ? 3 : (kind == .quadraticCurveTo ? 2 : (kind == .closePath ? 0 : 1))
            parts.append("\(kind.rawValue):" + points.prefix(count).map(NSStringFromPoint).joined(separator: ","))
        }
        #else
        path.cgPath.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            let kind: Int
            let count: Int
            // CGPath uses different raw values for quadratic/cubic/close.
            // Map semantic kinds to the existing native v1 path encoding.
            switch element.type {
            case .moveToPoint: (kind, count) = (0, 1)
            case .addLineToPoint: (kind, count) = (1, 1)
            case .addQuadCurveToPoint: (kind, count) = (4, 2)
            case .addCurveToPoint: (kind, count) = (2, 3)
            case .closeSubpath: (kind, count) = (3, 0)
            @unknown default:
                // Retain an unknown kind rather than aliasing a known element.
                parts.append("unknown:\(element.type.rawValue)")
                return
            }
            let points = UnsafeBufferPointer(start: element.points, count: count)
            parts.append("\(kind):" + points.map(pointVersion).joined(separator: ","))
        }
        #endif
        return parts.joined(separator: ";")
    }
}
