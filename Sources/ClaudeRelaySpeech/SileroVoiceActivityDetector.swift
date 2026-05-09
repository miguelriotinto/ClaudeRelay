import Foundation
import CoreML

/// CoreML-backed voice activity detector wrapping the Silero VAD SE-trained
/// model (MUSAN-trained, 86.47% accuracy). Composes with
/// `VoiceActivityDetector`'s hysteresis + debounce state machine by feeding
/// Silero's probability output as the "energy" signal.
///
/// The bundled CoreML model is stateless per call and expects a 512-sample
/// Float32 chunk (32 ms at 16 kHz). This wrapper buffers incoming variable-size
/// chunks from the audio tap, runs inference as 512-sample windows become
/// available, and re-uses the most recent probability for chunks that don't
/// contain a full window.
///
/// Falls back gracefully: if the bundled model fails to load, the init
/// returns nil and callers (e.g. `ContinuousListeningEngine.makeDefault`)
/// substitute the baseline energy-based detector.
public final class SileroVoiceActivityDetector: VoiceActivityDetecting, @unchecked Sendable {

    /// Chunk size expected by the Silero CoreML model.
    public static let chunkSamples = 512

    private let inner: VoiceActivityDetector
    private let model: MLModel

    /// Residual samples not yet consumed by a 512-sample inference window.
    /// Lives here (not in the audio buffer) because we may accumulate across
    /// many small tap chunks before a window is ready.
    private var residual: [Float] = []

    /// Last probability produced by the model, reused when `process(chunk:)`
    /// is called with fewer than 512 residual+input samples.
    private var lastProbability: Float = 0.0

    public convenience init?(config: VoiceActivityDetector.Config = .init()) {
        guard let url = Bundle.module.url(forResource: "SileroVAD", withExtension: "mlmodelc"),
              let loaded = try? MLModel(contentsOf: url) else {
            return nil
        }
        self.init(model: loaded, config: config)
    }

    init(model: MLModel, config: VoiceActivityDetector.Config) {
        self.model = model
        var cfg = config
        // Probability output is 0–1; reuse the base debounce state machine
        // unchanged, but with thresholds tuned for Silero's typical output
        // distribution rather than RMS energy.
        cfg.speechThreshold = 0.5
        cfg.silenceThreshold = 0.35
        // Base class uses chunkDurationSeconds only for debounce math (to
        // translate min-speech/silence durations into chunk counts). Leaving
        // it at the incoming-tap-chunk duration keeps debounce timing in
        // real-world seconds — the base class's counts refer to calls to
        // process(chunk:), not inference windows.
        self.inner = VoiceActivityDetector(config: cfg)
        self.residual.reserveCapacity(Self.chunkSamples * 2)
    }

    public func process(chunk: [Float]) -> VADEvent {
        // Accumulate incoming samples into the residual buffer and consume
        // as many 512-sample windows as are available. Update `lastProbability`
        // after each window.
        residual.append(contentsOf: chunk)
        while residual.count >= Self.chunkSamples {
            let window = Array(residual.prefix(Self.chunkSamples))
            residual.removeFirst(Self.chunkSamples)
            lastProbability = predict(window: window)
        }

        // Feed the probability as "energy" so the base class's hysteresis and
        // debounce logic apply unchanged. The base class expects a non-empty
        // chunk, so we synthesize one of matching length filled with the
        // probability value.
        let syntheticChunkSize = max(chunk.count, 1)
        return inner.process(chunk: Array(repeating: lastProbability, count: syntheticChunkSize))
    }

    public func reset() {
        inner.reset()
        residual.removeAll(keepingCapacity: true)
        lastProbability = 0.0
    }

    // MARK: - Internals

    private func predict(window: [Float]) -> Float {
        guard window.count == Self.chunkSamples else { return lastProbability }
        do {
            let input = try MLMultiArray(shape: [1, NSNumber(value: Self.chunkSamples)],
                                         dataType: .float32)
            for i in 0..<Self.chunkSamples {
                input[i] = NSNumber(value: window[i])
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "audio_chunk": input,
            ])
            let output = try model.prediction(from: provider)
            if let value = output.featureValue(for: "vad_probability")?.multiArrayValue,
               value.count > 0 {
                return Float(truncating: value[0])
            }
            return lastProbability
        } catch {
            return lastProbability
        }
    }
}
