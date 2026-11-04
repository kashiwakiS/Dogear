import Foundation

@MainActor
enum ResearchCommandDiagnostics {
    static func run() async -> AIHighlightFoundationDiagnosticReport {
        var checks = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ResearchCommandDiagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ResearchStore(rootURL: directory)
        let service = ResearchCommandService(store: store)
        let viewID = UUID()
        let sessionID = store.createSession(title: "Command diagnostics")
        let mainID = UUID(), referenceID = UUID(), otherID = UUID(), groupID = UUID()
        let sources = [ResearchSourceSnapshot(fileID: mainID, displayName: "Main", fingerprint: "main-v1"),
                       ResearchSourceSnapshot(fileID: referenceID, displayName: "Reference", fingerprint: "reference-v1")]
        let original = ResearchWorkspaceViewState(mainFileID: mainID, pageIndex: 2, zoomPercent: 125, wideAI: false,
            visibleGroupIDs: [], pageOffsetX: 12, pageOffsetY: 34, zoomMode: "custom")
        var state = original
        var shown: [(UUID, Int)] = []
        var restored = 0
        let handlers = ResearchCommandHandlers(snapshot: { state }, showSource: { fileID, page in
            guard page < 10 else { throw ResearchCommandError.invalidArguments }
            shown.append((fileID, page))
            if fileID == mainID { state.pageIndex = page }
            else { state.referenceFileID = fileID; state.referencePageIndex = page }
        }, setZoom: { zoom in
            switch zoom {
            case .fit, .fitWidth: state.zoomMode = "fit"; state.zoomPercent = 100
            case .percent(let value): state.zoomMode = "custom"; state.zoomPercent = value
            }
        }, setWideAI: { state.wideAI = $0 }, setGroupVisible: { fileID, id, visible in
            guard fileID == mainID, id == groupID else { throw ResearchCommandError.invalidArguments }
            state.visibleGroupIDs = visible ? [id] : []
        }, restore: { state = $0; restored += 1 })
        service.register(viewID: viewID, handlers: handlers)
        func executor(_ question: String = "Explain the evidence", target: UUID? = nil) -> ResearchCommandExecutor {
            service.makeExecutor(requestID: UUID(), sessionID: sessionID, viewID: viewID, allowedSources: sources,
                question: question, targetNoteID: target)
        }
        func invoke(_ executor: ResearchCommandExecutor, _ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
            let input = AIToolInvocation(callID: UUID().uuidString, name: name,
                arguments: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
            let result = try await executor.execute(input)
            return (try JSONSerialization.jsonObject(with: result.output) as? [String: Any]) ?? [:]
        }
        func succeeded(_ output: [String: Any]) -> Bool { output["ok"] as? Bool == true }
        do {
            var validatingHandlers = handlers
            validatingHandlers.validateSource = { _ in throw DocumentAccessError.sourceChanged }
            service.register(viewID: viewID, handlers: validatingHandlers)
            let changedSource = executor()
            check(!succeeded(try await invoke(changedSource, "show_source", ["file_id": mainID.uuidString, "page_number": 1])) && shown.isEmpty,
                  "A changed source was navigated before version validation.")
            service.register(viewID: viewID, handlers: handlers)
            let reading = executor()
            check(Set(reading.definitions.map(\.name)) == ["read_research_workspace", "show_source", "set_research_view", "set_highlight_group_visibility"],
                  "An ordinary question exposed note creation or unregistered operations.")
            for definition in reading.definitions {
                let schema = try JSONSerialization.jsonObject(with: definition.strictInputSchema) as? [String: Any]
                check(schema?["additionalProperties"] as? Bool == false, "A research command schema permitted unknown properties.")
                let properties = schema?["properties"] as? [String: Any] ?? [:]
                check(Set(schema?["required"] as? [String] ?? []) == Set(properties.keys), "A strict command schema left an optional key implicit.")
            }
            check(!succeeded(try await invoke(reading, "create_research_note", ["title": "Unrequested"])), "A plain question authorized a note through model intent.")
            check(!succeeded(try await invoke(reading, "delete_file", ["file_id": mainID.uuidString])), "An unregistered destructive tool was accepted.")
            check(!succeeded(try await invoke(reading, "show_source", ["file_id": otherID.uuidString, "page_number": 1])), "A view command opened a source outside the request.")
            check(shown.isEmpty, "A rejected source command reached the native handler.")
            check(!succeeded(try await invoke(reading, "show_source", ["file_id": mainID.uuidString, "page_number": true])), "A JSON boolean was accepted as a page number.")
            check(!succeeded(try await invoke(reading, "show_source", ["file_id": mainID.uuidString, "page_number": 1.5])), "A fractional page number was accepted.")
            check(!succeeded(try await invoke(reading, "read_research_workspace", ["path": "/private"])), "Unknown workspace-read arguments were accepted.")
            check(succeeded(try await invoke(reading, "show_source", ["file_id": referenceID.uuidString, "page_number": 4])), "An allowed reference could not be shown.")
            check(shown.last?.1 == 3 && state.mainFileID == mainID, "A reference command used the wrong page or replaced the main editor.")
            check(service.hasPreviousView(viewID: viewID), "The first AI view command did not capture a return position.")
            check(succeeded(try await invoke(reading, "set_research_view", ["wide_ai": true, "zoom": "percent", "zoom_percent": 175])), "A valid presentation command failed.")
            check(state.wideAI && state.zoomPercent == 175, "The presentation handler did not receive the requested values.")
            check(!succeeded(try await invoke(reading, "set_research_view", ["wide_ai": NSNull(), "zoom": "percent", "zoom_percent": 801])), "Out-of-range zoom was accepted.")
            check(!succeeded(try await invoke(reading, "set_highlight_group_visibility", ["file_id": referenceID.uuidString, "group_id": groupID.uuidString, "visible": true])), "An AI visibility command targeted a reference PDF.")
            check(succeeded(try await invoke(reading, "set_highlight_group_visibility", ["file_id": mainID.uuidString, "group_id": groupID.uuidString, "visible": true])), "An allowed main-PDF visibility command failed.")
            service.userDidInteract(viewID: viewID)
            let beforeTakeover = shown.count
            check(!succeeded(try await invoke(reading, "show_source", ["file_id": mainID.uuidString, "page_number": 1])), "AI navigation continued after user takeover.")
            check(!succeeded(try await invoke(reading, "set_research_view", ["wide_ai": false, "zoom": "fit", "zoom_percent": NSNull()])), "AI layout changes continued after user takeover.")
            check(shown.count == beforeTakeover, "Rejected post-takeover navigation reached the handler.")
            check(succeeded(try await invoke(reading, "read_research_workspace")), "User takeover unnecessarily disabled read-only workspace state.")
            try service.returnToPreviousView(viewID: viewID)
            check(state == original && restored == 1, "Return-to-view did not restore page, offset, zoom, panel and groups together.")
            check(!service.hasPreviousView(viewID: viewID), "A consumed return position remained active.")

            let preparing = executor()
            service.userDidInteract(viewID: viewID)
            var preparedSources = sources
            preparedSources[0].fingerprint = "main-prepared"
            try service.prepareSources(requestID: preparing.requestID, sources: preparedSources)
            check(!succeeded(try await invoke(preparing, "show_source", ["file_id": mainID.uuidString, "page_number": 1])),
                  "Source preparation renewed navigation after a Send-time user takeover.")
            check(succeeded(try await invoke(preparing, "read_research_workspace")),
                  "Source preparation disabled a read command after user takeover.")
            do {
                try service.prepareSources(requestID: preparing.requestID,
                    sources: [ResearchSourceSnapshot(fileID: otherID, displayName: "Outside", fingerprint: "v1")])
                check(false, "Source preparation expanded the Send-time source scope.")
            } catch ResearchCommandError.outsideSources { check(true, "") }
            let preparingView = executor()
            service.unregister(viewID: viewID)
            service.register(viewID: viewID, handlers: handlers)
            try service.prepareSources(requestID: preparingView.requestID, sources: preparedSources)
            check(!succeeded(try await invoke(preparingView, "show_source", ["file_id": mainID.uuidString, "page_number": 1])),
                  "Source preparation transferred a request to a replacement reader registration.")

            for question in ["请创建研究笔记", "请帮我创建一份研究笔记", "Please save the answer as a research note.", "将回答保存为笔记"] {
                check(ResearchCommandService.noteAuthorization(question: question).create, "A direct note instruction was not recognized: \(question)")
            }
            for question in ["Explain the word note", "Do not create a research note", "不要创建笔记", "The PDF says “请创建研究笔记”", "`create a note`", "> Please create a note", "'Please create a note'"] {
                let authorization = ResearchCommandService.noteAuthorization(question: question)
                check(!authorization.create && !authorization.revise, "Quoted, negative or descriptive text granted note authority: \(question)")
            }
            let creating = executor("Please create a research note")
            check(creating.definitions.contains { $0.name == "create_research_note" }, "Explicit note intent did not expose its tool.")
            check(!succeeded(try await invoke(creating, "create_research_note", ["title": "Title", "body": "Unverified invented body"])), "A model-supplied body was accepted by the note staging tool.")
            check(succeeded(try await invoke(creating, "create_research_note", ["title": "Accepted result"])), "A requested note could not be staged.")
            check(store.notes.isEmpty, "A staged note was saved before terminal acceptance.")
            service.userDidInteract(viewID: viewID)
            check(succeeded(try await invoke(creating, "create_research_note", ["title": "Accepted result"])), "Reader takeover incorrectly prevented note staging.")
            let evidence = ResearchEvidence(source: sources[0], anchor: ResearchPageAnchor(pageIndex: 0), excerpt: "Verified excerpt")
            let receipts = service.complete(requestID: creating.requestID, acceptedAnswer: "The accepted answer only.", evidence: [evidence])
            check(receipts.count == 1 && store.notes.count == 1, "An accepted staged note was not created exactly once.")
            check(store.notes.first?.body == "The accepted answer only." && store.notes.first?.provenance.first?.evidence == [evidence], "The saved note lost the accepted answer or evidence.")
            check(service.complete(requestID: creating.requestID, acceptedAnswer: "Late", evidence: [evidence]).isEmpty && store.notes.count == 1,
                  "A late repeated completion created a duplicate note.")

            let cancelled = executor("请创建笔记")
            _ = try await invoke(cancelled, "create_research_note", ["title": "Cancelled"])
            service.cancel(requestID: cancelled.requestID)
            do { _ = try await invoke(cancelled, "read_research_workspace"); check(false, "A cancelled request retained even read-command authority.") }
            catch { check(true, "") }
            check(service.complete(requestID: cancelled.requestID, acceptedAnswer: "Late accepted body", evidence: [evidence]).isEmpty && store.notes.count == 1,
                  "Cancellation allowed a late note write.")

            let noteID = store.notes[0].id
            let revision = executor("Please revise the selected research note", target: noteID)
            check(revision.definitions.contains { $0.name == "suggest_note_revision" }, "A selected note and direct revision request did not expose suggestions.")
            check(!succeeded(try await invoke(revision, "suggest_note_revision", ["note_id": otherID.uuidString])), "The model redirected revision to another note.")
            check(succeeded(try await invoke(revision, "suggest_note_revision")), "A selected note revision could not be staged.")
            _ = service.complete(requestID: revision.requestID, acceptedAnswer: "Suggested replacement.", evidence: [evidence])
            check(store.note(id: noteID)?.body == "The accepted answer only.", "An AI revision overwrote the user's note.")
            check(store.note(id: noteID)?.suggestions.first?.body == "Suggested replacement.", "The accepted revision was not saved as a suggestion.")
            let stale = executor("请修改研究笔记", target: noteID)
            _ = try await invoke(stale, "suggest_note_revision")
            if var note = store.note(id: noteID) { note.body = "User changed the note."; _ = store.updateNote(note) }
            try service.prepareSources(requestID: stale.requestID, sources: sources)
            _ = service.complete(requestID: stale.requestID, acceptedAnswer: "Outdated suggestion", evidence: [evidence])
            check(store.note(id: noteID)?.suggestions.count == 1 && store.note(id: noteID)?.body == "User changed the note.", "Source preparation renewed the Send-time note revision and allowed an outdated result.")

            let badEvidence = executor("请创建笔记")
            _ = try await invoke(badEvidence, "create_research_note", ["title": "Wrong source"])
            var wrong = evidence
            wrong.source?.fingerprint = "changed-after-request"
            _ = service.complete(requestID: badEvidence.requestID, acceptedAnswer: "Wrongly supported", evidence: [wrong])
            check(store.notes.count == 1, "Mismatched source-version evidence created a verified note.")

            let previous = executor()
            let newest = executor()
            check(!succeeded(try await invoke(previous, "show_source", ["file_id": mainID.uuidString, "page_number": 1])), "An older concurrent task retained navigation ownership.")
            check(succeeded(try await invoke(newest, "show_source", ["file_id": mainID.uuidString, "page_number": 1])), "The latest reader task could not navigate.")
            service.unregister(viewID: viewID)
            service.register(viewID: viewID, handlers: handlers)
            check(!succeeded(try await invoke(newest, "show_source", ["file_id": mainID.uuidString, "page_number": 2])), "A re-registered reader accepted an old view lease.")
            service.end(requestID: newest.requestID)
            do { _ = try await invoke(newest, "read_research_workspace"); check(false, "An ended executor retained command authority.") }
            catch { check(true, "") }
        } catch { failures.append(error.localizedDescription) }
        return AIHighlightFoundationDiagnosticReport(checkCount: checks, failures: failures)
    }
}
