import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Protocol used by the engine to receive streaming audio.
/// The real implementation wraps AVAudioEngine; tests can substitute a no-op.
public protocol StreamingAudioSourcing: AnyObject, Sendable {
    /// Set the callback that receives 16 kHz mono Float32 chunks.
    /// The source may emit larger chunks if the hardware delivers larger
    /// buffers; callers should handle any size.
    var onChunk: ((@Sendable ([Float]) -> Void))? { get set }

    func start() throws
    func stop()
}

/// Error cases for audio source setup.
public enum StreamingAudioSourceError: Error, LocalizedError {
    case formatCreationFailed
    case converterCreationFailed

    public var errorDescription: String? {
        switch self {
        case .formatCreationFailed:   return "Failed to create 16 kHz target audio format"
        case .converterCreationFailed: return "Failed to create audio format converter"
        }
    }
}

/// Production audio source backed by AVAudioEngine. Configures a 16 kHz
/// mono Float32 tap on the hardware input node and forwards chunks to
/// the engine via `onChunk`.
public final class StreamingAudioSource: StreamingAudioSourcing, @unchecked Sendable {

    public var onChunk: ((@Sendable ([Float]) -> Void))?

    private let audioEngine = AVAudioEngine()
    private var isRunning = false

    public init() {}

    public func start() throws {
        guard !isRunning else { return }

        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let input = audioEngine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw StreamingAudioSourceError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw StreamingAudioSourceError.converterCreationFailed
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] pcmBuffer, _ in
            guard let self else { return }
            let samples = Self.convert(pcmBuffer, using: converter, targetFormat: targetFormat)
            if !samples.isEmpty {
                self.onChunk?(samples)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false

        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        #endif
    }

    // MARK: - Private

    static func convert(
        _ pcmBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> [Float] {
        let frameCount = AVAudioFrameCount(
            Double(pcmBuffer.frameLength) * 16000.0 / pcmBuffer.format.sampleRate
        )
        guard frameCount > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
        else { return [] }

        var hasData = true
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return pcmBuffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard error == nil, let channelData = converted.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(converted.frameLength)
        ))
    }
}
