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

    /// HuggingFace URL for the Gemma 2 2B IT Q4_K_M GGUF model.
    private static let llmModelURL = URL(
        string: "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf"
    )!

    private static let llmFileName = "gemma-2-2b-it-q4km.gguf"

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
    /// Progress range: Whisper 0.0–0.5, LLM 0.5–1.0.
    func downloadAllModels() async throws {
        downloadProgress = 0.0

        // Phase 1: Whisper model — download with progress, then load
        let whisperFolder = try await WhisperKit.download(
            variant: "openai_whisper-small.en",
            progressCallback: { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress.fractionCompleted * 0.5
                }
            }
        )
        // Load from the downloaded folder (skip re-download)
        _ = try await WhisperKit(
            modelFolder: whisperFolder.path,
            verbose: false,
            prewarm: true,
            download: false
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

    /// Download the LLM GGUF file from HuggingFace with progress reporting.
    private func downloadLLMModel() async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let destination = llmModelPath
        let (tempURL, response) = try await downloadWithProgress(
            from: Self.llmModelURL,
            progressHandler: { [weak self] fraction in
                self?.downloadProgress = 0.5 + fraction * 0.5
            }
        )

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModelStoreError.downloadFailed
        }

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

    /// Download a file using a delegate-based URLSession to get progress updates.
    private func downloadWithProgress(
        from url: URL,
        progressHandler: @MainActor @escaping (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let delegate = DownloadProgressDelegate(progressHandler: progressHandler)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(from: url)

        // URLSession may delete the temp file after returning, so move to a safe location
        let safeTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: tempURL, to: safeTempURL)

        return (safeTempURL, response)
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

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let progressHandler: @MainActor (Double) -> Void

    init(progressHandler: @MainActor @escaping (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let handler = progressHandler
        Task { @MainActor in handler(fraction) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Required by protocol; actual file handling is done in the async caller.
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
