import Foundation

enum DocumentInteractionScope { case reader, pageOrganizer }

/// Presentation data and command callbacks are shared by native platforms.
/// The store captures and validates the document before invoking a command.
@MainActor
struct DocumentConfirmationRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let scope: DocumentInteractionScope
    let onConfirm: () -> Void
}

@MainActor
struct DocumentExportOptionsRequest: Identifiable {
    struct Option: Identifiable {
        let id: String
        let title: String
        var detail: String? = nil
        var isEnabled = true
        var isSelected = false
    }

    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let allowsMultipleSelection: Bool
    let options: [Option]
    let onConfirm: (Set<String>) -> Void
}
