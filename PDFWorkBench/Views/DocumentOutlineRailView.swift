import SwiftUI

enum OutlineRailSpacingMode: String, CaseIterable, Identifiable {
    case even
    case documentPosition

    static let defaultsKey = "PDFWorkBench.OutlineRailSpacingMode"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .even:
            return "Even Spacing"
        case .documentPosition:
            return "Document Position"
        }
    }
}

struct DocumentOutlineRailView: View {
    let entries: [DocumentOutlineEntry]
    let dogears: [DogearMarker]
    let pageCount: Int
    let currentPageIndex: Int
    let isLoading: Bool
    let isNightMode: Bool
    let selectedEntryID: DocumentOutlineEntry.ID?
    let onSelect: (DocumentOutlineEntry) -> Void
    let onSelectDogear: (DogearMarker) -> Void

    @State private var hoveredRowID: RailRow.ID?
    @State private var hoverPosition: CGFloat?
    @AppStorage(OutlineRailSpacingMode.defaultsKey) private var spacingModeRawValue =
        OutlineRailSpacingMode.even.rawValue
    @ObservedObject private var languageStore = AppLanguageStore.shared

    private let rowHeight: CGFloat = 13
    private let minimumProportionalSpacing: CGFloat = 6
    private let interactionWidth: CGFloat = 72
    private let visualWidth: CGFloat = 30
    private let presentationWidth: CGFloat = 260

    private var spacingMode: OutlineRailSpacingMode {
        OutlineRailSpacingMode(rawValue: spacingModeRawValue) ?? .even
    }

    private var activeEntryID: DocumentOutlineEntry.ID? {
        selectedEntryID
            ?? entries.last(where: { $0.target.pageIndex <= currentPageIndex })?.id
            ?? entries.first?.id
    }

    var preferredHeight: CGFloat {
        if isLoading || displayedRailRows.isEmpty {
            return 40
        }
        if spacingMode == .documentPosition {
            return 340
        }
        return min(340, max(56, CGFloat(railRows.count) * rowHeight + 8))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
            } else if displayedRailRows.isEmpty {
                Image(systemName: "list.bullet.indent")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
                    .help("No document outline available")
            } else {
                if spacingMode == .documentPosition {
                    ScrollView(.vertical, showsIndicators: false) {
                        ZStack(alignment: .topLeading) {
                            ForEach(proportionalLayout) { positionedRow in
                                railButton(for: positionedRow.row, at: positionedRow.index)
                                    .offset(y: positionedRow.offset)
                            }
                        }
                        .frame(
                            width: presentationWidth,
                            height: proportionalContentHeight,
                            alignment: .topLeading
                        )
                        .padding(.vertical, 4)
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(railRows.enumerated()), id: \.element.id) { index, row in
                                railButton(for: row, at: index)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(width: presentationWidth, height: preferredHeight, alignment: .leading)
    }

    private func railButton(for row: RailRow, at index: Int) -> some View {
        let isHovered = hoveredRowID == row.id
        let isActive = isRowActive(row)
        let level = row.level
        let fill = rowFill(row, isActive: isActive, isHovered: isHovered)

        return Button {
            switch row {
            case .outline(let entries):
                if let entry = entries.first {
                    onSelect(entry)
                }
            case .dogear(let marker):
                onSelectDogear(marker)
            }
        } label: {
            Capsule()
                .fill(fill)
                .frame(
                    width: lineWidth(for: level, at: index, isActive: isActive),
                    height: isHovered || isActive ? 3 : 2
                )
                .frame(width: interactionWidth, height: rowHeight, alignment: .leading)
                .padding(.leading, CGFloat(min(level, 4)) * 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.help(language: languageStore.selection))
        .overlay(alignment: .leading) {
            if isHovered {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title(language: languageStore.selection))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text("Page \(row.pageNumber)")
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
                hoveredRowID = row.id
                hoverPosition = CGFloat(index) + min(1, max(0, location.y / rowHeight))
            case .ended:
                if hoveredRowID == row.id {
                    hoveredRowID = nil
                    hoverPosition = nil
                }
            }
        }
        .zIndex(isHovered ? 2 : (isActive ? 1 : 0))
        .accessibilityLabel(row.title(language: languageStore.selection))
        .accessibilityValue(row.accessibilityValue(language: languageStore.selection))
    }

    private func isRowActive(_ row: RailRow) -> Bool {
        switch row {
        case .outline(let entries):
            return entries.contains { $0.id == activeEntryID }
        case .dogear(let marker):
            return marker.pageIndex == currentPageIndex
        }
    }

    private func rowFill(_ row: RailRow, isActive: Bool, isHovered: Bool) -> Color {
        switch row {
        case .outline:
            return isHovered || isActive ? Color.accentColor : inactiveLineColor
        case .dogear:
            return Color.yellow
        }
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

private enum RailRow: Identifiable {
    case outline([DocumentOutlineEntry])
    case dogear(DogearMarker)

    var id: String {
        switch self {
        case .outline(let entries):
            let component = entries
                .map { "\($0.id.utf8.count):\($0.id)" }
                .joined()
            return "outline.\(component)"
        case .dogear(let marker):
            return "dogear.\(marker.id.uuidString)"
        }
    }

    var pageIndex: Int {
        switch self {
        case .outline(let entries):
            return entries.first?.target.pageIndex ?? 0
        case .dogear(let marker):
            return marker.pageIndex
        }
    }

    var pageNumber: Int {
        pageIndex + 1
    }

    func documentPosition(pageCount: Int) -> CGFloat {
        let positionWithinPage: CGFloat
        switch self {
        case .outline(let entries):
            positionWithinPage = entries.first?.target.relativePagePosition ?? 0
        case .dogear:
            positionWithinPage = 0
        }

        let position = (CGFloat(pageIndex) + positionWithinPage) / CGFloat(max(1, pageCount))
        return min(1, max(0, position))
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .outline(let entries):
            guard let firstEntry = entries.first else {
                return ""
            }
            guard entries.count > 1 else {
                return firstEntry.title
            }
            return "\(firstEntry.title) (+\(entries.count - 1))"
        case .dogear(let marker):
            return marker.displayTitle(language: language)
        }
    }

    var level: Int {
        switch self {
        case .outline(let entries):
            return entries.first?.level ?? 0
        case .dogear:
            return 0
        }
    }

    func help(language: AppLanguage) -> String {
        L10n.string(
            "\(title(language: language)) — Page \(pageNumber)",
            language: language
        )
    }

    func accessibilityValue(language: AppLanguage) -> String {
        switch self {
        case .outline(let entries):
            return L10n.string(
                "Page \(pageNumber), level \((entries.first?.level ?? 0) + 1)",
                language: language
            )
        case .dogear:
            return L10n.string("Page \(pageNumber)", language: language)
        }
    }
}

private extension DocumentOutlineRailView {
    struct PositionedRailRow: Identifiable {
        let row: RailRow
        let index: Int
        let offset: CGFloat

        var id: RailRow.ID { row.id }
    }

    struct RailItem {
        let row: RailRow
        let pageIndex: Int
        let section: Int
        let order: Int
    }

    struct OutlineMergeKey: Hashable {
        let pageIndex: Int
        let level: Int
    }

    struct OutlineGroup {
        var entries: [DocumentOutlineEntry]
        let pageIndex: Int
        let order: Int
    }

    var displayedRailRows: [RailRow] {
        spacingMode == .documentPosition ? proportionalRailRows : railRows
    }

    var proportionalLayout: [PositionedRailRow] {
        let availableHeight = max(0, preferredHeight - rowHeight - 8)
        var nextAvailableOffset: CGFloat = 0

        return proportionalRailRows.enumerated().map { index, row in
            let naturalOffset = availableHeight * row.documentPosition(pageCount: pageCount)
            let offset = index == 0
                ? naturalOffset
                : max(naturalOffset, nextAvailableOffset)
            nextAvailableOffset = offset + minimumProportionalSpacing
            return PositionedRailRow(row: row, index: index, offset: offset)
        }
    }

    var proportionalContentHeight: CGFloat {
        let baseHeight = max(0, preferredHeight - 8)
        guard let lastOffset = proportionalLayout.last?.offset else {
            return baseHeight
        }
        return max(baseHeight, lastOffset + rowHeight)
    }

    var railRows: [RailRow] {
        let outlineItems = entries.enumerated().map { index, entry in
            RailItem(
                row: .outline([entry]),
                pageIndex: entry.target.pageIndex,
                section: 1,
                order: index
            )
        }

        return sortedRailRows(outlineItems: outlineItems)
    }

    var proportionalRailRows: [RailRow] {
        var groups: [OutlineGroup] = []
        var groupIndexByKey: [OutlineMergeKey: Int] = [:]

        for (index, entry) in entries.enumerated() {
            let key = OutlineMergeKey(
                pageIndex: entry.target.pageIndex,
                level: entry.level
            )
            if let groupIndex = groupIndexByKey[key] {
                groups[groupIndex].entries.append(entry)
            } else {
                groupIndexByKey[key] = groups.count
                groups.append(
                    OutlineGroup(
                        entries: [entry],
                        pageIndex: entry.target.pageIndex,
                        order: index
                    )
                )
            }
        }

        let outlineItems = groups.map { group in
            RailItem(
                row: .outline(group.entries),
                pageIndex: group.pageIndex,
                section: 1,
                order: group.order
            )
        }

        return sortedRailRows(outlineItems: outlineItems)
    }

    func sortedRailRows(outlineItems: [RailItem]) -> [RailRow] {

        let sortedDogears = dogears.enumerated().sorted { lhs, rhs in
            if lhs.element.pageIndex != rhs.element.pageIndex {
                return lhs.element.pageIndex < rhs.element.pageIndex
            }
            if lhs.element.sortIndex != rhs.element.sortIndex {
                return lhs.element.sortIndex < rhs.element.sortIndex
            }
            return lhs.element.title.localizedCaseInsensitiveCompare(rhs.element.title) == .orderedAscending
        }

        let dogearItems = sortedDogears.enumerated().map { index, item in
            RailItem(row: .dogear(item.element), pageIndex: item.element.pageIndex, section: 0, order: index)
        }

        return (outlineItems + dogearItems).sorted { lhs, rhs in
            if lhs.pageIndex != rhs.pageIndex {
                return lhs.pageIndex < rhs.pageIndex
            }
            if lhs.section != rhs.section {
                return lhs.section < rhs.section
            }
            return lhs.order < rhs.order
        }.map(\.row)
    }
}
