#if os(iOS)
import SwiftUI

@MainActor
struct IPadResearchSourcePicker: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var storage: ResearchStore
    let sessionID: UUID?
    let currentFileID: UUID?
    let currentGroupID: UUID
    @Environment(\.dismiss) private var dismiss
    @StateObject private var titleCommands = IPadResearchTextEditingCommands()

    private var session: ResearchSession? { sessionID.flatMap { storage.session(id: $0) } }
    private var sourceIDs: [UUID] {
        guard let session else { return [] }
        let members = session.sourceSelection.groupID.map { library.files(in: $0).map(\.id) } ?? []
        return session.sourceSelection.expandedFileIDs(groupMembers: members)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Session") {
                    if let sessionID {
                        IPadResearchNativeTextEditor(text: Binding(
                            get: { storage.session(id: sessionID)?.title ?? "" },
                            set: { title in
                                guard var value = storage.session(id: sessionID), value.title != title else { return }
                                value.title = title
                                _ = storage.updateSession(value)
                            }), commands: titleCommands, identity: sessionID, isTitle: true)
                            .frame(height: 52).id(sessionID)
                    }
                }
                Section {
                    Text("Sources are fixed when you send. Opening a PDF does not change this selection.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Group", selection: Binding<UUID?>(get: { session?.sourceSelection.groupID },
                        set: { value in mutate { $0.sourceSelection.groupID = value } })) {
                        Text("No Group").tag(nil as UUID?)
                        ForEach(library.userGroups) { group in Text(verbatim: group.name).tag(Optional(group.id)) }
                    }
                    if let currentFileID {
                        Button("Add current PDF") { setFile(currentFileID, included: true) }
                            .disabled(sourceIDs.contains(currentFileID))
                    }
                    if library.userGroups.contains(where: { $0.id == currentGroupID }) {
                        Button("Use current Group") { mutate { $0.sourceSelection.groupID = currentGroupID } }
                    }
                }
                Section("Additional files") {
                    ForEach(library.allFiles) { file in
                        Toggle(isOn: Binding(get: { session?.sourceSelection.fileIDs.contains(file.id) == true },
                            set: { setFile(file.id, included: $0) })) {
                            VStack(alignment: .leading) {
                                Text(verbatim: file.displayName)
                                Text(verbatim: String(file.id.uuidString.prefix(8)))
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Research sources")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") {
                if let sessionID, !titleCommands.commitMarkedTextAndEndEditing(identity: sessionID) { return }
                dismiss()
            } } }
        }
    }

    private func mutate(_ change: (inout ResearchSession) -> Void) {
        guard let id = sessionID, var value = storage.session(id: id) else { return }
        change(&value)
        _ = storage.updateSession(value)
    }

    private func setFile(_ id: UUID, included: Bool) {
        mutate {
            $0.sourceSelection.fileIDs.removeAll { $0 == id }
            if included { $0.sourceSelection.fileIDs.append(id) }
        }
    }
}
#endif
