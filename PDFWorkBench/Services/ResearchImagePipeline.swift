import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ResearchImageError: LocalizedError {
    case unsupported, tooLarge, saveFailed, invalidRegion
    var errorDescription: String? {
        switch self {
        case .unsupported: return L10n.string("Choose a still image that macOS can read. Animated images are not supported.")
        case .tooLarge: return L10n.string("Image limits: 4 attachments, 20 MiB per imported image, 4 MiB per processed image, 12 MiB per request.")
        case .saveFailed: return L10n.string("The image draft could not be saved. Retry saving before sending.")
        case .invalidRegion: return L10n.string("Select a visible area inside one PDF page.")
        }
    }
}

@MainActor
enum ResearchImagePipeline {
    struct ProcessedImage {
        let data: Data
        let mimeType: String
        let fileExtension: String
        let width: Int
        let height: Int
    }

    static func normalized(_ data: Data) throws -> ProcessedImage {
        guard data.count <= ResearchInputLimits.maximumImportedImageBytes else { throw ResearchImageError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: ResearchInputLimits.maximumImageDimension
              ] as CFDictionary) else { throw ResearchImageError.unsupported }
        let png = try encode(image, type: .png)
        if png.count <= ResearchInputLimits.maximumProcessedImageBytes {
            return ProcessedImage(data: png, mimeType: "image/png", fileExtension: "png", width: image.width, height: image.height)
        }
        let jpeg = try encode(opaqueImage(image), type: .jpeg)
        guard jpeg.count <= ResearchInputLimits.maximumProcessedImageBytes else { throw ResearchImageError.tooLarge }
        return ProcessedImage(data: jpeg, mimeType: "image/jpeg", fileExtension: "jpg", width: image.width, height: image.height)
    }

    static func importImage(data: Data, displayName: String, source: ResearchEvidence? = nil,
                            sessionID: UUID, store suppliedStore: ResearchStore? = nil) throws {
        let store = suppliedStore ?? .shared
        guard var session = store.session(id: sessionID) else { throw ResearchImageError.saveFailed }
        let count = session.draft.attachmentIDs.count
        guard count < ResearchInputLimits.maximumImages else { throw ResearchImageError.tooLarge }
        let image = try normalized(data)
        let existingBytes = store.attachments.filter { session.draft.attachmentIDs.contains($0.id) }.reduce(0) { $0 + $1.byteCount }
        guard image.data.count + existingBytes <= ResearchInputLimits.maximumRequestImageBytes else { throw ResearchImageError.tooLarge }
        let attachment = try store.importAttachment(data: image.data, displayName: displayName,
            mimeType: image.mimeType, fileExtension: image.fileExtension, pixelWidth: image.width, pixelHeight: image.height)
        var evidence = source ?? ResearchEvidence(source: nil, kind: .image, excerpt: displayName)
        evidence.kind = .image
        evidence.attachmentID = attachment.id
        session.draft.blocks.append(ResearchInputBlock(kind: .image, text: displayName,
            evidence: evidence, attachmentID: attachment.id))
        // Adding evidence preserves the session's explicit source selection.
        // Send explains an out-of-scope region and lets the user add its file.
        guard store.updateSession(session) else { throw ResearchImageError.saveFailed }
    }

    static func renderRegion(page: PDFPage, rect: CGRect) throws -> Data {
        let crop = page.bounds(for: .cropBox)
        guard [rect.minX, rect.minY, rect.width, rect.height, crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite),
              crop.width > 0, crop.height > 0 else { throw ResearchImageError.invalidRegion }
        let region = rect.standardized.intersection(crop)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { throw ResearchImageError.invalidRegion }
        // PDFPage.draw uses the crop-box origin and the page's display rotation.
        // Map the stored PDF-coordinate anchor into that display coordinate space
        // before translating the bounded bitmap. Drawing then includes the same
        // standard annotations that the capture sheet displays.
        let displayRegion = region.applying(try displayTransform(page: page)).standardized
        let scale = min(4, CGFloat(ResearchInputLimits.maximumImageDimension) / max(displayRegion.width, displayRegion.height))
        let width = min(ResearchInputLimits.maximumImageDimension, max(1, Int(ceil(displayRegion.width * scale))))
        let height = min(ResearchInputLimits.maximumImageDimension, max(1, Int(ceil(displayRegion.height * scale))))
        guard let context = bitmap(width: width, height: height) else { throw ResearchImageError.invalidRegion }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -displayRegion.minX, y: -displayRegion.minY)
        page.draw(with: .cropBox, to: context)
        guard let cgImage = context.makeImage() else { throw ResearchImageError.invalidRegion }
        return try encode(cgImage, type: .png)
    }

    static func displayTransform(page: PDFPage) throws -> CGAffineTransform {
        let box = page.bounds(for: .cropBox)
        switch ((page.rotation % 360) + 360) % 360 {
        case 0: return CGAffineTransform(translationX: -box.minX, y: -box.minY)
        case 90: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -box.minY, ty: box.maxX)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: box.maxX, ty: box.maxY)
        case 270: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: box.maxY, ty: -box.minX)
        default: throw ResearchImageError.invalidRegion
        }
    }

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// JPEG has no alpha channel. Flatten explicitly to the same white background
    /// used by PDF capture instead of letting transparent pixels turn black.
    private static func opaqueImage(_ image: CGImage) throws -> CGImage {
        guard let context = bitmap(width: image.width, height: image.height) else { throw ResearchImageError.unsupported }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let opaque = context.makeImage() else { throw ResearchImageError.unsupported }
        return opaque
    }

    private static func encode(_ image: CGImage, type: UTType) throws -> Data {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil) else {
            throw ResearchImageError.unsupported
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ResearchImageError.unsupported }
        return bytes as Data
    }
}
