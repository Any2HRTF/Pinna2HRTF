import AppKit
import SwiftUI

/// Owns a resizable editor window for the lifetime of its request.
struct EditorWindow<Request: Identifiable>: NSViewRepresentable {
    @Binding var request: Request?
    let title: String
    let content: (Request, @escaping () -> Void, @escaping (Bool) -> Void) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onClose = { request = nil }
        guard let request else {
            coordinator.window?.close()
            return
        }
        guard coordinator.window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = coordinator
        window.contentView = NSHostingView(rootView: content(request, {
            coordinator.window?.close()
        }, { coordinator.busy = $0 }))
        coordinator.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var window: NSWindow?
        var busy = false
        var onClose: (() -> Void)?
        func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
        func windowWillClose(_ notification: Notification) {
            window?.contentView = nil
            window = nil
            busy = false
            onClose?()
        }
    }
}
