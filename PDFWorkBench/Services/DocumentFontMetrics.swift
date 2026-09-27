import CoreText
import Foundation

/// PDF attributed text uses toll-free bridged CTFont/NSFont/UIFont values.
/// Inspect the Core Text contract instead of importing a desktop UI framework.
nonisolated struct DocumentFontMetrics: Equatable, Sendable {
    let pointSize: Double
    let isBold: Bool

    init?(attribute: Any?) {
        guard let attribute, CFGetTypeID(attribute as CFTypeRef) == CTFontGetTypeID() else { return nil }
        let font = attribute as! CTFont
        pointSize = Double(CTFontGetSize(font))
        isBold = CTFontGetSymbolicTraits(font).contains(.traitBold)
    }

    static let attributeKey = NSAttributedString.Key(kCTFontAttributeName as String)
}
