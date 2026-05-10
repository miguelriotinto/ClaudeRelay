import Foundation

public protocol ClipboardService: Sendable {
    func pasteImage(_ imageData: Data) -> Bool
}
