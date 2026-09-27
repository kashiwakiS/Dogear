import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Native compatibility checks for the shared style, Markdown, image and path
/// boundaries. Uses isolated fixtures; no user files, windows, clipboard or URLs.
@MainActor
enum SharedNativeAPIDiagnostics {
    static func run() -> AIHighlightFoundationDiagnosticReport {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append("Shared native APIs: " + message) }
        }

        let regular = NSFont.systemFont(ofSize: 13)
        let bold = NSFont.boldSystemFont(ofSize: 19)
        check(DocumentFontMetrics(attribute: regular) == DocumentFontMetrics(attribute: regular as CTFont),
              "Core Text and native font metrics differ")
        check(DocumentFontMetrics(attribute: bold)?.pointSize == 19
              && DocumentFontMetrics(attribute: bold)?.isBold == true,
              "Outline heading size/bold detection changed")
        check(DocumentFontMetrics(attribute: regular)?.isBold == false,
              "Ordinary body text was classified as bold")
        check(DocumentFontMetrics(attribute: nil) == nil && DocumentFontMetrics(attribute: "invalid") == nil,
              "An absent/nonfont attributed-text value was accepted")
        let combined = PDFPlatformStyle.font(PDFTextStyle(pointSize: 18, bold: true, italic: true, monospaced: true))
        let traits = combined.fontDescriptor.symbolicTraits
        check(traits.contains(.bold) && traits.contains(.italic) && traits.contains(.monoSpace),
              "Markdown combined font traits were lost")
        let resized = PDFPlatformStyle.resizedFont(combined, size: 27)
        check(resized.pointSize == 27 && resized.familyName == combined.familyName
              && resized.fontDescriptor.symbolicTraits == traits,
              "FreeText descriptor resize changed font family or traits")
        let palette = PDFColorComponents(red: 0.30, green: 0.78, blue: 0.88, alpha: 1)
        check(PDFPlatformStyle.color(palette).isEqual(NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.88, alpha: 1)),
              "The native AI annotation palette changed")
        let point = CGPoint(x: -12, y: 34)
        check(PDFPlatformStyle.pointValue(point).pointValue == point, "PDFKit boxed point conversion changed coordinates")

        let source = ResearchSourceSnapshot(fileID: UUID(), displayName: "来源.pdf", fingerprint: "unchanged")
        let evidence = ResearchEvidence(source: source, anchor: ResearchPageAnchor(pageIndex: 2), excerpt: "Evidence")
        let markdown = "# 标题\n\n😀 **粗体** [D001 p. 3] `literal [D001 p. 3]` [web](https://example.org)"
        let presentation = ResearchMarkdownPresentation(markdown, sources: [source], evidence: [evidence])
        let rendered = ResearchMarkdown.render(markdown, sources: [source], evidence: [evidence])
        check(presentation.text == rendered.string && presentation.text.hasPrefix("标题\n😀 粗体"),
              "Shared Markdown and native text differ")
        check(presentation.evidenceLinks.count == 1, "Citation parsing linked a code example or lost real evidence")
        if let link = presentation.evidenceLinks.first {
            check((presentation.text as NSString).substring(with: link.range) == "[D001 p. 3]",
                  "Unicode before a citation shifted its UTF-16 range")
            check((rendered.attribute(.link, at: link.range.location, effectiveRange: nil) as? URL) == link.url,
                  "Native renderer lost the shared citation link")
            check(ResearchLinkTarget(url: link.url) == .evidence(evidence.id),
                  "Internal evidence routing changed the saved identity")
        } else { check(false, "Expected evidence link was absent") }
        let web = URL(string: "https://example.org")!
        check(ResearchLinkTarget(url: web) == .web(web), "HTTPS links no longer reach the injected open action")
        check(ResearchLinkTarget(url: URL(string: "file:///tmp/private.pdf")!) == .unsupported
              && ResearchLinkTarget(url: URL(string: "javascript:alert(1)")!) == .unsupported
              && ResearchLinkTarget(url: URL(string: "dogear-evidence://invalid")!) == .unsupported,
              "An unsupported or malformed URL escaped evidence interception")
        let boldRange = (rendered.string as NSString).range(of: "粗体")
        check((rendered.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)?
            .fontDescriptor.symbolicTraits.contains(.bold) == true, "Markdown bold styling no longer renders")

        let fold = PDFOverlayGeometry.dogearFold(in: CGRect(x: 0, y: 0, width: 64, height: 64))
        check(fold == CGRect(x: 30, y: 30, width: 34, height: 34), "Dog-ear hit area moved")
        let oldFold = pixels { context in
            withNativeContext(context) {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: 34, y: 60)); path.line(to: CGPoint(x: 60, y: 60))
                path.line(to: CGPoint(x: 60, y: 34)); path.close()
                NSColor.yellow.setFill(); path.fill()
            }
        }
        let newFold = pixels { context in
            context.addPath(PDFOverlayGeometry.dogearTriangle(in: fold))
            context.setFillColor(NSColor.yellow.cgColor); context.fillPath()
        }
        check(oldFold != nil && oldFold == newFold, "Core Graphics Dog-ear differs from the native triangle")
        let start = CGPoint(x: 5, y: 10), end = CGPoint(x: 58, y: 40)
        let oldConnector = pixels { context in
            withNativeContext(context) {
                let path = NSBezierPath()
                path.move(to: start); path.line(to: CGPoint(x: 44, y: 10))
                path.line(to: CGPoint(x: 44, y: 40)); path.line(to: end)
                path.lineWidth = 1.8; NSColor.cyan.setStroke(); path.stroke()
            }
        }
        let newConnector = pixels { context in
            context.addPath(PDFOverlayGeometry.marginConnector(from: start, to: end))
            context.setLineWidth(1.8); context.setStrokeColor(NSColor.cyan.cgColor); context.strokePath()
        }
        check(oldConnector != nil && oldConnector == newConnector,
              "Core Graphics margin connector differs from its native predecessor")

        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DogearSharedImages-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("fixture.png")
            guard let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw FixtureError.image
            }
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw FixtureError.image
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw FixtureError.image }
            let full = LocalImageDecoding.stillImage(at: url)
            check(full?.width == 80 && full?.height == 40, "Attachment preview changed image dimensions")
            let bounded = LocalImageDecoding.stillImage(at: url, maximumPixelSize: 20)
            check(bounded?.width == 20 && bounded?.height == 10, "Attachment preview exceeded its pixel bound")
            check(full?.alphaInfo == .premultipliedLast || full?.alphaInfo == .premultipliedFirst
                  || full?.alphaInfo == .last || full?.alphaInfo == .first, "Attachment transparency was discarded")
            check(LocalImageDecoding.stillImage(at: web) == nil,
                  "Attachment previews accepted a remote URL")
            let badURL = directory.appendingPathComponent("invalid.png")
            try Data("not an image".utf8).write(to: badURL)
            check(LocalImageDecoding.stillImage(at: badURL) == nil, "Corrupt image became a preview")
            let animatedURL = directory.appendingPathComponent("animated.gif")
            guard let animated = CGImageDestinationCreateWithURL(animatedURL as CFURL, UTType.gif.identifier as CFString, 2, nil) else {
                throw FixtureError.image
            }
            CGImageDestinationAddImage(animated, image, nil); CGImageDestinationAddImage(animated, image, nil)
            guard CGImageDestinationFinalize(animated) else { throw FixtureError.image }
            check(LocalImageDecoding.stillImage(at: animatedURL) == nil, "A multi-frame image became a still preview")
        } catch { check(false, "Image fixture failed: \(error)") }
        return AIHighlightFoundationDiagnosticReport(checkCount: checks, failures: failures)
    }

    private enum FixtureError: Error { case image }

    private static func pixels(_ draw: (CGContext) -> Void) -> Data? {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
        draw(context)
        guard let data = context.data else { return nil }
        return Data(bytes: data, count: context.bytesPerRow * context.height)
    }

    private static func withNativeContext(_ context: CGContext, draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        draw()
    }
}
