import PDFKit
import SwiftUI

struct PageOrganizerView: View {
    @ObservedObject var documentStore: PDFDocumentStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Page Organizer")
                        .font(.title2.weight(.semibold))
                    Text("Drag to reorder. Hold Command or Shift to select multiple pages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if let document = documentStore.document {
                List(selection: $selection) {
                    ForEach(0..<document.pageCount, id: \.self) { pageIndex in
                        PageOrganizerRow(
                            document: document,
                            pageIndex: pageIndex,
                            isCurrent: pageIndex == documentStore.currentPageIndex
                        )
                        .tag(pageIndex)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            documentStore.goToPageNumber(pageIndex + 1, trigger: .pointer)
                        }
                    }
                    .onMove(perform: reorderPages)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack(spacing: 8) {
                Button { documentStore.undoDocumentChange() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!documentStore.canUndoDocumentChange)

                Button { documentStore.redoDocumentChange() } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!documentStore.canRedoDocumentChange)

                Divider().frame(height: 22)

                Button { moveSelection(by: -1) } label: {
                    Label("Move Up", systemImage: "arrow.up")
                }
                .disabled(!canMoveUp)

                Button { moveSelection(by: 1) } label: {
                    Label("Move Down", systemImage: "arrow.down")
                }
                .disabled(!canMoveDown)

                Divider().frame(height: 22)

                Button { duplicateSelection() } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(selection.isEmpty)

                Button { documentStore.rotatePages(at: selectedIndexes, clockwise: false) } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }
                .disabled(selection.isEmpty)

                Button { documentStore.rotatePages(at: selectedIndexes, clockwise: true) } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
                .disabled(selection.isEmpty)

                Spacer()

                Button {
                    documentStore.exportPages(at: selectedIndexes, trigger: .pointer)
                } label: {
                    Label("Export Selected…", systemImage: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty)

                Button(role: .destructive) {
                    deleteSelection()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selection.isEmpty || selection.count >= documentStore.pageCount)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(minWidth: 660, minHeight: 560)
        .onAppear {
            if documentStore.pageCount > 0 {
                selection = [documentStore.currentPageIndex]
            }
        }
    }

    private var selectedIndexes: IndexSet {
        IndexSet(selection)
    }

    private var canMoveUp: Bool {
        selection.min().map { $0 > 0 } == true
    }

    private var canMoveDown: Bool {
        selection.max().map { $0 + 1 < documentStore.pageCount } == true
    }

    private func reorderPages(from source: IndexSet, to destination: Int) {
        guard let document = documentStore.document else { return }
        let selectedPages = source.compactMap { document.page(at: $0) }
        documentStore.movePages(fromOffsets: source, toOffset: destination)
        selection = Set(selectedPages.compactMap { page in
            let index = document.index(for: page)
            return index == NSNotFound ? nil : index
        })
    }

    private func moveSelection(by offset: Int) {
        selection = Set(documentStore.moveSelectedPages(selectedIndexes, by: offset))
    }

    private func duplicateSelection() {
        selection = Set(documentStore.duplicatePages(at: selectedIndexes))
    }

    private func deleteSelection() {
        let firstRemainingIndex = min(selection.min() ?? 0, max(0, documentStore.pageCount - selection.count - 1))
        if documentStore.deletePagesFromWorkingCopy(at: selectedIndexes, trigger: .pointer) {
            selection = [firstRemainingIndex]
        }
    }
}

private struct PageOrganizerRow: View {
    let document: PDFDocument
    let pageIndex: Int
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 14) {
            if let page = document.page(at: pageIndex) {
                Image(nsImage: page.thumbnail(of: NSSize(width: 72, height: 96), for: .cropBox))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 96)
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Page \(pageIndex + 1)")
                    .font(.body.weight(.medium))
                if let page = document.page(at: pageIndex) {
                    Text("\(Int(page.bounds(for: .cropBox).width)) × \(Int(page.bounds(for: .cropBox).height)) pt · \(page.rotation)°")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isCurrent {
                    Label("Current page", systemImage: "location.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
    }
}
