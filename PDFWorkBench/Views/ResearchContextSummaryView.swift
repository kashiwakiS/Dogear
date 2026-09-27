import SwiftUI

struct ResearchContextSummaryView: View {
    let message: ResearchMessage

    var body: some View {
        DisclosureGroup("Reference scope for this request") {
            VStack(alignment: .leading, spacing: 8) {
                if let context = message.contextSummary {
                    if context.isLocalOutline {
                        Text("This local outline did not send conversation history or documents to a provider.")
                    } else {
                        Text("Previous exchanges included: \(context.historyMessageIDs.count) of \(context.availableHistoryRounds)")
                        if context.omittedHistoryRounds > 0 {
                            Text("Earlier exchanges omitted: \(context.omittedHistoryRounds)")
                            switch context.historyOmission {
                            case .roundLimit:
                                Text("Only the most recent six complete exchanges are included.")
                            case .characterLimit:
                                Text("Complete exchanges did not fit the history limit. A long latest exchange can leave no history in this request.")
                            default: EmptyView()
                            }
                        }
                        Text("Conversation history is background. Documentary claims still require current source evidence.")
                        if context.imageCount > 0 { Text("Images included: \(context.imageCount)") }
                        if context.excludedImageCount > 0 { Text("Images excluded by text-only sending: \(context.excludedImageCount)") }
                    }
                    sourceList(context)
                } else {
                    Text("This older request did not record its history selection. Its saved sources are shown below.")
                    ForEach(message.sourceSnapshot) { source in
                        Text(source.displayName).textSelection(.enabled)
                    }
                }
                Text("This scope was fixed when you started the request. It does not change with the current Group.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
        .font(.caption)
    }

    @ViewBuilder private func sourceList(_ context: ResearchContextSummary) -> some View {
        Text("Selected source files: \(message.sourceSnapshot.count)")
        let cited = Set(message.evidence.compactMap { $0.source?.fileID })
        ForEach(message.sourceSnapshot) { source in
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName).fontWeight(.medium).textSelection(.enabled)
                if let omission = context.skippedSources.first(where: { $0.fileID == source.fileID }) {
                    Text(L10n.string("Skipped") + ": " + omission.reason)
                } else if cited.contains(source.fileID) {
                    Text("Cited in this answer")
                } else if let indexed = context.retrievalFileIDs, indexed.contains(source.fileID) {
                    Text("Available for search; not cited")
                } else if let prepared = context.preparedFileIDs, prepared.contains(source.fileID) {
                    if context.isLocalOutline && message.status == .accepted { Text("Used for the local outline") }
                    else { Text("Text prepared; search coverage not recorded") }
                } else {
                    Text("Preparation not completed")
                }
            }
            .padding(.leading, 8)
        }
    }
}
