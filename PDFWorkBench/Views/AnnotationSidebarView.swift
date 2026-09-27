import PDFKit
import SwiftUI

struct AnnotationSidebarView: View {
    @ObservedObject var documentStore: PDFDocumentStore
    @ObservedObject private var languageStore = AppLanguageStore.shared
    let layout: ReaderSidebarLayout
    let expandedSections: Set<ReaderSidebarSection>
    let onToggleSection: (ReaderSidebarSection) -> Void
    @Binding var activeFindScope: ReaderFindScope
    let findFocusRequest: ReaderFindRequest?
    let onFindFieldFocusChanged: (ReaderFindScope?) -> Void

    @FocusState private var focusedFindScope: ReaderFindScope?
    @State private var highlightEditDraft: HighlightEditDraft?
    @State private var freeTextEditDraft: FreeTextEditDraft?

    private let maximumVisibleAIHighlightGroupRows = 5
    private let aiHighlightGroupRowHeight: CGFloat = 24
    private let aiHighlightGroupRowSpacing: CGFloat = 5

    var body: some View {
        VStack(spacing: 0) {
            documentSearchSection
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, expandedSections.contains(.fullText) ? 12 : 6)
                .frame(height: layout.height(for: .fullText))
                .clipped()

            ExpandableSidebarSection(
                section: .dogears,
                isExpanded: expandedSections.contains(.dogears),
                height: layout.height(for: .dogears),
                onToggle: { onToggleSection(.dogears) },
                accessory: {
                    Button {
                        documentStore.toggleDogearOnCurrentPage(trigger: .pointer)
                    } label: {
                        Image(systemName: documentStore.currentPageDogear == nil
                            ? "bookmark.circle"
                            : "bookmark.slash")
                    }
                    .disabled(documentStore.document == nil)
                    .help(documentStore.currentPageDogear == nil
                        ? "Add Dog-ear to Current Page"
                        : "Remove Dog-ear from Current Page")
                },
                content: {
                    dogearSection
                }
            )

            expandableSection(.annotations) {
                annotationSection
            }
        }
        .onAppear { applyFindFocusRequest() }
        .onChange(of: findFocusRequest?.id) { _, _ in
            applyFindFocusRequest()
        }
        .onChange(of: focusedFindScope) { _, newScope in
            if let newScope {
                activeFindScope = newScope
            }
            onFindFieldFocusChanged(newScope)
        }
        .sheet(item: $highlightEditDraft) { draft in
            HighlightEditorSheet(documentStore: documentStore, draft: draft)
                .environment(\.locale, languageStore.locale)
        }
        .sheet(item: $freeTextEditDraft) { draft in
            FreeTextEditorSheet(draft: draft, onSave: { values in
                documentStore.updateFreeText(draft, values: values)
            }, onDismiss: { freeTextEditDraft = nil })
                .environment(\.locale, languageStore.locale)
        }
        .onChange(of: documentStore.document.map(ObjectIdentifier.init)) { _, _ in
            highlightEditDraft = nil
            freeTextEditDraft = nil
        }
    }

    private var annotationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !documentStore.aiHighlightGroups.isEmpty {
                aiHighlightGroupSection

                Divider()
            }

            TextField("Search annotations", text: $documentStore.annotationSearchText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedFindScope, equals: .annotations)
                .onTapGesture { activeFindScope = .annotations }
                .disabled(documentStore.document == nil)

            HStack(spacing: 8) {
                Picker("Source", selection: $documentStore.annotationOriginFilter) {
                    ForEach(AnnotationOriginFilter.allCases) { filter in
                        Text(filter.displayTitle).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help("Annotation source")

                Picker(L10n.string("Filter Annotation Type"), selection: $documentStore.annotationKindFilter) {
                    ForEach(AnnotationKindFilter.allCases) { filter in
                        Text(filter.displayTitle).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help("Annotation type")
            }

            HStack(spacing: 6) {
                Text(documentStore.annotationGroupScopeDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if documentStore.activeAIHighlightGroupID != nil {
                    Button {
                        documentStore.activateAIHighlightGroup(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Search all visible annotations")
                }
            }

            HStack(spacing: 8) {
                Text(documentStore.filteredAnnotationCountDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Menu {
                    ForEach(AnnotationExportScope.allCases) { scope in
                        Button("\(scope.displayTitle) (\(documentStore.annotationsForExport(scope: scope).count))") {
                            documentStore.exportAnnotationsMarkdown(scope: scope, trigger: .pointer)
                        }
                        .disabled(documentStore.annotationsForExport(scope: scope).isEmpty)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Export Annotations Markdown")
                .accessibilityLabel("Export Annotations Markdown")
                .disabled(documentStore.annotations.isEmpty)

                Button {
                    documentStore.selectPreviousFilteredAnnotation()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(documentStore.filteredAnnotations.isEmpty)
                .help("Previous annotation")

                Button {
                    documentStore.selectNextFilteredAnnotation()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(documentStore.filteredAnnotations.isEmpty)
                .help("Next annotation")
            }

            if documentStore.filteredAnnotations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "highlighter")
                        .foregroundStyle(.secondary)

                    Text("No Annotations")
                        .font(.callout.weight(.semibold))

                    Text(emptyAnnotationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } else {
                List(documentStore.filteredAnnotations) { annotation in
                    HStack(alignment: .top, spacing: 3) {
                        Button {
                            documentStore.selectAnnotation(annotation)
                        } label: {
                            AnnotationRowView(
                                annotation: annotation,
                                annotationColor: color(for: annotation),
                                isSelected: annotation.id == documentStore.selectedAnnotationID
                            )
                        }
                        .buttonStyle(.plain)
                        Menu {
                            annotationActions(annotation)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .padding(.top, 10)
                        .help("Annotation Actions")
                        .accessibilityLabel("Annotation Actions")
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        annotationActions(annotation)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func annotationActions(_ annotation: PDFAnnotationItem) -> some View {
        if annotation.kind == .highlight {
            Button("Edit Highlight Color and Comment…") {
                highlightEditDraft = documentStore.highlightEditDraft(for: annotation)
            }
            .disabled(!documentStore.canEditDocument)
        } else if documentStore.freeTextEditDraft(for: annotation) != nil {
            Button("Edit Free Text…") {
                freeTextEditDraft = documentStore.freeTextEditDraft(for: annotation)
            }
        }
        Button("Export This Annotation…") {
            documentStore.selectAnnotation(annotation)
            documentStore.exportAnnotationsMarkdown(scope: .selected, trigger: .pointer)
        }
        Divider()
        Button(L10n.string(annotation.kind == .highlight ? "Remove Highlight" : "Remove Note"), role: .destructive) {
            documentStore.removeAnnotation(annotation, trigger: .pointer)
        }
        .disabled(!documentStore.canEditDocument)
    }

    private func color(for item: PDFAnnotationItem) -> Color {
        guard let document = documentStore.document,
              let annotation = AnnotationExtractor.annotation(matching: item, in: document)
        else {
            return Color(nsColor: .secondaryLabelColor)
        }
        // PDF highlights are translucent over paper; the sidebar uses the same
        // hue as an opaque marker so it remains legible in either appearance.
        return Color(nsColor: annotation.color.withAlphaComponent(1))
    }

    private var aiHighlightGroupSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(
                "AI Highlights",
                isOn: Binding(
                    get: { documentStore.showsAIGeneratedContent },
                    set: { documentStore.setAllAIHighlightGroupsVisible($0) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.caption.weight(.semibold))

            ScrollView(
                .vertical,
                showsIndicators: documentStore.aiHighlightGroups.count
                    > maximumVisibleAIHighlightGroupRows
            ) {
                LazyVStack(alignment: .leading, spacing: aiHighlightGroupRowSpacing) {
                    ForEach(documentStore.aiHighlightGroups) { group in
                        let isActive = documentStore.activeAIHighlightGroupID == group.id
                        HStack(spacing: 7) {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: {
                                        documentStore.isAIHighlightGroupVisible(group.id)
                                    },
                                    set: {
                                        documentStore.setAIHighlightGroupVisible(
                                            group.id,
                                            isVisible: $0
                                        )
                                    }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.checkbox)

                            Button {
                                activeFindScope = .annotations
                                documentStore.activateAIHighlightGroup(isActive ? nil : group.id)
                            } label: {
                                HStack(spacing: 7) {
                                    Text(group.displayTitle)
                                        .font(.caption.weight(isActive ? .semibold : .regular))
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text("\(documentStore.aiHighlightCount(in: group.id))")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    isActive ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Menu {
                                deleteGroupButton(group)
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("AI Highlight Group Actions")
                            .accessibilityLabel("AI Highlight Group Actions")
                        }
                        .frame(height: aiHighlightGroupRowHeight)
                        .contextMenu {
                            deleteGroupButton(group)
                        }
                    }
                }
            }
            .frame(height: aiHighlightGroupListHeight)
        }
    }

    private func deleteGroupButton(_ group: AIHighlightGroup) -> some View {
        Button("Delete this group…", role: .destructive) {
            documentStore.confirmRemoveAIHighlightGroup(group.id)
        }
        .disabled(!documentStore.canEditDocument || documentStore.aiHighlightCount(in: group.id) == 0)
    }

    private var aiHighlightGroupListHeight: CGFloat {
        let rowCount = min(
            documentStore.aiHighlightGroups.count,
            maximumVisibleAIHighlightGroupRows
        )
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * aiHighlightGroupRowHeight
            + CGFloat(rowCount - 1) * aiHighlightGroupRowSpacing
    }

    private var emptyAnnotationDescription: LocalizedStringKey {
        if !documentStore.annotationSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            || documentStore.annotationOriginFilter != .all
            || documentStore.annotationKindFilter != .all {
            return "No annotations match the current search and filters."
        }
        return documentStore.activeAIHighlightGroupID == nil
            ? "Highlights and notes appear here."
            : "No highlights match the current AI Highlight group."
    }

    private var dogearSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if documentStore.dogears.isEmpty {
                Text("Press D to add an index marker to the current page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVStack(spacing: ReaderSidebarLayout.dogearRowSpacing) {
                        ForEach(Array(documentStore.dogears.enumerated()), id: \.element.id) { index, marker in
                            DogearIndexRow(
                                marker: marker,
                                canMoveUp: index > 0,
                                canMoveDown: index + 1 < documentStore.dogears.count,
                                onOpen: { documentStore.navigate(to: marker) },
                                onRename: { documentStore.renameDogear(marker, title: $0) },
                                onMove: { documentStore.moveDogear(marker, by: $0) },
                                onRemove: { documentStore.removeDogear(marker, trigger: .pointer) }
                            )
                            .frame(height: ReaderSidebarLayout.dogearRowHeight)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var documentSearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search document text", text: $documentStore.documentSearchText)
                .textFieldStyle(.roundedBorder)
                .focused($focusedFindScope, equals: .documentText)
                .onTapGesture { activeFindScope = .documentText }
                .disabled(documentStore.document == nil)

            if expandedSections.contains(.fullText) {
                HStack(spacing: 8) {
                    Text(documentStore.documentSearchCountDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        documentStore.selectPreviousDocumentSearchResult()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(documentStore.documentSearchResults.isEmpty)
                    .help("Previous text match")

                    Button {
                        documentStore.selectNextDocumentSearchResult()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(documentStore.documentSearchResults.isEmpty)
                    .help("Next text match")
                }

                if !documentStore.documentSearchResults.isEmpty {
                    List(documentStore.documentSearchResults) { result in
                        Button {
                            documentStore.selectDocumentSearchResult(result)
                        } label: {
                            SearchResultRowView(
                                result: result,
                                isSelected: result.id == documentStore.selectedDocumentSearchResultID
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func applyFindFocusRequest() {
        guard let findFocusRequest else { return }
        activeFindScope = findFocusRequest.scope
        focusedFindScope = findFocusRequest.scope
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
}

private struct DogearIndexRow: View {
    let marker: DogearMarker
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onOpen: () -> Void
    let onRename: (String) -> Void
    let onMove: (Int) -> Void
    let onRemove: () -> Void

    @ObservedObject private var languageStore = AppLanguageStore.shared
    @State private var title: String
    @FocusState private var isTitleFocused: Bool

    init(
        marker: DogearMarker,
        canMoveUp: Bool,
        canMoveDown: Bool,
        onOpen: @escaping () -> Void,
        onRename: @escaping (String) -> Void,
        onMove: @escaping (Int) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.marker = marker
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.onOpen = onOpen
        self.onRename = onRename
        self.onMove = onMove
        self.onRemove = onRemove
        _title = State(initialValue: marker.title)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help("Go to Page \(marker.pageNumber)")

            TextField("Index name", text: $title)
                .textFieldStyle(.plain)
                .focused($isTitleFocused)
                .onSubmit { onRename(title) }
                .onAppear { title = marker.displayTitle(language: languageStore.selection) }
                .onChange(of: marker.title) { _, _ in
                    title = marker.displayTitle(language: languageStore.selection)
                }
                .onChange(of: languageStore.selection) { _, newLanguage in
                    title = marker.displayTitle(language: newLanguage)
                }
                .onChange(of: isTitleFocused) { wasFocused, isFocused in
                    if wasFocused && !isFocused {
                        onRename(title)
                    }
                }

            Text("\(marker.pageNumber)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Menu {
                Button("Move Up") { onMove(-1) }
                    .disabled(!canMoveUp)
                Button("Move Down") { onMove(1) }
                    .disabled(!canMoveDown)
                Divider()
                Button("Remove Dog-ear", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 18)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct SearchResultRowView: View {
    let result: PDFSearchResult
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Page \(result.pageNumber)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(result.snippet.isEmpty ? "Match on page \(result.pageNumber)" : result.snippet)
                .font(.callout)
                .lineLimit(3)
                .foregroundStyle(.primary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct AnnotationRowView: View {
    let annotation: PDFAnnotationItem
    let annotationColor: Color
    let isSelected: Bool

    @State private var isHovered = false

    private var quote: String {
        annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var comment: String {
        let note = annotation.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return note == quote ? "" : note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            metadata

            if !quote.isEmpty {
                Text(quote)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(annotationColor)
                            .frame(width: 3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                            }
                    }
            }

            if !comment.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.bubble")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .accessibilityHidden(true)

                    Text(comment)
                        .font(quote.isEmpty ? .callout : .caption)
                        .foregroundStyle(quote.isEmpty ? .primary : .secondary)
                        .lineSpacing(2)
                        .lineLimit(quote.isEmpty ? 5 : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if quote.isEmpty && comment.isEmpty {
                Text(annotation.displayText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            isSelected ? Color.accentColor.opacity(0.1)
                                : Color.primary.opacity(isHovered ? 0.06 : 0.025)
                        )
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.06),
                    lineWidth: isSelected ? 1.25 : 0.5
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(annotation.kind.displayTitle)
                Text("·")
                    .accessibilityHidden(true)
                Text("Page \(annotation.pageNumber)")
                    .lineLimit(1)

                Spacer(minLength: 4)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }

                Text(annotation.isAIGenerated ? L10n.string("AI") : L10n.string("Manual"))
                    .font(.caption2.weight(annotation.isAIGenerated ? .semibold : .regular))
                    .foregroundStyle(annotation.isAIGenerated ? Color.accentColor : .secondary)
            }

            if let category = annotation.aiCategory {
                Text(category.displayTitle)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
