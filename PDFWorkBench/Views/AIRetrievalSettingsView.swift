import SwiftUI
import UniformTypeIdentifiers

struct AIRetrievalSettingsView: View {
    @AppStorage(AIRetrievalMode.defaultsKey) private var mode = AIRetrievalMode.scheme1Lexical.rawValue
    @AppStorage(AIRetrievalSelection.packageDefaultsKey) private var packageID = ""
    @State private var isImporting = false
    @State private var isInstalling = false
    @State private var errorMessage: String?

    var body: some View {
        Section("Evidence Retrieval") {
            Picker("Retrieval Mode", selection: $mode) {
                Text("Lightweight — lexical").tag(AIRetrievalMode.scheme1Lexical.rawValue)
                Text("Semantic — Small EN (experimental)").tag(AIRetrievalMode.scheme2EvidenceRAG.rawValue)
            }
            Text("Semantic retrieval uses BGE Small EN locally for English papers. Chinese questions can produce English search queries. Changes apply to the next request only.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Import Local Model…") { isImporting = true }
                    .disabled(isInstalling)
                if isInstalling {
                    ProgressView().controlSize(.small)
                    Text("Checking and importing model…").font(.caption)
                } else {
                    Text(packageID.isEmpty ? "No local model imported" : "Model imported; validated before use")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Import the SmallEN folder produced by Dogear's model conversion script. No model downloads happen automatically. Lexical retrieval needs no local model.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
            switch result {
            case .failure(let error): errorMessage = error.localizedDescription
            case .success(let url):
                isInstalling = true; errorMessage = nil
                Task {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                        isInstalling = false
                    }
                    do { packageID = try await AILocalEmbeddingModels.shared.install(from: url) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        }
    }
}
