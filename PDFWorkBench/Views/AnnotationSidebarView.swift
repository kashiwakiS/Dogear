import SwiftUI

struct AnnotationSidebarView: View {
    @ObservedObject var documentStore: PDFDocumentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            documentSearchSection

            Divider()

            dogearSection

            Divider()

            Text("Annotations")
                .font(.headline)

            TextField("Search highlights and notes", text: $documentStore.searchText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Text(documentStore.filteredAnnotationCountDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

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

                    Text("No Matches")
                        .font(.callout.weight(.semibold))

                    Text("Highlights and notes appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } else {
                List(documentStore.filteredAnnotations) { annotation in
                    Button {
                        documentStore.selectAnnotation(annotation)
                    } label: {
                        AnnotationRowView(
                            annotation: annotation,
                            searchText: documentStore.searchText,
                            isSelected: annotation.id == documentStore.selectedAnnotationID
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if annotation.kind == .highlight {
                            Button("Remove Highlight", role: .destructive) {
                                documentStore.removeAnnotation(annotation, trigger: .pointer)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var dogearSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Dog-ears")
                    .font(.headline)
                Spacer()
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
            }

            if documentStore.dogears.isEmpty {
                Text("Press D to add an index marker to the current page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
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
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private var documentSearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Full Text")
                .font(.headline)

            TextField("Search document text", text: $documentStore.documentSearchText)
                .textFieldStyle(.roundedBorder)

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
                .frame(minHeight: 120, maxHeight: 220)
            }
        }
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

    @Environment(\.locale) private var locale
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
        _title = State(initialValue: marker.displayTitle)
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
                .onChange(of: marker.title) { _, _ in title = marker.displayTitle }
                .onChange(of: locale) { _, _ in title = marker.displayTitle }
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
    let searchText: String
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Page \(annotation.pageNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(annotation.kind.rawValue)
                    .font(.caption2)
                    .foregroundStyle(annotation.kind == .highlight ? .yellow : .blue)
            }

            highlightedText(annotation.displayText, query: searchText)
                .font(.callout)
                .lineLimit(4)
                .foregroundStyle(.primary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func highlightedText(_ text: String, query: String) -> Text {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuery.isEmpty else {
            return Text(text)
        }

        var attributedText = AttributedString(text)
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let range = text.range(
                of: trimmedQuery,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<text.endIndex
              ) {
            if let attributedStart = AttributedString.Index(range.lowerBound, within: attributedText),
               let attributedEnd = AttributedString.Index(range.upperBound, within: attributedText) {
                attributedText[attributedStart..<attributedEnd].font = .body.bold()
                attributedText[attributedStart..<attributedEnd].foregroundColor = .accentColor
            }

            searchStart = range.upperBound
        }

        return Text(attributedText)
    }
}
