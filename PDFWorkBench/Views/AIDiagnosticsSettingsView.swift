import AppKit
import SwiftUI

/// App-level diagnostics must stay reachable independently of a PDF's legacy Ask view.
struct AIDiagnosticsSettingsView: View {
    @ObservedObject private var runtime = ResearchRuntime.shared
    @State private var location = ""
    @State private var status: String?
#if DEBUG
    @AppStorage(AIHighlightTraceRecorder.detailedContentDefaultsKey) private var includesContent = false
    @State private var confirmsDetailedContent = false
#endif

    var body: some View {
        Section("Diagnostics") {
            Text("Workflow logs record progress and errors without passage or answer text.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Logs from earlier versions may contain document content. Review them before sharing.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Reveal Workflow Log") { Task { await reveal() } }
            if !location.isEmpty {
                Text(location).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
#if DEBUG
            Toggle("Include passage content in local logs", isOn: Binding(
                get: { includesContent },
                set: { enabled in
                    if enabled { confirmsDetailedContent = true }
                    else { includesContent = false }
                }
            ))
            Text("Detailed logs contain document excerpts and questions. API keys and authorization headers are never recorded.")
                .font(.caption).foregroundStyle(.secondary)
            DirectoryImportButton(title: "Choose Debug Log Folder…", prepare: canChooseDirectory) { result in
                Task { await chooseDirectory(result) }
            }
                .disabled(!runtime.jobs.isEmpty)
            Text("New logs go into DogearDiagnostics inside the selected folder. Existing logs are not moved.")
                .font(.caption).foregroundStyle(.secondary)
#endif
            if let status {
                Text(status).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .task { await refresh() }
        .onChange(of: runtime.jobs.count) { _, _ in Task { await refresh() } }
#if DEBUG
        .confirmationDialog("Include document content in local logs?", isPresented: $confirmsDetailedContent,
                            titleVisibility: .visible) {
            Button("Enable detailed logs") { includesContent = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Detailed logs contain document excerpts and questions. API keys and authorization headers are never recorded.")
        }
#endif
    }

    @MainActor private func refresh() async {
        let recorder = AIHighlightTraceRecorder.shared
        location = await recorder.traceFileURL()?.path ?? ""
        let lastError = await recorder.lastError
        status = lastError.map { L10n.string(String.LocalizationValue($0)) }
    }

    @MainActor private func reveal() async {
        await refresh()
        guard let url = await AIHighlightTraceRecorder.shared.traceFileURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            status = L10n.string("No workflow log yet. Run an AI request first.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

#if DEBUG
    @MainActor private func canChooseDirectory() async -> Bool {
        // Query live actor state; an asynchronously recorded terminal event may
        // follow the jobs observation, so do not cache a disabled-button flag.
        guard !(await AIHighlightTraceRecorder.shared.hasActiveWorkflows) else {
            status = L10n.string("Could not select the log folder. Finish active requests and choose a writable folder.")
            return false
        }
        return true
    }

    @MainActor private func chooseDirectory(_ selection: Result<URL, Error>) async {
        do {
            try await AIHighlightTraceRecorder.shared.chooseDebugDirectory(selection.get())
            await refresh()
        } catch {
            status = L10n.string("Could not select the log folder. Finish active requests and choose a writable folder.")
        }
    }
#endif
}
