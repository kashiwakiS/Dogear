import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

@MainActor
enum ResearchVisualEvidenceDiagnostics {
    struct Report: Sendable { let checks: Int; let failures: [String] }

    static func run() async -> Report {
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ failure: String) {
            checks += 1
            if !value { failures.append(failure) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearVisual-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let document = try coloredPDF()
            let page = document.page(at: 0)!
            let originalURL = root.appendingPathComponent("original.pdf")
            guard let original = document.dataRepresentation() else { throw FixtureError.invalid }
            try original.write(to: originalURL)
            let crop = page.bounds(for: .cropBox)
            for rotation in [0, 90, 180, 270] {
                page.rotation = rotation
                let count = page.annotations.count
                let data = try ResearchImagePipeline.renderRegion(page: page, rect: crop)
                let pixels = try PixelImage(data)
                check(pixels.width == (rotation % 180 == 0 ? 800 : 320)
                    && pixels.height == (rotation % 180 == 0 ? 320 : 800), "Rotation \(rotation) produced incorrect crop dimensions")
                let red = pixels.center { r, g, b in r > 200 && g < 50 && b < 50 }
                let green = pixels.center { r, g, b in r < 50 && g > 200 && b < 50 }
                let correctlyRotated: Bool
                switch rotation {
                case 0: correctlyRotated = red.x < Double(pixels.width) * 0.4
                case 90: correctlyRotated = red.y < Double(pixels.height) * 0.4
                case 180: correctlyRotated = red.x > Double(pixels.width) * 0.6
                default: correctlyRotated = red.y > Double(pixels.height) * 0.6
                }
                check(red.count > 0 && correctlyRotated, "Rotation \(rotation) changed orientation or selected the wrong part of the page")
                check(green.count > 100, "Rotation \(rotation) omitted the visible standard annotation")
                check(page.rotation == rotation && page.bounds(for: .cropBox) == crop && page.annotations.count == count,
                      "Capturing a page region mutated the PDF")
                let partial = try PixelImage(ResearchImagePipeline.renderRegion(page: page,
                    rect: CGRect(x: crop.minX, y: crop.minY, width: 100, height: crop.height)))
                check(partial.center { r, g, b in b > 200 && r < 50 && g < 50 }.count == 0,
                      "Rotation \(rotation) included pixels outside the selected red half")
            }
            check(try Data(contentsOf: originalURL) == original, "Region capture rewrote the original PDF file")
            for invalid in [CGRect(x: CGFloat.infinity, y: 0, width: 2, height: 2), CGRect(x: 20, y: 30, width: 0, height: 1),
                            CGRect(x: -1000, y: -1000, width: 20, height: 20)] {
                do { _ = try ResearchImagePipeline.renderRegion(page: page, rect: invalid); check(false, "Invalid capture geometry was accepted") }
                catch ResearchImageError.invalidRegion { check(true, "") }
            }

            let sourceImage = try bitmap(width: 80, height: 40, halves: true)
            let oriented = try encode(sourceImage, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
            let normalized = try ResearchImagePipeline.normalized(oriented)
            check(normalized.width == 40 && normalized.height == 80, "EXIF orientation was not applied exactly once")
            let normalizedPixels = try PixelImage(normalized.data)
            check(normalizedPixels.center { r, g, b in r > 180 && g < 80 && b < 80 }.y < 40,
                  "EXIF-oriented image was mirrored or rotated in the wrong direction")
            let large = try encode(bitmap(width: 4096, height: 1024), type: .png)
            let reduced = try ResearchImagePipeline.normalized(large)
            check(reduced.width == 2048 && reduced.height == 512
                && reduced.data.count <= ResearchInputLimits.maximumProcessedImageBytes,
                  "Normalization did not preserve aspect ratio within the 2048-pixel limit")
            let animated = NSMutableData()
            guard let animation = CGImageDestinationCreateWithData(animated, UTType.gif.identifier as CFString, 2, nil) else { throw FixtureError.invalid }
            CGImageDestinationAddImage(animation, sourceImage, nil)
            CGImageDestinationAddImage(animation, sourceImage, nil)
            guard CGImageDestinationFinalize(animation) else { throw FixtureError.invalid }
            do { _ = try ResearchImagePipeline.normalized(animated as Data); check(false, "Animated image was silently flattened") }
            catch ResearchImageError.unsupported { check(true, "") }
            do { _ = try ResearchImagePipeline.normalized(Data()); check(false, "Empty image data was accepted") }
            catch ResearchImageError.unsupported { check(true, "") }
            do {
                _ = try ResearchImagePipeline.normalized(Data(repeating: 0, count: ResearchInputLimits.maximumImportedImageBytes + 1))
                check(false, "Oversized imported image was decoded")
            } catch ResearchImageError.tooLarge { check(true, "") }

            let store = ResearchStore(rootURL: root.appendingPathComponent("research"))
            let sessionID = store.createSession(title: "Images")
            for _ in 0..<4 {
                try ResearchImagePipeline.importImage(data: normalized.data, displayName: "explicit.png", sessionID: sessionID, store: store)
            }
            let draftBeforeLimit = store.session(id: sessionID)?.draft
            do {
                try ResearchImagePipeline.importImage(data: normalized.data, displayName: "excess.png", sessionID: sessionID, store: store)
                check(false, "Fifth image changed the draft")
            } catch ResearchImageError.tooLarge { check(true, "") }
            check(store.session(id: sessionID)?.draft == draftBeforeLimit && store.attachments.count == 4,
                  "Rejected fifth image left an attachment or modified the input")
            check(store.session(id: sessionID)?.draft.blocks.allSatisfy { $0.evidence?.source == nil && $0.evidence?.kind == .image } == true,
                  "External images invented PDF provenance")
            let reopened = ResearchStore(rootURL: root.appendingPathComponent("research"))
            check(reopened.session(id: sessionID)?.draft == draftBeforeLimit
                && reopened.attachments.allSatisfy { $0.pixelWidth == 40 && $0.pixelHeight == 80 },
                  "Processed dimensions or image draft did not survive a restart")

            let textDocument = try textPDF("The unique evidence supports the result.", position: CGPoint(x: 72, y: 700))
            let native = try await NativePDFTextSnapshotBuilder(document: textDocument).makeTextSnapshotCooperatively()
            let fileID = UUID()
            let source = ResearchSourceSnapshot(fileID: fileID, displayName: "same.pdf", fingerprint: "version-one")
            let anchor = ResearchPageAnchor(pageIndex: 0, x: 72, y: 695, width: 150, height: 20,
                pageFingerprint: native.pages[0].fingerprint)
            let evidence = ResearchEvidence(source: source, kind: .pdfText, anchor: anchor, excerpt: "unique evidence")
            let unchanged = PDFSourceReadSnapshot(fileID: fileID, originalURL: originalURL,
                contentVersion: "version-one", document: textDocument)
            let resolved = try await ResearchEvidenceResolver.resolve(evidence, read: unchanged)
            check(!resolved.revalidated && resolved.rect == CGRect(x: 72, y: 695, width: 150, height: 20),
                  "Unchanged source lost its saved anchor")

            // Identical extracted text can move: version revalidation must derive
            // the new selection geometry rather than reuse the old rectangle.
            let movedText = try textPDF("The unique evidence supports the result.", position: CGPoint(x: 180, y: 300))
            let movedRead = PDFSourceReadSnapshot(fileID: fileID, originalURL: originalURL,
                contentVersion: "version-two", document: movedText)
            let moved = try await ResearchEvidenceResolver.resolve(evidence, read: movedRead)
            check(moved.revalidated && (moved.rect?.minY ?? 0) < 400 && (moved.rect?.minX ?? 0) > 180,
                  "Changed source jumped to stale text coordinates")
            var imageEvidence = evidence
            imageEvidence.kind = .image
            do { _ = try await ResearchEvidenceResolver.resolve(imageEvidence, read: movedRead); check(false, "Image evidence used text-only revalidation") }
            catch { check(true, "") }
            let wrongFile = PDFSourceReadSnapshot(fileID: UUID(), originalURL: originalURL,
                contentVersion: "version-one", document: textDocument)
            do { _ = try await ResearchEvidenceResolver.resolve(evidence, read: wrongFile); check(false, "Same-name different file identity was accepted") }
            catch { check(true, "") }
            for broken in [ResearchPageAnchor(pageIndex: -1), ResearchPageAnchor(pageIndex: 0, x: 10),
                           ResearchPageAnchor(pageIndex: 0, x: .nan, y: 0, width: 20, height: 20),
                           ResearchPageAnchor(pageIndex: 0, x: 0, y: 0, width: -10, height: 20),
                           ResearchPageAnchor(pageIndex: 0, x: 1000, y: 0, width: 20, height: 20)] {
                var invalid = evidence
                invalid.anchor = broken
                do { _ = try await ResearchEvidenceResolver.resolve(invalid, read: unchanged); check(false, "Malformed anchor silently became a page-only jump") }
                catch { check(true, "") }
            }
            let duplicate = try textPDF("unique evidence unique evidence", position: CGPoint(x: 72, y: 700))
            let duplicateNative = try await NativePDFTextSnapshotBuilder(document: duplicate).makeTextSnapshotCooperatively()
            var duplicateEvidence = evidence
            duplicateEvidence.anchor?.pageFingerprint = duplicateNative.pages[0].fingerprint
            let duplicateRead = PDFSourceReadSnapshot(fileID: fileID, originalURL: originalURL,
                contentVersion: "version-two", document: duplicate)
            do { _ = try await ResearchEvidenceResolver.resolve(duplicateEvidence, read: duplicateRead); check(false, "Ambiguous duplicate excerpt was guessed") }
            catch { check(true, "") }
            textDocument.page(at: 0)?.rotation = 90
            let rotatedRead = PDFSourceReadSnapshot(fileID: fileID, originalURL: originalURL,
                contentVersion: "rotated", document: textDocument)
            do { _ = try await ResearchEvidenceResolver.resolve(evidence, read: rotatedRead); check(false, "Changed page rotation reused an old anchor") }
            catch { check(true, "") }

            let preview = ReadOnlyEvidencePDFView()
            preview.document = document
            let annotationCount = page.annotations.count
            if let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51) {
                preview.keyDown(with: delete)
                check(page.annotations.count == annotationCount, "Read-only preview forwarded an editing key")
            }
        } catch { check(false, "Visual evidence diagnostics failed: \(error)") }
        return Report(checks: checks, failures: failures)
    }

    private enum FixtureError: Error { case invalid }
    private static func coloredPDF() throws -> PDFDocument {
        let document = try makePDF(size: CGSize(width: 240, height: 160)) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 20, y: 30, width: 100, height: 80))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 120, y: 30, width: 100, height: 80))
        }
        let page = document.page(at: 0)!
        page.setBounds(CGRect(x: 20, y: 30, width: 200, height: 80), for: .cropBox)
        let annotation = PDFAnnotation(bounds: CGRect(x: 30, y: 50, width: 30, height: 30), forType: .square, withProperties: nil)
        annotation.color = .green
        annotation.interiorColor = .green
        page.addAnnotation(annotation)
        return document
    }
    private static func textPDF(_ text: String, position: CGPoint) throws -> PDFDocument {
        try makePDF(size: CGSize(width: 612, height: 792)) { context in
            let line = NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
            context.textPosition = position
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
        }
    }
    private static func makePDF(size: CGSize, draw: (CGContext) -> Void) throws -> PDFDocument {
        let data = NSMutableData()
        var bounds = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw FixtureError.invalid }
        context.beginPDFPage(nil)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else { throw FixtureError.invalid }
        return document
    }
    private static func bitmap(width: Int, height: Int, halves: Bool = false) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FixtureError.invalid }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if halves {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
        guard let image = context.makeImage() else { throw FixtureError.invalid }
        return image
    }
    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw FixtureError.invalid }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.invalid }
        return data as Data
    }
    private struct PixelImage {
        let width: Int
        let height: Int
        let stride: Int
        let bytes: Data
        init(_ data: Data) throws {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FixtureError.invalid }
            width = image.width
            height = image.height
            stride = context.bytesPerRow
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let pointer = context.data else { throw FixtureError.invalid }
            bytes = Data(bytes: pointer, count: stride * height)
        }
        func center(matching: (UInt8, UInt8, UInt8) -> Bool) -> (x: Double, y: Double, count: Int) {
            var count = 0, totalX = 0, totalY = 0
            bytes.withUnsafeBytes { raw in
                let pixels = raw.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let index = y * stride + x * 4
                        if matching(pixels[index], pixels[index + 1], pixels[index + 2]) { count += 1; totalX += x; totalY += y }
                    }
                }
            }
            return (Double(totalX) / Double(max(1, count)), Double(totalY) / Double(max(1, count)), count)
        }
    }
}
