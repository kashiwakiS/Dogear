#if os(iOS)
import SwiftUI
import UIKit
import Combine

/// Two actual native composer installations share disposable Research records.
/// The fixture uses production leases, native callbacks and persistence; it
/// does not exercise another scene, an OS termination or a provider request.
@MainActor
enum IPadResearchComposerDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DogearIPadComposer-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            expect(false, "Composer diagnostics require an actual UIWindowScene.")
            return (checks, failures)
        }
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        var hosts: [NativeHost] = []
        defer {
            for host in hosts { host.dismantle() }
            window.isHidden = true
            previousWindow?.makeKey()
        }

        await exerciseTwoOwners(root: root.appendingPathComponent("owners"),
            hostView: controller.view, window: window, hosts: &hosts, expect: expect)
        await exerciseFailedHandoff(root: root.appendingPathComponent("failure"),
            hostView: controller.view, window: window, hosts: &hosts, expect: expect)
        await exerciseRemountAndSessionSwitch(root: root.appendingPathComponent("remount"),
            hostView: controller.view, window: window, hosts: &hosts, expect: expect)
        await exerciseSameObjectRemount(root: root.appendingPathComponent("same-object"),
            hostView: controller.view, window: window, hosts: &hosts, expect: expect)
        await exerciseProgrammaticChanges(root: root.appendingPathComponent("programmatic"),
            hostView: controller.view, window: window, hosts: &hosts, expect: expect)
        await exerciseRestoreResolutionFailure(root: root.appendingPathComponent("restore-failure"),
            hostView: controller.view, hosts: &hosts, expect: expect)
        return (checks, failures)
    }

    private static func exerciseTwoOwners(root: URL, hostView: UIView, window: UIWindow,
                                         hosts: inout [NativeHost], expect: (Bool, String) -> Void) async {
        let store = ResearchStore(rootURL: root)
        let id = store.createSession(title: "Two installed composers")
        let original = "Shared input "
        expect(store.saveDraft(.init(text: original), sessionID: id),
               "The two-host fixture starts with an actual durable Research draft.")
        let a = NativeHost(store: store, sessionID: id, hostView: hostView)
        let b = NativeHost(store: store, sessionID: id, hostView: hostView)
        hosts += [a, b]
        await settleNativeEditing()
        let firstLease = a.editing.lease
        expect(a.editing.ownsEditor && !b.editing.ownsEditor && firstLease != nil
               && store.composerOwner(sessionID: id) == firstLease && !b.native.isEditable,
               "Two mounted hosts share one real composer owner; the second stays read-only.")
        var publications = 0
        let observation = a.editing.objectWillChange.sink { publications += 1 }
        a.sync()
        a.sync()
        await settleNativeEditing()
        expect(publications == 0,
               "Repeated unchanged production native installations acknowledge text without publishing a composer update loop.")
        observation.cancel()
        _ = a.native.becomeFirstResponder()
        a.commands.activate(a.native)
        await settleNativeEditing()
        a.native.selectedRange = .init(location: (original as NSString).length, length: 0)
        a.native.setMarkedText("甲窗口组合", selectedRange: .init(location: 5, length: 0))
        let composed = a.native.text ?? ""
        expect(a.native.window === window && a.native.isFirstResponder && a.native.markedTextRange != nil
               && composed == original + "甲窗口组合" && store.session(id: id)?.draft.text == composed,
               "The owning host has actual marked Chinese input, native focus and the same shared draft.")

        let block = ResearchInputBlock(kind: .discussion, text: "Latest discussion block")
        let beforeBlocks = store.composerSnapshot(sessionID: id)
        var withBlock = store.session(id: id)?.draft ?? ResearchDraft()
        withBlock.blocks = [block]
        expect(store.saveDraft(withBlock, sessionID: id)
               && store.composerSnapshot(sessionID: id)?.textRevision == beforeBlocks?.textRevision
               && store.composerOwner(sessionID: id) == firstLease && a.native.markedTextRange != nil,
               "A block-only mutation preserves the native composition and its text revision.")
        expect(b.editing.takeOver() && b.editing.ownsEditor && !a.editing.ownsEditor
               && a.native.markedTextRange == nil && store.session(id: id)?.draft.text == composed,
               "Explicit takeover prepares the actual first native field before transferring its lease.")
        b.sync()
        _ = b.native.becomeFirstResponder()
        b.commands.activate(b.native)
        await settleNativeEditing()
        b.native.selectedRange = .init(location: (composed as NSString).length, length: 0)
        b.native.insertText("\n乙窗口最新全文")
        let latest = composed + "\n乙窗口最新全文"
        let latestLease = b.editing.lease
        expect(b.native.isFirstResponder && b.native.text == latest
               && store.session(id: id)?.draft == .init(text: latest, blocks: [block]),
               "The new native owner patches only text and preserves the latest discussion block.")

        let rejected = "甲窗口迟到的完整输入"
        a.native.text = rejected
        a.coordinator.textViewDidChange(a.native)
        a.native.commitCurrentText()
        a.dismantle()
        expect(store.composerOwner(sessionID: id) == latestLease
               && b.editing.ownsEditor && store.session(id: id)?.draft == .init(text: latest, blocks: [block]),
               "An old host's late delegate, native commit and dismantle cannot replace the newer draft or lease.")
        let conflict = store.composerConflicts.first {
            $0.sessionID == id && $0.editorID == a.editing.editorID && $0.text == rejected && !$0.isResolved
        }
        expect(a.editing.hasLocalConflict && conflict != nil,
               "Rejected old-host text remains in the published recoverable conflict inventory.")
        let reloaded = ResearchStore(rootURL: root)
        expect(reloaded.session(id: id)?.draft == .init(text: latest, blocks: [block])
               && reloaded.composerConflicts.contains(where: { $0.id == conflict?.id && $0.text == rejected && !$0.isResolved }),
               "Actual disk reload keeps both the newest shared draft and the rejected old-host text.")
        if let conflict {
            let merged = latest + "\n\n" + rejected
            expect(b.editing.restoreConflict(conflict.id),
                   "The current owner can explicitly restore a rejected input through the production merge API.")
            b.sync()
            let restored = ResearchStore(rootURL: root)
            expect(b.native.text == merged && store.session(id: id)?.draft == .init(text: merged, blocks: [block])
                   && restored.session(id: id)?.draft == .init(text: merged, blocks: [block])
                   && restored.composerConflicts.first(where: { $0.id == conflict.id })?.isResolved == true,
                   "Explicit recovery appends to the current input, preserves blocks and durably resolves the conflict.")
        }
    }

    private static func exerciseFailedHandoff(root: URL, hostView: UIView, window: UIWindow,
                                             hosts: inout [NativeHost], expect: (Bool, String) -> Void) async {
        let fault = WriteFault()
        let store = ResearchStore(rootURL: root, atomicWriter: { data, url in try fault.write(data, to: url) })
        let id = store.createSession(title: "Failed native handoff")
        let original = "Last durable input "
        expect(store.saveDraft(.init(text: original), sessionID: id),
               "The handoff fault fixture establishes a last valid file before blocking writes.")
        let a = NativeHost(store: store, sessionID: id, hostView: hostView)
        let b = NativeHost(store: store, sessionID: id, hostView: hostView)
        hosts += [a, b]
        await settleNativeEditing()
        _ = a.native.becomeFirstResponder()
        a.commands.activate(a.native)
        await settleNativeEditing()
        a.native.selectedRange = .init(location: (original as NSString).length, length: 0)
        let lease = a.editing.lease
        let initialRevision = store.composerSnapshot(sessionID: id)?.textRevision
        fault.blocksWrites = true
        a.native.setMarkedText("尚未落盘", selectedRange: .init(location: 4, length: 0))
        a.native.setMarkedText("尚未落盘最新", selectedRange: .init(location: 6, length: 0))
        let latest = original + "尚未落盘最新"
        let marked = markedRange(a.native)
        let selection = a.native.selectedRange
        let failedBeforeTakeover = fault.failedWrites
        let latestRevision = store.composerSnapshot(sessionID: id)?.textRevision
        expect(a.native.window === window && a.native.isFirstResponder && marked != nil
               && a.native.text == latest && store.session(id: id)?.draft.text == latest
               && failedBeforeTakeover >= 2 && !store.saveFailures.isEmpty
               && latestRevision != initialRevision,
               "Consecutive actual marked callbacks retain the latest in-memory text and advance revision despite failed writes.")
        expect(!b.editing.takeOver() && store.composerOwner(sessionID: id) == lease
               && a.editing.ownsEditor && !b.editing.ownsEditor && fault.failedWrites > failedBeforeTakeover,
               "A real failed persistence preflight rejects transfer and retains the original registration.")
        expect(a.native.markedTextRange != nil && markedRange(a.native) == marked
               && a.native.selectedRange == selection && a.native.isFirstResponder && a.native.text == latest,
               "Failed handoff preserves the exact native marked range, selection, focus and latest text.")
        expect(ResearchStore(rootURL: root).session(id: id)?.draft.text == original,
               "The injected save failure leaves the last durable Research file intact.")
        fault.blocksWrites = false
        expect(a.editing.retrySave() && store.saveFailures.isEmpty
               && store.composerSnapshot(sessionID: id)?.textRevision == latestRevision
               && a.native.markedTextRange != nil && a.native.isFirstResponder
               && ResearchStore(rootURL: root).session(id: id)?.draft.text == latest,
               "Retry persists the newest accepted revision without ending native composition or pretending an equal echo saved it.")
        expect(b.editing.takeOver() && b.editing.ownsEditor && !a.editing.ownsEditor
               && a.native.markedTextRange == nil && store.session(id: id)?.draft.text == latest,
               "Repair allows the same explicit handoff to finish composition and transfer ownership.")
        b.sync()
        b.native.selectedRange = .init(location: (latest as NSString).length, length: 0)
        b.native.insertText("，交接后输入")
        let afterHandoff = latest + "，交接后输入"
        expect(store.session(id: id)?.draft.text == afterHandoff
               && ResearchStore(rootURL: root).session(id: id)?.draft.text == afterHandoff
               && !b.editing.hasLocalConflict && store.saveFailures.isEmpty,
               "The repaired new host writes from its acknowledged revision and survives an actual reload.")

        // The old installation has not received a read-only SwiftUI echo yet.
        // Its late native producer must archive locally rather than borrow B's
        // lease, even if that archive cannot currently be written.
        _ = a.native.becomeFirstResponder()
        a.commands.activate(a.native)
        await settleNativeEditing()
        a.native.selectedRange = .init(location: ((a.native.text ?? "") as NSString).length, length: 0)
        fault.blocksWrites = true
        a.native.setMarkedText("旧窗口待恢复组合", selectedRange: .init(location: 8, length: 0))
        let localConflictText = a.native.text ?? ""
        let conflictMark = markedRange(a.native)
        let conflictSelection = a.native.selectedRange
        let bLease = b.editing.lease
        expect(a.editing.hasLocalConflict && conflictMark != nil && a.native.isFirstResponder
               && store.session(id: id)?.draft.text == afterHandoff
               && store.composerConflicts.contains(where: {
                   $0.sessionID == id && $0.editorID == a.editing.editorID && $0.text == localConflictText && !$0.isResolved
               }),
               "A late old-installation composition becomes recoverable local conflict without replacing the newer shared input.")
        expect(!a.editing.takeOver() && store.composerOwner(sessionID: id) == bLease
               && markedRange(a.native) == conflictMark && a.native.selectedRange == conflictSelection
               && a.native.isFirstResponder && a.native.text == localConflictText,
               "Explicit Edit here also refuses transfer before a failed local conflict archive is durable and keeps its actual composition.")
        fault.blocksWrites = false
        expect(a.editing.retrySave() && a.native.markedTextRange != nil
               && store.composerOwner(sessionID: id) == bLease,
               "Repair can save the rejected local input while the other native host keeps ownership.")
        expect(a.editing.takeOver() && a.editing.ownsEditor && !b.editing.ownsEditor
               && a.native.markedTextRange == nil && !a.editing.hasLocalConflict
               && store.session(id: id)?.draft.text == afterHandoff,
               "Explicit Edit here prepares the archived local field and adopts the current draft rather than replacing it with rejected text.")
        a.sync()
        let conflictReload = ResearchStore(rootURL: root)
        expect(a.native.text == afterHandoff && conflictReload.session(id: id)?.draft.text == afterHandoff
               && conflictReload.composerConflicts.contains(where: {
                   $0.sessionID == id && $0.editorID == a.editing.editorID && $0.text == localConflictText && !$0.isResolved
               }),
               "The reclaimed native editor displays current input while its separately archived composition remains available after reload.")
    }

    private static func exerciseProgrammaticChanges(root: URL, hostView: UIView, window: UIWindow,
                                                    hosts: inout [NativeHost], expect: (Bool, String) -> Void) async {
        let store = ResearchStore(rootURL: root)
        let id = store.createSession(title: "Programmatic composer replacement")
        let original = "Program input "
        let block = ResearchInputBlock(kind: .discussion, text: "Keep this latest block")
        _ = store.saveDraft(.init(text: original, blocks: [block]), sessionID: id)
        let host = NativeHost(store: store, sessionID: id, hostView: hostView)
        hosts.append(host)
        await settleNativeEditing()
        _ = host.native.becomeFirstResponder()
        host.commands.activate(host.native)
        await settleNativeEditing()
        host.native.selectedRange = .init(location: (original as NSString).length, length: 0)
        host.native.setMarkedText("先保留组合", selectedRange: .init(location: 5, length: 0))
        let composed = original + "先保留组合"
        let replaced = composed + "\nApplied programmatic input"
        expect(host.native.isFirstResponder && host.native.window === window
               && host.native.markedTextRange != nil && host.native.text == composed
               && store.session(id: id)?.draft == .init(text: composed, blocks: [block]),
               "Programmatic replacement starts from an actual marked native draft with a preserved block.")
        expect(store.saveDraft(.init(text: replaced, blocks: [block]), sessionID: id)
               && host.native.markedTextRange == nil
               && store.session(id: id)?.draft == .init(text: replaced, blocks: [block]),
               "The real programmatic save prepares native composition before publishing its merged replacement.")
        host.native.commitCurrentText()
        expect(host.native.text == composed && store.session(id: id)?.draft == .init(text: replaced, blocks: [block])
               && !host.editing.hasLocalConflict,
               "The unchanged old native buffer cannot overwrite or invent a conflict for programmatic text before its safe echo.")
        host.sync()
        host.native.commitCurrentText()
        expect(host.native.text == replaced && store.session(id: id)?.draft == .init(text: replaced, blocks: [block])
               && ResearchStore(rootURL: root).session(id: id)?.draft == .init(text: replaced, blocks: [block])
               && !host.editing.hasLocalConflict,
               "A safely acknowledged replacement cannot be overwritten by the subsequent native commit.")

        let acceptedID = store.createSession(title: "Accepted answer keeps new composition")
        let sent = "Frozen sent input "
        _ = store.saveDraft(.init(text: sent, blocks: [block]), sessionID: acceptedID)
        let acceptedHost = NativeHost(store: store, sessionID: acceptedID, hostView: hostView)
        hosts.append(acceptedHost)
        await settleNativeEditing()
        let sentDraft = store.session(id: acceptedID)?.draft ?? ResearchDraft()
        let requestID = store.beginRequest(sessionID: acceptedID, question: sent, sourceSnapshot: [], input: sentDraft)
        expect(requestID != nil, "Accepted-answer composition fixture starts an actual durable request.")
        _ = acceptedHost.native.becomeFirstResponder()
        acceptedHost.commands.activate(acceptedHost.native)
        await settleNativeEditing()
        acceptedHost.native.selectedRange = .init(location: (sent as NSString).length, length: 0)
        acceptedHost.native.setMarkedText("请求后新组合", selectedRange: .init(location: 6, length: 0))
        let newer = sent + "请求后新组合"
        let newerMark = markedRange(acceptedHost.native)
        let newerSelection = acceptedHost.native.selectedRange
        let newerRevision = store.composerSnapshot(sessionID: acceptedID)?.textRevision
        expect(acceptedHost.native.isFirstResponder && newerMark != nil
               && store.session(id: acceptedID)?.draft.text == newer,
               "A real outstanding request has newer marked input in the same native composer.")
        if let requestID {
            expect(store.finishRequest(sessionID: acceptedID, requestID: requestID,
                answer: "Accepted result", status: .accepted, origin: .localOutline)
                && store.session(id: acceptedID)?.draft == .init(text: newer, blocks: [block])
                && store.session(id: acceptedID)?.messages.last?.input == sentDraft
                && store.session(id: acceptedID)?.messages.last?.answer == "Accepted result"
                && store.session(id: acceptedID)?.messages.last?.status == .accepted,
                   "The real accepted answer keeps the newer draft and its frozen original request input.")
            expect(markedRange(acceptedHost.native) == newerMark
                   && acceptedHost.native.selectedRange == newerSelection && acceptedHost.native.isFirstResponder
                   && store.composerSnapshot(sessionID: acceptedID)?.textRevision == newerRevision
                   && ResearchStore(rootURL: root).session(id: acceptedID)?.draft == .init(text: newer, blocks: [block]),
                   "Answer publication leaves new native composition, focus and text revision intact and durably reloads it.")
        }

        let clearID = store.createSession(title: "Accepted answer clears settled input")
        let toClear = "Settled sent text"
        _ = store.saveDraft(.init(text: toClear), sessionID: clearID)
        let clearHost = NativeHost(store: store, sessionID: clearID, hostView: hostView)
        hosts.append(clearHost)
        await settleNativeEditing()
        let clearRequest = store.beginRequest(sessionID: clearID, question: toClear, sourceSnapshot: [],
            input: .init(text: toClear))
        expect(clearRequest != nil, "The settled-clear fixture has an actual durable running request.")
        if let clearRequest {
            expect(store.finishRequest(sessionID: clearID, requestID: clearRequest,
                answer: "Settled result", status: .accepted, origin: .localOutline)
                && store.session(id: clearID)?.draft == ResearchDraft(),
                   "An accepted answer clears an unchanged draft only after the owning native field prepares.")
            clearHost.native.commitCurrentText()
            expect(clearHost.native.text == toClear && store.session(id: clearID)?.draft == ResearchDraft()
                   && !clearHost.editing.hasLocalConflict,
                   "A native commit before the clear's safe echo cannot resurrect sent input or invent a local conflict.")
            clearHost.sync()
            clearHost.native.commitCurrentText()
            clearHost.dismantle()
            let reload = ResearchStore(rootURL: root)
            expect(clearHost.native.text.isEmpty && reload.session(id: clearID)?.draft == ResearchDraft()
                   && reload.session(id: clearID)?.messages.last?.answer == "Settled result"
                   && reload.session(id: clearID)?.messages.last?.input.text == toClear
                   && !clearHost.editing.hasLocalConflict,
                   "An acknowledged clear survives native commit, dismantle and actual reload without resurrecting sent input.")
        }

        let refusedID = store.createSession(title: "Accepted answer refuses native preparation")
        let refusedText = "Sent unchanged word"
        _ = store.saveDraft(.init(text: refusedText), sessionID: refusedID)
        let refusedHost = NativeHost(store: store, sessionID: refusedID, hostView: hostView)
        hosts.append(refusedHost)
        await settleNativeEditing()
        let refusedRequest = store.beginRequest(sessionID: refusedID, question: refusedText, sourceSnapshot: [],
            input: .init(text: refusedText))
        _ = refusedHost.native.becomeFirstResponder()
        refusedHost.commands.activate(refusedHost.native)
        await settleNativeEditing()
        refusedHost.native.selectedRange = .init(location: ("Sent unchanged " as NSString).length, length: 4)
        refusedHost.native.setMarkedText("word", selectedRange: .init(location: 4, length: 0))
        let refusedMark = markedRange(refusedHost.native)
        let refusedSelection = refusedHost.native.selectedRange
        let refusedLease = refusedHost.editing.lease
        expect(refusedRequest != nil && refusedMark != nil && refusedHost.native.isFirstResponder
               && refusedHost.native.text == refusedText && store.session(id: refusedID)?.draft.text == refusedText,
               "Refused preparation has a real marked range whose full text still equals the frozen request.")
        refusedHost.permitsPreparation = false
        refusedHost.installPreparationGate()
        if let refusedRequest {
            expect(store.finishRequest(sessionID: refusedID, requestID: refusedRequest,
                answer: "Accepted despite refused clear", status: .accepted, origin: .localOutline)
                && store.session(id: refusedID)?.draft.text == refusedText
                && store.session(id: refusedID)?.messages.last?.status == .accepted
                && store.composerOwner(sessionID: refusedID) == refusedLease,
                   "Refusing native preparation keeps input and ownership while the accepted answer is still saved.")
            let reload = ResearchStore(rootURL: root)
            expect(markedRange(refusedHost.native) == refusedMark
                   && refusedHost.native.selectedRange == refusedSelection && refusedHost.native.isFirstResponder
                   && reload.session(id: refusedID)?.draft.text == refusedText
                   && reload.session(id: refusedID)?.messages.last?.answer == "Accepted despite refused clear"
                   && reload.session(id: refusedID)?.messages.last?.status == .accepted,
                   "The failed native clear preserves actual composition and durably retains the accepted answer and input.")
        }
        refusedHost.permitsPreparation = true
    }

    private static func exerciseRemountAndSessionSwitch(root: URL, hostView: UIView, window: UIWindow,
                                                       hosts: inout [NativeHost], expect: (Bool, String) -> Void) async {
        let store = ResearchStore(rootURL: root)
        let id = store.createSession(title: "Same editor identity remount")
        let otherID = store.createSession(title: "New captured session")
        let original = "Mounted once "
        let otherOriginal = "Independent session "
        _ = store.saveDraft(.init(text: original), sessionID: id)
        _ = store.saveDraft(.init(text: otherOriginal), sessionID: otherID)
        let editorID = UUID()
        let old = NativeHost(store: store, sessionID: id, hostView: hostView, editorID: editorID)
        hosts.append(old)
        await settleNativeEditing()
        let oldLease = old.editing.lease
        _ = old.native.becomeFirstResponder()
        old.commands.activate(old.native)
        await settleNativeEditing()
        old.native.selectedRange = .init(location: (original as NSString).length, length: 0)
        old.native.setMarkedText("重挂保留", selectedRange: .init(location: 4, length: 0))
        let composed = original + "重挂保留"
        expect(old.native.window === window && old.native.isFirstResponder && old.native.markedTextRange != nil
               && old.native.text == composed && store.session(id: id)?.draft.text == composed,
               "A same-editor remount begins with actual composition in its earlier installation.")
        let replacement = NativeHost(store: store, sessionID: id, hostView: hostView, editorID: editorID)
        hosts.append(replacement)
        await settleNativeEditing()
        let freshLease = replacement.editing.lease
        expect(freshLease != nil && oldLease != nil && freshLease != oldLease
               && freshLease?.editorID == oldLease?.editorID
               && freshLease?.registrationID != oldLease?.registrationID
               && replacement.editing.ownsEditor && !old.editing.ownsEditor
               && old.native.markedTextRange == nil && replacement.native.text == composed,
               "A replacement EditingSession with the same editor identity prepares the old native field and receives a fresh registration.")
        replacement.native.selectedRange = .init(location: (composed as NSString).length, length: 0)
        replacement.native.insertText("，新安装输入")
        let latest = composed + "，新安装输入"
        old.native.text = "Late previous installation"
        old.coordinator.textViewDidChange(old.native)
        old.dismantle()
        expect(old.editing.release() && store.composerOwner(sessionID: id) == freshLease
               && store.session(id: id)?.draft.text == latest && replacement.editing.ownsEditor,
               "An old registration's callback, dismantle and release cannot revoke or overwrite its same-editor replacement.")

        let reusedObject = replacement.editing
        let switched = NativeHost(store: store, sessionID: otherID, hostView: hostView, editing: reusedObject)
        hosts.append(switched)
        await settleNativeEditing()
        expect(reusedObject.sessionID == otherID && switched.editing.ownsEditor
               && store.composerOwner(sessionID: id) == nil
               && store.composerOwner(sessionID: otherID) == switched.editing.lease,
               "The real editing object can release its old capability and bind a different Research UUID.")
        switched.native.selectedRange = .init(location: (otherOriginal as NSString).length, length: 0)
        switched.native.insertText("新会话输入")
        let otherLatest = otherOriginal + "新会话输入"
        replacement.native.text = "Late callback after Research UUID switch"
        replacement.coordinator.textViewDidChange(replacement.native)
        replacement.dismantle()
        let reload = ResearchStore(rootURL: root)
        expect(store.session(id: id)?.draft.text == latest && store.session(id: otherID)?.draft.text == otherLatest
               && reload.session(id: id)?.draft.text == latest && reload.session(id: otherID)?.draft.text == otherLatest
               && !switched.editing.hasLocalConflict,
               "Captured UUID guards reject an old native binding after its EditingSession object moves to another Research session.")
    }

    private static func exerciseRestoreResolutionFailure(root: URL, hostView: UIView,
                                                         hosts: inout [NativeHost], expect: (Bool, String) -> Void) async {
        let fault = WriteFault()
        let store = ResearchStore(rootURL: root, atomicWriter: { data, url in try fault.write(data, to: url) })
        let id = store.createSession(title: "Recovery resolution write failure")
        let block = ResearchInputBlock(kind: .discussion, text: "Retain the latest block through recovery")
        let original = "Current input"
        _ = store.saveDraft(.init(text: original, blocks: [block]), sessionID: id)
        let a = NativeHost(store: store, sessionID: id, hostView: hostView)
        let b = NativeHost(store: store, sessionID: id, hostView: hostView)
        hosts += [a, b]
        await settleNativeEditing()
        expect(b.editing.takeOver(), "The resolution-fault fixture transfers an actual installed composer lease.")
        b.sync()
        b.native.selectedRange = .init(location: (original as NSString).length, length: 0)
        b.native.insertText(" plus newer input")
        let latest = original + " plus newer input"
        let rejected = "Rejected native text to recover"
        a.native.text = rejected
        a.coordinator.textViewDidChange(a.native)
        a.dismantle()
        guard let conflict = store.composerConflicts.first(where: {
            $0.sessionID == id && $0.editorID == a.editing.editorID && $0.text == rejected && !$0.isResolved
        }) else {
            expect(false, "The resolution-fault fixture requires a real durable rejected-native conflict.")
            return
        }
        let merged = latest + "\n\n" + rejected
        fault.rejectResolvedConflictWrites = true
        expect(!b.editing.restoreConflict(conflict.id) && fault.failedResolutionWrites > 0
               && store.session(id: id)?.draft == .init(text: merged, blocks: [block])
               && store.session(id: id)?.appliedComposerConflictIDs == Set([conflict.id])
               && !store.saveFailures.isEmpty,
               "Only the actual resolved-conflict JSON write fails after the merged draft and recovery ID become durable together.")
        // Do not install a model echo first: the old native buffer is precisely
        // the producer that must not overwrite an unacknowledged merged draft.
        b.native.commitCurrentText()
        b.dismantle()
        expect(store.session(id: id)?.draft == .init(text: merged, blocks: [block])
               && store.session(id: id)?.appliedComposerConflictIDs == Set([conflict.id]),
               "A native commit and dismantle before the failed restore's model echo cannot write its old full text over the merge.")

        let rebuilt = ResearchStore(rootURL: root, atomicWriter: { data, url in try fault.write(data, to: url) })
        expect(rebuilt !== store && rebuilt.session(id: id)?.draft == .init(text: merged, blocks: [block])
               && rebuilt.session(id: id)?.appliedComposerConflictIDs == Set([conflict.id])
               && rebuilt.composerConflicts.first(where: { $0.id == conflict.id })?.isResolved == false,
               "A new actual Store reconstructs the committed recovery ID and exact once-merged text beside the unresolved archive.")
        let repaired = NativeHost(store: rebuilt, sessionID: id, hostView: hostView)
        hosts.append(repaired)
        await settleNativeEditing()
        let failuresBeforeRetry = fault.failedResolutionWrites
        expect(repaired.editing !== b.editing && repaired.editing.ownsEditor
               && !repaired.editing.restoreConflict(conflict.id)
               && fault.failedResolutionWrites > failuresBeforeRetry
               && rebuilt.session(id: id)?.draft == .init(text: merged, blocks: [block]),
               "A new native editing object retries that recovery ID without appending its text again while archive resolution is still blocked.")
        fault.rejectResolvedConflictWrites = false
        expect(repaired.editing.retrySave() && rebuilt.saveFailures.isEmpty,
               "Repair retries the failed resolution through the actual editing API.")
        repaired.sync()
        let resolved = ResearchStore(rootURL: root)
        expect(repaired.native.text == merged && resolved.session(id: id)?.draft == .init(text: merged, blocks: [block])
               && resolved.session(id: id)?.appliedComposerConflictIDs == Set([conflict.id])
               && resolved.composerConflicts.first(where: { $0.id == conflict.id })?.isResolved == true,
               "After reconstruction and repair, recovery remains exactly once, preserves blocks and durably resolves its archive.")

        let legacyID = rebuilt.createSession(title: "Legacy optional recovery identity")
        let legacyText = "Legacy session input"
        _ = rebuilt.saveDraft(.init(text: legacyText), sessionID: legacyID)
        let legacyURL = root.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(legacyID.uuidString).json")
        do {
            let data = try Data(contentsOf: legacyURL)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                expect(false, "Legacy fixture must start from an actual Research session JSON object.")
                return
            }
            json.removeValue(forKey: "appliedComposerConflictIDs")
            let legacyData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try legacyData.write(to: legacyURL, options: .atomic)
            let legacyReload = ResearchStore(rootURL: root)
            expect(legacyReload.loadWarnings.isEmpty && legacyReload.session(id: legacyID)?.draft.text == legacyText
                   && legacyReload.session(id: legacyID)?.appliedComposerConflictIDs == nil,
                   "The actual Research loader preserves legacy JSON with the optional applied-recovery field absent.")
        } catch {
            expect(false, "Legacy recovery-identity fixture failed: \(error.localizedDescription)")
        }
    }

    private static func exerciseSameObjectRemount(root: URL, hostView: UIView, window: UIWindow,
                                                 hosts: inout [NativeHost], expect: (Bool, String) -> Void) async {
        let fault = WriteFault()
        let store = ResearchStore(rootURL: root, atomicWriter: { data, url in try fault.write(data, to: url) })
        let id = store.createSession(title: "One StateObject, two native installations")
        let original = "Retained editing object "
        _ = store.saveDraft(.init(text: original), sessionID: id)
        let retained = ResearchComposerEditingSession(store: store)
        let old = NativeHost(store: store, sessionID: id, hostView: hostView, editing: retained)
        hosts.append(old)
        await settleNativeEditing()
        _ = old.native.becomeFirstResponder()
        old.commands.activate(old.native)
        await settleNativeEditing()
        old.native.selectedRange = .init(location: (original as NSString).length, length: 0)
        let oldLease = retained.lease
        let oldInstallation = old.coordinator.installationID
        fault.blocksWrites = true
        old.native.setMarkedText("同对象待提交", selectedRange: .init(location: 6, length: 0))
        let composed = original + "同对象待提交"
        let oldMark = markedRange(old.native)
        let oldSelection = old.native.selectedRange
        let failuresBeforeRemount = fault.failedWrites
        expect(retained.nativeInstallationID == oldInstallation && oldLease != nil
               && oldMark != nil && old.native.isFirstResponder && old.native.window === window
               && old.native.text == composed && store.session(id: id)?.draft.text == composed
               && failuresBeforeRemount > 0,
               "A retained EditingSession has a real native installation with marked input and an actual failed write.")
        let replacement = NativeHost(store: store, sessionID: id, hostView: hostView, editing: retained)
        hosts.append(replacement)
        expect(replacement.editing === old.editing && replacement.coordinator.installationID != oldInstallation
               && !replacement.native.isEditable && retained.nativeInstallationID == oldInstallation,
               "A new Coordinator sharing the same StateObject remains read-only before its immutable installation attaches.")
        await settleNativeEditing()
        expect(!replacement.native.isEditable && retained.lease == oldLease
               && retained.nativeInstallationID == oldInstallation && store.composerOwner(sessionID: id) == oldLease
               && fault.failedWrites > failuresBeforeRemount && markedRange(old.native) == oldMark
               && old.native.selectedRange == oldSelection && old.native.isFirstResponder,
               "A failed production attach keeps the original registration, exact composition, selection and focus.")
        fault.blocksWrites = false
        expect(retained.retrySave() && old.native.markedTextRange != nil
               && ResearchStore(rootURL: root).session(id: id)?.draft.text == composed,
               "Repair persists the retained object's marked input before a replacement native host can take over.")
        replacement.sync()
        await settleNativeEditing()
        let newLease = retained.lease
        expect(newLease != nil && newLease != oldLease
               && newLease?.registrationID != oldLease?.registrationID
               && retained.nativeInstallationID == replacement.coordinator.installationID
               && replacement.native.isEditable && old.native.markedTextRange == nil
               && replacement.native.text == composed,
               "The production replacement attach prepares the old host and installs a fresh registration before acknowledging text.")
        _ = replacement.native.becomeFirstResponder()
        replacement.commands.activate(replacement.native)
        await settleNativeEditing()
        replacement.native.selectedRange = .init(location: (composed as NSString).length, length: 0)
        replacement.native.insertText("，新的原生安装")
        let latest = composed + "，新的原生安装"
        expect(replacement.native.isFirstResponder && retained.text == latest
               && store.session(id: id)?.draft.text == latest,
               "The acknowledged new installation writes the exact newest text through its retained StateObject.")
        old.native.submitResearch()
        replacement.native.submitResearch()
        expect(old.native.isEditable && old.submissions == 0 && replacement.submissions == 1
               && retained.lease == newLease && store.composerOwner(sessionID: id) == newLease
               && store.session(id: id)?.draft.text == latest,
               "The old still-editable native command cannot borrow a newer installation's Send capability; the real current command submits once.")
        old.sync()
        await settleNativeEditing()
        expect(!old.native.isEditable && retained.lease == newLease
               && retained.nativeInstallationID == replacement.coordinator.installationID
               && store.composerOwner(sessionID: id) == newLease && retained.text == latest,
               "Updating an already superseded real Coordinator cannot let its asynchronous attach reclaim the newer native installation.")
        let rejected = "Same-StateObject old native full text"
        old.native.text = rejected
        old.coordinator.textViewDidChange(old.native)
        old.native.commitCurrentText()
        let oldCallback = old.native.onTextChanged
        old.dismantle()
        expect(retained.lease == newLease && store.composerOwner(sessionID: id) == newLease
               && retained.nativeInstallationID == replacement.coordinator.installationID
               && retained.text == latest && !retained.hasLocalConflict && retained.error == nil
               && store.session(id: id)?.draft.text == latest,
               "An immutable old-host callback and detach cannot borrow the new lease or change the current object's input or error state.")
        let reload = ResearchStore(rootURL: root)
        expect(reload.session(id: id)?.draft.text == latest
               && reload.composerConflicts.contains(where: {
                   $0.id == oldInstallation && $0.sessionID == id && $0.editorID == retained.editorID
                       && $0.text == rejected && !$0.isResolved
               }),
               "The old installation's rejected text uses its captured identity in durable recovery while the newest shared draft stays exact.")
        guard let firstConflict = store.composerConflicts.first(where: { $0.id == oldInstallation && $0.text == rejected }) else {
            expect(false, "Versioned late-producer recovery requires its actual first immutable-installation archive.")
            return
        }
        let firstMerged = latest + "\n\n" + rejected
        expect(replacement.editing.restoreConflict(firstConflict.id),
               "The first immutable-installation archive restores through the current native owner's real recovery API.")
        replacement.sync()
        let laterRejected = "Same-StateObject later distinct native input"
        old.native.text = laterRejected
        oldCallback?(old.native.text ?? "")
        let laterConflict = store.composerConflicts.first(where: {
            $0.sessionID == id && $0.editorID == retained.editorID && $0.text == laterRejected && !$0.isResolved
        })
        let recordCount = store.composerConflicts.count
        oldCallback?(laterRejected)
        expect(laterConflict != nil && laterConflict?.id != firstConflict.id
               && store.composerConflicts.count == recordCount
               && store.composerConflicts.first(where: { $0.id == firstConflict.id })?.isResolved == true
               && store.session(id: id)?.draft.text == firstMerged && !retained.hasLocalConflict && retained.error == nil,
               "A distinct late value after recovery gets a new recoverable version while repeated identical callbacks keep one record and preserve current input.")
        if let laterConflict {
            let finalMerged = firstMerged + "\n\n" + laterRejected
            expect(replacement.editing.restoreConflict(laterConflict.id),
                   "A later version from the same old native producer can be explicitly recovered as its own input.")
            replacement.sync()
            oldCallback?(laterRejected)
            let finalReload = ResearchStore(rootURL: root)
            expect(retained.text == finalMerged && replacement.native.text == finalMerged
                   && finalReload.session(id: id)?.draft.text == finalMerged
                   && finalReload.session(id: id)?.appliedComposerConflictIDs == Set([firstConflict.id, laterConflict.id])
                   && finalReload.composerConflicts.count == recordCount
                   && finalReload.composerConflicts.first(where: { $0.id == laterConflict.id })?.isResolved == true,
                   "Both old-producer versions recover exactly once and a repeated already-applied value cannot reopen or duplicate their durable archives.")
        }

        let dormant = NativeHost(store: store, sessionID: id, hostView: hostView,
            editing: retained, installInWindow: false)
        let dormantHadNoWindow = dormant.native.window == nil
        let winner = NativeHost(store: store, sessionID: id, hostView: hostView, editing: retained)
        hosts += [dormant, winner]
        await settleNativeEditing()
        let winningLease = retained.lease
        let winningDraft = store.session(id: id)?.draft
        hostView.addSubview(dormant.native)
        dormant.sync()
        await settleNativeEditing()
        expect(dormantHadNoWindow && winningLease != nil && winningLease != newLease
               && dormant.native.window === window && !dormant.native.isEditable
               && winner.native.window === window && winner.native.isEditable
               && retained.nativeInstallationID == winner.coordinator.installationID
               && retained.lease == winningLease && store.composerOwner(sessionID: id) == winningLease
               && store.session(id: id)?.draft == winningDraft && !retained.hasLocalConflict && retained.error == nil,
               "A never-attached older reserved Coordinator arriving in the real window cannot claim the newer installation or alter its draft.")
    }

    private static func markedRange(_ native: UITextView) -> NSRange? {
        guard let range = native.markedTextRange else { return nil }
        return .init(location: native.offset(from: native.beginningOfDocument, to: range.start),
                     length: native.offset(from: range.start, to: range.end))
    }

    private static func settleNativeEditing() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    @MainActor
    private final class WriteFault {
        var blocksWrites = false
        var rejectResolvedConflictWrites = false
        private(set) var failedWrites = 0
        private(set) var failedResolutionWrites = 0
        func write(_ data: Data, to url: URL) throws {
            if blocksWrites {
                failedWrites += 1
                throw CocoaError(.fileWriteOutOfSpace)
            }
            if rejectResolvedConflictWrites, url.deletingLastPathComponent().lastPathComponent == "composer-conflicts",
               let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               record["isResolved"] as? Bool == true {
                failedResolutionWrites += 1
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        }
    }

    @MainActor
    private final class NativeHost {
        let editing: ResearchComposerEditingSession
        let commands = IPadResearchTextEditingCommands()
        let native = IPadResearchNativeTextView(frame: .init(x: 0, y: 0, width: 420, height: 220))
        private(set) var coordinator: IPadResearchNativeTextEditor.Coordinator!
        let capturedSessionID: UUID
        var permitsPreparation = true
        private(set) var submissions = 0
        private var isDismantled = false

        init(store: ResearchStore, sessionID: UUID, hostView: UIView, editorID: UUID = UUID(),
             editing: ResearchComposerEditingSession? = nil, installInWindow: Bool = true) {
            self.editing = editing ?? ResearchComposerEditingSession(store: store, editorID: editorID)
            capturedSessionID = sessionID
            _ = self.editing.bind(sessionID: sessionID, prepareNativeInput: { [weak self] in
                guard let self, self.permitsPreparation else { return false }
                return self.commands.commitMarkedTextAndEndEditing(identity: sessionID)
            })
            coordinator = IPadResearchNativeTextEditor.Coordinator(input())
            coordinator.install(native)
            if installInWindow { hostView.addSubview(native) }
        }

        private func input() -> IPadResearchNativeTextEditor {
            let capturedID = capturedSessionID
            let editing = self.editing
            let binding = Binding<String>(get: {
                guard editing.sessionID == capturedID else { return "" }
                return editing.text
            }, set: { value in
                guard editing.sessionID == capturedID else { return }
                _ = editing.acceptNativeText(value)
            })
            return IPadResearchNativeTextEditor(text: binding, commands: commands, identity: capturedID,
                isEditable: editing.ownsEditor,
                onSubmit: { [weak self] in self?.submissions += 1 },
                onExternalTextApplied: { value in
                    guard editing.sessionID == capturedID else { return }
                    editing.externalTextApplied(value)
                }, composerEditing: editing)
        }

        func sync() {
            guard !isDismantled else { return }
            coordinator.parent = input()
            coordinator.install(native)
        }

        /// Inject a refused native preparation only after the production
        /// coordinator has attached its immutable installation. Persistence and
        /// lease handling still run through the actual shared editing service.
        func installPreparationGate() {
            _ = editing.attachNativeHost(sessionID: capturedSessionID,
                installationID: coordinator.installationID, prepareNativeInput: { [weak self] in
                    guard let self, self.permitsPreparation else { return false }
                    return self.commands.commitMarkedTextAndEndEditing(identity: self.capturedSessionID)
                })
        }

        func dismantle() {
            guard !isDismantled else { return }
            isDismantled = true
            IPadResearchNativeTextEditor.dismantleUIView(native, coordinator: coordinator)
            native.removeFromSuperview()
        }
    }
}
#endif
