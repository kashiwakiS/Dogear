import AppKit
import SwiftUI

struct ReaderSidebarView: View {
    @ObservedObject var documentStore: PDFDocumentStore
    @ObservedObject var aiStore: AIReadingStore

    var body: some View {
        VStack(spacing: 0) {
            AnnotationSidebarView(documentStore: documentStore)
                .frame(maxHeight: .infinity)

            Divider()

            AISidebarView(documentStore: documentStore, aiStore: aiStore)
                .frame(maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct AISidebarView: View {
    @ObservedObject var documentStore: PDFDocumentStore
    @ObservedObject var aiStore: AIReadingStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summarySection
                Divider()
                questionSection

                if let pending = aiStore.pendingRequest {
                    Divider()
                    requestPreview(pending)
                }

                if let error = aiStore.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
        }
        .overlay {
            if aiStore.isPreparing || aiStore.isRunning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(aiStore.progressDescription.isEmpty ? "Preparing context..." : aiStore.progressDescription)
                        .font(.caption)
                    Button("Cancel") { aiStore.cancel() }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Document Summary")
                .font(.headline)

            Button("Review Complete-PDF Summary") {
                aiStore.prepareDocumentSummary(from: documentStore)
            }
            .disabled(documentStore.document == nil || aiStore.isPreparing || aiStore.isRunning)

            if !aiStore.summaryMarkdown.isEmpty {
                markdownText(aiStore.summaryMarkdown)
                    .textSelection(.enabled)

                Button("Copy Summary") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(aiStore.summaryMarkdown, forType: .string)
                }
                .font(.caption)
            }
        }
    }

    private var questionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ask About Selection")
                    .font(.headline)
                Spacer()
                if aiStore.capturedSelection != nil {
                    Button("Use New Selection") {
                        aiStore.useNewSelection(from: documentStore)
                    }
                    .font(.caption)
                }
            }

            if let context = aiStore.capturedSelection {
                Text("Using \(context.characterCount) characters from page(s) \(pageDescription(context.pageNumbers)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let selection = documentStore.currentTextSelection {
                Text("Selected \(selection.text.count) characters on page(s) \(pageDescription(selection.pageNumbers)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select text in the PDF to begin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(aiStore.conversation) { turn in
                VStack(alignment: .leading, spacing: 5) {
                    Text(turn.question)
                        .font(.callout.weight(.semibold))
                    markdownText(turn.answer)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            TextField("Ask a question...", text: $aiStore.questionText, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            Button("Review Request") {
                aiStore.prepareQuestion(from: documentStore)
            }
            .disabled(
                aiStore.questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (aiStore.capturedSelection == nil && documentStore.currentTextSelection == nil)
                    || aiStore.isRunning
            )
        }
    }

    private func requestPreview(_ pending: AIPendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review Before Sending")
                .font(.headline)
            if let file = pending.context.file {
                Text("\(pending.kind.rawValue) · \(file.pageCount) page(s) · \(formattedByteCount(file.byteCount)) · 1 request")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label("The complete PDF “\(file.filename)” will be uploaded to the configured provider.", systemImage: "doc.badge.arrow.up")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("\(pending.kind.rawValue) · \(pending.context.pageNumbers.count) page(s) · \(pending.previewText.count) characters · \(pending.estimatedRequestCount) request")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Exact text to send") {
                    ScrollView {
                        Text(pending.previewText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }

            HStack {
                Button("Cancel", role: .cancel) { aiStore.cancelPendingRequest() }
                Spacer()
                Button("Send to Provider") { aiStore.sendPendingRequest() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func markdownText(_ markdown: String) -> Text {
        if let attributed = try? AttributedString(markdown: markdown) {
            return Text(attributed)
        }
        return Text(markdown)
    }

    private func pageDescription(_ pages: [Int]) -> String {
        pages.map(String.init).joined(separator: ", ")
    }

    private func formattedByteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
