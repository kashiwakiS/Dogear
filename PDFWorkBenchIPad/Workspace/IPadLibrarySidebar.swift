#if os(iOS)
import SwiftUI

/// One Library navigator. Shared rows/content match Mac; this host supplies
/// touch selection, native split navigation and platform presentation callbacks.
struct IPadLibrarySidebar: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var session: IPadWorkspaceSession
    let onCreateGroup: () -> Void
    let onRenameGroup: (LibraryGroup) -> Void
    let onDeleteGroup: (LibraryGroup) -> Void
    let onEditFile: (LibraryFile) -> Void
    let onImport: (Bool) -> Void
    let onAddFromLibrary: () -> Void
    let onSettings: () -> Void
    let onShowDetail: () -> Void
    let onInteraction: () -> Void
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var initializedExpansion = false
    @State private var query = ""
    @State private var selectedTag = ""
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Find a file", text: $query).textFieldStyle(.roundedBorder).focused($queryFocused)
                Menu {
                    Button("All Tags") { selectedTag = "" }
                    ForEach(library.navigatorTags, id: \.self) { tag in Button(tag) { selectedTag = tag } }
                } label: { Image(systemName: selectedTag.isEmpty ? "tag" : "tag.fill").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Filter by tag")
            }.padding(.horizontal, 12)
            if !selectedTag.isEmpty {
                HStack {
                    Text(verbatim: selectedTag).font(.caption)
                    Button { selectedTag = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Clear tag filter")
                    Spacer()
                }.padding(.horizontal, 12)
            }
            List(selection: selectedFile) {
                ForEach(library.navigatorGroups(selectedGroupID: session.groupID, sessionID: session.id,
                                                query: query, selectedTag: selectedTag)) { group in
                    groupRow(group)
                    if expandedGroupIDs.contains(group.id) {
                        let files = library.navigatorFiles(in: group.id, selectedGroupID: session.groupID,
                                                           sessionID: session.id, query: query, selectedTag: selectedTag)
                        if files.isEmpty {
                            Text("No PDFs").font(.caption).foregroundStyle(.tertiary)
                                .listRowInsets(EdgeInsets(top: 2, leading: 66, bottom: 2, trailing: 10))
                                .listRowSeparator(.hidden)
                        }
                        ForEach(files) { file in fileRow(file, in: group) }
                    }
                }
            }.listStyle(.sidebar)
        }
        .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button(action: onCreateGroup) {
                Image(systemName: "folder.badge.plus")
            }.accessibilityLabel("New Group") }
            ToolbarItem(placement: .topBarTrailing) { Menu {
                Button("Import PDFs") { onImport(false) }
                Button("Import Folder") { onImport(true) }
                Button("Add from Library", action: onAddFromLibrary)
            } label: { Image(systemName: "plus") }.accessibilityLabel("Import PDF") }
            ToolbarItem(placement: .bottomBar) { Button("Settings", systemImage: "gear", action: onSettings) }
        }
        .onAppear {
            guard !initializedExpansion else { return }
            initializedExpansion = true
            expandedGroupIDs.formUnion(library.sidebarGroups.map(\.id))
        }
        .onChange(of: library.sidebarGroups.map(\.id)) { old, new in
            expandedGroupIDs.formIntersection(new)
            expandedGroupIDs.formUnion(Set(new).subtracting(old))
        }
        .onChange(of: query) { _, _ in onInteraction() }
        .onChange(of: selectedTag) { _, _ in onInteraction() }
    }

    private var selectedFile: Binding<LibraryFileSelection?> {
        Binding(get: {
            guard let file = library.file(for: session.workspace.document.selectedPDFURL) else { return nil }
            return LibraryFileSelection(fileID: file.id, groupID: session.groupID)
        }, set: { selection in
            guard let selection, let file = library.allFiles.first(where: { $0.id == selection.fileID }) else { return }
            onInteraction(); queryFocused = false
            // Selection reflects the actual activated workspace. Export or an
            // existing editing owner may refuse or redirect the requested open.
            if session.open(file, in: selection.groupID) || session.workspace.inlineNoteSession != nil { onShowDetail() }
        })
    }

    private func groupRow(_ group: LibraryGroup) -> some View {
        HStack(spacing: 0) {
            LibraryNavigatorGroupRow(group: group, isExpanded: expandedGroupIDs.contains(group.id),
                                     isSelected: session.groupID == group.id, onToggleExpansion: {
                onInteraction()
                if !expandedGroupIDs.insert(group.id).inserted { expandedGroupIDs.remove(group.id) }
            }, disclosureTargetSize: 44)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture { onInteraction(); queryFocused = false; session.selectGroup(group.id) }
            if !group.isSystemGroup {
                Menu { groupActions(group) } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Group actions")
                .accessibilityValue(Text(verbatim: group.localizedName))
                .accessibilityIdentifier("ipad.library.group.actions.\(group.id)")
            }
        }
        .opacity(group.isArchived ? 0.62 : 1)
        .contextMenu { groupActions(group) }
        .listRowSeparator(.hidden)
        .listRowBackground(session.groupID == group.id ? Color.accentColor.opacity(0.14) : .clear)
    }

    private func fileRow(_ file: LibraryFile, in group: LibraryGroup) -> some View {
        let row = LibraryFileSelection(fileID: file.id, groupID: group.id)
        return HStack(spacing: 0) {
            NavigationLink(value: row) {
                LibraryNavigatorFileRow(item: file,
                    markerColor: LibraryNavigatorFileStyle.markerColor(for: file, in: library.allFiles),
                    isUnavailable: LibraryNavigatorFileStyle.isUnavailable(file),
                    isTemporary: library.isTemporaryFile(file, in: group.id, sessionID: session.id))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ipad.library.file.\(group.id).\(file.id)")
            Menu { fileActions(file, in: group) } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("File actions")
            .accessibilityValue(Text(verbatim: file.displayName))
            .accessibilityIdentifier("ipad.library.file.actions.\(group.id).\(file.id)")
        }
        .tag(row)
        .contextMenu { fileActions(file, in: group) }
        .listRowInsets(EdgeInsets(top: 6, leading: 42, bottom: 6, trailing: 10))
        .listRowSeparator(.hidden)
        .listRowBackground(selectedFile.wrappedValue == row ? Color.accentColor.opacity(0.14) : .clear)
    }

    @ViewBuilder
    private func groupActions(_ group: LibraryGroup) -> some View {
        if !group.isSystemGroup {
            Button("Rename") { onRenameGroup(group) }
            Button(group.isArchived ? "Restore Group" : "Archive Group") {
                onInteraction(); _ = library.setGroupArchived(group, archived: !group.isArchived)
            }
            Button("Delete Group", role: .destructive) { onDeleteGroup(group) }
        }
    }

    @ViewBuilder
    private func fileActions(_ file: LibraryFile, in group: LibraryGroup) -> some View {
        Button("File Details") { onEditFile(file) }
        Menu("Add to Group") { ForEach(library.activeUserGroups) { target in Button(target.localizedName) {
            onInteraction(); library.addFile(file, to: target)
        } } }
        Menu("Move to Group") { ForEach(library.activeUserGroups.filter { $0.id != group.id }) { target in Button(target.localizedName) {
            onInteraction(); library.moveFile(file, to: target, from: group)
        } } }
        if !group.isSystemGroup, library.isFile(file, in: group) {
            Button("Remove from Group", role: .destructive) { onInteraction(); library.removeFile(file, from: group) }
        }
    }
}
#endif
