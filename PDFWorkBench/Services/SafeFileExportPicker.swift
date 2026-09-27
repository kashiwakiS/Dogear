#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// A narrow macOS adapter: returns the authorized destination before any bytes
/// are written. PDF callers must then use SafeDocumentExport's original guard.
@MainActor
enum SafeFileExportPicker {
    static func chooseDestination(suggestedName: String, contentType: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
    }
}
#endif
