import Combine
import Foundation

enum FeedbackDetailLevel: String, Codable, CaseIterable {
    case minimal
    case standard
    case verbose
}

enum OperationFeedbackKind: String, Equatable {
    case info
    case success
    case warning
    case error

    var defaultDisplayDuration: TimeInterval {
        switch self {
        case .info, .success:
            2.5
        case .warning, .error:
            6
        }
    }
}

enum FeedbackTrigger: Equatable {
    case keyboard(shortcut: String)
    case toolbar
    case command(shortcut: String?)
    case pointer
    case system

    var description: String {
        switch self {
        case .keyboard(let shortcut):
            return "Keyboard: \(shortcut)"
        case .toolbar:
            return "Toolbar"
        case .command(let shortcut):
            return shortcut.map { "Menu command: \($0)" } ?? "Menu command"
        case .pointer:
            return "Pointer"
        case .system:
            return "System"
        }
    }
}

struct OperationFeedback: Identifiable, Equatable {
    let id: UUID
    let message: String
    let kind: OperationFeedbackKind
    let action: String?
    let trigger: FeedbackTrigger?
    let timestamp: Date
    let displayDuration: TimeInterval

    init(
        id: UUID = UUID(),
        message: String,
        kind: OperationFeedbackKind = .info,
        action: String? = nil,
        trigger: FeedbackTrigger? = nil,
        timestamp: Date = Date(),
        displayDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.message = message
        self.kind = kind
        self.action = action
        self.trigger = trigger
        self.timestamp = timestamp
        self.displayDuration = displayDuration ?? kind.defaultDisplayDuration
    }
}

@MainActor
final class OperationFeedbackCenter: ObservableObject {
    @Published private(set) var currentFeedback: OperationFeedback?
    @Published private(set) var detailLevel: FeedbackDetailLevel

    private static let detailLevelDefaultsKey = "PDFWorkBench.FeedbackDetailLevel"

    private let userDefaults: UserDefaults
    private var dismissWorkItem: DispatchWorkItem?
    private var dismissDeadline: Date?
    private var remainingDisplayDuration: TimeInterval?
    private var isPaused = false

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        detailLevel = userDefaults.string(forKey: Self.detailLevelDefaultsKey)
            .flatMap(FeedbackDetailLevel.init(rawValue:))
            ?? .standard
    }

    func post(
        _ message: String,
        kind: OperationFeedbackKind = .info,
        action: String? = nil,
        trigger: FeedbackTrigger? = nil,
        displayDuration: TimeInterval? = nil
    ) {
        let feedback = OperationFeedback(
            message: message,
            kind: kind,
            action: action,
            trigger: trigger,
            displayDuration: displayDuration
        )

        dismissWorkItem?.cancel()
        currentFeedback = feedback
        remainingDisplayDuration = feedback.displayDuration
        isPaused = false
        scheduleDismiss(after: feedback.displayDuration)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        dismissDeadline = nil
        remainingDisplayDuration = nil
        isPaused = false
        currentFeedback = nil
    }

    func setPaused(_ shouldPause: Bool) {
        guard currentFeedback != nil, shouldPause != isPaused else {
            return
        }

        isPaused = shouldPause

        if shouldPause {
            if let dismissDeadline {
                remainingDisplayDuration = max(0.1, dismissDeadline.timeIntervalSinceNow)
            }
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            self.dismissDeadline = nil
        } else {
            scheduleDismiss(after: remainingDisplayDuration ?? 0.1)
        }
    }

    func setDetailLevel(_ detailLevel: FeedbackDetailLevel) {
        self.detailLevel = detailLevel
        userDefaults.set(detailLevel.rawValue, forKey: Self.detailLevelDefaultsKey)
    }

    private func scheduleDismiss(after duration: TimeInterval) {
        dismissWorkItem?.cancel()

        let safeDuration = max(0.1, duration)
        remainingDisplayDuration = safeDuration
        dismissDeadline = Date().addingTimeInterval(safeDuration)

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + safeDuration, execute: workItem)
    }
}
