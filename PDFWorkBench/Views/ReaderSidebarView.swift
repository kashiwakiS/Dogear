import AppKit
import SwiftUI

struct ReaderSidebarView: View {
    @ObservedObject var documentStore: PDFDocumentStore
    @ObservedObject var aiStore: AIReadingStore
    @ObservedObject var aiHighlightStore: AIHighlightGenerationStore
    @Binding var activeFindScope: ReaderFindScope
    let findFocusRequest: ReaderFindRequest?
    let onFindFieldFocusChanged: (ReaderFindScope?) -> Void

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
                    },
                    activeFindScope: $activeFindScope,
                    findFocusRequest: findFocusRequest,
                    onFindFieldFocusChanged: onFindFieldFocusChanged
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
                expandRequestedFindScope(availableHeight: availableHeight)
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
            .onChange(of: findFocusRequest?.id) { _, _ in
                expandRequestedFindScope(availableHeight: availableHeight)
            }
            .onChange(of: aiStore.capturedSelection) { _, selection in
                guard selection != nil else { return }
                expand(.askSelection, availableHeight: availableHeight)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func expandRequestedFindScope(availableHeight: CGFloat) {
        guard let findFocusRequest else { return }
        let section: ReaderSidebarSection = findFocusRequest.scope == .annotations
            ? .annotations
            : .fullText
        expand(section, availableHeight: availableHeight)
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

private struct AISidebarView: View {
    @ObservedObject var documentStore: PDFDocumentStore
    @ObservedObject var aiStore: AIReadingStore
    @ObservedObject var aiHighlightStore: AIHighlightGenerationStore
    let layout: ReaderSidebarLayout
    let expandedSections: Set<ReaderSidebarSection>
    let onToggleSection: (ReaderSidebarSection) -> Void

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

                            Divider()
                            highlightDiagnostics
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            )
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
                Text("Ask about the document or select a passage to focus the answer. Highlights are added only when useful.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let answer = aiHighlightStore.currentAnswer {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(answer.title)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        if aiHighlightStore.isLocalOutline {
                            Text("Local outline")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if !answer.terminate {
                            Text("Interim answer")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    markdownText(answer.resultMarkdown)
                        .textSelection(.enabled)

                    Button("Copy Answer") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer.resultMarkdown, forType: .string)
                    }
                    .font(.caption)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            if aiHighlightStore.isRunning {
                HStack(alignment: .top, spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(aiHighlightStore.progressDescription)
                            .font(.caption.weight(.medium))
                        Text("\(aiHighlightStore.progressDetail) · \(formattedDuration(aiHighlightStore.elapsedTime))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Cancel") {
                        aiHighlightStore.cancel()
                    }
                    .font(.caption)
                }
                .padding(9)
                .background(
                    Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .accessibilityElement(children: .contain)
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
                        Text("Ask a question, or leave blank for an overview…")
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Ask a question, or leave blank for an overview…")

                HStack {
                    Spacer()

                    Toggle("Allow highlights", isOn: $aiHighlightStore.allowsAnnotations)
                        .toggleStyle(.checkbox)
                        .disabled(isAnyAIActionRunning)

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
        aiHighlightStore.isRunning
    }

    private var canSubmit: Bool {
        documentStore.document != nil && !isAnyAIActionRunning
    }

    private var submitActionHelp: String {
        let question = aiStore.questionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty {
            return aiHighlightStore.canGenerate
                ? L10n.string("Summarize the document with optional evidence highlights")
                : L10n.string("Create a local outline without cloud AI")
        }
        if aiStore.capturedSelection != nil || documentStore.currentTextSelection != nil {
            return L10n.string("Answer using the selected passage and relevant document evidence")
        }
        return L10n.string("Answer from document evidence, with optional highlights")
    }

    private func submitQuestionIfPossible() {
        guard canSubmit else { return }
        submitUnifiedAction()
    }

    private func submitUnifiedAction() {
        let question = aiStore.questionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty {
            aiHighlightStore.generateOverview(from: documentStore)
            return
        }

        let selectedContext = aiStore.contextForCurrentQuestion(from: documentStore)
        // Keep the current question editable for retry/correction, including
        // configuration failures before a workflow starts. This is composer
        // state only; a later Send still starts an independent conversation.
        aiHighlightStore.questionText = question
        aiHighlightStore.generateForQuestion(
            from: documentStore,
            selectedContext: selectedContext
        )
    }

    private var highlightDiagnostics: some View {
        DisclosureGroup("Diagnostics") {
            VStack(alignment: .leading, spacing: 7) {
#if DEBUG
                Toggle(
                    "Include passage content in local logs",
                    isOn: $aiHighlightStore.recordsDetailedTraceContent
                )
                .font(.caption)

                Text("Detailed logs contain document excerpts and questions. API keys and authorization headers are never recorded.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Choose Debug Log Folder…") { aiHighlightStore.chooseDebugLogFolder() }
                    .disabled(isAnyAIActionRunning)
                Text("New logs go into DogearDiagnostics inside the selected folder. Existing logs are not moved.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
#else
                Text("Workflow logs record progress and errors without passage or answer text.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
#endif

                Text(aiHighlightStore.providerDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Reveal Workflow Log") {
                    aiHighlightStore.revealTraceLog()
                }
                .font(.caption)
                Text(aiHighlightStore.traceLocation)
                    .id(aiHighlightStore.traceLocation)
                    .font(.caption2)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = aiHighlightStore.traceStatus {
                    Text(status).font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.top, 4)
            .task { await aiHighlightStore.refreshTraceLocation() }
            .onChange(of: aiHighlightStore.isRunning) { _, running in
                if !running { Task { await aiHighlightStore.refreshTraceLocation() } }
            }
        }
        .font(.caption)
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
