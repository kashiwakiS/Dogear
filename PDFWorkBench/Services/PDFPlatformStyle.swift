import CoreGraphics
import Foundation

#if canImport(AppKit)
import AppKit
typealias PDFPlatformColor = NSColor
typealias PDFPlatformFont = NSFont
#elseif canImport(UIKit)
import UIKit
typealias PDFPlatformColor = UIColor
typealias PDFPlatformFont = UIFont
#endif

/// PDFKit exposes native colors, fonts and boxed points on each platform. Keep
/// those conversions here; document/presentation values use shared types.
@MainActor
enum PDFPlatformStyle {
    static func color(_ value: PDFColorComponents) -> PDFPlatformColor {
        #if canImport(AppKit)
        // Preserve the existing macOS annotation palette and color space.
        NSColor(calibratedRed: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
        #else
        UIColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha)
        #endif
    }

    static func alphaComponent(of color: PDFPlatformColor) -> CGFloat {
        #if canImport(AppKit)
        color.alphaComponent
        #else
        color.cgColor.alpha
        #endif
    }

    static func resizedFont(_ font: PDFPlatformFont, size: CGFloat) -> PDFPlatformFont {
        #if canImport(AppKit)
        NSFont(descriptor: font.fontDescriptor, size: size) ?? font
        #else
        font.withSize(size)
        #endif
    }

    static func font(_ style: PDFTextStyle) -> PDFPlatformFont {
        let size = CGFloat(style.pointSize)
        let font = style.monospaced
            ? PDFPlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : PDFPlatformFont.systemFont(ofSize: size)
        var traits = font.fontDescriptor.symbolicTraits
        #if canImport(AppKit)
        if style.bold { traits.insert(.bold) }
        if style.italic { traits.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) ?? font
        #else
        if style.bold { traits.insert(.traitBold) }
        if style.italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }

    static func pointValue(_ point: CGPoint) -> NSValue {
        #if canImport(AppKit)
        NSValue(point: point)
        #else
        NSValue(cgPoint: point)
        #endif
    }

    static func point(from value: NSValue) -> CGPoint {
        #if canImport(AppKit)
        value.pointValue
        #else
        value.cgPointValue
        #endif
    }

    static var labelColor: PDFPlatformColor {
        #if canImport(AppKit)
        .labelColor
        #else
        .label
        #endif
    }

    static var secondaryLabelColor: PDFPlatformColor {
        #if canImport(AppKit)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    static var codeBackgroundColor: PDFPlatformColor {
        #if canImport(AppKit)
        .quaternaryLabelColor
        #else
        .quaternaryLabel
        #endif
    }

    static var linkColor: PDFPlatformColor {
        #if canImport(AppKit)
        .linkColor
        #else
        .link
        #endif
    }
}
