#if os(iOS)
import SwiftUI

/// Presentation actions only. PDF ownership, draft flushing and teardown stay
/// in the retained tab model and its existing Session owners.
@MainActor
struct IPadWindowTabStrip: View {
    @ObservedObject var tabs: IPadWindowTabs
    let onNewWindow: () -> Void
    let onMoveTab: (IPadWorkspaceSession) -> Void
    let onToggleLibrary: () -> Void
    let isLibraryVisible: Bool
    @State private var closing: IPadWorkspaceSession?
    @State private var showsFailure = false

    init(tabs: IPadWindowTabs, onNewWindow: @escaping () -> Void,
         onMoveTab: @escaping (IPadWorkspaceSession) -> Void,
         onToggleLibrary: @escaping () -> Void = {}, isLibraryVisible: Bool = true) {
        self.tabs = tabs; self.onNewWindow = onNewWindow; self.onMoveTab = onMoveTab
        self.onToggleLibrary = onToggleLibrary; self.isLibraryVisible = isLibraryVisible
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggleLibrary) {
                Image(systemName: "sidebar.left").frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isLibraryVisible ? "Hide Library" : "Show Library")
            .accessibilityIdentifier("ipad.tabs.library")
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(tabs.sessions, id: \.id) { session in
                            tab(session).id(session.id)
                        }
                    }.padding(.horizontal, 4)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    if let id = tabs.selectedID { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: tabs.selectedID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Button {
                if tabs.addTab() == nil { showsFailure = true }
            } label: {
                Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("New Tab")
            .accessibilityIdentifier("ipad.tabs.new")
            .keyboardShortcut("t", modifiers: .command)
            Menu {
                Button("New Window", systemImage: "macwindow.badge.plus", action: onNewWindow)
                    .keyboardShortcut("n", modifiers: .command)
                if let session = tabs.selectedSession {
                    Button("Move Tab to New Window", systemImage: "arrow.up.forward.app") { onMoveTab(session) }
                        .disabled(tabs.pendingTransfer != nil)
                }
                if tabs.pendingTransfer != nil {
                    Button("Cancel Move", systemImage: "xmark") { tabs.cancelTransfer() }
                }
                if !tabs.closedTabIDs.isEmpty {
                    Menu("Reopen Closed Tab", systemImage: "arrow.uturn.backward") {
                        ForEach(Array(tabs.closedTabIDs.reversed()), id: \.self) { id in
                            Button {
                                _ = tabs.reopenClosedTab(tabID: id)
                            } label: {
                                Text(verbatim: tabs.closedTabTitle(tabID: id))
                            }
                            .accessibilityIdentifier("ipad.tabs.reopen.\(id.uuidString)")
                        }
                    }
                }
            } label: {
                Image(systemName: "macwindow").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Windows")
            .accessibilityIdentifier("ipad.tabs.windows")
        }
        .padding(.horizontal, 6)
        .background(.bar)
        .disabled(!tabs.acceptsUserActions)
        .confirmationDialog("Close Tab?", isPresented: Binding(get: { closing != nil }, set: {
            if !$0 { closing = nil }
        }), titleVisibility: .visible, presenting: closing) { captured in
            Button("Close Tab", role: .destructive) {
                guard tabs.session(for: captured.id) === captured else { return }
                if !tabs.closeConfirmed(tabID: captured.id) { showsFailure = true }
                closing = nil
            }
            Button("Cancel", role: .cancel) { closing = nil }
        } message: { captured in
            Text(verbatim: captured.workspace.document.selectedPDFURL == nil
                 ? L10n.string("New Tab") : captured.workspace.document.selectedDocumentName)
        }
        .alert("Could Not Change Tabs", isPresented: $showsFailure) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Finish the current action and try again.")
        }
    }

    private func tab(_ session: IPadWorkspaceSession) -> some View {
        let selected = tabs.selectedID == session.id
        return HStack(spacing: 0) {
            Button {
                if !tabs.select(tabID: session.id) { showsFailure = true }
            } label: {
                IPadWindowTabTitle(session: session)
                    .frame(minWidth: 80, maxWidth: 180, minHeight: 44, alignment: .leading)
                    .padding(.leading, 10).padding(.trailing, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("ipad.tabs.select.\(session.id.uuidString)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button { closing = session } label: {
                Image(systemName: "xmark").font(.caption)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close Tab")
            .accessibilityIdentifier("ipad.tabs.close.\(session.id.uuidString)")
        }
        .background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor
private struct IPadWindowTabTitle: View {
    @ObservedObject var session: IPadWorkspaceSession
    var body: some View { IPadWindowTabDocumentTitle(store: session.workspace.document) }
}

@MainActor
private struct IPadWindowTabDocumentTitle: View {
    @ObservedObject var store: PDFDocumentStore
    var body: some View {
        Label {
            Text(verbatim: store.selectedPDFURL == nil ? L10n.string("New Tab") : store.selectedDocumentName)
                .lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: store.document == nil ? "doc" : "doc.text")
        }.font(.subheadline)
    }
}
#endif
