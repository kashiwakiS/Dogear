import SwiftUI

struct DocumentMetadataView: View {
    @ObservedObject var libraryStore: LibraryStore
    let selectedURL: URL?
    let currentWorkingCopyURL: URL?
    let onExportWorkingCopy: (LibraryItem) -> Void
    let onDiscardAllChanges: (LibraryItem) -> Void
    let onRevealOriginal: (URL) -> Void
    let onRevealWorkingCopy: (URL) -> Void

    var body: some View {
        if let item = libraryStore.file(for: selectedURL) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Library Info")
                    .font(.headline)

                if !groupNames(for: item).isEmpty {
                    Text(groupNames(for: item).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                TextField(
                    "Tags, comma separated",
                    text: bindingForTags(item)
                )

                HStack(spacing: 8) {
                    Button("Reveal Original") {
                        onRevealOriginal(libraryStore.resolvedURL(for: item))
                    }
                    .font(.caption)

                    Spacer()
                }

                if let workingCopyURL = currentWorkingCopyURL ?? item.workingCopyURL {
                    Label("Working copy active", systemImage: "pencil.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    HStack(spacing: 8) {
                        Button("Save Copy As...") {
                            onExportWorkingCopy(item)
                        }
                        .font(.caption)

                        Button("Reveal") {
                            onRevealWorkingCopy(workingCopyURL)
                        }
                        .font(.caption)

                        Button("Discard...") {
                            onDiscardAllChanges(item)
                        }
                        .font(.caption)
                    }
                } else {
                    Text("No working copy; the original is unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("App-only labels. PDF metadata is not edited.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
        }
    }

    private func bindingForTags(_ item: LibraryItem) -> Binding<String> {
        Binding {
            libraryStore.file(for: item.url)?.tagsText ?? ""
        } set: { newValue in
            guard var updated = libraryStore.file(for: item.url) else {
                return
            }

            updated.tagsText = newValue
            libraryStore.update(updated)
        }
    }

    private func groupNames(for item: LibraryItem) -> [String] {
        libraryStore.groups(containing: item).map(\.localizedName)
    }
}
