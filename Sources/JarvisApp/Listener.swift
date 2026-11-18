import AVFoundation
import Foundation
import JarvisCore
import Speech

/// One recognition callback, reduced to Sendable values before it crosses to the main actor.
struct RecognitionUpdate: Sendable {
    let text: String
    let confidences: [Float]
    let isFinal: Bool
    let failed: Bool
    /// "<domain> <code>" of a recognizer error, for diagnostics only (no speech content).
    let errorInfo: String?
}

/// Listens for one Turkish answer with on-device recognition only.
/// `listen` always returns in bounded time (`maxSeconds`) and never falls back to server recognition.
@MainActor
final class Listener {
    static let empty = Heard(text: "", confidence: 0)
    /// After the audio ends, how long to wait for the recognizer's final result (real confidences).
    static let finalResultWaitSeconds: Double = 1.0

    private final class Session {
        /// Distinguishes this listen from earlier ones so late callbacks are ignored.
        let generation: Int
        let silenceSeconds: Double
        var continuation: CheckedContinuation<Heard, Never>?
        var recognizer: SFSpeechRecognizer?
        var engine: AVAudioEngine?
        var tapInstalled = false
        var request: SFSpeechAudioBufferRecognitionRequest?
        var task: SFSpeechRecognitionTask?
        var hardTimer: Task<Void, Never>?
        var silenceTimer: Task<Void, Never>?
        var drainTimer: Task<Void, Never>?
        var text = ""
        var confidences: [Float] = []
        /// True when `text`/`confidences` come from a final result.
        var isFinal = false
        /// Audio has ended; only the final result (or the drain timeout) is awaited.
        var draining = false

        init(generation: Int, silenceSeconds: Double) {
            self.generation = generation
            self.silenceSeconds = silenceSeconds
        }
    }

    private let locale = Locale(identifier: "tr-TR")
    private let log: JarvisLog
    private var session: Session?
    private var nextGeneration = 0

    init(log: JarvisLog) {
        self.log = log
    }

    func listen(maxSeconds: Double = 20, silenceSeconds: Double = 1.5) async -> Heard {
        cancel()
        nextGeneration += 1
        let s = Session(generation: nextGeneration, silenceSeconds: silenceSeconds)
        session = s
        return await withCheckedContinuation { (c: CheckedContinuation<Heard, Never>) in
            s.continuation = c
            start(s, maxSeconds: maxSeconds)
        }
    }

    /// Ends the current listen at once with empty text and tears the audio tap down.
    func cancel() {
        guard let s = session else { return }
        finish(s, Self.empty)
    }

    private func start(_ s: Session, maxSeconds: Double) {
        // Each failed listen logs its cause once; only causes are logged, never request content.
        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard speechAuth == .authorized, micAuth == .authorized else {
            log.append("listen: not authorised (speech=\(speechAuth.rawValue) microphone=\(micAuth.rawValue))")
            finish(s, Self.empty)
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            log.append("listen: recognizer unavailable")
            finish(s, Self.empty)
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            log.append("listen: on-device recognition unsupported")
            finish(s, Self.empty)
            return
        }
        guard recognizer.isAvailable else {
            log.append("listen: recognizer unavailable")
            finish(s, Self.empty)
            return
        }
        s.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        s.request = request

        let engine = AVAudioEngine()
        s.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log.append("listen: audio engine failed: no input format")
            finish(s, Self.empty)
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(request))
        s.tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            log.append("listen: audio engine failed: \(error)")
            finish(s, Self.empty)
            return
        }

        let generation = s.generation
        s.task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] update in
            self?.handle(update, generation: generation)
        })
        s.hardTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(maxSeconds))
            guard !Task.isCancelled else { return }
            self?.endAudioAndDrain(generation: generation)
        }
    }

    private func handle(_ u: RecognitionUpdate, generation: Int) {
        guard let s = session, s.generation == generation, s.continuation != nil else { return }
        if u.failed {
            log.append("listen: recognizer error \(u.errorInfo ?? "unknown")")
            // After endAudio the text heard so far is kept, at confidence 0 (it never was final).
            finish(s, s.draining ? Self.result(s) : Self.empty)
            return
        }
        if u.isFinal && s.text.isEmpty && u.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log.append("listen: final result with no text")
        }
        if !u.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s.text = u.text
            s.confidences = u.confidences
            s.isFinal = u.isFinal
            if !s.draining {
                s.silenceTimer?.cancel()
                let wait = s.silenceSeconds
                s.silenceTimer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    self?.endAudioAndDrain(generation: generation)
                }
            }
        }
        if u.isFinal {
            finish(s, Self.result(s))
        }
    }

    /// Silence or the hard timer: stop feeding audio, tell the recognizer the audio has ended and wait up
    /// to `finalResultWaitSeconds` for its final result. Only a final result carries real confidences;
    /// without one the text heard so far is returned at confidence 0, so the stop gate can work.
    private func endAudioAndDrain(generation: Int) {
        guard let s = session, s.generation == generation, s.continuation != nil, !s.draining else { return }
        s.draining = true
        s.silenceTimer?.cancel()
        s.silenceTimer = nil
        s.drainTimer?.cancel()
        s.drainTimer = nil
        if let engine = s.engine {
            engine.stop()
            if s.tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        s.tapInstalled = false
        s.request?.endAudio()
        let wait = Self.finalResultWaitSeconds
        s.drainTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.finishWithTranscript(generation: generation)
        }
    }

    private func finishWithTranscript(generation: Int) {
        guard let s = session, s.generation == generation else { return }
        finish(s, Self.result(s))
    }

    private static func result(_ s: Session) -> Heard {
        Heard.recognized(text: s.text, confidences: s.confidences, isFinal: s.isFinal)
    }

    /// The only place a listen ends: releases all audio resources and resumes the continuation once.
    private func finish(_ s: Session, _ result: Heard) {
        s.hardTimer?.cancel()
        s.hardTimer = nil
        s.silenceTimer?.cancel()
        s.silenceTimer = nil
        s.drainTimer?.cancel()
        s.drainTimer = nil
        if let engine = s.engine {
            engine.stop()
            if s.tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        s.tapInstalled = false
        s.engine = nil
        s.request?.endAudio()
        s.request = nil
        s.task?.cancel()
        s.task = nil
        s.recognizer = nil
        if session === s { session = nil }
        guard let c = s.continuation else { return }
        s.continuation = nil
        c.resume(returning: result)
    }

    // Built outside the main actor: these closures run on audio / recognizer threads.
    private nonisolated static func tapBlock(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func resultHandler(
        _ sink: @escaping @MainActor @Sendable (RecognitionUpdate) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let update: RecognitionUpdate
            if let result {
                let segments = result.bestTranscription.segments
                update = RecognitionUpdate(text: result.bestTranscription.formattedString,
                                           confidences: segments.map(\.confidence),
                                           isFinal: result.isFinal, failed: false, errorInfo: nil)
            } else {
                let info = error.map { e -> String in
                    let ns = e as NSError
                    return "\(ns.domain) \(ns.code)"
                }
                update = RecognitionUpdate(text: "", confidences: [], isFinal: false, failed: error != nil,
                                           errorInfo: info)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { sink(update) } }
        }
    }
}
