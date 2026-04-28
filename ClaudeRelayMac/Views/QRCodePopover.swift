import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

struct QRCodePopover: View {
    let sessionId: UUID
    let sessionName: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(sessionName ?? String(sessionId.uuidString.prefix(8)))
                .font(.headline)
            if let image = generateQRCode() {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
            } else {
                Text("Failed to generate QR code")
                    .foregroundStyle(.red)
            }
            Text("clauderelay://session/\(sessionId.uuidString)")
                .font(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(16)
        .frame(width: 260)
    }

    private func generateQRCode() -> NSImage? {
        let urlString = "clauderelay://session/\(sessionId.uuidString)"
        guard let data = urlString.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = ciImage.transformed(by: scale)

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: scaled.extent.size)
    }
}
