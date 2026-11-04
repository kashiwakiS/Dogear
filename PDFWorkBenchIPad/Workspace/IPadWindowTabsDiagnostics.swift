#if os(iOS)
import PDFKit
import SwiftUI
import UIKit

/// Presentation transitions use disposable, real Session/Store instances. A
/// successful model claim is not evidence that iPadOS opened a second scene.
@MainActor
enum IPadWindowTabsDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearWindowTabs-\(UUID())")
        let suite = "DogearWindowTabs.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return (1, ["The tab fixture could not isolate its defaults."])
        }
        var madeSessions: [IPadWorkspaceSession] = []
        defer {
            madeSessions.forEach { $0.close() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let originalURL = root.appendingPathComponent("Tab Original.pdf")
            let originalBytes = UIGraphicsPDFRenderer(bounds: .init(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
                for index in 0..<3 {
                    context.beginPage()
                    ("Real retained tab page \(index + 1)" as NSString).draw(at: .init(x: 60, y: 90),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
                }
            }
            try originalBytes.write(to: originalURL)
            let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("journal"), workingCopyStore: copies)
            let access = DocumentAccessCoordinator(saveQueue: queue)
            let library = LibraryStore(userDefaults: defaults,
                storage: try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json")),
                readingPositionSaveDelay: 3_600, workingCopyStore: copies)
            guard let file = library.upsertOpenedURLs([originalURL], refreshBookmark: false).first else {
                throw FixtureError.missingValue
            }
            let research = ResearchStore(rootURL: root.appendingPathComponent("research"))
            let commands = ResearchCommandService(store: research)
            let configuration = AIConfigurationStore(configurationURL: root.appendingPathComponent("ai.json"),
                legacyUserDefaults: defaults, secretStore: EmptySecrets())
            let trace = AIHighlightTraceRecorder(fileURL: root.appendingPathComponent("trace.jsonl"), defaults: defaults)
            let runtime = ResearchRuntime(storage: research, configuration: configuration,
                service: AIHighlightWorkflowService(traceRecorder: trace), traceRecorder: trace,
                commands: commands, retrievalSelection: .lexical)
            let services = IPadApplicationServices(library: library, research: research,
                configuration: configuration, language: AppLanguageStore(userDefaults: defaults),
                commands: commands, runtime: runtime, saveQueue: queue, observesApplication: false,
                beginBackgroundTask: { _ in .invalid }, endBackgroundTask: { _ in })
            let workspaceFactory: @MainActor (UUID, UUID, DocumentAccessCoordinator) -> IPadGroupWorkspace = { id, groupID, coordinator in
                let feedback = OperationFeedbackCenter(userDefaults: defaults)
                let directory = root.appendingPathComponent(id.uuidString)
                let store = PDFDocumentStore(feedbackCenter: feedback,
                    metadataStore: DocumentMetadataStore(stateURL: directory.appendingPathComponent("metadata.json")),
                    aiHighlightGroupStore: AIHighlightGroupStore(stateURL: directory.appendingPathComponent("groups.json")),
                    workingCopyStore: copies, saveQueue: queue, accessCoordinator: coordinator,
                    exportPresenter: IPadDocumentExportPresenter())
                let workspace = IPadGroupWorkspace(id: id, groupID: groupID, documentStore: store,
                    feedbackCenter: feedback, accessCoordinator: coordinator,
                    noteDraftDirectoryURL: root.appendingPathComponent("drafts"),
                    highlightDraftDirectoryURL: root.appendingPathComponent("highlight-drafts"))
                workspace.state.undoManager.groupsByEvent = false
                return workspace
            }
            let sessionFactory: @MainActor (UUID) -> IPadWorkspaceSession = { id in
                let session = IPadWorkspaceSession(id: id, services: services, userDefaults: defaults,
                    accessCoordinator: access, workspaceFactory: workspaceFactory)
                madeSessions.append(session)
                return session
            }
            let source = IPadWindowTabs(windowID: UUID(), services: services, defaults: defaults,
                sessionFactory: sessionFactory, activateExistingEditor: { access.activateExistingEditor(fileID: $0) })
            let registry = IPadWindowTabTransferRegistry()
            expect(registry.register(source), "The real source tab collection registers exactly once.")
            let duplicateWindow = IPadWindowTabs(windowID: source.windowID, services: services, defaults: defaults,
                restore: false, sessionFactory: sessionFactory)
            expect(!registry.register(duplicateWindow) && duplicateWindow.sessions.isEmpty,
                "A duplicate native window identifier cannot register a second tab collection or placeholder Store.")
            guard let first = source.selectedSession, first.open(file),
                  let document = first.workspace.document.document, let page = document.page(at: 1),
                  let savedNote = first.workspace.document.newFreeTextDraft(page: page,
                    bounds: .init(x: 80, y: 400, width: 180, height: 80)) else { throw FixtureError.missingValue }
            var savedValues = savedNote.values; savedValues.text = "Saved retained tab note"
            first.workspace.state.undoManager.beginUndoGrouping()
            let saved = first.workspace.document.saveFreeText(savedNote, values: savedValues)
            first.workspace.state.undoManager.endUndoGrouping()
            await queue.drain()
            for _ in 0..<50 where first.workspace.document.hasUnsavedChanges { try? await Task.sleep(for: .milliseconds(10)) }
            let copyURL = first.workspace.document.currentWorkingCopyURL
            let undo = first.workspace.state.undoManager
            first.workspace.document.recordCurrentPage(1)
            first.workspace.libraryBinding?.recordPage(1, in: document)
            expect(saved && !first.workspace.document.hasUnsavedChanges && undo.canUndo && copyURL != nil,
                "The first real tab has a durable standard PDF note and its actual document Undo.")
            guard let noteDraft = first.workspace.document.newFreeTextDraft(page: page,
                bounds: .init(x: 100, y: 220, width: 200, height: 90)) else { throw FixtureError.missingValue }
            let inline = IPadInlineNoteEditingSession(draft: noteDraft)
            inline.values.text = "Unsubmitted tab note 中文"
            first.workspace.inlineNoteSession = inline
            let researchID = research.createSession(title: "Tab composition")
            let editing = IPadResearchTextEditingCommands()
            let binding = Binding<String>(get: { research.session(id: researchID)?.draft.text ?? "" }, set: { value in
                guard var draft = research.session(id: researchID)?.draft else { return }
                draft.text = value; _ = research.saveDraft(draft, sessionID: researchID)
            })
            let native = IPadResearchNativeTextView(frame: .init(x: 0, y: 0, width: 400, height: 200))
            let editor = IPadResearchNativeTextEditor(text: binding, commands: editing, identity: researchID)
            let coordinator = IPadResearchNativeTextEditor.Coordinator(editor)
            coordinator.install(native)
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let previous = scene?.windows.first(where: \.isKeyWindow)
            let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: native.frame)
            let controller = UIViewController(); controller.view.addSubview(native)
            window.rootViewController = controller; window.makeKeyAndVisible()
            defer {
                IPadResearchNativeTextEditor.dismantleUIView(native, coordinator: coordinator)
                window.isHidden = true; previous?.makeKey()
            }
            native.becomeFirstResponder(); editing.activate(native)
            native.insertText("Question ")
            native.setMarkedText("中文候选", selectedRange: .init(location: 4, length: 0))
            let compositionToken = first.workspace.registerResearchPresentationPreparation {
                editing.commitMarkedTextAndEndEditing(identity: researchID)
            }
            expect(native.markedTextRange != nil, "Tab switching starts with actual native marked Chinese input.")
            guard let second = source.addTab() else { throw FixtureError.missingValue }
            expect(source.selectedSession === second && second.workspace.document.document == nil
                && first.workspace.document.document === document && first.workspace.state.undoManager === undo
                && undo.canUndo && first.workspace.inlineNoteSession === inline && !first.workspace.state.isActive,
                "A new blank tab retains the previous real document, Undo and unfinished inline draft.")
            expect(native.markedTextRange == nil && !native.isFirstResponder
                && binding.wrappedValue.contains("中文候选") && native.undoManager?.canUndo == true,
                "A real tab switch commits its captured native composition and retains local text history.")
            first.workspace.unregisterResearchPresentationPreparation(compositionToken)
            let rejected = second.workspace.registerResearchPresentationPreparation { false }
            expect(!source.select(tabID: first.id) && source.selectedSession === second
                && first.workspace.document.document === document && first.workspace.inlineNoteSession === inline,
                "A failed presentation preparation leaves the active tab and prior draft intact.")
            second.workspace.unregisterResearchPresentationPreparation(rejected)
            expect(source.select(tabID: first.id) && source.selectedSession === first && first.workspace.state.isActive
                && first.workspace.document.document === document && undo.canUndo,
                "Selecting the existing tab reuses its document and document Undo without reopening it.")
            let targetID = UUID()
            let countBeforeTarget = madeSessions.count
            guard let ticket = registry.stage(source: source, tabID: first.id, targetWindowID: targetID) else { throw FixtureError.missingValue }
            let destination = IPadWindowTabs(windowID: targetID, services: services, defaults: defaults, restore: false,
                sessionFactory: sessionFactory, activateExistingEditor: { access.activateExistingEditor(fileID: $0) })
            expect(destination.sessions.isEmpty && madeSessions.count == countBeforeTarget && source.selectedSession === first
                && first.workspace.document.document === document && first.workspace.state.isActive,
                "Staging a native-window destination creates no placeholder Store and leaves the source usable.")
            expect(registry.register(destination), "The empty destination collection registers before an exact claim.")
            expect(registry.claim(token: ticket.token, targetWindowID: UUID(), into: destination) == nil
                && source.session(for: first.id) === first && destination.sessions.isEmpty,
                "A wrong destination cannot claim or remove the source's live tab.")
            registry.cancel(token: ticket.token, sourceWindowID: UUID())
            expect(registry.pendingTicket(targetWindowID: targetID) == ticket,
                "A foreign source identifier cannot cancel the pending transfer.")
            let moved = registry.claim(token: ticket.token, targetWindowID: targetID, into: destination)
            expect(moved === first && destination.selectedSession === first && source.session(for: first.id) == nil
                && first.workspace.document.document === document && first.workspace.state.undoManager === undo
                && undo.canUndo && first.workspace.inlineNoteSession === inline
                && first.workspace.document.currentWorkingCopyURL?.libraryComparablePath == copyURL?.libraryComparablePath
                && access.owns(first.workspace.document, url: originalURL),
                "A successful claim moves the exact live Session, document, Undo, draft, copy identity and unique writer.")
            expect(destination.restoreSelectedTab() && first.workspace.document.document === document
                && registry.claim(token: ticket.token, targetWindowID: targetID, into: destination) == nil
                && source.closedTabIDs.isEmpty,
                "A moved tab is already restored, a consumed claim cannot replay, and a move is not recorded as closing.")
            let cancelledTarget = UUID()
            guard let cancelledTicket = registry.stage(source: destination, tabID: first.id, targetWindowID: cancelledTarget) else { throw FixtureError.missingValue }
            destination.cancelTransfer()
            let cancelledDestination = IPadWindowTabs(windowID: cancelledTarget, services: services, defaults: defaults,
                restore: false, sessionFactory: sessionFactory)
            expect(registry.register(cancelledDestination)
                && registry.claim(token: cancelledTicket.token, targetWindowID: cancelledTarget, into: cancelledDestination) == nil
                && destination.selectedSession === first && first.workspace.document.document === document
                && first.workspace.inlineNoteSession === inline,
                "Cancel Move preserves the source and rejects a late destination claim.")
            let cancelledBlank = cancelledDestination.ensureBlankTab()
            expect(cancelledBlank != nil && cancelledDestination.selectedSession === cancelledBlank
                && cancelledBlank?.workspace.document.document == nil,
                "A cancelled destination can become a usable blank window without reopening a source PDF.")
            expect(destination.closeConfirmed(tabID: first.id) && destination.closedTabIDs.contains(first.id)
                && destination.selectedSession?.id != first.id && destination.selectedSession?.workspace.document.document == nil,
                "Closing the last confirmed tab keeps a blank tab and a discoverable original identifier for draft recovery.")
            guard let reopened = destination.reopenClosedTab(tabID: first.id) else { throw FixtureError.missingValue }
            expect(reopened.id == first.id && reopened !== first && reopened.workspace.document.document != nil
                && reopened.workspace.inlineNoteSession?.values.text == inline.values.text
                && !destination.closedTabIDs.contains(first.id),
                "Reopening a closed tab rebuilds its original workspace identity and restores its unsubmitted sidecar draft.")
            expect(destination.closeConfirmed(tabID: reopened.id), "The recovered draft can close durably under its original tab identifier.")
            var ownerActivations = 0
            second.activateScene = { ownerActivations += 1 }
            guard second.open(file) else { throw FixtureError.missingValue }
            let creationCount = madeSessions.count
            expect(destination.reopenClosedTab(tabID: first.id) == nil && ownerActivations == 1
                && madeSessions.count == creationCount && destination.closedTabIDs.contains(first.id),
                "Reopening an already-owned PDF activates its existing tab without constructing another Session or losing closed history.")
            expect(source.closeConfirmed(tabID: second.id), "The existing owner closes through the same durable tab boundary.")
            guard let finalReopened = destination.reopenClosedTab(tabID: first.id) else { throw FixtureError.missingValue }
            let blocksWindowClose = finalReopened.workspace.registerResearchPresentationPreparation { false }
            expect(!destination.closeWindow() && destination.session(for: finalReopened.id) === finalReopened
                && finalReopened.acceptsUserActions && finalReopened.workspace.document.document != nil
                && finalReopened.workspace.inlineNoteSession?.values.text == inline.values.text,
                "A failed window preparation keeps every real Session and its recoverable draft for the app-scope owner.")
            finalReopened.workspace.unregisterResearchPresentationPreparation(blocksWindowClose)
            try exerciseIdentifierRepair(defaults: defaults, services: services, sessionFactory: sessionFactory,
                createdCount: { madeSessions.count }, check: expect)
            expect(try Data(contentsOf: originalURL) == originalBytes,
                "Tab switches, claims, cancellation and closed-tab recovery never overwrite the original PDF.")
            await queue.drain()
        } catch { expect(false, "The real tab fixture could not complete: \(error.localizedDescription)") }
        for highlights in [true, false] {
            do {
                try await exerciseFailedTargetNavigation(root: root.appendingPathComponent(highlights ? "highlight-target" : "inline-target"),
                    highlights: highlights, check: expect)
            } catch {
                expect(false, "Hidden \(highlights ? "Highlight" : "inline") target fixture failed: \(error.localizedDescription)")
            }
        }
        return (checks, failures)
    }

    /// Actual directory faults occur only after the target is retained off
    /// screen. UIKit marked text verifies the visible source's preparation;
    /// neither a tab model claim nor this synthetic composition is native UI
    /// delivery, hardware IME or an actual second-window acceptance result.
    private static func exerciseFailedTargetNavigation(root: URL, highlights: Bool, check: (Bool, String) -> Void) async throws {
        let suite = "DogearFailedTabTarget.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw FixtureError.missingValue }
        var made: [IPadWorkspaceSession] = []
        defer { made.forEach { $0.close() }; defaults.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = ["A", "B"].map { root.appendingPathComponent("\($0).pdf") }
        let originalBytes = try urls.enumerated().map { index, url -> Data in
            let data = try faultFixturePDF("Native tab fault \(index)")
            try data.write(to: url); return data
        }
        let copies = try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies"))
        let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("journal"), workingCopyStore: copies)
        let access = DocumentAccessCoordinator(saveQueue: queue)
        let library = LibraryStore(userDefaults: defaults,
            storage: try LibraryJSONStore(stateURL: root.appendingPathComponent("library.json")),
            readingPositionSaveDelay: 3_600, workingCopyStore: copies)
        let files = library.upsertOpenedURLs(urls, refreshBookmark: false)
        guard files.count == 2 else { throw FixtureError.missingValue }
        let research = ResearchStore(rootURL: root.appendingPathComponent("research"))
        let commands = ResearchCommandService(store: research)
        let configuration = AIConfigurationStore(configurationURL: root.appendingPathComponent("ai.json"),
            legacyUserDefaults: defaults, secretStore: EmptySecrets())
        let trace = AIHighlightTraceRecorder(fileURL: root.appendingPathComponent("trace.jsonl"), defaults: defaults)
        let runtime = ResearchRuntime(storage: research, configuration: configuration,
            service: AIHighlightWorkflowService(traceRecorder: trace), traceRecorder: trace,
            commands: commands, retrievalSelection: .lexical)
        let services = IPadApplicationServices(library: library, research: research,
            configuration: configuration, language: AppLanguageStore(userDefaults: defaults),
            commands: commands, runtime: runtime, saveQueue: queue, observesApplication: false,
            beginBackgroundTask: { _ in .invalid }, endBackgroundTask: { _ in })
        func directory(_ workspace: IPadGroupWorkspace) -> URL {
            root.appendingPathComponent(workspace.state.id.uuidString).appendingPathComponent(highlights ? "highlight-drafts" : "inline-drafts")
        }
        let workspaceFactory: @MainActor (UUID, UUID, DocumentAccessCoordinator) -> IPadGroupWorkspace = { id, groupID, coordinator in
            let feedback = OperationFeedbackCenter(userDefaults: defaults)
            let base = root.appendingPathComponent(id.uuidString)
            let store = PDFDocumentStore(feedbackCenter: feedback,
                metadataStore: DocumentMetadataStore(stateURL: base.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: base.appendingPathComponent("groups.json")),
                workingCopyStore: copies, saveQueue: queue, accessCoordinator: coordinator,
                exportPresenter: IPadDocumentExportPresenter())
            let workspace = IPadGroupWorkspace(id: id, groupID: groupID, documentStore: store,
                feedbackCenter: feedback, accessCoordinator: coordinator,
                noteDraftDirectoryURL: base.appendingPathComponent("inline-drafts"),
                highlightDraftDirectoryURL: base.appendingPathComponent("highlight-drafts"))
            workspace.state.undoManager.groupsByEvent = false
            return workspace
        }
        let sessionFactory: @MainActor (UUID) -> IPadWorkspaceSession = { id in
            let session = IPadWorkspaceSession(id: id, services: services, userDefaults: defaults,
                accessCoordinator: access, workspaceFactory: workspaceFactory)
            made.append(session); return session
        }
        let source = IPadWindowTabs(windowID: UUID(), services: services, defaults: defaults,
            restore: false, sessionFactory: sessionFactory)
        let registry = IPadWindowTabTransferRegistry()
        check(registry.register(source), "The hidden-target fixture registers its actual source collection.")
        guard let a = source.ensureBlankTab(), a.open(files[0]),
              let aDocument = a.workspace.document.document,
              let savedDraft = a.workspace.document.newFreeTextDraft(page: aDocument.page(at: 1),
                bounds: .init(x: 90, y: 320, width: 200, height: 90)) else { throw FixtureError.missingValue }
        let held = a.workspace, aStore = held.document, documentUndo = held.state.undoManager
        var savedValues = savedDraft.values; savedValues.text = "Actual document Undo before tab fault"
        documentUndo.beginUndoGrouping(); let saved = aStore.saveFreeText(savedDraft, values: savedValues); documentUndo.endUndoGrouping()
        await queue.drain(); for _ in 0..<8 { await Task.yield() }
        check(saved && !aStore.hasUnsavedChanges && documentUndo.canUndo,
            "The target starts with a real persisted annotation and shared document Undo history.")
        let aHighlight: IPadHighlightEditingSession?, aInline: IPadInlineNoteEditingSession?
        if highlights {
            guard let item = aStore.annotations.first(where: { $0.kind == .highlight }),
                  let draft = aStore.highlightEditDraft(for: item) else { throw FixtureError.missingValue }
            let editor = IPadHighlightEditingSession(draft: draft); aHighlight = editor; aInline = nil
            held.highlightEditingSession = editor; editor.commentBinding.wrappedValue = "隐藏 A 保留中文批注"
        } else {
            guard let draft = aStore.newFreeTextDraft() else { throw FixtureError.missingValue }
            let editor = IPadInlineNoteEditingSession(draft: draft); aInline = editor; aHighlight = nil
            held.inlineNoteSession = editor; editor.textBinding.wrappedValue = "隐藏 A 保留中文便笺"
        }
        let aDraftID = aHighlight?.id ?? aInline!.id
        let aText = aHighlight?.values.comment ?? aInline!.values.text
        let aDirectory = directory(held)
        let aURL = try onlyRecord(in: aDirectory)
        let targetID = UUID()
        guard let ticket = registry.stage(source: source, tabID: a.id, targetWindowID: targetID) else { throw FixtureError.missingValue }
        let destination = IPadWindowTabs(windowID: targetID, services: services, defaults: defaults,
            restore: false, sessionFactory: sessionFactory)
        check(registry.register(destination) && destination.sessions.isEmpty && source.selectedSession === a
            && source.pendingTransfer == ticket,
            "A healthy selected target first stages a real ticket and registers an empty destination.")
        guard let b = source.addTab(), b.open(files[1]) else { throw FixtureError.missingValue }
        let bWorkspace = b.workspace
        let bHighlight: IPadHighlightEditingSession?, bInline: IPadInlineNoteEditingSession?
        if highlights {
            guard let item = bWorkspace.document.annotations.first(where: { $0.kind == .highlight }),
                  let draft = bWorkspace.document.highlightEditDraft(for: item) else { throw FixtureError.missingValue }
            let editor = IPadHighlightEditingSession(draft: draft); bHighlight = editor; bInline = nil
            bWorkspace.highlightEditingSession = editor; editor.commentBinding.wrappedValue = "Visible B comment "
        } else {
            guard let draft = bWorkspace.document.newFreeTextDraft() else { throw FixtureError.missingValue }
            let editor = IPadInlineNoteEditingSession(draft: draft); bInline = editor; bHighlight = nil
            bWorkspace.inlineNoteSession = editor; editor.textBinding.wrappedValue = "Visible B note "
        }
        let bDraftID = bHighlight?.id ?? bInline!.id
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123_456_789)], ofItemAtPath: aURL.path)
        guard let healthyTargetModifiedAt = try FileManager.default.attributesOfItem(atPath: aURL.path)[.modificationDate] as? Date else {
            throw FixtureError.missingValue
        }
        let healthyTargetBytes = try Data(contentsOf: aURL)
        let revealedHealthy = source.select(tabID: a.id)
        let healthyTargetBytesAfter = try Data(contentsOf: aURL)
        guard let healthyTargetModifiedAtAfter = try FileManager.default.attributesOfItem(atPath: aURL.path)[.modificationDate] as? Date else {
            throw FixtureError.missingValue
        }
        check(revealedHealthy && source.selectedSession === a && a.workspace === held
            && healthyTargetBytesAfter == healthyTargetBytes && healthyTargetModifiedAtAfter == healthyTargetModifiedAt,
            "Revealing a healthy hidden editor does not require or rewrite its sidecar checkpoint.")
        check(source.select(tabID: b.id) && source.selectedSession === b && b.workspace === bWorkspace,
            "Returning to B leaves the exact healthy retained A owner through its normal checkpoint.")
        let textCommands = bHighlight?.textCommands ?? bInline!.textCommands
        let binding = bHighlight?.commentBinding ?? bInline!.textBinding
        let native = IPadResearchNativeTextView(frame: .init(x: 0, y: 0, width: 420, height: 220))
        let coordinator = IPadResearchNativeTextEditor.Coordinator(.init(text: binding, commands: textCommands, identity: bDraftID))
        coordinator.install(native)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousWindow = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: native.frame)
        let controller = UIViewController(); controller.view.addSubview(native)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer {
            IPadResearchNativeTextEditor.dismantleUIView(native, coordinator: coordinator)
            window.isHidden = true; previousWindow?.makeKey()
        }
        _ = native.becomeFirstResponder(); textCommands.activate(native)
        native.selectedRange = .init(location: (binding.wrappedValue as NSString).length, length: 0)
        native.setMarkedText("源组中文", selectedRange: .init(location: 4, length: 0))
        let aBackup = root.appendingPathComponent("a-drafts-backup")
        let aRecordBytes = try Data(contentsOf: aURL)
        try FileManager.default.moveItem(at: aDirectory, to: aBackup)
        try Data("A directory fault".utf8).write(to: aDirectory)
        a.flushReadingState()
        check(source.selectedSession === b && !held.state.isActive && draftError(in: held, highlights: highlights) != nil
            && (highlights ? held.highlightEditingSession === aHighlight : held.inlineNoteSession === aInline),
            "The hidden target's actual lifecycle flush reports its real directory failure while retaining its editor.")
        let bDirectory = directory(bWorkspace), bBackup = root.appendingPathComponent("b-drafts-backup")
        try FileManager.default.moveItem(at: bDirectory, to: bBackup)
        try Data("B directory fault".utf8).write(to: bDirectory)
        b.flushReadingState()
        check(!source.select(tabID: a.id) && source.selectedSession === b && bWorkspace.state.isActive
            && draftError(in: bWorkspace, highlights: highlights) != nil,
            "A visible source whose real checkpoint fails cannot leave even to reveal another failed target.")
        try FileManager.default.removeItem(at: bDirectory); try FileManager.default.moveItem(at: bBackup, to: bDirectory)
        b.flushReadingState()
        check(draftError(in: bWorkspace, highlights: highlights) == nil
            && (highlights ? bHighlight?.error == nil : bInline?.error == nil)
            && (highlights ? bWorkspace.highlightEditingSession === bHighlight : bWorkspace.inlineNoteSession === bInline),
            "Repairing B checkpoints its same retained editor before another navigation attempt.")
        check(!source.closeConfirmed(tabID: a.id) && source.selectedSession === b && source.session(for: a.id) === a,
            "Closing a hidden failed target still requires its actual successful checkpoint.")
        _ = native.becomeFirstResponder(); textCommands.activate(native)
        native.selectedRange = .init(location: (binding.wrappedValue as NSString).length, length: 0)
        native.setMarkedText("用于转移", selectedRange: .init(location: 4, length: 0))
        let beforeClaim = native.text ?? ""
        check(native.markedTextRange != nil && registry.claim(token: ticket.token, targetWindowID: targetID, into: destination) == nil
            && source.selectedSession === b && source.session(for: a.id) === a && destination.sessions.isEmpty
            && source.pendingTransfer == ticket && aStore.document === aDocument && access.owns(aStore, url: urls[0]),
            "A genuinely staged hidden target cannot transfer while its own sidecar checkpoint fails.")
        let claimRecordMatches = try recordMatches(onlyRecord(in: bDirectory), draftID: bDraftID, text: beforeClaim, highlights: highlights)
        check(native.markedTextRange == nil && !native.isFirstResponder && binding.wrappedValue == beforeClaim
            && draftError(in: bWorkspace, highlights: highlights) == nil
            && (highlights ? bHighlight?.error == nil : bInline?.error == nil) && claimRecordMatches,
            "The refused transfer really prepares healthy source B and checkpoints its captured native composition.")
        registry.cancel(token: ticket.token, sourceWindowID: source.windowID)
        _ = native.becomeFirstResponder(); textCommands.activate(native)
        native.selectedRange = .init(location: (binding.wrappedValue as NSString).length, length: 0)
        native.setMarkedText("用于切换", selectedRange: .init(location: 4, length: 0))
        let beforeSelection = native.text ?? ""
        let selected = source.select(tabID: a.id)
        check(selected && source.selectedSession === a && a.workspace === held && held.document === aStore
            && aStore.document === aDocument && held.state.undoManager === documentUndo && documentUndo.canUndo
            && access.owns(aStore, url: urls[0]) && held.state.isActive && !bWorkspace.state.isActive
            && (highlights ? held.highlightEditingSession === aHighlight : held.inlineNoteSession === aInline)
            && draftError(in: held, highlights: highlights) != nil,
            "Selecting the failed hidden target reveals the exact Session/workspace/Store/PDF/editor/Undo/writer and its real Retry error.")
        let selectionRecordMatches = try recordMatches(onlyRecord(in: bDirectory), draftID: bDraftID, text: beforeSelection, highlights: highlights)
        let preservedARecord = try Data(contentsOf: aBackup.appendingPathComponent(aURL.lastPathComponent)) == aRecordBytes
        check(native.markedTextRange == nil && !native.isFirstResponder && binding.wrappedValue == beforeSelection
            && selectionRecordMatches && preservedARecord,
            "Successful target navigation first durably prepares B and preserves A's exact previously written payload.")
        check(!source.closeWindow() && source.selectedSession === a && source.session(for: a.id) === a
            && registry.stage(source: source, tabID: a.id, targetWindowID: UUID()) == nil,
            "Revealing a failed target does not relax normal window close or selected-tab transfer preparation.")
        try FileManager.default.removeItem(at: aDirectory); try FileManager.default.moveItem(at: aBackup, to: aDirectory)
        if highlights { held.restoreHighlightIfNeeded() } else { held.restoreInlineNoteIfNeeded() }
        let retryRecordMatches = try recordMatches(onlyRecord(in: aDirectory), draftID: aDraftID, text: aText, highlights: highlights)
        check(draftError(in: held, highlights: highlights) == nil
            && (highlights ? aHighlight?.error == nil : aInline?.error == nil) && retryRecordMatches
            && (highlights ? held.highlightEditingSession === aHighlight && aHighlight?.completion == nil
                : held.inlineNoteSession === aInline && aInline?.completion == nil),
            "The actual Retry entry point writes the same draft UUID and Chinese payload without replacement or silent discard.")
        let currentABytes = try Data(contentsOf: urls[0]), currentBBytes = try Data(contentsOf: urls[1])
        let originalsUnchanged = currentABytes == originalBytes[0] && currentBBytes == originalBytes[1]
        check(aStore.document === aDocument && documentUndo.canUndo && !aStore.hasUnsavedChanges
            && (highlights ? aHighlight?.draft.annotation.contents == aHighlight?.draft.comment : aInline?.draft.annotation.page == nil)
            && originalsUnchanged,
            "Fault navigation and Retry preserve native document history, detached values and both original PDFs.")
        await queue.drain()
    }

    private static func draftError(in workspace: IPadGroupWorkspace, highlights: Bool) -> String? {
        highlights ? workspace.highlightDraftRecovery.lastError : workspace.noteDraftRecovery.lastError
    }
    private static func onlyRecord(in directory: URL) throws -> URL {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard urls.count == 1, let url = urls.first else { throw FixtureError.missingValue }; return url
    }
    private static func recordMatches(_ url: URL, draftID: UUID, text: String, highlights: Bool) throws -> Bool {
        let data = try Data(contentsOf: url)
        if highlights {
            let record = try JSONDecoder().decode(IPadHighlightDraftRecovery.Record.self, from: data)
            return record.draftID == draftID && record.values.comment == text && !record.pendingSave && !record.completed
        }
        let record = try JSONDecoder().decode(IPadInlineNoteDraftRecovery.Record.self, from: data)
        return record.draftID == draftID && record.values.text == text && !record.pendingSave && !record.completed
    }
    private static func faultFixturePDF(_ phrase: String) throws -> Data {
        let data = UIGraphicsPDFRenderer(bounds: .init(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            (phrase as NSString).draw(at: .init(x: 70, y: 110), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            context.beginPage()
            ("Separate annotation page" as NSString).draw(at: .init(x: 90, y: 150), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        guard let document = PDFDocument(data: data), let selection = document.findString(phrase, withOptions: []).first,
              let prepared = PDFTextSelectionService.prepareHighlights(from: selection, in: document).first else { throw FixtureError.missingValue }
        prepared.annotation.contents = "Original highlight comment"; prepared.page.addAnnotation(prepared.annotation)
        guard let result = document.dataRepresentation() else { throw FixtureError.missingValue }; return result
    }

    /// Simulates each process-stop boundary by writing real identifier records.
    /// Repair must not allocate a Store or infer missing PDF/document state.
    private static func exerciseIdentifierRepair(defaults: UserDefaults, services: IPadApplicationServices,
        sessionFactory: @escaping @MainActor (UUID) -> IPadWorkspaceSession, createdCount: () -> Int,
        check: (Bool, String) -> Void) throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let sourceID = UUID(), targetID = UUID(), movedID = UUID(), replacementID = UUID()
        let sourceHistory = UUID(), targetHistory = UUID()
        let key = "Dogear.iPad.WindowTabTransferIntent"
        func recordKey(_ id: UUID) -> String { "Dogear.iPad.WindowTabs.\(id.uuidString)" }
        let intent = TransferRecord(token: UUID(), sourceWindowID: sourceID, targetWindowID: targetID,
            tabID: movedID, sourceReplacementID: replacementID)
        let intentData = try encoder.encode(intent)
        let initialCount = createdCount()
        for phase in 0..<3 {
            let source = TabRecord(windowID: sourceID, tabIDs: phase == 0 ? [movedID] : [replacementID],
                selectedID: phase == 0 ? movedID : replacementID, closedTabIDs: [sourceHistory])
            defaults.set(try encoder.encode(source), forKey: recordKey(sourceID))
            if phase < 2 { defaults.removeObject(forKey: recordKey(targetID)) }
            else {
                defaults.set(try encoder.encode(TabRecord(windowID: targetID, tabIDs: [movedID], selectedID: movedID,
                    closedTabIDs: [targetHistory])), forKey: recordKey(targetID))
            }
            defaults.set(intentData, forKey: key)
            let repaired = IPadWindowTabs.repairPendingTransfer(defaults: defaults)
            let sourceData = defaults.data(forKey: recordKey(sourceID)) ?? Data()
            let targetData = defaults.data(forKey: recordKey(targetID)) ?? Data()
            let repairedSource = try decoder.decode(TabRecord.self, from: sourceData)
            let repairedTarget = try decoder.decode(TabRecord.self, from: targetData)
            check(repaired && repairedSource.tabIDs == [replacementID] && repairedSource.selectedID == replacementID
                && repairedTarget.tabIDs == [movedID] && repairedTarget.selectedID == movedID
                && repairedSource.closedTabIDs == [sourceHistory]
                && (phase < 2 || repairedTarget.closedTabIDs == [targetHistory])
                && defaults.data(forKey: key) == nil && createdCount() == initialCount,
                "Interrupted move phase \(phase) repairs one destination owner and the captured source replacement using identifiers only.")
        }
        let foreign = TabRecord(windowID: targetID, tabIDs: [UUID()], selectedID: nil, closedTabIDs: [targetHistory])
        let foreignData = try encoder.encode(foreign)
        defaults.set(foreignData, forKey: recordKey(targetID)); defaults.set(intentData, forKey: key)
        let sourceBefore = defaults.data(forKey: recordKey(sourceID))
        check(!IPadWindowTabs.repairPendingTransfer(defaults: defaults)
            && defaults.data(forKey: recordKey(sourceID)) == sourceBefore
            && defaults.data(forKey: recordKey(targetID)) == foreignData && defaults.data(forKey: key) == intentData,
            "A transfer recovery refuses to replace an unrelated target tab and preserves both records and its intent.")
        let blocked = IPadWindowTabs(windowID: sourceID, services: services, defaults: defaults,
            sessionFactory: sessionFactory)
        check(blocked.requiresTransferRecovery && blocked.transferRecoveryError != nil && blocked.sessions.isEmpty
            && !blocked.acceptsUserActions && blocked.addTab() == nil && blocked.ensureBlankTab() == nil
            && !blocked.closeWindow() && defaults.data(forKey: recordKey(sourceID)) == sourceBefore
            && defaults.data(forKey: key) == intentData && createdCount() == initialCount,
            "Unresolved identifier recovery allocates no Session and blocks blank-tab writes that would replace prior tab metadata.")
        defaults.removeObject(forKey: key)
        check(blocked.retryTransferRecovery() && !blocked.requiresTransferRecovery && blocked.acceptsUserActions
            && blocked.selectedSession?.id == replacementID && createdCount() == initialCount + 1,
            "An explicit successful retry reconstructs the recorded tab identity once recovery is resolved.")
        let corruptSource = Data("invalid tab record".utf8)
        defaults.set(corruptSource, forKey: recordKey(sourceID))
        defaults.removeObject(forKey: recordKey(targetID)); defaults.set(intentData, forKey: key)
        check(!IPadWindowTabs.repairPendingTransfer(defaults: defaults)
            && defaults.data(forKey: recordKey(sourceID)) == corruptSource
            && defaults.data(forKey: recordKey(targetID)) == nil && defaults.data(forKey: key) == intentData,
            "Corrupt source metadata is preserved for recovery instead of being treated as an empty source window.")
        defaults.removeObject(forKey: key)
    }

    private struct TabRecord: Codable {
        let windowID: UUID
        let tabIDs: [UUID]
        let selectedID: UUID?
        let closedTabIDs: [UUID]?
    }
    private struct TransferRecord: Codable {
        let token: UUID
        let sourceWindowID: UUID
        let targetWindowID: UUID
        let tabID: UUID
        let sourceReplacementID: UUID?
    }

    private enum FixtureError: Error { case missingValue }
    private final class EmptySecrets: AISecretStoring {
        func readSecret(profileID: UUID) -> String? { nil }
        func saveSecret(_ secret: String, profileID: UUID, configurationName: String) {}
        func removeSecret(profileID: UUID) {}
        func updateLabel(profileID: UUID, configurationName: String) {}
    }
}
#endif
