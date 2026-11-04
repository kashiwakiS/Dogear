#if os(iOS)
import Combine
import Darwin
import SwiftUI
import UIKit

@main
enum DogearIPadEntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--run-ipad-diagnostics") { IPadDiagnosticsApp.main() }
        else { DogearIPadApp.main() }
    }
}

struct DogearIPadApp: App {
    @StateObject private var services = IPadApplicationServices()
    @StateObject private var windows = IPadNativeWindowPresentation()
    var body: some Scene {
        WindowGroup("Dogear", id: "workspace", for: UUID.self) { id in
            IPadSceneRoot(services: services, windows: windows, requestedID: id.wrappedValue)
        }
    }
}

/// Native scene retention and activation only. Domain state, drafts, document
/// ownership and save services remain in the retained workspace sessions.
@MainActor
private final class IPadNativeWindowPresentation: ObservableObject {
    private final class Window {
        let tabs: IPadWindowTabs
        weak var scene: UIWindowScene?
        init(tabs: IPadWindowTabs) { self.tabs = tabs }
    }
    @Published private(set) var windowsNeedingRecovery: [UUID] = []
    private var windows: [UUID: Window] = [:]
    private var openScene: ((UUID) -> Void)?
    let transfers = IPadWindowTabTransferRegistry.shared

    func connect(id: UUID, services: IPadApplicationServices,
                 open: @escaping (UUID) -> Void) -> IPadWindowTabs {
        openScene = open
        if let existing = windows[id] { return existing.tabs }
        let pending = transfers.pendingTicket(targetWindowID: id)
        let tabs = IPadWindowTabs(windowID: id, services: services, restore: pending == nil)
        let window = Window(tabs: tabs)
        windows[id] = window
        _ = transfers.register(tabs)
        tabs.onChange = { [weak self, weak tabs] in
            guard let self, let tabs else { return }
            self.bindActivationHandlers(tabs)
            _ = tabs.restoreSelectedTab()
        }
        if let pending,
           transfers.claim(token: pending.token, targetWindowID: id, into: tabs) == nil {
            transfers.cancel(token: pending.token, sourceWindowID: pending.sourceWindowID)
            _ = tabs.ensureBlankTab()
        }
        bindActivationHandlers(tabs)
        _ = tabs.restoreSelectedTab()
        return tabs
    }

    func attach(_ scene: UIWindowScene, to tabs: IPadWindowTabs) {
        guard let window = windows[tabs.windowID], window.tabs === tabs else { return }
        window.scene = scene
        tabs.sessions.forEach { $0.setPresented($0.id == tabs.selectedID) }
        windowsNeedingRecovery.removeAll { $0 == tabs.windowID }
        bindActivationHandlers(tabs)
    }

    func disconnect(_ tabs: IPadWindowTabs) {
        guard let window = windows[tabs.windowID], window.tabs === tabs else { return }
        window.scene = nil
        if let ticket = tabs.pendingTransfer {
            transfers.cancel(token: ticket.token, sourceWindowID: tabs.windowID)
        }
        if tabs.closeWindow() {
            transfers.unregister(windowID: tabs.windowID)
            tabs.onChange = nil
            windows.removeValue(forKey: tabs.windowID)
            windowsNeedingRecovery.removeAll { $0 == tabs.windowID }
        } else {
            // UIKit already disconnected the scene; retaining its live owners
            // gives failed draft checkpoints a concrete recovery window.
            tabs.sessions.forEach { $0.setPresented(false) }
            if !windowsNeedingRecovery.contains(tabs.windowID) { windowsNeedingRecovery.append(tabs.windowID) }
            bindActivationHandlers(tabs)
        }
    }

    func reopen(_ id: UUID) { openScene?(id) }

    func retryTransferRecovery(_ tabs: IPadWindowTabs) -> Bool {
        guard windows[tabs.windowID]?.tabs === tabs,
              tabs.retryTransferRecovery(), transfers.register(tabs) else { return false }
        bindActivationHandlers(tabs)
        return tabs.restoreSelectedTab()
    }

    private func bindActivationHandlers(_ tabs: IPadWindowTabs) {
        for session in tabs.sessions {
            session.activateScene = { [weak self, weak tabs, weak session] in
                guard let self, let tabs, let session, tabs.activateSession(session),
                      let window = self.windows[tabs.windowID], window.tabs === tabs else { return }
                if let scene = window.scene {
                    UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil)
                } else { self.openScene?(tabs.windowID) }
            }
        }
    }
}

private struct IPadSceneRoot: View {
    @ObservedObject var services: IPadApplicationServices
    @ObservedObject var windows: IPadNativeWindowPresentation
    let requestedID: UUID?
    @ObservedObject private var language: AppLanguageStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    init(services: IPadApplicationServices, windows: IPadNativeWindowPresentation, requestedID: UUID?) {
        self.services = services; self.windows = windows
        self.requestedID = requestedID; language = services.language
    }
    @SceneStorage("Dogear.SceneID") private var storedID = ""
    @State private var tabs: IPadWindowTabs?
    @State private var windowError: String?
    var body: some View {
        Group {
            if let tabs {
                IPadWindowWorkspace(tabs: tabs, services: services,
                    onNewWindow: newWindow, onMoveTab: { move($0, from: tabs) },
                    onRetryTransferRecovery: { _ = windows.retryTransferRecovery(tabs) })
                .background(IPadSceneConnector(onAttach: { windows.attach($0, to: tabs) },
                    onDisconnect: { windows.disconnect(tabs) }))
                .safeAreaInset(edge: .bottom) {
                    if !windows.windowsNeedingRecovery.isEmpty {
                        HStack {
                            Text("A closed window needs attention before its drafts can be saved.").font(.caption)
                            ForEach(windows.windowsNeedingRecovery, id: \.self) { id in
                                Button("Recover Window") { windows.reopen(id) }.frame(minHeight: 44)
                            }
                        }.padding(.horizontal, 8).background(.regularMaterial)
                    }
                }
            } else { ProgressView().task {
                guard tabs == nil else { return }
                let id = requestedID ?? UUID(uuidString: storedID) ?? UUID()
                storedID = id.uuidString
                let nativeOpen = openWindow
                let value = windows.connect(id: id, services: services,
                    open: { nativeOpen(id: "workspace", value: $0) })
                tabs = value
                if CommandLine.arguments.contains("--ipad-demo"), let session = value.selectedSession,
                   session.workspace.document.document == nil {
                    try? IPadDemoFixture.install(services: services, session: session)
                }
            } }
        }.environment(\.locale, language.locale)
        .onChange(of: scenePhase) { _, phase in if phase != .active { tabs?.flushReadingState() } }
        .alert("Window unavailable", isPresented: Binding(get: { windowError != nil },
            set: { if !$0 { windowError = nil } })) {
                Button("OK") { windowError = nil }
        } message: { Text(verbatim: windowError ?? "") }
    }

    private func newWindow() {
        guard UIApplication.shared.supportsMultipleScenes else {
            windowError = L10n.string("Multiple windows are unavailable in this environment."); return
        }
        openWindow(id: "workspace", value: UUID())
    }

    private func move(_ session: IPadWorkspaceSession, from tabs: IPadWindowTabs) {
        guard tabs.selectedSession === session, tabs.session(for: session.id) === session,
              session.acceptsUserActions else { return }
        guard UIApplication.shared.supportsMultipleScenes else {
            windowError = L10n.string("Multiple windows are unavailable in this environment."); return
        }
        let targetID = UUID()
        guard windows.transfers.stage(source: tabs, tabID: session.id, targetWindowID: targetID) != nil else {
            windowError = L10n.string("Finish saving or dismiss the current operation before moving this tab."); return
        }
        openWindow(id: "workspace", value: targetID)
    }
}

private struct IPadWindowWorkspace: View {
    @ObservedObject var tabs: IPadWindowTabs
    @ObservedObject var services: IPadApplicationServices
    let onNewWindow: () -> Void
    let onMoveTab: (IPadWorkspaceSession) -> Void
    let onRetryTransferRecovery: () -> Void
    @State private var libraryVisibility: NavigationSplitViewVisibility = .all
    var body: some View {
        VStack(spacing: 0) {
            IPadWindowTabStrip(tabs: tabs, onNewWindow: onNewWindow, onMoveTab: onMoveTab,
                onToggleLibrary: { libraryVisibility = libraryVisibility == .detailOnly ? .all : .detailOnly },
                isLibraryVisible: libraryVisibility != .detailOnly)
            Divider()
            ZStack {
                if tabs.requiresTransferRecovery {
                    VStack(spacing: 12) {
                        ContentUnavailableView("Window recovery needs attention", systemImage: "exclamationmark.triangle",
                            description: Text(verbatim: tabs.transferRecoveryError ?? ""))
                        Button("Retry recovery", action: onRetryTransferRecovery).frame(minHeight: 44)
                    }
                }
                ForEach(tabs.sessions, id: \.id) { session in
                    IPadWorkspaceView(services: services, library: services.library, session: session,
                        isPresentationActive: tabs.selectedID == session.id, libraryVisibility: $libraryVisibility)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(tabs.selectedID == session.id ? 1 : 0)
                        .allowsHitTesting(tabs.selectedID == session.id)
                        .accessibilityHidden(tabs.selectedID != session.id)
                        .zIndex(tabs.selectedID == session.id ? 1 : 0)
                }
            }.clipped()
        }
    }
}

/// Scene destruction releases editing leases; backgrounding keeps them so a
/// second scene cannot replace a still-live writer with stale disk contents.
private struct IPadSceneConnector: UIViewRepresentable {
    let onAttach: (UIWindowScene) -> Void
    let onDisconnect: () -> Void
    func makeUIView(context: Context) -> Probe { Probe(onAttach: onAttach, onDisconnect: onDisconnect) }
    func updateUIView(_ view: Probe, context: Context) {}
    final class Probe: UIView {
        let onAttach: (UIWindowScene) -> Void
        let onDisconnect: () -> Void
        private var observer: NSObjectProtocol?
        init(onAttach: @escaping (UIWindowScene) -> Void, onDisconnect: @escaping () -> Void) {
            self.onAttach = onAttach; self.onDisconnect = onDisconnect
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            onAttach(scene)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification,
                object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onDisconnect() }
            }
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

private struct IPadDiagnosticsApp: App {
    var body: some Scene { WindowGroup { IPadDiagnosticsView() } }
}
private struct IPadDiagnosticsView: View {
    @State private var started = false
    var body: some View {
        ProgressView("Checking Dogear iPad workflows…").task {
            guard !started else { return }; started = true
            let result = await IPadWorkflowDiagnostics.run()
            await PDFSaveQueue.shared.drain()
            let report: [String: Any] = ["checks": result.checks, "failures": result.failures,
                "platform": "iPad", "retrieval": "Scheme 1 BM25", "date": ISO8601DateFormatter().string(from: Date())]
            do {
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DiagnosticResults.json")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                print("Dogear iPad diagnostics: \(result.checks) checks, \(result.failures.count) failures")
                result.failures.forEach { print($0) }
                exit(result.failures.isEmpty ? 0 : 1)
            } catch { print("Diagnostic report failed: \(error)"); exit(2) }
        }
    }
}
#endif
