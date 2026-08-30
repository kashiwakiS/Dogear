import AppKit
import SwiftUI

struct ReaderSidebarView: View {
    @ObservedObject var documentStore: PDFDocumentStore
    @ObservedObject var aiStore: AIReadingStore
    @ObservedObject var aiHighlightStore: AIHighlightGenerationStore

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
                availableHeight: availableHeight,
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
                    aiHighlightStore: aiHighlightStore,
                    layout: layout,
                    expandedSections: expandedSections,
                    onToggleSection: {
                        toggle($0, availableHeight: availableHeight)
                    }
                )
            }
            .onAppear {
                enforceExpansionCapacity(availableHeight: availableHeight)
                if !documentStore.documentSearchText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty {
                    expand(.fullText, availableHeight: availableHeight)
                }
            }
            .onChange(of: geometry.size.height) { _, newHeight in
                enforceExpansionCapacity(availableHeight: max(1, newHeight))
            }
            .onChange(of: documentStore.activeAIHighlightGroupID) { _, groupID in
                guard groupID != nil else { return }
                expand(.annotations, availableHeight: availableHeight)
            }
            .onChange(of: documentStore.documentSearchText) { _, query in
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    collapseFullTextSearch()
                } else {
                    expand(.fullText, availableHeight: availableHeight)
                }
            }
            .onChange(of: aiStore.capturedSelection) { _, selection in
                guard selection != nil else { return }
                expand(.askSelection, availableHeight: availableHeight)
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

    private func expand(
        _ section: ReaderSidebarSection,
        availableHeight: CGFloat
    ) {
        withAnimation(.easeInOut(duration: 0.22)) {
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

    private func collapseFullTextSearch() {
        withAnimation(.easeInOut(duration: 0.22)) {
            expandedSections.remove(.fullText)
            expansionOrder.removeAll { $0 == .fullText }
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

private enum PendingAIHighlightContinuation: Equatable {
    case overview(summaryRevision: Int)
    case question(String, conversationCount: Int)
}

private struct AISidebarView: View {
    @ObservedObject var documentStore: PDFDocumentStore
    @ObservedObject var aiStore: AIReadingStore
    @ObservedObject var aiHighlightStore: AIHighlightGenerationStore
    let layout: ReaderSidebarLayout
    let expandedSections: Set<ReaderSidebarSection>
    let onToggleSection: (ReaderSidebarSection) -> Void
    @State private var pendingHighlightContinuation: PendingAIHighlightContinuation?

    var body: some View {
        VStack(spacing: 0) {
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

                            if let report = aiHighlightStore.lastReport {
                                Label(report, systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            if let error = aiHighlightStore.errorMessage {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }

#if DEBUG
                            Divider()
                            highlightDiagnostics
#endif
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            )
        }
        .overlay {
            if aiStore.isPreparing
                || (aiStore.isRunning && aiStore.activeTaskKind == .summarizeDocument)
                || aiHighlightStore.isRunning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(documentActionProgressDescription)
                        .font(.caption)
                    Button("Cancel") { cancelDocumentAction() }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: aiStore.summaryRevision) { _, revision in
            guard case .overview(let startingRevision) = pendingHighlightContinuation,
                  revision > startingRevision
            else {
                return
            }
            pendingHighlightContinuation = nil
            aiHighlightStore.generateOverview(from: documentStore)
        }
        .onChange(of: aiStore.conversation.count) { _, count in
            guard case .question(let question, let startingCount) = pendingHighlightContinuation,
                  count > startingCount
            else {
                return
            }
            pendingHighlightContinuation = nil
            aiHighlightStore.questionText = question
            aiHighlightStore.generateForQuestion(from: documentStore)
        }
        .onChange(of: aiStore.errorMessage) { _, errorMessage in
            if errorMessage != nil {
                pendingHighlightContinuation = nil
            }
        }
        .onChange(of: documentStore.document.map(ObjectIdentifier.init)) { _, _ in
            pendingHighlightContinuation = nil
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
                Text("Select PDF or margin-note text for an answer. Without a selection, a question finds evidence highlights in the document.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !aiStore.summaryMarkdown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    markdownText(aiStore.summaryMarkdown)
                        .textSelection(.enabled)

                    Button("Copy Summary") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(aiStore.summaryMarkdown, forType: .string)
                    }
                    .font(.caption)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
                            Button("Cancel") {
                                pendingHighlightContinuation = nil
                                aiStore.cancel()
                            }
                                .font(.caption)
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
            }

            VStack(alignment: .trailing, spacing: 7) {
                ZStack(alignment: .topLeading) {
                    TextField(
                        "",
                        text: $aiStore.questionText,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitQuestionIfPossible() }

                    if aiStore.questionText.isEmpty {
                        Text("Ask a question, or leave blank to summarize and highlight…")
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Ask a question, or leave blank to summarize and highlight…")

                HStack {
                    Spacer()

                    Button(action: submitUnifiedAction) {
                        Label("Send", systemImage: "arrow.up")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .help(submitActionHelp)
                    .accessibilityLabel("Send")
                    .disabled(!canSubmit)
                }
                .controlSize(.small)
            }
        }
    }

    private var isAnyAIActionRunning: Bool {
        aiStore.isPreparing
            || aiStore.isRunning
            || aiStore.pendingRequest != nil
            || aiHighlightStore.isRunning
    }

    private var canSubmit: Bool {
        documentStore.document != nil && !isAnyAIActionRunning
    }

    private var submitActionHelp: String {
        let question = aiStore.questionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty {
            return L10n.string("Summarize and highlight the document")
        }
        if aiStore.capturedSelection != nil || documentStore.currentTextSelection != nil {
            return L10n.string("Ask and highlight supporting evidence")
        }
        return L10n.string("Highlight evidence for this question")
    }

    private var documentActionProgressDescription: String {
        if aiHighlightStore.isRunning {
            return aiHighlightStore.progressDescription.isEmpty
                ? String(localized: "Preparing highlights…")
                : aiHighlightStore.progressDescription
        }
        return aiStore.progressDescription.isEmpty
            ? String(localized: "Preparing context...")
            : aiStore.progressDescription
    }

    private func cancelDocumentAction() {
        pendingHighlightContinuation = nil
        if aiHighlightStore.isRunning {
            aiHighlightStore.cancel()
        } else {
            aiStore.cancel()
        }
    }

    private func submitQuestionIfPossible() {
        guard canSubmit else { return }
        submitUnifiedAction()
    }

    private func submitUnifiedAction() {
        let question = aiStore.questionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty {
            pendingHighlightContinuation = .overview(
                summaryRevision: aiStore.summaryRevision
            )
            aiStore.prepareDocumentSummary(from: documentStore)
            return
        }

        if aiStore.capturedSelection != nil || documentStore.currentTextSelection != nil {
            pendingHighlightContinuation = .question(
                question,
                conversationCount: aiStore.conversation.count
            )
            aiStore.sendQuestion(from: documentStore)
        } else {
            aiHighlightStore.questionText = question
            aiHighlightStore.generateForQuestion(from: documentStore)
        }
    }

#if DEBUG
    private var highlightDiagnostics: some View {
        DisclosureGroup("Diagnostics") {
            VStack(alignment: .leading, spacing: 7) {
                Toggle(
                    "Include passage content in local logs",
                    isOn: $aiHighlightStore.recordsDetailedTraceContent
                )
                .font(.caption)

                Text("Detailed logs contain document excerpts and questions. API keys and authorization headers are never recorded.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(aiHighlightStore.providerDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Reveal Workflow Log") {
                    aiHighlightStore.revealTraceLog()
                }
                .font(.caption)
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }
#endif

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
                Button("Cancel", role: .cancel) {
                    pendingHighlightContinuation = nil
                    aiStore.cancelPendingRequest()
                }
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
