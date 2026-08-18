import SwiftUI

struct DocumentOutlineRailView: View {
    let entries: [DocumentOutlineEntry]
    let currentPageIndex: Int
    let isLoading: Bool
    let isNightMode: Bool
    let selectedEntryID: DocumentOutlineEntry.ID?
    let onSelect: (DocumentOutlineEntry) -> Void

    @State private var hoveredEntryID: DocumentOutlineEntry.ID?
    @State private var hoverPosition: CGFloat?

    private let rowHeight: CGFloat = 13
    private let interactionWidth: CGFloat = 72
    private let visualWidth: CGFloat = 30
    private let presentationWidth: CGFloat = 260

    private var activeEntryID: DocumentOutlineEntry.ID? {
        selectedEntryID
            ?? entries.last(where: { $0.target.pageIndex <= currentPageIndex })?.id
            ?? entries.first?.id
    }

    var preferredHeight: CGFloat {
        if isLoading || entries.isEmpty {
            return 40
        }
        return min(340, max(56, CGFloat(entries.count) * 13 + 8))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
            } else if entries.isEmpty {
                Image(systemName: "list.bullet.indent")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                    .help("No document outline available")
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            outlineButton(for: entry, at: index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(width: presentationWidth, height: preferredHeight, alignment: .leading)
    }

    private func outlineButton(for entry: DocumentOutlineEntry, at index: Int) -> some View {
        let isHovered = hoveredEntryID == entry.id
        let isActive = activeEntryID == entry.id

        return Button {
            onSelect(entry)
        } label: {
            Capsule()
                .fill(isHovered || isActive ? Color.accentColor : inactiveLineColor)
                .frame(
                    width: lineWidth(for: entry.level, at: index, isActive: isActive),
                    height: isHovered || isActive ? 3 : 2
                )
                .frame(width: interactionWidth, height: rowHeight, alignment: .leading)
                .padding(.leading, CGFloat(min(entry.level, 4)) * 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(entry.title) — Page \(entry.pageNumber)")
        .overlay(alignment: .leading) {
            if isHovered {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text("Page \(entry.pageNumber)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .fixedSize()
                .offset(x: 36)
                .allowsHitTesting(false)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoveredEntryID = entry.id
                hoverPosition = CGFloat(index) + min(1, max(0, location.y / rowHeight))
            case .ended:
                if hoveredEntryID == entry.id {
                    hoveredEntryID = nil
                    hoverPosition = nil
                }
            }
        }
        .accessibilityLabel(entry.title)
        .accessibilityValue("Page \(entry.pageNumber), level \(entry.level + 1)")
    }

    private func lineWidth(for level: Int, at index: Int, isActive: Bool) -> CGFloat {
        let baseWidth = max(7, 18 - CGFloat(min(level, 4)) * 2.5)
        let activeBoost: CGFloat = isActive ? 3 : 0
        guard let hoverPosition else {
            return baseWidth + activeBoost
        }

        let distance = abs(CGFloat(index) + 0.5 - hoverPosition)
        let tidalBoost = max(0, 11 - distance * 3.5)
        return min(visualWidth - CGFloat(min(level, 4)) * 2, baseWidth + activeBoost + tidalBoost)
    }

    private var inactiveLineColor: Color {
        isNightMode ? Color(white: 0.52) : Color(white: 0.72)
    }
}
