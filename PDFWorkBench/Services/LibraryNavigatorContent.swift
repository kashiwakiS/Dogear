import Foundation
import SwiftUI

/// A file can appear in several Groups. Navigation identity includes its row's
/// membership while document editing ownership remains the shared file identity.
nonisolated struct LibraryFileSelection: Hashable {
    let fileID: UUID
    let groupID: UUID
}

extension LibraryStore {
    var navigatorTags: [String] { Array(Set(allFiles.flatMap(\.tags))).sorted() }

    func navigatorGroups(selectedGroupID: UUID, sessionID: UUID,
                         query: String, selectedTag: String) -> [LibraryGroup] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedTag.isEmpty else {
            return sidebarGroups
        }
        return sidebarGroups.filter {
            !navigatorFiles(in: $0.id, selectedGroupID: selectedGroupID, sessionID: sessionID,
                            query: query, selectedTag: selectedTag).isEmpty
        }
    }

    func navigatorFiles(in groupID: UUID, selectedGroupID: UUID, sessionID: UUID,
                        query: String, selectedTag: String) -> [LibraryFile] {
        let files = groupID == selectedGroupID
            ? filesForWindow(in: groupID, sessionID: sessionID)
            : files(in: groupID)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return files.filter { file in
            (selectedTag.isEmpty || file.tags.contains(selectedTag)) &&
            (needle.isEmpty || file.displayName.localizedCaseInsensitiveContains(needle) ||
             file.tags.contains(where: { $0.localizedCaseInsensitiveContains(needle) }))
        }
    }
}

/// Preserve the existing Mac duplicate-name palette and availability display.
@MainActor
enum LibraryNavigatorFileStyle {
    static func markerColor(for item: LibraryFile, in files: [LibraryFile]) -> Color? {
        let names = Dictionary(grouping: files, by: { $0.displayName.lowercased() })
            .filter { $0.value.count > 1 }.map(\.key).sorted()
        guard let index = names.firstIndex(of: item.displayName.lowercased()) else { return nil }
        let palette: [Color] = [.green, .yellow, .orange, .blue, .pink, .purple]
        return palette[index % palette.count]
    }

    static func isUnavailable(_ item: LibraryFile) -> Bool {
        item.isUnavailable || (item.bookmarkData == nil && !FileManager.default.fileExists(atPath: item.path))
    }
}
