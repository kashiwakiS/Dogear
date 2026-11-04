#if os(iOS)
import PDFKit
import UIKit

/// Authored sample used only when launched with --ipad-demo for visual QA.
@MainActor
enum IPadDemoFixture {
    static func install(services: IPadApplicationServices, session: IPadWorkspaceSession) throws {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = root.appendingPathComponent("Dogear Sample.pdf")
        if !FileManager.default.fileExists(atPath: url.path) {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            let data = renderer.pdfData { context in
                for index in 0..<3 {
                    context.beginPage()
                    let title = "Dogear on iPad · Page \(index + 1)"
                    (title as NSString).draw(at: CGPoint(x: 54, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
                    let text = "PDF reading, standard highlights, notes and safe page operations.\n\nBM25 retrieves relevant passages from a fixed set of documents. Research keeps evidence and notes together.\n\nSelect text to highlight it. Your edits are saved to an app managed working copy. The original PDF is preserved."
                    (text as NSString).draw(in: CGRect(x: 54, y: 130, width: 500, height: 560), withAttributes: [.font: UIFont.systemFont(ofSize: 17)])
                }
            }
            try data.write(to: url, options: .atomic)
        }
        session.importURLs([url], groupID: session.groupID)
    }
}
#endif
