import SwiftUI

enum ReaderSidebarSection: CaseIterable, Hashable {
    case fullText
    case dogears
    case annotations
    case documentSummary
    case askSelection

    var titleKey: String.LocalizationValue {
        switch self {
        case .fullText:
            return "Full Text"
        case .dogears:
            return "Dog-ears"
        case .annotations:
            return "Annotations"
        case .documentSummary:
            return "Document Summary"
        case .askSelection:
            return "Ask About Selection"
        }
    }
}

struct ReaderSidebarLayout {
    static let collapsedSectionHeight: CGFloat = 36
    static let expandedSectionHeight: CGFloat = 240
    static let maximumOccupiedHeightRatio: CGFloat = 0.8

    let expandedSections: Set<ReaderSidebarSection>

    static func maximumExpandedSectionCount(for availableHeight: CGFloat) -> Int {
        let sectionCount = ReaderSidebarSection.allCases.count
        let heightLimit = availableHeight * maximumOccupiedHeightRatio

        for expandedCount in stride(from: sectionCount, through: 1, by: -1) {
            let collapsedCount = sectionCount - expandedCount
            let occupiedHeight = CGFloat(expandedCount) * expandedSectionHeight
                + CGFloat(collapsedCount) * collapsedSectionHeight
            if occupiedHeight <= heightLimit {
                return expandedCount
            }
        }

        return 1
    }

    func height(for section: ReaderSidebarSection) -> CGFloat {
        expandedSections.contains(section)
            ? Self.expandedSectionHeight
            : Self.collapsedSectionHeight
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
