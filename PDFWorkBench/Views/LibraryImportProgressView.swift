import SwiftUI

struct LibraryImportProgressView: View {
    @ObservedObject var controller: LibraryImportController

    var body: some View {
        if controller.isVisible {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    if controller.isRunning { ProgressView().controlSize(.small) }
                    if controller.isScanning {
                        Text("Scanning · \(controller.found) PDFs found")
                    } else if controller.isRunning {
                        Text("Importing · \(controller.completed) of \(controller.total)")
                    } else if controller.cancelled {
                        Text("Import stopped · \(controller.completed) files kept")
                    } else {
                        Text("Import finished · \(controller.completed) files · \(controller.skipped) skipped · \(controller.failures.count) failed")
                    }
                    Spacer()
                    if controller.isRunning { Button("Cancel") { controller.cancel() } }
                    else { Button("Dismiss") { controller.dismiss() } }
                }
                if !controller.failures.isEmpty {
                    DisclosureGroup("Import details") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(controller.failures.enumerated()), id: \.offset) { _, failure in
                                    Text("\(failure.url.lastPathComponent): \(L10n.string(String.LocalizationValue(failure.reason)))")
                                        .textSelection(.enabled)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 100)
                    }
                }
            }.font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                .background(.quaternary.opacity(0.3))
        }
    }
}
