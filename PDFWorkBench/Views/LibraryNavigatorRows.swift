import SwiftUI

/// Shared Library row presentation; native hosts own selection and gestures.
struct LibraryNavigatorGroupRow: View {
    let group: LibraryGroup
    let isExpanded: Bool
    let isSelected: Bool
    let onToggleExpansion: () -> Void
    var disclosureTargetSize: CGFloat? = nil

    @ObservedObject private var languageStore = AppLanguageStore.shared

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onToggleExpansion) {
                Image(systemName: groupIconName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: disclosureTargetSize ?? 18, height: disclosureTargetSize ?? 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expansionLabel)
            .accessibilityLabel(expansionLabel)

            Text(displayName)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)

            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expansionLabel: Text {
        isExpanded ? Text("Collapse \(displayName)") : Text("Expand \(displayName)")
    }

    private var displayName: String {
        group.localizedName(language: languageStore.selection)
    }

    private var groupIconName: String {
        if group.isSystemGroup {
            return isExpanded ? "tray.fill" : "tray"
        }

        if group.isArchived {
            return "archivebox"
        }

        return isExpanded ? "folder.fill" : "folder"
    }
}

struct LibraryNavigatorFileRow: View {
    let item: LibraryItem
    let markerColor: Color?
    let isUnavailable: Bool
    let isTemporary: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: "doc")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .lineLimit(1)
                    .foregroundStyle(isUnavailable ? .secondary : .primary)

                if !item.tags.isEmpty {
                    Text(item.tags.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            if isTemporary {
                Image(systemName: "pin.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Temporary in this window")
            }

            if let markerColor {
                DuplicateLibraryMarker(color: markerColor)
                    .help(item.path)
                    .padding(.trailing, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isUnavailable ? 0.55 : 1)
    }
}

private struct DuplicateLibraryMarker: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color)

            Circle()
                .stroke(Color.primary.opacity(0.25), lineWidth: 0.5)
        }
        .frame(width: 8, height: 8)
        .accessibilityLabel("Duplicate filename marker")
    }
}
