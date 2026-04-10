import Foundation
import Speech
import AVFoundation

@MainActor
final class LegacySpeechRecognizer: ObservableObject {

    // MARK: - Published State

    @Published var isRecording = false
    @Published var permissionError: PermissionError?

    enum PermissionError: Identifiable {
        case microphoneDenied
        case speechDenied
        case unavailable

        var id: Self { self }
    }

    // MARK: - Private State

    private let speechRecognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var lastSentText = ""
    private var onInput: ((Data) -> Void)?

    // MARK: - Start / Stop

    func startRecording(onInput: @escaping (Data) -> Void) {
        guard !isRecording else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            permissionError = .unavailable
            return
        }

        self.onInput = onInput

        Task {
            // Request microphone permission
            let micAllowed = await AVAudioApplication.requestRecordPermission()
            guard micAllowed else {
                permissionError = .microphoneDenied
                return
            }

            // Request speech recognition permission
            let speechStatus = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status)
                }
            }
            guard speechStatus == .authorized else {
                permissionError = .speechDenied
                return
            }

            do {
                try beginRecognition()
            } catch {
                cleanUp()
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        cleanUp()
    }

    // MARK: - Recognition Pipeline

    private func beginRecognition() throws {
        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Create recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        // Install audio tap
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        // Start recognition task
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let newText = result.bestTranscription.formattedString
                    self.applyDiff(newText: newText)
                }

                if error != nil || result?.isFinal == true {
                    self.cleanUp()
                }
            }
        }

        lastSentText = ""
        isRecording = true
    }

    // MARK: - Diff Algorithm

    private func applyDiff(newText: String) {
        let commonLen = zip(lastSentText, newText).prefix(while: { $0 == $1 }).count
        let charsToErase = lastSentText.count - commonLen
        let newSuffix = String(newText.dropFirst(commonLen))

        var bytes = Data(repeating: 0x7F, count: charsToErase)
        bytes.append(Data(newSuffix.utf8))

        if !bytes.isEmpty {
            onInput?(bytes)
        }

        lastSentText = newText
    }

    // MARK: - Cleanup

    private func cleanUp() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        lastSentText = ""
        onInput = nil
        isRecording = false

        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }
}
