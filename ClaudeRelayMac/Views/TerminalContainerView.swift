import SwiftUI
import SwiftTerm
import AppKit
import ClaudeRelayClient

/// Wraps a SwiftTerm TerminalView and intercepts Cmd+V to handle image paste.
final class PasteAwareTerminalView: TerminalView {

    /// Callback when an image was found on the pasteboard and handled.
    var onImagePaste: ((Data) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.png, .tiff, .fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.png, .tiff, .fileURL])
    }

    override func paste(_ sender: Any) {
        // If the clipboard holds an image, handle it specially.
        if let pngData = ImagePasteHandler.extractFromPasteboard() {
            onImagePaste?(pngData)
            return
        }
        // Otherwise, fall through to SwiftTerm's default text paste.
        super.paste(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.availableType(from: [.png, .tiff, .fileURL]) != nil {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        // Direct image data first.
        if let pngData = ImagePasteHandler.extractFromPasteboard(pasteboard) {
            onImagePaste?(pngData)
            return true
        }

        // File URLs: look for image extensions.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let pngData = ImagePasteHandler.convertFileToPNG(at: url) {
                    onImagePaste?(pngData)
                    return true
                }
            }
        }
        return false
    }
}

struct TerminalContainerView: NSViewRepresentable {
    @ObservedObject var viewModel: TerminalViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> PasteAwareTerminalView {
        let terminal = PasteAwareTerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.onImagePaste = { [weak viewModel] data in
            viewModel?.sendPasteImage(data)
        }

        // Appearance: black chrome to match iOS app.
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white
        terminal.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        // Feed buffered output through the ViewModel.
        viewModel.onTerminalOutput = { [weak terminal] data in
            guard let terminal else { return }
            let bytes = Array(data)
            terminal.feed(byteArray: bytes[...])
        }

        viewModel.terminalReady()

        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }

        return terminal
    }

    func updateNSView(_ nsView: PasteAwareTerminalView, context: Context) {
        // No-op — updates are driven by the ViewModel callbacks.
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, TerminalViewDelegate {
        let viewModel: TerminalViewModel

        init(viewModel: TerminalViewModel) {
            self.viewModel = viewModel
        }

        // Called by SwiftTerm when the user types or pastes.
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { @MainActor [viewModel] in
                viewModel.sendInput(bytes)
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols > 0, newRows > 0 else { return }
            let cols = UInt16(newCols)
            let rows = UInt16(newRows)
            Task { @MainActor [viewModel] in
                viewModel.sendResize(cols: cols, rows: rows)
                viewModel.terminalReady()
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            Task { @MainActor [viewModel] in
                viewModel.terminalTitle = title
                viewModel.onTitleChanged?(title)
            }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Not used.
        }

        func scrolled(source: TerminalView, position: Double) {
            // Not used.
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let str = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            }
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            // Not used.
        }
    }
}
