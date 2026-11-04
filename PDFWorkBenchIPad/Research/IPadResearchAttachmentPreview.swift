#if os(iOS)
import SwiftUI

struct IPadResearchAttachmentPreview: View {
    let attachment: ResearchAttachment
    @ObservedObject var storage: ResearchStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url = storage.attachmentURL(id: attachment.id),
                   let image = LocalImageDecoding.stillImage(at: url) {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().padding()
                } else {
                    ContentUnavailableView("Image unavailable", systemImage: "photo",
                        description: Text("A research attachment is missing."))
                }
            }
            .navigationTitle(attachment.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
