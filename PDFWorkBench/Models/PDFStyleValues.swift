import CoreGraphics
import Foundation

/// Explicit color values for document styles. Platform colors remain at the
/// PDFKit/UI boundary; these values can be shared without AppKit or UIKit.
nonisolated struct PDFColorComponents: Codable, Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
}

/// A reusable font request rather than an NSFont/UIFont in presentation data.
nonisolated struct PDFTextStyle: Equatable, Sendable {
    var pointSize: Double = 13
    var bold = false
    var italic = false
    var monospaced = false
}
