#if os(iOS)
import PDFKit
import UIKit

/// Real PDFKit coordinate/selection fixtures invoke the same intent entry points
/// as UIKit recognizers. This does not synthesize hardware Pencil touches.
@MainActor
enum PDFReaderUIKitInputDiagnostics {
    static func run() async -> (checks: Int, failures: [String]) {
        var checks = 0, failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1; if !condition { failures.append(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DogearReaderInput-\(UUID())")
        let suite = "DogearReaderInput.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { return (1, ["Could not isolate input defaults."]) }
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("input.pdf"), data = fixtureData()
            try data.write(to: url)
            let queue = PDFSaveQueue(recoveryDirectoryURL: root.appendingPathComponent("recovery"))
            let access = DocumentAccessCoordinator(saveQueue: queue)
            let store = PDFDocumentStore(feedbackCenter: OperationFeedbackCenter(userDefaults: defaults),
                metadataStore: DocumentMetadataStore(stateURL: root.appendingPathComponent("metadata.json")),
                aiHighlightGroupStore: AIHighlightGroupStore(stateURL: root.appendingPathComponent("groups.json")),
                workingCopyStore: try PDFWorkingCopyStore(directoryURL: root.appendingPathComponent("copies")),
                saveQueue: queue, accessCoordinator: access, exportPresenter: IPadDocumentExportPresenter())
            defer { store.releaseEditorAccess() }
            let undo = UndoManager(); undo.groupsByEvent = false; store.setUndoManager(undo)
            guard store.openPDF(from: url), let document = store.document, let page = document.page(at: 0),
                  let previous = document.findString("Second", withOptions: []).first else {
                return (checks + 1, failures + ["Input fixture could not expose its real PDF text."])
            }
            let view = UIKitReaderPDFView(frame: CGRect(x: 0, y: 0, width: 1000, height: 1100))
            view.autoScales = true; view.displayMode = .singlePageContinuous
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
            let window: UIWindow
            if let scene { window = UIWindow(windowScene: scene) }
            else { window = UIWindow(frame: view.frame) }
            let controller = UIViewController()
            window.frame = view.frame; window.rootViewController = controller
            controller.view.addSubview(view); window.makeKeyAndVisible()
            defer { window.isHidden = true; previousKeyWindow?.makeKey() }
            let coordinator = PDFReaderUIKitView.Coordinator()
            var reportedSelection: PDFTextSelectionSnapshot?, noteDraft: FreeTextEditDraft?
            var reportedSelectionDocument: PDFDocument?
            var activatedAnnotations: [PDFAnnotation] = []
            var keyboardCommands: [(PDFDocument, PDFReaderUIKitKeyboardCommand)] = []
            var interactions = 0
            coordinator.onUserInteraction = { interactions += 1 }
            coordinator.onSelectionChanged = { pdf, _, snapshot in
                guard store.document === pdf else { return }
                reportedSelectionDocument = pdf
                reportedSelection = snapshot; store.recordTextSelection(snapshot)
            }
            coordinator.onNotePlaced = { pdf, targetPage, bounds in
                guard store.document === pdf else { return }
                noteDraft = store.newFreeTextDraft(page: targetPage, bounds: bounds)
            }
            coordinator.onAnnotationTapped = { pdf, annotation in
                if store.document === pdf { activatedAnnotations.append(annotation) }
            }
            coordinator.onKeyboardCommand = { keyboardCommands.append(($0, $1)) }
            coordinator.attach(to: view); coordinator.install(document, in: view)
            view.layoutDocumentView(); await settle()
            let adapter = coordinator.inputAdapter
            adapter.refreshNativeGestures()
            let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
            let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
            expect(adapter.selectionPan.allowedTouchTypes == [pencil] && adapter.selectionTap.allowedTouchTypes == [pencil],
                "Reading Pencil recognizers accept Pencil only, retaining native finger/pointer reading.")
            expect(adapter.selectionPan.maximumNumberOfTouches == 1 && !adapter.noteTap.isEnabled,
                "Reading uses one Pencil drag and no accidental note-placement intent.")
            let pans = nativeGestures(in: view).filter { $0 is UIPanGestureRecognizer && $0 !== adapter.selectionPan }
            let scrollPans = pans.compactMap { gesture -> UIPanGestureRecognizer? in
                guard let scroll = gesture.view as? UIScrollView, gesture === scroll.panGestureRecognizer else { return nil }
                return gesture as? UIPanGestureRecognizer
            }
            let originalScrollTouches = scrollPans.map(\.minimumNumberOfTouches)
            let originalScrollMasks = scrollPans.map(\.allowedScrollTypesMask)
            let pinches = nativeGestures(in: view).filter { $0 is UIPinchGestureRecognizer }
            expect(!scrollPans.isEmpty && scrollPans.allSatisfy { !$0.allowedTouchTypes.contains(pencil) && $0.allowedTouchTypes.contains(direct) },
                "Native finger panning retains direct touches while Pencil cannot scroll the same document.")
            expect(!pinches.isEmpty && pinches.allSatisfy { $0.allowedTouchTypes.contains(direct) && !$0.allowedTouchTypes.contains(pencil) },
                "Native pinch keeps fingers and excludes Pencil.")
            let nativeTaps = nativeGestures(in: view).filter { $0 is UITapGestureRecognizer
                && $0 !== adapter.selectionTap && $0 !== adapter.noteTap && $0 !== adapter.selectionDismissTap
                && $0 !== adapter.annotationTapRecognizer }
            expect(nativeTaps.allSatisfy { !$0.allowedTouchTypes.contains(pencil) },
                "PDFKit tap navigation cannot compete with precise Pencil text selection.")

            let begin = point(character: 0, on: page, in: view)
            let end = point(character: 12, on: page, in: view)
            expect(adapter.selectWord(at: begin), "A Pencil tap maps to native word selection.")
            await settle()
            expect(reportedSelection?.text == "Orchard", "The shared selection callback receives the selected PDF word.")
            expect(selectionPresentationMatchesCurrent(in: view, document: document) && view.hasReaderKeyboardFocus,
                "A focused native PDFView displays a separate blue copy of its exact current word selection.")
            let whitespace = view.convert(CGPoint(x: 400, y: 300), from: page)
            expect(!adapter.selectWord(at: whitespace) && !adapter.beginSelection(at: whitespace),
                "Blank page space cannot snap a precise Pencil intent to distant text.")
            expect(view.hasReaderKeyboardFocus && view.readerKeyboardResponder?.isFirstResponder == true,
                "Explicit native reading interaction acquires an exact Reader first responder in its key window. \(focusDescription(in: window))")
            expect(view.keyCommands?.contains { $0.input == "h" && $0.modifierFlags.isEmpty } == true
                && view.keyCommands?.contains { $0.input == "n" && $0.modifierFlags == [.command, .shift] } == true,
                "The focused native reader advertises Highlight and note-placement keyboard commands.")
            expect((view.readerKeyboardResponder?.target(forAction: #selector(UIResponder.copy(_:)), withSender: nil) as? UIResponder) === view,
                "The Reader's real focus responder chain retains native PDFKit Copy for its selected text.")
            expect(coordinator.performKeyboardCommand(.find, in: view)
                && keyboardCommands.last?.0 === document && keyboardCommands.last?.1 == .find,
                "Native command dispatch captures the exact installed document.")
            let textInput = UITextField(frame: CGRect(x: 10, y: 10, width: 200, height: 44))
            controller.view.addSubview(textInput)
            textInput.becomeFirstResponder()
            textInput.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
            let markedText = textInput.text
            expect(textInput.isFirstResponder && !view.requestReaderFocus(),
                "Reader interaction does not steal an active native text field's composition focus.")
            let commandCount = keyboardCommands.count
            expect(!coordinator.performKeyboardCommand(.addHighlight, in: view)
                && !coordinator.performKeyboardCommand(.undo, in: view)
                && !coordinator.performKeyboardCommand(.redo, in: view)
                && keyboardCommands.count == commandCount && textInput.text == markedText,
                "Reader Highlight and document Undo/Redo stay unavailable while a text field owns input.")
            expect(selectionPresentationMatchesCurrent(in: view, document: document) && textInput.isFirstResponder,
                "Selection feedback survives native text-entry focus without replacing its marked-text responder.")
            textInput.unmarkText(); textInput.resignFirstResponder(); textInput.removeFromSuperview()
            expect(view.requestReaderFocus() && view.hasReaderKeyboardFocus && view.readerKeyboardResponder?.isFirstResponder == true,
                "The reader regains exact first-responder focus only after native text entry relinquishes it. \(focusDescription(in: window))")
            await settle()
            // This control has no Coordinator or selection observer. Capture
            // the authority PDFKit actually installs before invoking our display
            // synchronization; native setter normalization is a separate phase.
            let nativeProbe = UIKitReaderPDFView(frame: view.frame)
            controller.view.insertSubview(nativeProbe, belowSubview: view)
            nativeProbe.document = document; nativeProbe.autoScales = true
            nativeProbe.layoutDocumentView()
            let callerSelection = previous.copy() as! PDFSelection
            let callerColorBefore = callerSelection.color
            let expectedSnapshot = PDFTextSelectionService.snapshot(of: callerSelection, in: document)
            let expectedRanges = selectionRanges(callerSelection, in: document)
            let pageCountBefore = document.pageCount
            let annotationsBefore = annotationIdentities(in: document)
            nativeProbe.setCurrentSelection(callerSelection, animate: false)
            await settle()
            let installedNative = nativeProbe.currentSelection
            let nativeGetterStableBefore = nativeProbe.currentSelection === installedNative
            let installedColor = installedNative?.color
            let installedSnapshot = installedNative.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) }
            let installedRanges = installedNative.map { selectionRanges($0, in: document) }
            let nativeSnapshotMatches = expectedSnapshot != nil && installedSnapshot == expectedSnapshot
            let nativeRangesMatch = installedRanges == expectedRanges
            let nativeAnnotationsMatch = annotationIdentities(in: document) == annotationsBefore
            let nativeSetterDetails = "caller=\(selectionIdentity(callerSelection)), native=\(selectionIdentity(installedNative)), callerIdentityRetained=\(installedNative === callerSelection), nativeGetterStableBefore=\(nativeGetterStableBefore), callerColorBefore=\(colorDescription(callerColorBefore)), callerColorAfter=\(colorDescription(callerSelection.color)), callerColorChanged=\(callerSelection.color != callerColorBefore), nativeColor=\(colorDescription(installedColor)), snapshotBool=\(nativeSnapshotMatches), rangesBool=\(nativeRangesMatch), annotationsBool=\(nativeAnnotationsMatch), expectedRanges=\(expectedRanges), installedRanges=\(installedRanges ?? [])"
            expect(nativeSnapshotMatches && nativeRangesMatch
                && nativeProbe.highlightedSelections?.isEmpty != false && document.pageCount == pageCountBefore
                && nativeAnnotationsMatch,
                "An unobserved native PDFView setter installs the exact selection text, page and glyph ranges before display synchronization. \(nativeSetterDetails)")
            nativeProbe.synchronizeSelectionPresentation(in: document)
            await settle()
            let displayedNative = nativeProbe.currentSelection
            let identityPreserved = installedNative != nil && displayedNative === installedNative
            let colorPreserved = displayedNative?.color == installedColor
            let snapshotPreserved = displayedNative.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == installedSnapshot
            let afterRanges = displayedNative.map { selectionRanges($0, in: document) }
            let rangesPreserved = afterRanges == installedRanges
            let annotationsPreserved = annotationIdentities(in: document) == annotationsBefore
            let displayMatches = selectionPresentationMatchesCurrent(in: nativeProbe, document: document)
            let mirrorDetails = "\(nativeSetterDetails), afterMirror=\(selectionIdentity(displayedNative)), afterColor=\(colorDescription(displayedNative?.color)), identityBool=\(identityPreserved), colorBool=\(colorPreserved), snapshotBool=\(snapshotPreserved), rangesBool=\(rangesPreserved), annotationsBool=\(annotationsPreserved), displayBool=\(displayMatches), pageCountBool=\(document.pageCount == pageCountBefore), afterRanges=\(afterRanges ?? [])"
            #if DEBUG
            NSLog("DogearReaderInput native-selection-probe %@", mirrorDetails)
            #endif
            expect(identityPreserved && colorPreserved && snapshotPreserved && rangesPreserved
                && document.pageCount == pageCountBefore && annotationsPreserved && displayMatches,
                "The display copy leaves the actually installed native PDFSelection identity, color, text, glyph ranges and annotations intact. \(mirrorDetails)")
            nativeProbe.clearSelectionPresentation(); nativeProbe.clearSelection()
            nativeProbe.endEditing(true); nativeProbe.releaseReaderFocus(); nativeProbe.removeFromSuperview(); nativeProbe.document = nil
            let mainFocusRestored = view.requestReaderFocus(allowPDFSelectionResponder: true)
            #if DEBUG
            NSLog("DogearReaderInput native-probe-restored-main-focus accepted=%@ focus=%@", String(mainFocusRestored), focusDescription(in: window))
            #endif
            view.setCurrentSelection(previous, animate: false)
            await settle()
            expect(view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == expectedSnapshot
                && view.currentSelection.map { selectionRanges($0, in: document) } == expectedRanges
                && selectionPresentationMatchesCurrent(in: view, document: document),
                "The observed Reader retains exact native selection text and glyph ranges with its separate display copy. \(nativeSetterDetails)")
            expect(adapter.beginSelection(at: begin) && adapter.updateSelection(to: end),
                "A Pencil drag maps view coordinates to PDFKit text selection.")
            adapter.cancelSelection(restoring: true)
            expect(view.currentSelection?.string == previous.string, "Cancelling a transient drag restores the prior committed selection.")
            await settle()
            expect(selectionPresentationMatchesCurrent(in: view, document: document)
                && view.highlightedSelections?.first?.string == previous.string,
                "Cancelling a transient drag restores the previous selection's blue display rather than leaving a stale drag preview.")
            _ = adapter.beginSelection(at: begin); _ = adapter.updateSelection(to: end)
            expect(coordinator.performKeyboardCommand(.cancel, in: view)
                && !adapter.isSelecting && view.currentSelection?.string == previous.string,
                "Escape rolls back a transient selection before host mode cancellation.")
            await settle()
            expect(selectionPresentationMatchesCurrent(in: view, document: document)
                && view.highlightedSelections?.first?.string == previous.string,
                "Escape restores native selection feedback alongside the previous authoritative selection.")
            expect(adapter.beginSelection(at: begin) && adapter.updateSelection(to: end, finished: true),
                "A completed text drag publishes a retained native selection.")
            await settle()
            expect(reportedSelection?.text.contains("Orchard") == true, "Pencil drag reporting uses the common selection snapshot service.")
            if let selection = view.currentSelection {
                undo.beginUndoGrouping(); let added = store.addHighlights(from: selection, in: document); undo.endUndoGrouping()
                expect(added && page.annotations.contains { $0.type == "Highlight" }, "Pencil selection commits only through shared standard-highlight rules.")
                // The host clears its committed selection by issuing this same
                // selection-free navigation after a successful Highlight.
                let clearedAfterCommit = coordinator.navigate(.init(document: document, pageIndex: 0), in: view)
                await settle()
                expect(clearedAfterCommit && view.currentSelection == nil && view.highlightedSelections?.isEmpty != false
                    && page.annotations.contains { $0.type == "Highlight" },
                    "Successful Highlight navigation clears the temporary blue display while retaining the actual standard annotation.")
                undo.undo(); expect(page.annotations.isEmpty, "One shared Undo removes the Pencil-selected highlight.")
                undo.redo(); expect(page.annotations.filter { $0.type == "Highlight" }.count == 1, "Redo restores the same standard highlight.")
                undo.undo()
            } else { expect(false, "The completed native selection must remain available for Highlight.") }

            let wordNavigationSelection = page.selection(for: NSRange(location: 0, length: 7))!
            let selectedNavigation = coordinator.navigate(.init(document: document, pageIndex: 0, selection: wordNavigationSelection), in: view)
            await settle()
            expect(selectedNavigation && selectionPresentationMatchesCurrent(in: view, document: document)
                && view.currentSelection?.string == "Orchard",
                "Selection navigation updates the native blue display to the same authoritative PDF glyph ranges.")
            view.clearSelection(); await settle()
            expect(view.currentSelection == nil && view.highlightedSelections?.isEmpty != false,
                "Clearing the native current selection also removes the view-only display copy.")

            view.go(to: page); view.layoutDocumentView(); await settle()
            let wordPoint = point(character: 0, on: page, in: view)
            let blankPoint = view.convert(CGPoint(x: 400, y: 300), from: page)
            _ = adapter.tapSelection(at: wordPoint); await settle()
            let wordSnapshot = view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) }
            expect(wordSnapshot?.text == "Orchard" && !adapter.dismissSelection(at: wordPoint)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == wordSnapshot,
                "Read-mode finger/pointer taps inside the selected word preserve the authoritative selection.")
            let readDismissed = adapter.dismissSelection(at: blankPoint); await settle()
            expect(readDismissed && view.currentSelection == nil && view.highlightedSelections?.isEmpty != false
                && reportedSelection == nil && reportedSelectionDocument === document,
                "Read-mode finger/pointer taps outside selected text clear native selection, blue feedback and the exact-document report.")
            _ = adapter.tapSelection(at: wordPoint)
            let pencilDismissed = adapter.tapSelection(at: blankPoint); await settle()
            expect(pencilDismissed && view.currentSelection == nil && view.highlightedSelections?.isEmpty != false && reportedSelection == nil,
                "A reading Pencil blank tap uses the same native selection-tap intent to clear its prior selection.")
            adapter.configure(mode: .selectText)
            _ = adapter.tapSelection(at: wordPoint); await settle()
            expect(!adapter.dismissSelection(at: wordPoint) && view.currentSelection?.string == "Orchard",
                "Select Text retains glyph taps for word selection rather than dismissing the selected word.")
            let selectDismissed = adapter.tapSelection(at: blankPoint); await settle()
            expect(selectDismissed && view.currentSelection == nil && view.highlightedSelections?.isEmpty != false && reportedSelection == nil,
                "Select Text clears selection and blue feedback when its selection tap lands on blank page space.")
            adapter.configure(mode: .read); _ = adapter.tapSelection(at: wordPoint); await settle()
            _ = adapter.beginSelection(at: wordPoint); _ = adapter.updateSelection(to: point(character: 12, on: page, in: view))
            expect(!adapter.dismissSelection(at: blankPoint) && adapter.isSelecting,
                "A blank tap cannot clear a live native selection transaction.")
            adapter.cancelSelection(restoring: true)
            adapter.configure(mode: .addNote)
            expect(!adapter.dismissSelection(at: blankPoint) && view.currentSelection?.string == "Orchard",
                "Note placement keeps its page tap and does not dismiss reading selection.")
            adapter.configure(mode: .read)

            let annotation = PDFAnnotation(bounds: CGRect(x: 360, y: 440, width: 100, height: 50), forType: .freeText, withProperties: nil)
            annotation.contents = "Hit target"; page.addAnnotation(annotation)
            let annotationPoint = view.convert(CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY), from: page)
            expect(!adapter.dismissSelection(at: annotationPoint) && view.currentSelection?.string == "Orchard",
                "A visible standard annotation protects its editor tap from outside-selection dismissal.")
            let link = PDFAnnotation(bounds: CGRect(x: 380, y: 360, width: 100, height: 40), forType: .link, withProperties: nil)
            link.url = URL(string: "https://example.invalid/reader-fixture"); page.addAnnotation(link)
            expect(!adapter.dismissSelection(at: view.convert(CGPoint(x: link.bounds.midX, y: link.bounds.midY), from: page))
                && view.currentSelection?.string == "Orchard" && link.page === page,
                "A native PDF Link tap retains its intent and the current selection without opening a fixture URL.")
            page.removeAnnotation(link)
            expect(coordinator.activateAnnotation(at: annotationPoint) && activatedAnnotations.last === annotation,
                "A native PDFKit annotation hit opens the exact standard annotation.")
            annotation.shouldDisplay = false
            expect(!coordinator.activateAnnotation(at: annotationPoint), "A hidden annotation cannot open an editor.")
            annotation.shouldDisplay = true
            adapter.configure(mode: .addNote)
            expect(nativeTaps.allSatisfy { !$0.allowedTouchTypes.contains(direct)
                && !$0.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)) },
                "Note placement reserves page taps while native finger navigation gestures remain available.")
            expect(!coordinator.activateAnnotation(at: annotationPoint), "Note placement reserves tap intent instead of opening an old annotation.")
            adapter.configure(mode: .read); page.removeAnnotation(annotation)
            expect(!coordinator.activateAnnotation(at: annotationPoint), "An annotation removed from its page cannot be edited by an old hit.")

            adapter.configure(mode: .selectText)
            expect(adapter.selectionPan.allowedTouchTypes.contains(direct)
                && adapter.selectionPan.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)),
                "Explicit Select Text allows finger and external pointer drag.")
            expect(!scrollPans.isEmpty && scrollPans.allSatisfy { $0.minimumNumberOfTouches >= 2 && $0.allowedTouchTypes.contains(direct) }
                && pinches.allSatisfy { $0.allowedTouchTypes.contains(direct) },
                "Select Text reserves one-finger drag while native two-finger scrolling and pinch remain available.")
            expect(scrollPans.map(\.allowedScrollTypesMask) == originalScrollMasks,
                "Text-selection policy preserves PDFKit's pointer wheel/trackpad scroll masks.")
            expect(pinches.first.map { adapter.gestureRecognizer(adapter.selectionPan, shouldRecognizeSimultaneouslyWith: $0) } == true,
                "Native pinch may interrupt an input selection instead of losing zoom.")
            view.setCurrentSelection(previous, animate: false)
            _ = adapter.beginSelection(at: begin); _ = adapter.updateSelection(to: end)
            adapter.configure(mode: .read)
            expect(view.currentSelection?.string == previous.string && scrollPans.allSatisfy { $0.allowedTouchTypes.contains(direct) }
                && scrollPans.map(\.minimumNumberOfTouches) == originalScrollTouches,
                "Leaving Select Text cancels its transient drag and restores native one-finger reading.")
            expect(!adapter.beginSelection(at: CGPoint(x: -100, y: -100)), "A drag outside page bounds has no selection intent.")
            _ = adapter.beginSelection(at: begin); _ = adapter.updateSelection(to: end)
            view.autoScales = false; view.scaleFactor = 1.15
            expect(!adapter.isSelecting && view.currentSelection?.string == previous.string,
                "Native scale changes cancel transient text coordinates before the viewport changes.")
            view.autoScales = true; view.layoutDocumentView(); view.go(to: page)

            // Native conversions keep Pencil meaning stable at custom zoom and
            // each orthogonal rotation; no device-model branching is involved.
            for rotation in [0, 90, 180, 270] {
                page.rotation = rotation
                view.autoScales = false; view.scaleFactor = 1.1; view.layoutDocumentView(); view.go(to: page)
                await settle(); view.layoutIfNeeded(); view.layoutDocumentView()
                let startPoint = point(character: 0, on: page, in: view)
                let endPoint = point(character: 12, on: page, in: view)
                let mappedStart = view.convert(startPoint, to: page)
                let startGlyph = page.characterBounds(at: 0)
                let referenceText = document.selection(from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 12)?.string
                let began = adapter.beginSelection(at: startPoint)
                let wasSelecting = adapter.isSelecting
                let updated = adapter.updateSelection(to: endPoint, finished: true)
                let selectedText = view.currentSelection?.string
                expect(began && updated && selectedText?.contains("Orchard") == true,
                    "Precise selection uses PDFKit transforms at rotation \(rotation) and custom zoom. begin=\(began), active=\(wasSelecting), update=\(updated), scale=\(view.scaleFactor), point=\(startPoint), pdfPoint=\(mappedStart), glyphDelta=(\(mappedStart.x - startGlyph.midX),\(mappedStart.y - startGlyph.midY)), character=\(page.characterIndex(at: mappedStart)), pageMatch=\(view.page(for: startPoint, nearest: false) === page), selection=\(selectedText ?? "nil"), characterReference=\(referenceText ?? "nil")")
            }
            page.rotation = 0
            view.autoScales = false; view.scaleFactor = 0.5; view.layoutDocumentView(); view.go(to: page)
            await settle(); view.layoutIfNeeded(); view.layoutDocumentView()
            guard let nextPage = document.page(at: 1),
                  let samePageReference = document.selection(from: page, atCharacterIndex: 0, to: page, atCharacterIndex: 12),
                  let crossPageReference = document.selection(from: page, atCharacterIndex: 0, to: nextPage, atCharacterIndex: 5),
                  let samePageSnapshot = PDFTextSelectionService.snapshot(of: samePageReference, in: document),
                  let crossPageSnapshot = PDFTextSelectionService.snapshot(of: crossPageReference, in: document) else {
                return (checks + 1, failures + ["Precise drag boundary fixtures require native character-index references."])
            }
            let firstCharacter = point(character: 0, on: page, in: view)
            let laterCharacter = point(character: 12, on: page, in: view)
            // Index 6 is the space after "Second". A reverse gesture must
            // start on the visible "d" at index 5, as a real native touch does.
            let nextPageCharacter = point(character: 5, on: nextPage, in: view)
            expect(adapter.beginSelection(at: firstCharacter) && adapter.updateSelection(to: laterCharacter, finished: true)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == samePageSnapshot,
                "Forward precise drag includes both touched glyphs and matches PDFKit's native character-index selection.")
            expect(adapter.beginSelection(at: laterCharacter) && adapter.updateSelection(to: firstCharacter, finished: true)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == samePageSnapshot,
                "Reverse same-page drag normalizes character order and keeps the first touched glyph.")
            expect(adapter.beginSelection(at: firstCharacter) && adapter.updateSelection(to: firstCharacter, finished: true)
                && view.currentSelection?.string == "O",
                "Dragging within one glyph preserves that exact character rather than an empty caret selection.")
            expect(adapter.beginSelection(at: firstCharacter) && adapter.updateSelection(to: nextPageCharacter, finished: true)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == crossPageSnapshot,
                "A forward cross-page drag includes both touched endpoint glyphs through real PDFKit selection.")
            await settle()
            expect(reportedSelection == crossPageSnapshot && reportedSelection?.pageNumbers == [1, 2],
                "Forward cross-page selection reports the same complete multi-page snapshot through the shared host callback.")
            expect(selectionPresentationMatchesCurrent(in: view, document: document)
                && view.highlightedSelections?.first.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == crossPageSnapshot,
                "The native blue display preserves the complete real cross-page selection ranges.")
            // PDFKit can update its viewport while publishing the forward
            // selection. A later native gesture uses coordinates from its own
            // event, so convert the same exact glyphs again after that await.
            view.layoutIfNeeded(); view.layoutDocumentView()
            let reverseStart = point(character: 5, on: nextPage, in: view)
            let reverseEnd = point(character: 0, on: page, in: view)
            let startPageMatches = view.page(for: reverseStart, nearest: false) === nextPage
            let endPageMatches = view.page(for: reverseEnd, nearest: true) === page
            let reverseStartPDF = view.convert(reverseStart, to: nextPage)
            let reverseEndPDF = view.convert(reverseEnd, to: page)
            let startCharacterBefore = nextPage.characterIndex(at: reverseStartPDF)
            let endCharacterBefore = page.characterIndex(at: reverseEndPDF)
            let actualStartGlyph = characterText(at: startCharacterBefore, on: nextPage)
            let actualEndGlyph = characterText(at: endCharacterBefore, on: page)
            let scaleBeforeReverse = view.scaleFactor
            let reverseBegan = adapter.beginSelection(at: reverseStart)
            let reverseActive = adapter.isSelecting
            let startCharacterAfter = nextPage.characterIndex(at: view.convert(reverseStart, to: nextPage))
            let reverseUpdated = adapter.updateSelection(to: reverseEnd, finished: true)
            let reverseSnapshot = view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) }
            expect(startPageMatches && endPageMatches && startCharacterBefore == 5 && endCharacterBefore == 0
                && actualStartGlyph == "d" && actualEndGlyph == "O"
                && reverseBegan && reverseUpdated && reverseSnapshot == crossPageSnapshot,
                "A reverse cross-page drag normalizes page and glyph order without losing either endpoint. begin=\(reverseBegan), active=\(reverseActive), update=\(reverseUpdated), startPageMatch=\(startPageMatches), endPageMatch=\(endPageMatches), startCharacter=\(startCharacterBefore)->\(startCharacterAfter), endCharacter=\(endCharacterBefore), startGlyph=\(actualStartGlyph == " " ? "<SPACE>" : String(reflecting: actualStartGlyph)), endGlyph=\(String(reflecting: actualEndGlyph)), scale=\(scaleBeforeReverse)->\(view.scaleFactor), start=\(reverseStart), end=\(reverseEnd), startPDF=\(reverseStartPDF), endPDF=\(reverseEndPDF), actual=\(selectionDescription(view.currentSelection, in: document)), expected=\(selectionDescription(crossPageReference, in: document))")
            await settle()
            expect(reportedSelection == crossPageSnapshot,
                "Reverse cross-page selection retains complete shared selection feedback.")
            let blankEndpoint = view.convert(CGPoint(x: 400, y: 300), from: page)
            expect(adapter.beginSelection(at: point(character: 0, on: page, in: view)) && adapter.updateSelection(to: blankEndpoint, finished: true)
                && view.currentSelection?.string?.contains("Orchard") == true,
                "A drag ending in page whitespace uses native caret resolution while retaining its real first glyph.")
            let glyphBounds = page.characterBounds(at: 0), cropBox = page.bounds(for: view.displayBox)
            let outsidePageEdge = view.convert(CGPoint(x: cropBox.minX - 20, y: glyphBounds.midY), from: page)
            expect(adapter.beginSelection(at: point(character: 0, on: page, in: view)) && adapter.updateSelection(to: outsidePageEdge, finished: true)
                && view.currentSelection?.string?.contains("O") == true && view.currentSelection?.pages.first === page,
                "An anchored drag may finish beyond a page edge through PDFKit's nearest-page conversion without losing selection.")

            // Public native-intent hooks exercise touch-down capture separately
            // from the later recognition point. No UITouch or recognizer state
            // is synthesized, and the origin may have no live touch reference.
            guard let nativePage = document.page(at: 2),
                  let nativeReference = document.selection(from: nativePage, atCharacterIndex: 36, to: nativePage, atCharacterIndex: 52),
                  let nativeSnapshot = PDFTextSelectionService.snapshot(of: nativeReference, in: document),
                  let priorNativeSelection = nativePage.selection(for: NSRange(location: 0, length: 10)),
                  let priorNativeSnapshot = PDFTextSelectionService.snapshot(of: priorNativeSelection, in: document) else {
                return (checks + 1, failures + ["Native-origin fixtures require visible real PDF glyphs 36 and 52."])
            }
            adapter.configure(mode: .selectText)
            view.go(to: nativePage); await settle(); view.layoutDocumentView()
            let nativeTouchTokens = [NSObject(), NSObject()]
            defer { withExtendedLifetime(nativeTouchTokens) {} }
            let firstTouchID = ObjectIdentifier(nativeTouchTokens[0]), secondTouchID = ObjectIdentifier(nativeTouchTokens[1])
            let originPoint = point(character: 36, on: nativePage, in: view)
            let recognitionPoint = point(character: 52, on: nativePage, in: view)
            let nativeAnnotations = annotationIdentities(in: document)
            let nativeRanges = selectionRanges(nativeReference, in: document)
            let originCaptured = adapter.captureNativeSelectionOrigin(at: originPoint, touchIdentifier: firstTouchID, touchType: .direct)
            let dragRecognized = adapter.beginNativeDrag(at: recognitionPoint)
            let dragFinished = adapter.updateNativeDrag(to: recognitionPoint, finished: true)
            expect(characterText(at: 36, on: nativePage) == "a" && characterText(at: 52, on: nativePage) == "q"
                && nativePage.bounds(for: view.displayBox).contains(nativePage.characterBounds(at: 36))
                && nativePage.bounds(for: view.displayBox).contains(nativePage.characterBounds(at: 52))
                && originCaptured && dragRecognized && dragFinished
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == nativeSnapshot
                && view.currentSelection.map { selectionRanges($0, in: document) } == nativeRanges
                && annotationIdentities(in: document) == nativeAnnotations,
                "A native drag recognized at its endpoint retains actual touch-down glyph 36 through endpoint 52 without translation or a live UITouch. capture=\(originCaptured), begin=\(dragRecognized), finish=\(dragFinished), actual=\(selectionDescription(view.currentSelection, in: document)), expected=\(selectionDescription(nativeReference, in: document))")
            expect(!adapter.beginNativeDrag(at: recognitionPoint)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == nativeSnapshot,
                "A completed native sequence consumes its origin; an endpoint alone cannot begin another range.")
            expect(adapter.captureNativeSelectionOrigin(at: recognitionPoint, touchIdentifier: firstTouchID, touchType: .direct)
                && adapter.beginNativeDrag(at: originPoint) && adapter.updateNativeDrag(to: originPoint, finished: true)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == nativeSnapshot
                && view.currentSelection.map { selectionRanges($0, in: document) } == nativeRanges,
                "Reverse native drag preserves both independently captured endpoint glyphs and exact PDFKit ranges.")
            view.setCurrentSelection(priorNativeSelection, animate: false)
            _ = adapter.captureNativeSelectionOrigin(at: originPoint, touchIdentifier: firstTouchID, touchType: .direct)
            adapter.cancelSelection(restoring: true)
            expect(!adapter.beginNativeDrag(at: recognitionPoint)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == priorNativeSnapshot,
                "Cancelling a pending native touch origin cannot create an endpoint-only range or replace the prior selection.")
            _ = adapter.captureNativeSelectionOrigin(at: originPoint, touchIdentifier: firstTouchID, touchType: .direct)
            let secondPendingTouchAccepted = adapter.captureNativeSelectionOrigin(at: recognitionPoint, touchIdentifier: secondTouchID, touchType: .direct)
            expect(!secondPendingTouchAccepted && !adapter.beginNativeDrag(at: recognitionPoint)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == priorNativeSnapshot,
                "A second accepted touch invalidates a pending native origin instead of overwriting the first anchor.")
            _ = adapter.captureNativeSelectionOrigin(at: originPoint, touchIdentifier: firstTouchID, touchType: .direct)
            let beganBeforeSecondTouch = adapter.beginNativeDrag(at: recognitionPoint)
            let secondActiveTouchAccepted = adapter.captureNativeSelectionOrigin(at: recognitionPoint, touchIdentifier: secondTouchID, touchType: .direct)
            expect(beganBeforeSecondTouch && !secondActiveTouchAccepted && !adapter.updateNativeDrag(to: recognitionPoint, finished: true)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == priorNativeSnapshot
                && view.currentSelection.map { selectionRanges($0, in: document) } == selectionRanges(priorNativeSelection, in: document),
                "A second touch cancels an active native range and restores the exact prior glyph ranges for two-finger navigation.")
            adapter.configure(mode: .read)
            let pencilOriginCaptured = adapter.captureNativeSelectionOrigin(at: originPoint, touchIdentifier: firstTouchID, touchType: .pencil)
            let excludedFingerAccepted = adapter.captureNativeSelectionOrigin(at: recognitionPoint, touchIdentifier: secondTouchID, touchType: .direct)
            expect(pencilOriginCaptured && !excludedFingerAccepted && adapter.beginNativeDrag(at: recognitionPoint)
                && adapter.updateNativeDrag(to: recognitionPoint, finished: true)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == nativeSnapshot,
                "Excluded reading-mode finger input preserves the captured Pencil anchor and its complete native range.")
            adapter.configure(mode: .selectText)
            _ = adapter.captureNativeSelectionOrigin(at: originPoint, touchIdentifier: firstTouchID, touchType: .direct)
            adapter.configure(mode: .read); adapter.configure(mode: .selectText)
            expect(!adapter.beginNativeDrag(at: recognitionPoint)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == nativeSnapshot,
                "Mode changes invalidate a pending native origin even after returning to the same selection mode.")
            _ = adapter.captureNativeSelectionOrigin(at: originPoint, touchIdentifier: firstTouchID, touchType: .direct)
            adapter.nativeNavigationDidBegin()
            expect(!adapter.beginNativeDrag(at: recognitionPoint)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == nativeSnapshot,
                "Native scroll or pinch initiation clears a pending touch origin before the viewport moves.")
            _ = adapter.captureNativeSelectionOrigin(at: originPoint, touchIdentifier: firstTouchID, touchType: .direct)
            let originalBounds = view.bounds
            view.bounds = originalBounds.offsetBy(dx: 1, dy: 0)
            expect(!adapter.beginNativeDrag(at: recognitionPoint)
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == nativeSnapshot,
                "A changed view transform fingerprint rejects the stale native origin without selecting its recognition endpoint.")
            view.bounds = originalBounds; view.layoutDocumentView(); await settle()
            let windowPageCount = document.pageCount
            let beforeWindowSnapshot = view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) }
            let beforeWindowRanges = view.currentSelection.map { selectionRanges($0, in: document) }
            expect(beforeWindowSnapshot == nativeSnapshot && beforeWindowRanges == nativeRanges,
                "Window-detach setup retains the exact committed native glyph ranges after viewport restoration. snapshotBool=\(beforeWindowSnapshot == nativeSnapshot), rangesBool=\(beforeWindowRanges == nativeRanges), actualRanges=\(beforeWindowRanges ?? []), expectedRanges=\(nativeRanges)")

            // A plain PDFView has no Reader Coordinator, focus proxy or display
            // mirror. Observe its real removal behavior without making a
            // preservation assumption about PDFKit's native window lifecycle.
            let rawWindowProbe = PDFView(frame: view.frame)
            controller.view.insertSubview(rawWindowProbe, belowSubview: view)
            rawWindowProbe.document = document; rawWindowProbe.autoScales = false; rawWindowProbe.scaleFactor = view.scaleFactor
            rawWindowProbe.layoutDocumentView(); rawWindowProbe.setCurrentSelection(nativeReference, animate: false)
            await settle()
            let rawBeforeSnapshot = rawWindowProbe.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) }
            let rawBeforeRanges = rawWindowProbe.currentSelection.map { selectionRanges($0, in: document) }
            let rawBeforeWindow = rawWindowProbe.window != nil
            expect(rawBeforeWindow && rawBeforeSnapshot == nativeSnapshot && rawBeforeRanges == nativeRanges,
                "The unobserved native window-detach control installs exact glyph ranges in the real fixture window. window=\(rawBeforeWindow), snapshotBool=\(rawBeforeSnapshot == nativeSnapshot), rangesBool=\(rawBeforeRanges == nativeRanges), actualRanges=\(rawBeforeRanges ?? []), expectedRanges=\(nativeRanges)")
            rawWindowProbe.removeFromSuperview()
            let rawImmediateSelectionIsNil = rawWindowProbe.currentSelection == nil
            let rawImmediateSnapshot = rawWindowProbe.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) }
            let rawImmediateRanges = rawWindowProbe.currentSelection.map { selectionRanges($0, in: document) }
            await settle()
            let rawSettledSelectionIsNil = rawWindowProbe.currentSelection == nil
            let rawSettledSnapshot = rawWindowProbe.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) }
            let rawSettledRanges = rawWindowProbe.currentSelection.map { selectionRanges($0, in: document) }
            let rawDocumentUnchanged = rawWindowProbe.document === document
            let rawWindowDetails = "windowBefore=\(rawBeforeWindow), windowAfter=\(rawWindowProbe.window != nil), beforeNil=\(rawBeforeSnapshot == nil), immediateNil=\(rawImmediateSelectionIsNil), settledNil=\(rawSettledSelectionIsNil), immediateSnapshotBool=\(rawImmediateSnapshot == rawBeforeSnapshot), settledSnapshotBool=\(rawSettledSnapshot == rawBeforeSnapshot), beforeRanges=\(rawBeforeRanges ?? []), immediateRanges=\(rawImmediateRanges ?? []), settledRanges=\(rawSettledRanges ?? []), documentBool=\(rawDocumentUnchanged), pageCountBool=\(document.pageCount == windowPageCount)"
            #if DEBUG
            NSLog("DogearReaderInput raw-window-detach-probe %@", rawWindowDetails)
            #endif
            rawWindowProbe.endEditing(true); rawWindowProbe.document = nil
            view.requestReaderFocus(allowPDFSelectionResponder: true)
            let actualBeforeRemoval = view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) }
            let rangesBeforeRemoval = view.currentSelection.map { selectionRanges($0, in: document) }
            let callbackBeforeRemoval = reportedSelection
            let callbackDocumentBeforeRemoval = reportedSelectionDocument
            let captureBeforeRemoval = adapter.captureNativeSelectionOrigin(at: point(character: 36, on: nativePage, in: view), touchIdentifier: firstTouchID, touchType: .direct)
            let hadWindowBeforeRemoval = view.window === window
            view.removeFromSuperview()
            let immediateSelectionIsNil = view.currentSelection == nil
            let immediateWindowSnapshot = view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) }
            let immediateWindowRanges = view.currentSelection.map { selectionRanges($0, in: document) }
            let beganAfterWindowRemoval = adapter.beginNativeDrag(at: recognitionPoint)
            let activeAfterWindowRemoval = adapter.isSelecting
            await settle()
            let settledSelectionIsNil = view.currentSelection == nil
            let settledWindowSnapshot = view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) }
            let settledWindowRanges = view.currentSelection.map { selectionRanges($0, in: document) }
            let windowDetails = "capture=\(captureBeforeRemoval), windowBefore=\(hadWindowBeforeRemoval), windowAfter=\(view.window != nil), begin=\(beganAfterWindowRemoval), active=\(activeAfterWindowRemoval), beforeNativeBool=\(actualBeforeRemoval == nativeSnapshot), immediateRawBool=\(immediateWindowSnapshot == rawImmediateSnapshot), settledRawBool=\(settledWindowSnapshot == rawSettledSnapshot), beforeNil=\(actualBeforeRemoval == nil), immediateNil=\(immediateSelectionIsNil), settledNil=\(settledSelectionIsNil), beforeRanges=\(rangesBeforeRemoval ?? []), immediateRanges=\(immediateWindowRanges ?? []), settledRanges=\(settledWindowRanges ?? []), expectedRanges=\(nativeRanges), callbackBeforeNativeBool=\(callbackBeforeRemoval == nativeSnapshot), callbackAfterRawBool=\(reportedSelection == rawSettledSnapshot), callbackDocumentBool=\(reportedSelectionDocument === document), documentBool=\(view.document === document), pageCountBool=\(document.pageCount == windowPageCount), annotationsBool=\(annotationIdentities(in: document) == nativeAnnotations), rawControl={\(rawWindowDetails)}"
            #if DEBUG
            NSLog("DogearReaderInput reader-window-detach-probe %@", windowDetails)
            #endif
            expect(captureBeforeRemoval && hadWindowBeforeRemoval && view.window == nil
                && !beganAfterWindowRemoval && !activeAfterWindowRemoval
                && actualBeforeRemoval == nativeSnapshot && actualBeforeRemoval == rawBeforeSnapshot
                && rangesBeforeRemoval == nativeRanges && rangesBeforeRemoval == rawBeforeRanges
                && immediateSelectionIsNil == rawImmediateSelectionIsNil && settledSelectionIsNil == rawSettledSelectionIsNil
                && immediateWindowSnapshot == rawImmediateSnapshot && settledWindowSnapshot == rawSettledSnapshot
                && immediateWindowRanges == rawImmediateRanges && settledWindowRanges == rawSettledRanges
                && callbackBeforeRemoval == nativeSnapshot && callbackDocumentBeforeRemoval === document
                && reportedSelection == rawSettledSnapshot && reportedSelectionDocument === document
                && rawDocumentUnchanged && view.document === document && store.document === document
                && document.pageCount == windowPageCount && annotationIdentities(in: document) == nativeAnnotations
                && !view.hasReaderKeyboardFocus && view.highlightedSelections?.isEmpty != false,
                "Leaving the native window invalidates Reader input and selection exactly like the unobserved PDFView, with the callback still owned by the unchanged document. \(windowDetails)")
            controller.view.addSubview(view); view.requestReaderFocus(); view.layoutDocumentView(); await settle()
            let reattachedEndpoint = point(character: 52, on: nativePage, in: view)
            let oldOriginBeganAfterReattach = adapter.beginNativeDrag(at: reattachedEndpoint)
            expect(view.window === window && view.document === document && !oldOriginBeganAfterReattach && !adapter.isSelecting
                && document.pageCount == windowPageCount && annotationIdentities(in: document) == nativeAnnotations,
                "Reattaching the same PDFView cannot revive its previous window's captured touch origin. begin=\(oldOriginBeganAfterReattach), active=\(adapter.isSelecting), documentBool=\(view.document === document)")
            let freshOriginCaptured = adapter.captureNativeSelectionOrigin(at: point(character: 36, on: nativePage, in: view),
                touchIdentifier: firstTouchID, touchType: .direct)
            let freshOriginBegan = adapter.beginNativeDrag(at: reattachedEndpoint)
            let freshOriginFinished = adapter.updateNativeDrag(to: reattachedEndpoint, finished: true)
            await settle()
            expect(freshOriginCaptured && freshOriginBegan && freshOriginFinished
                && view.currentSelection.flatMap { PDFTextSelectionService.snapshot(of: $0, in: document) } == nativeSnapshot
                && view.currentSelection.map { selectionRanges($0, in: document) } == nativeRanges
                && reportedSelection == nativeSnapshot && reportedSelectionDocument === document
                && view.document === document && document.pageCount == windowPageCount
                && annotationIdentities(in: document) == nativeAnnotations && selectionPresentationMatchesCurrent(in: view, document: document),
                "A fresh native touch after reattachment selects and reports exact glyphs 36 through 52 without changing pages or annotations. capture=\(freshOriginCaptured), begin=\(freshOriginBegan), finish=\(freshOriginFinished), actualRanges=\(view.currentSelection.map { selectionRanges($0, in: document) } ?? []), expectedRanges=\(nativeRanges)")
            _ = adapter.captureNativeSelectionOrigin(at: point(character: 36, on: nativePage, in: view), touchIdentifier: firstTouchID, touchType: .direct)
            let nativeReplacement = PDFDocument(data: data)!
            coordinator.install(nativeReplacement, in: view)
            expect(!adapter.beginNativeDrag(at: recognitionPoint) && view.currentSelection == nil,
                "Document installation rejects a captured origin belonging to the previous exact PDF document.")
            coordinator.install(document, in: view)
            view.autoScales = true; view.layoutDocumentView(); view.go(to: page)
            await settle()
            adapter.configure(mode: .addNote)
            for rotation in [0, 90, 180, 270] {
                page.rotation = rotation; view.autoScales = false; view.scaleFactor = 0.6
                view.layoutDocumentView(); view.go(to: page); await settle(); view.layoutIfNeeded(); await settle()
                let tap = view.convert(CGPoint(x: 300, y: 400), from: page)
                noteDraft = nil
                let placed = adapter.placeNote(at: tap)
                let draft = noteDraft
                let frame = draft.map { view.convert($0.annotation.bounds, from: page) }
                expect(placed && draft?.page === page && draft?.annotation.page == nil
                    && draft.map { page.bounds(for: .cropBox).contains($0.annotation.bounds) } == true
                    && frame.map { abs($0.minX - tap.x) < 0.01 && abs($0.minY - tap.y) < 0.01 } == true
                    && page.annotations.isEmpty,
                    "New-note placement aligns its displayed top-left with the native tap at rotation \(rotation) without creating an annotation. tap=\(tap), frame=\(String(describing: frame))")
            }
            page.rotation = 0; view.autoScales = true; view.layoutDocumentView(); view.go(to: page); await settle()
            let nearEdge = CGPoint(x: page.bounds(for: .cropBox).minX + 2, y: page.bounds(for: .cropBox).maxY - 2)
            expect(adapter.placeNote(at: view.convert(nearEdge, from: page)), "Pencil/finger/pointer note placement produces a common draft.")
            if let draft = noteDraft {
                expect(draft.isNew && draft.annotation.page == nil && page.bounds(for: .cropBox).contains(draft.annotation.bounds),
                    "A precise note remains detached and clamps its bounds inside the PDF page.")
                expect(page.annotations.isEmpty, "Cancelling the note editor needs no PDF rollback because placement alone creates no annotation.")
                var values = draft.values; values.text = "Pencil note 中文"
                undo.beginUndoGrouping(); let saved = store.saveFreeText(draft, values: values); undo.endUndoGrouping()
                expect(saved && draft.annotation.page === page && draft.annotation.type == "FreeText", "Explicit Save creates a standard FreeText through the shared Store.")
                undo.undo(); expect(draft.annotation.page == nil, "Precise note creation participates in shared Undo.")
                undo.redo(); expect(draft.annotation.page === page, "Precise note Redo restores annotation identity.")
            } else { expect(false, "The note-placement host must receive a detached draft.") }
            expect(!adapter.selectWord(at: CGPoint(x: -100, y: -100)), "An out-of-page Pencil tap cannot invent selected text.")
            adapter.configure(mode: .read)
            let currentBegin = point(character: 0, on: page, in: view)
            let currentEnd = point(character: 12, on: page, in: view)
            _ = adapter.beginSelection(at: currentBegin)
            document.removePage(at: 0)
            expect(!adapter.updateSelection(to: currentEnd, finished: true), "Page removal invalidates the active input transaction.")
            document.insert(page, at: 0)
            let replacement = PDFDocument(data: data)!
            view.layoutDocumentView(); view.go(to: page)
            let restoredBegin = point(character: 0, on: page, in: view)
            coordinator.onUserInteraction = {
                interactions += 1; coordinator.install(replacement, in: view)
            }
            expect(!adapter.selectWord(at: restoredBegin) && view.currentSelection == nil,
                "A synchronous document switch during user interaction rejects an old word selection.")
            expect(view.highlightedSelections?.isEmpty != false,
                "Synchronous document replacement cannot retain an old document's blue selection display.")
            coordinator.install(document, in: view); view.layoutDocumentView(); view.go(to: page)
            expect(!adapter.beginSelection(at: point(character: 0, on: page, in: view)) && !adapter.isSelecting,
                "A synchronous document switch cannot begin a transaction against the old PDF.")
            coordinator.install(document, in: view); view.layoutDocumentView(); view.go(to: page)
            adapter.configure(mode: .addNote); noteDraft = nil
            expect(!adapter.placeNote(at: view.convert(nearEdge, from: page)) && noteDraft == nil,
                "A synchronous document switch cannot publish an old note-placement draft.")
            coordinator.install(document, in: view); view.layoutDocumentView(); view.go(to: page)
            adapter.configure(mode: .read); page.addAnnotation(annotation)
            expect(!coordinator.activateAnnotation(at: view.convert(CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY), from: page)),
                "Annotation activation revalidates document identity after interaction revokes an old lease.")
            coordinator.install(document, in: view); view.layoutDocumentView(); view.go(to: page)
            view.requestReaderFocus()
            let keysBeforeReplacement = keyboardCommands.count
            expect(!coordinator.performKeyboardCommand(.addHighlight, in: view)
                && keyboardCommands.count == keysBeforeReplacement,
                "Keyboard dispatch rejects its captured document if the interaction callback replaces it.")
            page.removeAnnotation(annotation)
            coordinator.onUserInteraction = { interactions += 1 }
            coordinator.install(replacement, in: view)
            expect(!adapter.updateSelection(to: currentEnd, finished: true), "Document replacement cannot publish an old Pencil selection.")
            let replacementPage = replacement.page(at: 0)!
            view.layoutDocumentView(); view.go(to: replacementPage)
            view.setCurrentSelection(replacementPage.selection(for: NSRange(location: 0, length: 7)), animate: false)
            await settle()
            view.synchronizeSelectionPresentation(in: document)
            expect(selectionPresentationMatchesCurrent(in: view, document: replacement),
                "A stale presentation request cannot erase or recolor a newer document's native selection display.")
            _ = adapter.beginSelection(at: point(character: 0, on: replacementPage, in: view))
            adapter.configure(mode: .addNote); adapter.configure(mode: .read)
            expect(!adapter.updateSelection(to: point(character: 12, on: replacementPage, in: view), finished: true),
                "Switching modes away and back cannot finish an earlier touch sequence.")
            let detachedScrollPans = nativeGestures(in: view).compactMap { gesture -> UIPanGestureRecognizer? in
                guard let scroll = gesture.view as? UIScrollView, gesture === scroll.panGestureRecognizer else { return nil }
                return gesture as? UIPanGestureRecognizer
            }
            let detachedMinimums = detachedScrollPans.map(\.minimumNumberOfTouches)
            adapter.configure(mode: .selectText)
            await settle(); view.layoutDocumentView()
            let capturedBeforeDetach = adapter.captureNativeSelectionOrigin(at: point(character: 0, on: replacementPage, in: view),
                touchIdentifier: firstTouchID, touchType: .direct)
            coordinator.detach()
            expect(!adapter.placeNote(at: begin) && !adapter.beginSelection(at: begin), "Detached input cannot emit note or selection intent.")
            expect(capturedBeforeDetach && !adapter.beginNativeDrag(at: begin),
                "Detaching invalidates a captured native touch origin before any later recognizer callback can consume it.")
            expect(detachedScrollPans.map(\.minimumNumberOfTouches) == detachedMinimums && !view.hasReaderKeyboardFocus,
                "Detaching restores native scrolling policy and relinquishes Reader focus.")
            expect(view.highlightedSelections?.isEmpty != false,
                "Detaching explicitly removes the view-owned selection display copy.")
            expect(interactions > 0, "Direct input revokes delayed Research navigation through the existing interaction callback.")
            await queue.drain(); await settle()
            expect(try Data(contentsOf: url) == data, "Input, standard annotation saves and Undo preserve the original PDF bytes.")
        } catch { expect(false, "Input fixture failed: \(error.localizedDescription)") }
        return (checks, failures)
    }

    private static func point(character index: Int, on page: PDFPage, in view: PDFView) -> CGPoint {
        let bounds = page.characterBounds(at: index)
        return view.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: page)
    }
    private static func selectionPresentationMatchesCurrent(in view: PDFView, document: PDFDocument) -> Bool {
        guard view.document === document, let current = view.currentSelection,
              let displayed = view.highlightedSelections, displayed.count == 1,
              let copy = displayed.first, copy !== current,
              let currentSnapshot = PDFTextSelectionService.snapshot(of: current, in: document),
              let displayedSnapshot = PDFTextSelectionService.snapshot(of: copy, in: document) else { return false }
        return currentSnapshot == displayedSnapshot
            && copy.color == UIColor.systemBlue.withAlphaComponent(0.28)
    }
    private static func selectionRanges(_ selection: PDFSelection, in document: PDFDocument) -> [String] {
        selection.pages.map { page in
            let ranges = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
            return "page=\(document.index(for: page)), ranges=\(ranges)"
        }
    }
    private static func annotationIdentities(in document: PDFDocument) -> [[ObjectIdentifier]] {
        (0..<document.pageCount).map { document.page(at: $0)?.annotations.map(ObjectIdentifier.init) ?? [] }
    }
    private static func selectionIdentity(_ selection: PDFSelection?) -> String {
        selection.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
    }
    private static func colorDescription(_ color: UIColor?) -> String {
        color.map { String(describing: $0) } ?? "nil"
    }
    private static func nativeGestures(in view: UIView) -> [UIGestureRecognizer] {
        (view.gestureRecognizers ?? []) + view.subviews.flatMap { nativeGestures(in: $0) }
    }
    private static func settle() async {
        for _ in 0..<3 { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    private static func focusDescription(in view: UIView) -> String {
        if view.isFirstResponder {
            return "firstResponder=\(type(of: view)), keyWindow=\(view.window?.isKeyWindow ?? false)"
        }
        for child in view.subviews {
            let result = focusDescription(in: child)
            if !result.isEmpty { return result }
        }
        return ""
    }
    private static func selectionDescription(_ selection: PDFSelection?, in document: PDFDocument) -> String {
        guard let selection else { return "nil" }
        let ranges = selection.pages.map { page in
            let pageRanges = (0..<selection.numberOfTextRanges(on: page)).map { selection.range(at: $0, on: page) }
            return "page\(document.index(for: page)):\(pageRanges)"
        }.joined(separator: ",")
        return "text=\(String(reflecting: selection.string)), ranges=[\(ranges)]"
    }
    private static func characterText(at index: Int, on page: PDFPage) -> String? {
        guard let string = page.string else { return nil }
        let text = string as NSString
        guard index != NSNotFound, index >= 0, index < text.length else { return nil }
        return text.substring(with: NSRange(location: index, length: 1))
    }
    private static func fixtureData() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).pdfData { context in
            for (index, text) in ["Orchard findings confirm apple roots.", "Second page selection.",
                                  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"].enumerated() {
                context.beginPage()
                let font = index == 2 ? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular) : UIFont.systemFont(ofSize: 24)
                (text as NSString).draw(at: CGPoint(x: 60, y: 70), withAttributes: [.font: font, .foregroundColor: UIColor.black])
            }
        }
    }
}
#endif
