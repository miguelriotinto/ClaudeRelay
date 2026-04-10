import AVFoundation

/// Captures microphone audio and accumulates a 16kHz mono Float32 buffer.
/// Not an actor — must be called from @MainActor (OnDeviceSpeechEngine).
final class AudioCaptureSession {

    private let audioEngine = AVAudioEngine()
    private var buffer: [Float] = []
    private(set) var isRecording = false

    /// Minimum recording duration in seconds to avoid empty transcriptions.
    static let minimumDuration: TimeInterval = 0.5

    private var recordingStart: Date?

    /// Configure audio session, install tap on input node, start engine.
    func start() throws {
        guard !isRecording else { return }
        buffer.removeAll()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16kHz mono Float32 (WhisperKit requirement)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatCreationFailed
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] pcmBuffer, _ in
            guard let self else { return }
            self.convert(buffer: pcmBuffer, using: converter, targetFormat: targetFormat)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recordingStart = Date()
        isRecording = true
    }

    /// Stop engine, deactivate audio session, return accumulated buffer.
    /// Returns nil if recording was shorter than `minimumDuration`.
    func stop() -> [Float]? {
        guard isRecording else { return nil }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )

        // Guard against empty/too-short recordings
        if let start = recordingStart,
           Date().timeIntervalSince(start) < Self.minimumDuration {
            buffer.removeAll()
            return nil
        }

        let result = buffer
        buffer.removeAll()
        return result
    }

    // MARK: - Private

    private func convert(
        buffer pcmBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let frameCount = AVAudioFrameCount(
            Double(pcmBuffer.frameLength) * 16000.0 / pcmBuffer.format.sampleRate
        )
        guard frameCount > 0,
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
        else { return }

        var error: NSError?
        var hasData = true
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return pcmBuffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        if error == nil, let channelData = convertedBuffer.floatChannelData {
            let samples = Array(UnsafeBufferPointer(
                start: channelData[0],
                count: Int(convertedBuffer.frameLength)
            ))
            self.buffer.append(contentsOf: samples)
        }
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case formatCreationFailed
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed: return "Failed to create 16kHz audio format"
        case .converterCreationFailed: return "Failed to create audio converter"
        }
    }
}
