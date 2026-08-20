import AppKit
import SwiftUI

struct ReaderSidebarView: View {
    @ObservedObject var documentStore: PDFDocumentStore
    @ObservedObject var aiStore: AIReadingStore

    @State private var expandedSections: Set<ReaderSidebarSection> = [
        .annotations,
        .askSelection
    ]
    @State private var expansionOrder: [ReaderSidebarSection] = [
        .annotations,
        .askSelection
    ]

    var body: some View {
        GeometryReader { geometry in
            let availableHeight = max(1, geometry.size.height)
            let layout = ReaderSidebarLayout(
                expandedSections: expandedSections
            )

            VStack(spacing: 0) {
                AnnotationSidebarView(
                    documentStore: documentStore,
                    layout: layout,
                    expandedSections: expandedSections,
                    onToggleSection: {
                        toggle($0, availableHeight: availableHeight)
                    }
                )

                AISidebarView(
                    documentStore: documentStore,
                    aiStore: aiStore,
                    layout: layout,
                    expandedSections: expandedSections,
                    onToggleSection: {
                        toggle($0, availableHeight: availableHeight)
                    }
                )
            }
            .onAppear {
                enforceExpansionCapacity(availableHeight: availableHeight)
            }
            .onChange(of: geometry.size.height) { _, newHeight in
                enforceExpansionCapacity(availableHeight: max(1, newHeight))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func toggle(
        _ section: ReaderSidebarSection,
        availableHeight: CGFloat
    ) {
        withAnimation(.easeInOut(duration: 0.22)) {
            if expandedSections.remove(section) != nil {
                expansionOrder.removeAll { $0 == section }
                return
            }

            expandedSections.insert(section)
            expansionOrder.removeAll { $0 == section }
            expansionOrder.append(section)
            trimExpandedSections(
                to: ReaderSidebarLayout.maximumExpandedSectionCount(
                    for: availableHeight
                ),
                preserving: section
            )
        }
    }

    private func enforceExpansionCapacity(availableHeight: CGFloat) {
        withAnimation(.easeInOut(duration: 0.22)) {
            trimExpandedSections(
                to: ReaderSidebarLayout.maximumExpandedSectionCount(
                    for: availableHeight
                ),
                preserving: expansionOrder.last
            )
        }
    }

    private func trimExpandedSections(
        to maximumCount: Int,
        preserving preservedSection: ReaderSidebarSection?
    ) {
        while expandedSections.count > maximumCount {
            guard let sectionToCollapse = expansionOrder.first(where: {
                $0 != preservedSection && expandedSections.contains($0)
            }) else {
                break
            }
            expandedSections.remove(sectionToCollapse)
            expansionOrder.removeAll { $0 == sectionToCollapse }
        }
    }
}

private struct AISidebarView: View {
    @ObservedObject var documentStore: PDFDocumentStore
    @ObservedObject var aiStore: AIReadingStore
    let layout: ReaderSidebarLayout
    let expandedSections: Set<ReaderSidebarSection>
    let onToggleSection: (ReaderSidebarSection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            expandableSection(.documentSummary) {
                summarySection
            }

            ExpandableSidebarSection(
                section: .askSelection,
                isExpanded: expandedSections.contains(.askSelection),
                height: layout.height(for: .askSelection),
                onToggle: { onToggleSection(.askSelection) },
                accessory: {
                    if aiStore.capturedSelection != nil {
                        Button("Use New Selection") {
                            aiStore.useNewSelection(from: documentStore)
                        }
                        .font(.caption)
                    }
                },
                content: {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            )
        }
        .overlay {
            if aiStore.isPreparing
                || (aiStore.isRunning && aiStore.activeTaskKind == .summarizeDocument) {
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

    private func expandableSection<Content: View>(
        _ section: ReaderSidebarSection,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ExpandableSidebarSection(
            section: section,
            isExpanded: expandedSections.contains(section),
            height: layout.height(for: section),
            onToggle: { onToggleSection(section) },
            content: content
        )
    }

    private var summarySection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var questionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                conversationTurn(turn)
            }

            if aiStore.activeTaskKind == .askSelection,
               let question = aiStore.activeQuestion {
                VStack(alignment: .leading, spacing: 8) {
                    userBubble(question: question, context: aiStore.capturedSelection)
                    DisclosureGroup("Thinking… \(formattedDuration(aiStore.elapsedTime))") {
                        VStack(alignment: .leading, spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text(aiStore.progressDescription.isEmpty
                                ? "Waiting for the provider…"
                                : aiStore.progressDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Cancel") { aiStore.cancel() }
                                .font(.caption)
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
            }

            VStack(alignment: .trailing, spacing: 7) {
                TextField("Ask a question...", text: $aiStore.questionText, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendQuestion() }

                Button(action: sendQuestion) {
                    Label("Send", systemImage: "arrow.up")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .help("Send")
                .accessibilityLabel("Send")
                .disabled(
                    aiStore.questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (aiStore.capturedSelection == nil && documentStore.currentTextSelection == nil)
                        || aiStore.isRunning
                )
            }
        }
    }

    private func sendQuestion() {
        aiStore.sendQuestion(from: documentStore)
    }

    private func conversationTurn(_ turn: AIConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            userBubble(
                question: turn.question,
                context: AIContextPackage(
                    title: documentStore.selectedDocumentName,
                    text: turn.selectionText,
                    pageNumbers: turn.pageNumbers
                )
            )

            VStack(alignment: .leading, spacing: 8) {
                reasoningDisclosure(
                    summary: turn.reasoningSummary,
                    duration: turn.duration
                )
                markdownText(turn.answer)
                    .textSelection(.enabled)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func userBubble(question: String, context: AIContextPackage?) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            if let context {
                DisclosureGroup("Selected text · page(s) \(pageDescription(context.pageNumbers))") {
                    Text(context.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption)
            }
            Text(question)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    private func reasoningDisclosure(summary: String?, duration: TimeInterval) -> some View {
        DisclosureGroup("Thought for \(formattedDuration(duration))") {
            Text(summary ?? "The provider did not return a shareable reasoning summary.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        }
        .font(.caption)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.1fs", max(0, duration))
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
