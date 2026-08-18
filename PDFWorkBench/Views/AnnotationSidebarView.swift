import SwiftUI

struct AnnotationSidebarView: View {
    @ObservedObject var documentStore: PDFDocumentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            documentSearchSection

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
