#if os(iOS)
import Combine
import Foundation
import UIKit

@MainActor
final class IPadApplicationServices: ObservableObject {
    let library: LibraryStore
    let research: ResearchStore
    let configuration: AIConfigurationStore
    let language: AppLanguageStore
    let commands: ResearchCommandService
    let runtime: ResearchRuntime
    private let saveQueue: PDFSaveQueue
    private let beginBackgroundTask: (@escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    private let endBackgroundTask: (UIBackgroundTaskIdentifier) -> Void
    private var backgroundObserver: NSObjectProtocol?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundWindowID: UUID?
    private var backgroundSaveGeneration = 0
    private var draining: Task<Void, Never>?

    init(library: LibraryStore? = nil, research: ResearchStore? = nil,
         configuration: AIConfigurationStore? = nil, language: AppLanguageStore? = nil,
         commands: ResearchCommandService? = nil, runtime: ResearchRuntime? = nil,
         saveQueue: PDFSaveQueue? = nil, observesApplication: Bool = true,
         beginBackgroundTask: ((@escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier)? = nil,
         endBackgroundTask: ((UIBackgroundTaskIdentifier) -> Void)? = nil) {
        self.library = library ?? LibraryStore()
        self.research = research ?? .shared
        self.configuration = configuration ?? .shared
        self.language = language ?? .shared
        self.commands = commands ?? .shared
        self.saveQueue = saveQueue ?? .shared
        self.runtime = runtime ?? ResearchRuntime(storage: self.research, configuration: self.configuration,
                                                  commands: self.commands, retrievalSelection: .lexical)
        self.beginBackgroundTask = beginBackgroundTask ?? { expiration in
            UIApplication.shared.beginBackgroundTask(withName: "Save Dogear drafts") {
                MainActor.assumeIsolated { expiration() }
            }
        }
        self.endBackgroundTask = endBackgroundTask ?? { UIApplication.shared.endBackgroundTask($0) }
        if observesApplication {
            backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveForBackground() }
            }
        }
    }

    /// Observe the application, not one scene: another scene may still be active.
    /// The OS may interrupt this window; the shared save journal retains pending
    /// writes and the shared stores retain failed saves for an explicit retry.
    func saveForBackground() {
        // Another background event may arrive after foreground edits while the
        // previous queue drain is still running. Always flush the new state.
        backgroundSaveGeneration += 1
        beginBackgroundWindowIfNeeded()
        runtime.shutdown()
        research.retryFailedSaves()
        _ = library.flushPendingPersistence()
        guard draining == nil else { return }
        let queue = saveQueue
        draining = Task { [weak self] in
            while let generation = self?.backgroundSaveGeneration {
                await queue.drain()
                guard let self else { return }
                if generation != self.backgroundSaveGeneration { continue }
                self.endBackgroundWindow()
                self.draining = nil
                return
            }
        }
    }

    func waitForBackgroundSave() async { await draining?.value }

    private func beginBackgroundWindowIfNeeded() {
        guard backgroundTask == .invalid else { return }
        let windowID = UUID()
        backgroundWindowID = windowID
        let task = beginBackgroundTask { [weak self] in
            guard self?.backgroundWindowID == windowID else { return }
            self?.endBackgroundWindow()
        }
        if backgroundWindowID == windowID {
            backgroundTask = task
            if task == .invalid { backgroundWindowID = nil }
        } else if task != .invalid {
            // Handle an expiration callback that occurred during registration.
            endBackgroundTask(task)
        }
    }

    private func endBackgroundWindow() {
        let task = backgroundTask
        backgroundTask = .invalid
        backgroundWindowID = nil
        if task != .invalid { endBackgroundTask(task) }
    }

    deinit { if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) } }
}
#endif
