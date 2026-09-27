import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Disposable files and Research records; no file picker, clipboard or network.
@MainActor
enum ResearchImageImportDiagnostics {
    static func run() -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResearchImageImport-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let png = root.appendingPathComponent("figure.png")
            let text = root.appendingPathComponent("not-image.txt")
            let malformed = root.appendingPathComponent("malformed.png")
            let directory = root.appendingPathComponent("directory.png", isDirectory: true)
            let bytes = try imageData()
            try bytes.write(to: png)
            try Data("not an image".utf8).write(to: text)
            try Data("not a PNG".utf8).write(to: malformed)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let read = try ResearchImageFileReader.read(png, maximumBytes: bytes.count)
            check(read == bytes, "An image exactly at the import limit was changed or rejected.")
            for invalid in [text, directory, URL(string: "https://example.invalid/figure.png")!] {
                do {
                    _ = try ResearchImageFileReader.read(invalid, maximumBytes: 1024)
                    check(false, "The image reader accepted a non-image, directory or remote URL.")
                } catch ResearchImageFileReadError.unsupported { check(true, "") }
            }
            do {
                _ = try ResearchImageFileReader.read(png, maximumBytes: bytes.count - 1)
                check(false, "The reader accepted image bytes above the import limit.")
            } catch ResearchImageFileReadError.tooLarge { check(true, "") }

            let store = ResearchStore(rootURL: root.appendingPathComponent("research"))
            let originalSessionID = store.createSession(title: "Picker target")
            let switchedSessionID = store.createSession(title: "Currently visible")
            store.saveDraft(ResearchDraft(text: "Keep the target draft"), sessionID: originalSessionID)
            store.saveDraft(ResearchDraft(text: "Keep the other draft"), sessionID: switchedSessionID)
            let request = ResearchImageImportRequest(sessionID: originalSessionID)
            check(request.complete(.success([png]), store: store).isEmpty,
                "The captured image import could not complete after switching the visible session.")
            check(store.session(id: originalSessionID)?.draft.attachmentIDs.count == 1
                && store.session(id: originalSessionID)?.draft.text == "Keep the target draft",
                "The image import failed to append to its captured session or replaced its text draft.")
            check(store.session(id: switchedSessionID)?.draft.attachmentIDs.isEmpty == true
                && store.session(id: switchedSessionID)?.draft.text == "Keep the other draft",
                "An image selection leaked into the newly visible session.")

            let beforeCancellation = store.session(id: originalSessionID)?.draft
            check(request.complete(.failure(CocoaError(.userCancelled)), store: store).isEmpty
                && request.complete(.failure(CancellationError()), store: store).isEmpty,
                "Cancelling a file picker produced an attachment error.")
            check(store.session(id: originalSessionID)?.draft == beforeCancellation && store.attachments.count == 1,
                "Cancelling a picker changed the draft or created attachment storage.")
            let partial = request.complete(.success([png, text, png]), store: store)
            check(partial.count == 1 && store.session(id: originalSessionID)?.draft.attachmentIDs.count == 3,
                "Multiple selection did not retain valid images while reporting an invalid file.")
            let bounded = request.complete(.success([png, png]), store: store)
            check(bounded.count == 1 && store.session(id: originalSessionID)?.draft.attachmentIDs.count == 4,
                "The importer exceeded the four-image draft limit or dropped already accepted images.")

            let malformedRequest = ResearchImageImportRequest(sessionID: switchedSessionID)
            check(malformedRequest.complete(.success([malformed]), store: store).count == 1
                && store.session(id: switchedSessionID)?.draft.attachmentIDs.isEmpty == true,
                "An image filename bypassed actual image decoding.")
            let deletedID = store.createSession(title: "Deleted while selecting")
            let deletedRequest = ResearchImageImportRequest(sessionID: deletedID)
            check(store.deleteSession(id: deletedID), "The deleted-session fixture could not be removed.")
            let deletedResult = deletedRequest.complete(.success([png]), store: store)
            check(deletedResult.count == 1 && (deletedResult.first as? ResearchStoreError) == .missingRecord
                && store.session(id: deletedID) == nil && store.attachments.count == 4,
                "An import resurrected a deleted session or created an unreferenced attachment for it.")
            let persisted = ResearchStore(rootURL: root.appendingPathComponent("research"))
            check(persisted.session(id: originalSessionID)?.draft.attachmentIDs.count == 4
                && persisted.session(id: switchedSessionID)?.draft.attachmentIDs.isEmpty == true,
                "The captured session's imported attachments did not persist independently.")
            check((try? Data(contentsOf: png)) == bytes, "Import modified the selected image file.")
        } catch { failures.append(error.localizedDescription) }
        return (checks, failures)
    }

    private static func imageData() throws -> Data {
        guard let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ResearchImageError.unsupported }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let bytes = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)
        else { throw ResearchImageError.unsupported }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ResearchImageError.unsupported }
        return bytes as Data
    }
}
