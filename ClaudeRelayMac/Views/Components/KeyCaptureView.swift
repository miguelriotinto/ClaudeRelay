import SwiftUI
import AppKit

struct KeyCaptureView: NSViewRepresentable {
    @Binding var capturedModifiers: NSEvent.ModifierFlags
    @Binding var capturedKey: String
    @Binding var isCapturing: Bool
    var onCommit: (NSEvent.ModifierFlags, String) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        if isCapturing {
            nsView.startCapturing()
        } else {
            nsView.stopCapturing()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: KeyCaptureDelegate {
        let parent: KeyCaptureView
        private var lastModifiers: NSEvent.ModifierFlags = []
        private var lastKey: String = ""

        init(_ parent: KeyCaptureView) {
            self.parent = parent
        }

        func keysChanged(modifiers: NSEvent.ModifierFlags, key: String) {
            lastModifiers = modifiers
            lastKey = key
            parent.capturedModifiers = modifiers
            parent.capturedKey = key
        }

        func committed() {
            guard !lastModifiers.isEmpty else {
                parent.isCapturing = false
                return
            }
            parent.onCommit(lastModifiers, lastKey)
            parent.isCapturing = false
        }
    }
}

protocol KeyCaptureDelegate: AnyObject {
    func keysChanged(modifiers: NSEvent.ModifierFlags, key: String)
    func committed()
}

final class KeyCaptureNSView: NSView {
    weak var delegate: KeyCaptureDelegate?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var currentModifiers: NSEvent.ModifierFlags = []
    private var currentKey: String = ""

    override var acceptsFirstResponder: Bool { true }

    func startCapturing() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return nil
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    func stopCapturing() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        currentModifiers = []
        currentKey = ""
    }

    private func handleKeyDown(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        currentModifiers = mods
        currentKey = key
        delegate?.keysChanged(modifiers: mods, key: key)
        delegate?.committed()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        currentModifiers = mods
        if mods.isEmpty && !currentKey.isEmpty {
            delegate?.committed()
            currentKey = ""
        } else {
            delegate?.keysChanged(modifiers: mods, key: currentKey)
        }
    }

    deinit {
        stopCapturing()
    }
}
