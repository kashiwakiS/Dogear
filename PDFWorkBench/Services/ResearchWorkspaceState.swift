import Combine
import Foundation

/// Only presentation state belongs to a window; research content has its own store.
@MainActor
final class ResearchWorkspaceState: ObservableObject {
    private struct Saved: Codable {
        var sessionID: UUID?
        var wide = false
        var fraction = 0.5
        var focusesResearch = true
    }
    private let defaults: UserDefaults
    private let key: String
    @Published var sessionID: UUID? { didSet { save() } }
    @Published var wide: Bool { didSet { save() } }
    @Published var fraction: Double { didSet { save() } }
    @Published var focusesResearch: Bool { didSet { save() } }

    init(windowSessionID: UUID, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "PDFWorkBench.ResearchWorkspace.\(windowSessionID.uuidString)"
        let state = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
        sessionID = state.sessionID
        wide = state.wide
        fraction = min(0.75, max(0.25, state.fraction.isFinite ? state.fraction : 0.5))
        focusesResearch = state.focusesResearch
    }

    private func save() {
        let value = Saved(sessionID: sessionID, wide: wide, fraction: fraction, focusesResearch: focusesResearch)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
