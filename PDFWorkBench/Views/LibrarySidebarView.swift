import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

struct LibrarySidebarView: View {
    @ObservedObject var libraryStore: LibraryStore
    let selectedGroupID: UUID
    let sessionID: UUID
    let selectedURL: URL?
    let currentWorkingCopyURL: URL?
    let onSelectGroup: (LibraryGroup) -> Void
    let onCreateGroup: () -> Void
    let onRenameGroup: (LibraryGroup) -> Void
    let onDeleteGroup: (LibraryGroup) -> Void
    let onSetGroupArchived: (LibraryGroup, Bool) -> Void
    let onOpenGroupInNewWindow: (LibraryGroup) -> Void
    let onOpen: (LibraryItem, LibraryGroup) -> Void
    let onRemoveFromLibrary: (LibraryItem) -> Void
    let onDiscardAllChanges: (LibraryItem) -> Void
    let onImportURLsToGroup: ([URL], LibraryGroup) -> Void
    let onImportURLsToCurrentWindow: ([URL]) -> Void

    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var contentDropTargetGroupID: UUID?
    @State private var insertionDropTarget: GroupInsertionTarget?
    @State private var fileDropTarget: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)

            groupTree
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            expandedGroupIDs.formUnion(libraryStore.sidebarGroups.map(\.id))
        }
        .onChange(of: libraryStore.sidebarGroups.map(\.id)) { oldIDs, newIDs in
            let addedIDs = Set(newIDs).subtracting(oldIDs)
            expandedGroupIDs.formUnion(addedIDs)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            return FileDropSupport.loadFileURLs(
                from: providers,
                completion: onImportURLsToCurrentWindow
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Library")
                .font(.headline)

            Spacer()

            Button {
                onCreateGroup()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Group")
        }
    }

    private var groupTree: some View {
        List {
            ForEach(libraryStore.sidebarGroups) { group in
                groupRows(for: group)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 24)
    }

    @ViewBuilder
    private func groupRows(for group: LibraryGroup) -> some View {
        if expandedGroupIDs.contains(group.id) {
            groupRow(for: group)

            let items = displayedFiles(in: group)
            if items.isEmpty {
                rowAtGroupBoundary(emptyGroupRow, after: group)
            } else {
                ForEach(items) { item in
                    if item.id == items.last?.id {
                        rowAtGroupBoundary(fileRow(for: item, in: group), after: group)
                    } else {
                        fileRow(for: item, in: group)
                    }
                }
            }
        } else {
            rowAtGroupBoundary(groupRow(for: group), after: group)
        }
    }

    private func rowAtGroupBoundary<Row: View>(
        _ row: Row,
        after group: LibraryGroup
    ) -> some View {
        row.overlay(alignment: .bottom) {
            groupInsertionTarget(after: group)
                .zIndex(1)
        }
    }

    private func groupRow(for group: LibraryGroup) -> some View {
        GroupRow(
            group: group,
            isExpanded: expandedGroupIDs.contains(group.id),
            isSelected: group.id == selectedGroupID,
            onToggleExpansion: {
                toggleExpansion(of: group)
            }
        )
        .opacity(group.isArchived ? 0.62 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectGroup(group)
        }
        .contextMenu {
            groupContextMenu(for: group)
        }
        .modifier(ModernGroupDragSourceModifier(group: group))
        .dropDestination(for: LibraryGroupDragItem.self) { items, _ in
            guard !group.isSystemGroup,
                  !group.isArchived,
                  let source = items.first,
                  source.groupID != group.id
            else {
                contentDropTargetGroupID = nil
                return false
            }
            contentDropTargetGroupID = nil
            libraryStore.mergeGroupContents(from: source.groupID, into: group.id)
            return true
        } isTargeted: { isTargeted in
            contentDropTargetGroupID = isTargeted && !group.isSystemGroup && !group.isArchived
                ? group.id
                : nil
        }
        .dropDestination(for: LibraryFileDragItem.self) { items, _ in
            guard !group.isSystemGroup, !group.isArchived, let source = items.first else {
                contentDropTargetGroupID = nil
                return false
            }
            contentDropTargetGroupID = nil
            libraryStore.addFile(source.fileID, to: group.id)
            return true
        } isTargeted: { isTargeted in
            if isTargeted && !group.isSystemGroup && !group.isArchived {
                contentDropTargetGroupID = group.id
            } else if contentDropTargetGroupID == group.id {
                contentDropTargetGroupID = nil
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard !group.isArchived else {
                return false
            }

            return FileDropSupport.loadFileURLs(
                from: providers,
                completion: { urls in onImportURLsToGroup(urls, group) }
            )
        }
        .overlay(alignment: .top) {
            groupInsertionTarget(relativeTo: group, placeAfterTarget: false)
                .zIndex(2)
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(groupRowBackground(for: group))
    }

    private func fileRow(for item: LibraryItem, in group: LibraryGroup) -> some View {
        LibraryFileRow(
            item: item,
            markerColor: duplicateGroupColor(for: item),
            isUnavailable: isUnavailable(item),
            isTemporary: libraryStore.isTemporaryFile(
                item,
                in: group.id,
                sessionID: sessionID
            )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen(item, group)
        }
        .help(item.path)
        .contextMenu {
            fileContextMenu(for: item, in: group)
        }
        .draggable(LibraryFileDragItem(fileID: item.id, groupID: group.id))
        .dropDestination(for: LibraryFileDragItem.self) { items, location in
            guard let source = items.first, source.fileID != item.id else {
                fileDropTarget = nil
                return false
            }
            guard source.groupID == group.id
                || (group.id != LibraryGroup.ungroupedID && !group.isArchived)
            else {
                fileDropTarget = nil
                return false
            }
            if source.groupID != group.id {
                libraryStore.addFile(source.fileID, to: group.id)
            }
            libraryStore.reorderFile(
                source.fileID,
                relativeTo: item.id,
                in: group.id,
                sessionID: sessionID,
                placeAfterTarget: location.y > 12
            )
            fileDropTarget = nil
            return true
        } isTargeted: { isTargeted in
            fileDropTarget = isTargeted ? item.id : (fileDropTarget == item.id ? nil : fileDropTarget)
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 42, bottom: 1, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(
            fileDropTarget == item.id
                ? Color.accentColor.opacity(0.22)
                : selectedURL?.libraryComparablePath == item.path
                ? Color.accentColor.opacity(0.14)
                : Color.clear
        )
    }

    private var emptyGroupRow: some View {
        Text("No PDFs")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 0, leading: 66, bottom: 2, trailing: 10))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func groupInsertionTarget(after group: LibraryGroup) -> some View {
        groupInsertionTarget(relativeTo: group, placeAfterTarget: true)
    }

    private func groupInsertionTarget(
        relativeTo group: LibraryGroup,
        placeAfterTarget: Bool
    ) -> some View {
        GroupInsertionOverlay(
            isActive: insertionDropTarget == GroupInsertionTarget(
                groupID: group.id,
                placeAfterTarget: placeAfterTarget
            )
        )
        .dropDestination(for: LibraryGroupDragItem.self) { items, _ in
            guard let source = items.first, source.groupID != group.id else {
                insertionDropTarget = nil
                return false
            }
            libraryStore.reorderGroup(
                source.groupID,
                relativeTo: group.id,
                placeAfterTarget: placeAfterTarget
            )
            insertionDropTarget = nil
            return true
        } isTargeted: { isTargeted in
            insertionDropTarget = isTargeted
                ? GroupInsertionTarget(
                    groupID: group.id,
                    placeAfterTarget: placeAfterTarget
                )
                : nil
        }
    }

    private func displayedFiles(in group: LibraryGroup) -> [LibraryItem] {
        if group.id == selectedGroupID {
            return libraryStore.filesForWindow(in: group.id, sessionID: sessionID)
        }

        return libraryStore.files(in: group.id)
    }

    private func toggleExpansion(of group: LibraryGroup) {
        if expandedGroupIDs.contains(group.id) {
            expandedGroupIDs.remove(group.id)
        } else {
            expandedGroupIDs.insert(group.id)
        }
    }

    private func groupRowBackground(for group: LibraryGroup) -> Color {
        if contentDropTargetGroupID == group.id {
            return Color.accentColor.opacity(0.28)
        }

        if group.id == selectedGroupID {
            return Color.accentColor.opacity(0.14)
        }

        return .clear
    }

    @ViewBuilder
    private func groupContextMenu(for group: LibraryGroup) -> some View {
        if !group.isSystemGroup {
            Button("Open Group in New Window") {
                onOpenGroupInNewWindow(group)
            }

            Button("Rename Group...") { onRenameGroup(group) }

            Button(group.isArchived ? "Restore Group" : "Archive Group") {
                onSetGroupArchived(group, !group.isArchived)
            }

            Button("Delete Group...", role: .destructive) { onDeleteGroup(group) }
        }

        Button("New Group...") {
            onCreateGroup()
        }
    }

    @ViewBuilder
    private func fileContextMenu(for item: LibraryItem, in sourceGroup: LibraryGroup) -> some View {
        if !libraryStore.activeUserGroups.isEmpty {
            Menu("Add to Group") {
                    ForEach(libraryStore.activeUserGroups) { group in
                    Button(group.localizedName) {
                        libraryStore.addFile(item, to: group)
                    }
                    .disabled(libraryStore.isFile(item, in: group))
                }
            }

            Menu("Move to Group") {
                ForEach(libraryStore.activeUserGroups) { group in
                    Button(group.localizedName) {
                        libraryStore.moveFile(
                            item,
                            to: group,
                            from: libraryStore.isFile(item, in: sourceGroup) ? sourceGroup : nil
                        )
                    }
                    .disabled(group.id == sourceGroup.id)
                }
            }
        }

        if sourceGroup.id != LibraryGroup.ungroupedID,
           libraryStore.isFile(item, in: sourceGroup) {
            Button("Remove from This Group") {
                libraryStore.removeFile(item, from: sourceGroup)
            }
        }

        Button("Remove from Library...", role: .destructive) {
            onRemoveFromLibrary(item)
        }

        Divider()

        Button("Discard All Changes...") {
            onDiscardAllChanges(item)
        }
        .disabled(workingCopyURL(for: item) == nil)
    }

    private func workingCopyURL(for item: LibraryItem) -> URL? {
        if selectedURL?.libraryComparablePath == item.path {
            return currentWorkingCopyURL ?? item.workingCopyURL
        }

        return item.workingCopyURL
    }

    private func duplicateGroupColor(for item: LibraryItem) -> Color? {
        let duplicateNames = duplicateDisplayNames()
        let itemName = normalizedDisplayName(item)

        guard let index = duplicateNames.firstIndex(of: itemName) else {
            return nil
        }

        return duplicateMarkerPalette[index % duplicateMarkerPalette.count]
    }

    private func duplicateDisplayNames() -> [String] {
        Dictionary(grouping: libraryStore.allFiles, by: normalizedDisplayName)
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
    }

    private func normalizedDisplayName(_ item: LibraryItem) -> String {
        item.displayName.lowercased()
    }

    private func isUnavailable(_ item: LibraryItem) -> Bool {
        item.isUnavailable
            || (item.bookmarkData == nil && !FileManager.default.fileExists(atPath: item.path))
    }

    private var duplicateMarkerPalette: [Color] {
        [.green, .yellow, .orange, .blue, .pink, .purple]
    }
}

private struct GroupRow: View {
    let group: LibraryGroup
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleExpansion: () -> Void

    @ObservedObject private var languageStore = AppLanguageStore.shared

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onToggleExpansion) {
                Image(systemName: groupIconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse \(displayName)" : "Expand \(displayName)")

            Text(displayName)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)

            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayName: String {
        group.localizedName(language: languageStore.selection)
    }

    private var groupIconName: String {
        if group.isSystemGroup {
            return isExpanded ? "tray.fill" : "tray"
        }

        if group.isArchived {
            return "archivebox"
        }

        return isExpanded ? "folder.fill" : "folder"
    }
}

private struct GroupInsertionOverlay: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            Color.clear

            if isActive {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 10)
            }
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}

private struct LibraryFileRow: View {
    let item: LibraryItem
    let markerColor: Color?
    let isUnavailable: Bool
    let isTemporary: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: "doc")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .lineLimit(1)
                    .foregroundStyle(isUnavailable ? .secondary : .primary)

                if !item.tags.isEmpty {
                    Text(item.tags.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            if isTemporary {
                Image(systemName: "pin.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Temporary in this window")
            }

            if let markerColor {
                DuplicateLibraryMarker(color: markerColor)
                    .help(item.path)
                    .padding(.trailing, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isUnavailable ? 0.55 : 1)
    }
}

private struct GroupInsertionTarget: Equatable {
    let groupID: UUID
    let placeAfterTarget: Bool
}

private struct LibraryGroupDragItem: Codable, Transferable {
    let groupID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pdfWorkbenchModernGroupDragPayload)
    }
}

private struct LibraryFileDragItem: Codable, Transferable {
    let fileID: UUID
    let groupID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pdfWorkbenchModernFileDragPayload)
    }
}

private struct ModernGroupDragSourceModifier: ViewModifier {
    let group: LibraryGroup

    @ViewBuilder
    func body(content: Content) -> some View {
        if group.isSystemGroup {
            content
        } else {
            content.draggable(LibraryGroupDragItem(groupID: group.id))
        }
    }
}

private extension UTType {
    static let pdfWorkbenchModernGroupDragPayload = UTType(
        exportedAs: "com.pdfworkbench.library-group"
    )
    static let pdfWorkbenchModernFileDragPayload = UTType(
        exportedAs: "com.pdfworkbench.library-file"
    )
}

private enum LibraryDragPayload: Sendable {
    case group(UUID)
    case file(UUID, groupID: UUID)

    static func provider(for payload: LibraryDragPayload) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(payload.encodedValue.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: payload.contentType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func load(
        from providers: [NSItemProvider],
        contentType: UTType,
        completion: @escaping @Sendable (LibraryDragPayload) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(contentType.identifier)
        }) else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { data, _ in
            guard let data,
                  let value = String(data: data, encoding: .utf8),
                  let payload = decode(value)
            else {
                return
            }

            completion(payload)
        }
        return true
    }

    private static let groupPrefix = "group:"
    private static let filePrefix = "file:"

    private static func decode(_ value: String) -> LibraryDragPayload? {
        if value.hasPrefix(groupPrefix),
           let id = UUID(uuidString: String(value.dropFirst(groupPrefix.count))) {
            return .group(id)
        }

        if value.hasPrefix(filePrefix) {
            let components = value.dropFirst(filePrefix.count).split(separator: ":")
            if components.count == 2,
               let fileID = UUID(uuidString: String(components[0])),
               let groupID = UUID(uuidString: String(components[1])) {
                return .file(fileID, groupID: groupID)
            }
        }

        return nil
    }

    private var encodedValue: String {
        switch self {
        case .group(let id):
            return "\(Self.groupPrefix)\(id.uuidString)"
        case .file(let id, let groupID):
            return "\(Self.filePrefix)\(id.uuidString):\(groupID.uuidString)"
        }
    }

    private var contentType: UTType {
        switch self {
        case .group:
            return .pdfWorkbenchGroupDragPayload
        case .file:
            return .pdfWorkbenchFileDragPayload
        }
    }
}

private extension UTType {
    static let pdfWorkbenchGroupDragPayload = UTType(
        exportedAs: "com.pdfworkbench.group-drag-payload"
    )
    static let pdfWorkbenchFileDragPayload = UTType(
        exportedAs: "com.pdfworkbench.file-drag-payload"
    )
}

private struct GroupDragSourceModifier: ViewModifier {
    let group: LibraryGroup
    @Binding var draggedGroupID: UUID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if group.isSystemGroup {
            content
        } else {
            content.onDrag {
                draggedGroupID = group.id
                return LibraryDragPayload.provider(for: .group(group.id))
            }
        }
    }
}

private struct GroupContentDropDelegate: DropDelegate {
    let targetGroup: LibraryGroup
    let libraryStore: LibraryStore
    @Binding var activeTargetGroupID: UUID?
    @Binding var draggedGroupID: UUID?
    let onImportURLs: ([URL], LibraryGroup) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [UTType.fileURL]) {
            return true
        }

        if targetGroup.isSystemGroup {
            return false
        }

        if isSelfGroupDrop(info: info) {
            return false
        }

        return info.hasItemsConforming(to: [
            .pdfWorkbenchGroupDragPayload,
            .pdfWorkbenchFileDragPayload
        ])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else {
            return
        }

        activeTargetGroupID = targetGroup.id
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isSelfGroupDrop(info: info) {
            activeTargetGroupID = nil
            return DropProposal(operation: .move)
        }

        guard validateDrop(info: info) else {
            activeTargetGroupID = nil
            return DropProposal(operation: .forbidden)
        }

        activeTargetGroupID = targetGroup.id
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        if activeTargetGroupID == targetGroup.id {
            activeTargetGroupID = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        activeTargetGroupID = nil
        if isSelfGroupDrop(info: info) {
            draggedGroupID = nil
            return false
        }

        if info.hasItemsConforming(to: [.pdfWorkbenchGroupDragPayload]) {
            draggedGroupID = nil
        }
        let providers = info.itemProviders(for: [
            UTType.fileURL,
            .pdfWorkbenchGroupDragPayload,
            .pdfWorkbenchFileDragPayload
        ])

        if FileDropSupport.loadFileURLs(
            from: providers,
            completion: { urls in onImportURLs(urls, targetGroup) }
        ) {
            return true
        }

        if LibraryDragPayload.load(
            from: providers,
            contentType: .pdfWorkbenchGroupDragPayload,
            completion: { payload in
                guard case .group(let sourceGroupID) = payload else {
                    return
                }

                Task { @MainActor in
                    libraryStore.mergeGroupContents(
                        from: sourceGroupID,
                        into: targetGroup.id
                    )
                }
            }
        ) {
            return true
        }

        return LibraryDragPayload.load(
            from: providers,
            contentType: .pdfWorkbenchFileDragPayload,
            completion: { payload in
                guard case .file(let fileID, _) = payload else {
                    return
                }

                Task { @MainActor in
                    libraryStore.addFile(fileID, to: targetGroup.id)
                }
            }
        )
    }

    private func isSelfGroupDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.pdfWorkbenchGroupDragPayload])
            && draggedGroupID == targetGroup.id
    }
}

private struct GroupInsertionDropDelegate: DropDelegate {
    let target: GroupInsertionTarget
    let libraryStore: LibraryStore
    @Binding var activeTarget: GroupInsertionTarget?
    @Binding var draggedGroupID: UUID?

    func dropEntered(info: DropInfo) {
        guard draggedGroupID != target.groupID else {
            return
        }
        activeTarget = target
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggedGroupID != target.groupID else {
            activeTarget = nil
            return DropProposal(operation: .move)
        }
        activeTarget = target
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if activeTarget == target {
            activeTarget = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        activeTarget = nil
        if draggedGroupID == target.groupID {
            draggedGroupID = nil
            return false
        }
        draggedGroupID = nil
        let providers = info.itemProviders(for: [.pdfWorkbenchGroupDragPayload])

        return LibraryDragPayload.load(
            from: providers,
            contentType: .pdfWorkbenchGroupDragPayload,
            completion: { payload in
                guard case .group(let draggedGroupID) = payload else {
                    return
                }

                Task { @MainActor in
                    libraryStore.reorderGroup(
                        draggedGroupID,
                        relativeTo: target.groupID,
                        placeAfterTarget: target.placeAfterTarget
                    )
                }
            }
        )
    }
}

private struct LibraryFileDropDelegate: DropDelegate {
    let targetFileID: UUID
    let targetGroupID: UUID
    let sessionID: UUID
    let libraryStore: LibraryStore

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.pdfWorkbenchFileDragPayload])
        let placeAfterTarget = info.location.y > 18

        return LibraryDragPayload.load(
            from: providers,
            contentType: .pdfWorkbenchFileDragPayload,
            completion: { payload in
                guard case .file(let draggedFileID, let sourceGroupID) = payload else {
                    return
                }

                Task { @MainActor in
                    if sourceGroupID != targetGroupID {
                        guard targetGroupID != LibraryGroup.ungroupedID else {
                            return
                        }
                        libraryStore.addFile(draggedFileID, to: targetGroupID)
                    }

                    libraryStore.reorderFile(
                        draggedFileID,
                        relativeTo: targetFileID,
                        in: targetGroupID,
                        sessionID: sessionID,
                        placeAfterTarget: placeAfterTarget
                    )
                }
            }
        )
    }
}

private struct DuplicateLibraryMarker: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color)

            Circle()
                .stroke(Color.primary.opacity(0.25), lineWidth: 0.5)
        }
        .frame(width: 8, height: 8)
        .accessibilityLabel("Duplicate filename marker")
    }
}
