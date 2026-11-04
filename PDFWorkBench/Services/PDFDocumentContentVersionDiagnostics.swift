import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import PDFKit

#if canImport(AppKit)
import AppKit
private typealias DiagnosticColor = NSColor
private typealias DiagnosticFont = NSFont
#elseif canImport(UIKit)
import UIKit
private typealias DiagnosticColor = UIColor
private typealias DiagnosticFont = UIFont
#endif

/// Real PDFKit fixtures only; no app stores, user files, preferences, windows or
/// providers. The macOS oracle preserves the pre-extraction v1 implementation.
@MainActor
enum PDFDocumentContentVersionDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        @MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        @MainActor func legacyCheck(_ document: PDFDocument, _ name: String) {
            #if canImport(AppKit)
            check(PDFDocumentContentVersion.value(of: document) == legacyVersion(of: document),
                  "The extracted macOS version changed the legacy encoding for \(name).")
            #endif
        }

        do {
            let fixture = try makeFixture()
            let version = PDFDocumentContentVersion.value(of: fixture.document)
            check(version == PDFDocumentContentVersion.value(of: fixture.document),
                  "An unchanged PDF did not produce a repeatable version.")
            check(version.count == 64 && version.allSatisfy { $0.isHexDigit },
                  "The semantic version lost its SHA-256 encoding.")
            legacyCheck(fixture.document, "the rich Unicode/style/ink fixture")

            typealias Mutation = @MainActor (Fixture) -> Void
            let mutations: [(String, Mutation)] = [
                ("page count", { $0.document.insert(PDFPage(), at: $0.document.pageCount) }),
                ("page order", { $0.document.exchangePage(at: 0, withPageAt: 1) }),
                ("page rotation", { $0.page.rotation = 90 }),
                ("media box", { $0.page.setBounds(CGRect(x: -5, y: -4, width: 622, height: 802), for: .mediaBox) }),
                ("crop box", { $0.page.setBounds(CGRect(x: 20, y: 25, width: 550, height: 720), for: .cropBox) }),
                ("bleed box", { $0.page.setBounds(CGRect(x: 12, y: 14, width: 584, height: 760), for: .bleedBox) }),
                ("trim box", { $0.page.setBounds(CGRect(x: 14, y: 16, width: 582, height: 758), for: .trimBox) }),
                ("art box", { $0.page.setBounds(CGRect(x: 16, y: 18, width: 580, height: 756), for: .artBox) }),
                ("annotation bounds", { $0.note.bounds.origin.x += 11 }),
                ("annotation contents", { $0.note.contents = "Changed contents 中文😀" }),
                ("annotation author", { $0.note.userName = "Changed author" }),
                ("annotation date", { $0.note.modificationDate = Date(timeIntervalSince1970: 1_234_568) }),
                ("annotation color", { $0.note.color = rgba(0.15, 0.25, 0.35, 0.45) }),
                ("annotation interior color", { $0.note.interiorColor = rgba(0.25, 0.35, 0.45, 0.55) }),
                ("annotation font name", { $0.note.font = font(named: "Courier", size: 17) }),
                ("annotation font size", { $0.note.font = font(named: "Helvetica", size: 23) }),
                ("annotation font color", { $0.note.fontColor = rgba(0.35, 0.45, 0.55, 0.65) }),
                ("annotation alignment", { $0.note.alignment = .right }),
                ("annotation border width", { $0.note.border?.lineWidth = 4 }),
                ("annotation border style", { $0.note.border?.style = .beveled }),
                ("annotation dash pattern", { $0.note.border?.dashPattern = [7, 2, 1] }),
                ("highlight quadrilateral", { $0.highlight.quadrilateralPoints = quadPoints(offset: 3) }),
                ("ink move point", { replaceInkPath(in: $0, moveOffset: 3) }),
                ("ink line point", { replaceInkPath(in: $0, lineOffset: 3) }),
                ("ink quadratic control", { replaceInkPath(in: $0, quadControlOffset: 3) }),
                ("ink quadratic endpoint", { replaceInkPath(in: $0, quadEndOffset: 3) }),
                ("ink first cubic control", { replaceInkPath(in: $0, cubicFirstOffset: 3) }),
                ("ink second cubic control", { replaceInkPath(in: $0, cubicSecondOffset: 3) }),
                ("ink cubic endpoint", { replaceInkPath(in: $0, cubicEndOffset: 3) }),
                ("ink close element", { replaceInkPath(in: $0, close: false) }),
                ("additional ink path", { $0.ink.add(makePath(moveOffset: 9)) })
            ]
            for (name, mutation) in mutations {
                let changed = try makeFixture()
                let before = PDFDocumentContentVersion.value(of: changed.document)
                let dates = (changed.note.modificationDate, changed.highlight.modificationDate, changed.ink.modificationDate)
                mutation(changed)
                // A style/geometry check must not pass because PDFKit happened
                // to update incidental modification metadata.
                if name != "annotation date" { changed.note.modificationDate = dates.0 }
                changed.highlight.modificationDate = dates.1
                changed.ink.modificationDate = dates.2
                check(before != PDFDocumentContentVersion.value(of: changed.document),
                      "Changing \(name) did not invalidate the semantic version.")
                legacyCheck(changed.document, name)
            }

            let firstText = try makeDocument(texts: ["First page text"])
            let otherText = try makeDocument(texts: ["Other page text"])
            check(firstText.string != otherText.string,
                  "The page-text fixture did not contain distinct extractable text.")
            check(PDFDocumentContentVersion.value(of: firstText) != PDFDocumentContentVersion.value(of: otherText),
                  "Changing page text did not invalidate the semantic version.")
            legacyCheck(firstText, "a text-only PDF")
            legacyCheck(otherText, "changed text-only content")

            let square = try makeDocument(texts: ["Annotation subtype"])
            let circle = try makeDocument(texts: ["Annotation subtype"])
            let bounds = CGRect(x: 30, y: 40, width: 80, height: 60)
            square.page(at: 0)?.addAnnotation(PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil))
            circle.page(at: 0)?.addAnnotation(PDFAnnotation(bounds: bounds, forType: .circle, withProperties: nil))
            check(PDFDocumentContentVersion.value(of: square) != PDFDocumentContentVersion.value(of: circle),
                  "Changing annotation subtype did not invalidate the semantic version.")
            legacyCheck(square, "a square annotation")
            legacyCheck(circle, "a circle annotation")

            fixture.note.shouldDisplay = false
            fixture.highlight.shouldDisplay = false
            fixture.ink.shouldDisplay = false
            check(version == PDFDocumentContentVersion.value(of: fixture.document),
                  "Local display visibility invalidated the semantic version.")
            fixture.note.shouldPrint = false
            fixture.highlight.shouldPrint = false
            fixture.ink.shouldPrint = false
            check(version == PDFDocumentContentVersion.value(of: fixture.document),
                  "Local print visibility invalidated the semantic version.")
            legacyCheck(fixture.document, "visibility-only changes")

            let separated = try makeFixture()
            separated.note.contents = "a"
            separated.note.userName = "bc"
            let firstDelimited = PDFDocumentContentVersion.value(of: separated.document)
            separated.note.contents = "ab"
            separated.note.userName = "c"
            check(firstDelimited != PDFDocumentContentVersion.value(of: separated.document),
                  "Adjacent annotation strings collided without their length prefixes.")
            legacyCheck(separated.document, "length-delimited annotation strings")

            let path = makePath()
            let openExpected = "0:{1, 2};1:{3, 4};4:{5, 6},{7, 8};2:{9, 10},{11, 12},{13, 14}"
            #if canImport(AppKit)
            // Native close() also emits a move back to the subpath start. It
            // is already part of the macOS v1 encoding and must be retained.
            let expected = openExpected + ";3:;0:{1, 2}"
            #else
            let expected = openExpected + ";3:"
            #endif
            let closedPathValue = PDFDocumentContentVersion.inkPathValue(path)
            let openPathValue = PDFDocumentContentVersion.inkPathValue(makePath(close: false))
            check(closedPathValue == expected,
                  "Native ink elements did not preserve v1 move/line/quadratic/cubic/close codes and point order: \(closedPathValue)")
            check(openPathValue == openExpected,
                  "An open ink path acquired a closing element: \(openPathValue)")

            let empty = PDFDocument()
            check(PDFDocumentContentVersion.value(of: empty) != version,
                  "An empty PDF reused a populated document's version.")
            legacyCheck(empty, "an empty PDF")
            let bare = try makeDocument(texts: ["No annotation styles"])
            let unannotatedVersion = PDFDocumentContentVersion.value(of: bare)
            bare.page(at: 0)?.addAnnotation(PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil))
            check(PDFDocumentContentVersion.value(of: bare) != unannotatedVersion,
                  "An annotation with absent optional styles did not invalidate the semantic version.")
            legacyCheck(bare, "absent optional annotation style values")
        } catch {
            check(false, "Content-version fixture failed: \(error)")
        }
        return (checks, failures)
    }

    private struct Fixture {
        let document: PDFDocument
        let page: PDFPage
        let note: PDFAnnotation
        let highlight: PDFAnnotation
        let ink: PDFAnnotation
    }

    private enum FixtureError: Error { case pdf }

    private static func makeFixture() throws -> Fixture {
        let document = try makeDocument(texts: ["First semantic page", "Second semantic page"])
        guard let page = document.page(at: 0) else { throw FixtureError.pdf }
        for (box, inset) in [(PDFDisplayBox.cropBox, 5.0), (.bleedBox, 6.0), (.trimBox, 7.0), (.artBox, 8.0)] {
            page.setBounds(CGRect(x: inset, y: inset + 1, width: 612 - inset * 2, height: 792 - inset * 2), for: box)
        }
        let note = PDFAnnotation(bounds: CGRect(x: 50, y: 60, width: 210, height: 70), forType: .freeText, withProperties: nil)
        note.contents = "Original 中文😀:;\ncontents"
        note.userName = "Diagnostic author"
        note.modificationDate = Date(timeIntervalSince1970: 1_234_567)
        note.color = rgba(0.2, 0.3, 0.4, 0.5)
        note.interiorColor = rgba(0.3, 0.4, 0.5, 0.6)
        note.font = font(named: "Helvetica", size: 17)
        note.fontColor = rgba(0.4, 0.5, 0.6, 0.7)
        note.alignment = .left
        let border = PDFBorder()
        border.lineWidth = 1.5
        border.style = .dashed
        border.dashPattern = [3, 2]
        note.border = border
        page.addAnnotation(note)
        let highlight = PDFAnnotation(bounds: CGRect(x: 40, y: 150, width: 100, height: 20), forType: .highlight, withProperties: nil)
        highlight.quadrilateralPoints = quadPoints()
        page.addAnnotation(highlight)
        let ink = PDFAnnotation(bounds: CGRect(x: 40, y: 210, width: 100, height: 60), forType: .ink, withProperties: nil)
        ink.add(makePath())
        page.addAnnotation(ink)
        return Fixture(document: document, page: page, note: note, highlight: highlight, ink: ink)
    }

    private static func makeDocument(texts: [String]) throws -> PDFDocument {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw FixtureError.pdf }
        for text in texts {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 40, y: 700)
            let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: data as Data) else { throw FixtureError.pdf }
        return document
    }

    private static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> DiagnosticColor {
        #if canImport(AppKit)
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
        #else
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }

    private static func font(named name: String, size: CGFloat) -> DiagnosticFont {
        DiagnosticFont(name: name, size: size) ?? DiagnosticFont.systemFont(ofSize: size)
    }

    private static func quadPoints(offset: CGFloat = 0) -> [NSValue] {
        [CGPoint(x: 0 + offset, y: 20), CGPoint(x: 100, y: 20), .zero, CGPoint(x: 100, y: 0)].map {
            #if canImport(AppKit)
            NSValue(point: $0)
            #else
            NSValue(cgPoint: $0)
            #endif
        }
    }

    private static func makePath(moveOffset: CGFloat = 0, lineOffset: CGFloat = 0,
                                 quadControlOffset: CGFloat = 0, quadEndOffset: CGFloat = 0,
                                 cubicFirstOffset: CGFloat = 0, cubicSecondOffset: CGFloat = 0,
                                 cubicEndOffset: CGFloat = 0, close: Bool = true) -> PDFContentVersionPath {
        #if canImport(AppKit)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 1 + moveOffset, y: 2))
        path.line(to: CGPoint(x: 3 + lineOffset, y: 4))
        path.curve(to: CGPoint(x: 7 + quadEndOffset, y: 8), controlPoint: CGPoint(x: 5 + quadControlOffset, y: 6))
        path.curve(to: CGPoint(x: 13 + cubicEndOffset, y: 14),
                   controlPoint1: CGPoint(x: 9 + cubicFirstOffset, y: 10),
                   controlPoint2: CGPoint(x: 11 + cubicSecondOffset, y: 12))
        if close { path.close() }
        return path
        #else
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1 + moveOffset, y: 2))
        path.addLine(to: CGPoint(x: 3 + lineOffset, y: 4))
        path.addQuadCurve(to: CGPoint(x: 7 + quadEndOffset, y: 8), control: CGPoint(x: 5 + quadControlOffset, y: 6))
        path.addCurve(to: CGPoint(x: 13 + cubicEndOffset, y: 14),
                      control1: CGPoint(x: 9 + cubicFirstOffset, y: 10),
                      control2: CGPoint(x: 11 + cubicSecondOffset, y: 12))
        if close { path.closeSubpath() }
        return PDFContentVersionPath(cgPath: path)
        #endif
    }

    private static func replaceInkPath(in fixture: Fixture, moveOffset: CGFloat = 0, lineOffset: CGFloat = 0,
                                       quadControlOffset: CGFloat = 0, quadEndOffset: CGFloat = 0,
                                       cubicFirstOffset: CGFloat = 0, cubicSecondOffset: CGFloat = 0,
                                       cubicEndOffset: CGFloat = 0, close: Bool = true) {
        for path in fixture.ink.paths ?? [] { fixture.ink.remove(path) }
        fixture.ink.add(makePath(moveOffset: moveOffset, lineOffset: lineOffset,
                                quadControlOffset: quadControlOffset, quadEndOffset: quadEndOffset,
                                cubicFirstOffset: cubicFirstOffset, cubicSecondOffset: cubicSecondOffset,
                                cubicEndOffset: cubicEndOffset, close: close))
    }

    #if canImport(AppKit)
    /// Deliberately frozen pre-extraction algorithm: checking only changed
    /// hashes would miss a formatter or color-space change that alters all v1
    /// versions. This oracle calls no production platform helper.
    private static func legacyVersion(of document: PDFDocument) -> String {
        var values = ["dogear-source-v1", String(document.pageCount)]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            values += [page.string ?? "", String(page.rotation)]
            for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                values.append(NSStringFromRect(page.bounds(for: box)))
            }
            for annotation in page.annotations {
                values.append(annotation.type ?? "")
                values.append(NSStringFromRect(annotation.bounds))
                values.append(annotation.contents ?? "")
                values.append(annotation.userName ?? "")
                values.append(annotation.modificationDate.map { String($0.timeIntervalSince1970) } ?? "")
                values.append(legacyColorVersion(annotation.color))
                values.append(legacyColorVersion(annotation.interiorColor))
                values.append(annotation.font?.fontName ?? "")
                values.append(String(describing: annotation.font?.pointSize ?? 0))
                values.append(legacyColorVersion(annotation.fontColor))
                values.append(String(annotation.alignment.rawValue))
                values.append(String(describing: annotation.border?.lineWidth ?? 0))
                values.append(String(annotation.border?.style.rawValue ?? 0))
                values.append(annotation.border?.dashPattern?.map { String(describing: $0) }.joined(separator: ",") ?? "")
                values.append(annotation.quadrilateralPoints?.map { NSStringFromPoint($0.pointValue) }.joined(separator: ",") ?? "")
                values.append(annotation.paths?.map { path in
                    var parts: [String] = []
                    for element in 0..<path.elementCount {
                        var points = [NSPoint](repeating: .zero, count: 3)
                        let kind = path.element(at: element, associatedPoints: &points)
                        let count = kind == .cubicCurveTo ? 3 : (kind == .quadraticCurveTo ? 2 : (kind == .closePath ? 0 : 1))
                        parts.append("\(kind.rawValue):" + points.prefix(count).map(NSStringFromPoint).joined(separator: ","))
                    }
                    return parts.joined(separator: ";")
                }.joined(separator: "|") ?? "")
            }
        }
        let encoded = values.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func legacyColorVersion(_ color: NSColor?) -> String {
        guard let color = color?.usingColorSpace(.deviceRGB) else { return "" }
        return "\(color.redComponent),\(color.greenComponent),\(color.blueComponent),\(color.alphaComponent)"
    }
    #endif
}
