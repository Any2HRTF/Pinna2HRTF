import AppKit
import Combine
import SwiftUI

@MainActor
protocol EditorDocument: ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    var undoManager: EditorUndoManager { get }
    var hasUnsavedChanges: Bool { get }
    var canSaveDocument: Bool { get }
    var isSaving: Bool { get }
    func saveDocument() async -> Bool
    func closeDocument()
}

final class EditorUndoManager: UndoManager {
    var isSuspended = false
    override var canUndo: Bool { !isSuspended && super.canUndo }
    override var canRedo: Bool { !isSuspended && super.canRedo }
    override func undo() { if !isSuspended { super.undo() } }
    override func redo() { if !isSuspended { super.redo() } }
}

struct EditorWindowActions {
    let save: () -> Void
    let close: () -> Void
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [EditorWindowController] = []

    let requestID: UUID
    private let editorDocument: any EditorDocument
    private let closed: () -> Void
    private var documentChanges: AnyCancellable?
    private var closeConfirmed = false
    private var reviewCompletion: ((Bool) -> Void)?

    static var hasOpenEditors: Bool { !openControllers.isEmpty }
    static var isSavingAny: Bool { openControllers.contains { $0.editorDocument.isSaving } }
    static var hasUnsavedChanges: Bool { openControllers.contains { $0.editorDocument.hasUnsavedChanges } }

    static func present<Document: EditorDocument, Content: View>(
        requestID: UUID, title: String, subtitle: String, autosaveName: String,
        document: @autoclosure () -> Document,
        content: (Document, EditorWindowActions) -> Content,
        closed: @escaping () -> Void
    ) {
        if let existing = openControllers.first(where: { $0.requestID == requestID }) {
            existing.showWindow(nil)
            return
        }
        let document = document()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.subtitle = subtitle
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 960, height: 560)
        let controller = EditorWindowController(window: window, requestID: requestID, document: document, closed: closed)
        let hosting = NSHostingController(rootView: content(document, EditorWindowActions(
            save: { [weak controller] in controller?.saveAndClose() },
            close: { [weak controller] in controller?.window?.performClose(nil) })))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1180, height: 780))
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
        openControllers.append(controller)
        controller.showWindow(nil)
    }

    static func revealOpenEditors() {
        openControllers.forEach { $0.showWindow(nil) }
    }

    static func discardAll() {
        for controller in openControllers {
            controller.closeConfirmed = true
            controller.window?.close()
        }
    }

    static func reviewAll(completion: @escaping (Bool) -> Void) {
        guard let next = openControllers.first else { completion(true); return }
        next.reviewAndClose { closed in
            if closed { reviewAll(completion: completion) } else { completion(false) }
        }
    }

    private init(window: NSWindow, requestID: UUID, document: any EditorDocument, closed: @escaping () -> Void) {
        self.requestID = requestID
        self.editorDocument = document
        self.closed = closed
        super.init(window: window)
        window.delegate = self
        documentChanges = document.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateEditedState() }
    }

    required init?(coder: NSCoder) { fatalError("Use present(requestID:title:subtitle:autosaveName:document:content:closed:)") }

    private func updateEditedState() {
        window?.isDocumentEdited = editorDocument.hasUnsavedChanges
    }

    private func saveAndClose() {
        guard editorDocument.canSaveDocument else { NSSound.beep(); return }
        Task {
            if await editorDocument.saveDocument() {
                closeConfirmed = true
                window?.close()
            }
        }
    }

    private func reviewAndClose(completion: @escaping (Bool) -> Void) {
        guard let window else { completion(true); return }
        showWindow(nil)
        reviewCompletion = completion
        if windowShouldClose(window) { window.close() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if editorDocument.isSaving || (!closeConfirmed && sender.attachedSheet != nil) {
            NSSound.beep()
            finishReview(closed: false)
            return false
        }
        if closeConfirmed || !editorDocument.hasUnsavedChanges { return true }
        let alert = NSAlert()
        let canSave = editorDocument.canSaveDocument
        if canSave {
            alert.messageText = "Save changes before closing?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
        } else {
            alert.messageText = "Discard unsaved changes?"
            alert.informativeText = "Your changes will be lost."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
        }
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch (canSave, response) {
            case (true, .alertFirstButtonReturn):
                Task {
                    if await self.editorDocument.saveDocument() {
                        self.closeConfirmed = true
                        self.window?.close()
                    } else {
                        self.finishReview(closed: false)
                    }
                }
            case (true, .alertThirdButtonReturn), (false, .alertSecondButtonReturn):
                self.closeConfirmed = true
                self.window?.close()
            default:
                self.finishReview(closed: false)
            }
        }
        return false
    }

    private func finishReview(closed: Bool) {
        let completion = reviewCompletion
        reviewCompletion = nil
        completion?(closed)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editorDocument.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        documentChanges = nil
        editorDocument.undoManager.removeAllActions()
        editorDocument.closeDocument()
        Self.openControllers.removeAll { $0 === self }
        closed()
        DispatchQueue.main.async { withExtendedLifetime(self) { self.window?.contentViewController = nil } }
        finishReview(closed: true)
    }
}
