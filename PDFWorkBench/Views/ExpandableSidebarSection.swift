import SwiftUI

enum ReaderSidebarSection: CaseIterable, Hashable {
    case fullText
    case dogears
    case annotations
    case askSelection

    var titleKey: String.LocalizationValue {
        switch self {
        case .fullText:
            return "Full Text"
        case .dogears:
            return "Dog-ears"
        case .annotations:
            return "Annotations"
        case .askSelection:
            return "Ask"
        }
    }
}

struct ReaderSidebarLayout {
    static let collapsedSectionHeight: CGFloat = 36
    static let minimumExpandedSectionHeight: CGFloat = 240
    static let dogearRowHeight: CGFloat = 30
    static let dogearRowSpacing: CGFloat = 4
    static let maximumVisibleDogearRows = 8
    private static let expandedContentInsets: CGFloat = 16
    private static let emptyDogearContentHeight: CGFloat = 44

    let availableHeight: CGFloat
    let expandedSections: Set<ReaderSidebarSection>
    var visibleSections: Set<ReaderSidebarSection> = Set(ReaderSidebarSection.allCases)
    var dogearCount = 0

    private var expandedVisibleSections: Set<ReaderSidebarSection> {
        expandedSections.intersection(visibleSections)
    }

    private var minimumDogearHeight: CGFloat {
        Self.collapsedSectionHeight + Self.expandedContentInsets + Self.dogearRowHeight
    }

    var preferredDogearHeight: CGFloat {
        let rows = min(max(0, dogearCount), Self.maximumVisibleDogearRows)
        let contentHeight = rows == 0 ? Self.emptyDogearContentHeight
            : CGFloat(rows) * Self.dogearRowHeight + CGFloat(rows - 1) * Self.dogearRowSpacing
        return Self.collapsedSectionHeight + Self.expandedContentInsets + contentHeight
    }

    var fitsExpandedSections: Bool {
        let requiredHeight = visibleSections.reduce(CGFloat(0)) { total, section in
            guard expandedVisibleSections.contains(section) else { return total + Self.collapsedSectionHeight }
            return total + (section == .dogears ? minimumDogearHeight : Self.minimumExpandedSectionHeight)
        }
        return requiredHeight <= availableHeight
    }

    static func maximumExpandedSectionCount(for availableHeight: CGFloat, sectionCount: Int = ReaderSidebarSection.allCases.count) -> Int {
        for expandedCount in stride(from: sectionCount, through: 1, by: -1) {
            let collapsedCount = sectionCount - expandedCount
            let occupiedHeight = CGFloat(expandedCount) * minimumExpandedSectionHeight
                + CGFloat(collapsedCount) * collapsedSectionHeight
            if occupiedHeight <= availableHeight {
                return expandedCount
            }
        }

        return 1
    }

    func height(for section: ReaderSidebarSection) -> CGFloat {
        guard visibleSections.contains(section) else { return 0 }
        guard expandedSections.contains(section) else {
            return Self.collapsedSectionHeight
        }

        let expandedCount = max(1, expandedVisibleSections.count)
        let collapsedCount = visibleSections.count - expandedCount
        let availableExpandedHeight = max(
            Self.collapsedSectionHeight,
            availableHeight - CGFloat(collapsedCount) * Self.collapsedSectionHeight
        )
        guard expandedVisibleSections.contains(.dogears) else {
            return availableExpandedHeight / CGFloat(expandedCount)
        }

        // A short index takes only its content height. Longer indexes scroll
        // after eight rows, or sooner when the other open panes need space.
        let flexibleCount = expandedCount - 1
        let reservedHeight = CGFloat(flexibleCount) * Self.minimumExpandedSectionHeight
        let dogearHeight = min(preferredDogearHeight, availableExpandedHeight,
            max(minimumDogearHeight, availableExpandedHeight - reservedHeight))
        if section == .dogears { return dogearHeight }
        return max(0, availableExpandedHeight - dogearHeight) / CGFloat(max(1, flexibleCount))
    }
}

struct ExpandableSidebarSection<Accessory: View, Content: View>: View {
    let section: ReaderSidebarSection
    let isExpanded: Bool
    let height: CGFloat
    let onToggle: () -> Void
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    private var title: String {
        L10n.string(section.titleKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    Text(title)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                accessory()

                Button(action: onToggle) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .help(
                    isExpanded
                        ? L10n.string("Collapse \(title)")
                        : L10n.string("Expand \(title)")
                )
            }
            .padding(.horizontal, 12)
            .frame(height: ReaderSidebarLayout.collapsedSectionHeight)

            if isExpanded {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .frame(height: height)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipped()
    }
}

extension ExpandableSidebarSection where Accessory == EmptyView {
    init(
        section: ReaderSidebarSection,
        isExpanded: Bool,
        height: CGFloat,
        onToggle: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.section = section
        self.isExpanded = isExpanded
        self.height = height
        self.onToggle = onToggle
        self.accessory = { EmptyView() }
        self.content = content
    }
}
