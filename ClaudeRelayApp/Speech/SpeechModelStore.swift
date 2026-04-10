import Foundation
import WhisperKit

/// Manages model downloads, caching, and disk lifecycle for the speech pipeline.
@MainActor
final class SpeechModelStore: ObservableObject {

    static let shared = SpeechModelStore()

    @Published private(set) var whisperReady = false
    @Published private(set) var llmDownloaded = false
    @Published private(set) var downloadProgress: Double?

    private static let whisperReadyKey = "speechModelStore.whisperDownloaded"

    /// HuggingFace URL for the Qwen 3.5 0.8B Q4_K_M GGUF model.
    private static let llmModelURL = URL(
        string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf"
    )!

    private static let llmFileName = "qwen35-0.8b-q4km.gguf"

    var modelsReady: Bool { whisperReady && llmDownloaded }

    // MARK: - Paths

    /// Base directory for speech models: <AppSupport>/Models/
    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Models", isDirectory: true)
    }

    /// Path to the LLM GGUF file on disk.
    var llmModelPath: URL {
        modelsDirectory.appendingPathComponent(Self.llmFileName)
    }

    // MARK: - Init

    private init() {
        llmDownloaded = FileManager.default.fileExists(atPath: llmModelPath.path)
        whisperReady = UserDefaults.standard.bool(forKey: Self.whisperReadyKey)
    }

    // MARK: - Download

    /// Download both models. Updates `downloadProgress` during the process.
    func downloadAllModels() async throws {
        downloadProgress = 0.0

        // Phase 1: Whisper model (WhisperKit handles its own download + CoreML compilation)
        downloadProgress = 0.1
        _ = try await WhisperKit(
            model: "openai_whisper-small.en",
            verbose: false,
            prewarm: true
        )
        whisperReady = true
        UserDefaults.standard.set(true, forKey: Self.whisperReadyKey)
        downloadProgress = 0.5

        // Phase 2: LLM GGUF download (if not already on disk)
        if !llmDownloaded {
            try await downloadLLMModel()
        }
        llmDownloaded = true

        downloadProgress = 1.0
        try? await Task.sleep(for: .milliseconds(500))
        downloadProgress = nil
    }

    /// Download the LLM GGUF file from HuggingFace using URLSession.
    private func downloadLLMModel() async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        // Use URLSession download task for large file
        let (tempURL, response) = try await URLSession.shared.download(from: Self.llmModelURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModelStoreError.downloadFailed
        }

        // Move temp file to final location
        let destination = llmModelPath
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)

        // Exclude from iCloud backup
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDest = destination
        try mutableDest.setResourceValues(resourceValues)
    }

    /// Delete all downloaded models to free disk space.
    func deleteModels() {
        try? FileManager.default.removeItem(at: modelsDirectory)
        whisperReady = false
        llmDownloaded = false
        UserDefaults.standard.removeObject(forKey: Self.whisperReadyKey)
    }

    /// Total bytes used by models on disk.
    var totalModelSize: Int64 {
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else { return 0 }
        let enumerator = FileManager.default.enumerator(at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}

enum ModelStoreError: Error, LocalizedError {
    case downloadFailed
    case insufficientDiskSpace

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "Failed to download speech model"
        case .insufficientDiskSpace: return "Not enough storage for speech models (~1 GB required)"
        }
    }
}
