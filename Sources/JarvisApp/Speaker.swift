import AVFoundation
import Foundation
import JarvisCore

/// Speaks Turkish text with `AVSpeechSynthesizer`. `speak` always returns in bounded time:
/// when the utterance finishes, when `stop()` is called, or when the time limit runs out.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    /// Resumed exactly once per `speak` call; nil when nothing is pending.
    private var pending: CheckedContinuation<Void, Never>?
    private var currentUtterance: ObjectIdentifier?
    private var timeout: Task<Void, Never>?

    init(log: JarvisLog) {
        voice = AVSpeechSynthesisVoice(language: "tr-TR")
        super.init()
        // Logged once at startup; a nil voice makes the synthesizer use the system default.
        if voice == nil { log.append("speech: tr-TR voice missing, using default") }
        synthesizer.delegate = self
    }

    /// Speech that has not finished within this limit is stopped.
    static func timeLimit(for text: String) -> Double {
        max(10, 0.12 * Double(text.count))
    }

    /// `maxSeconds`: the caller's remaining time; the text's own limit never exceeds it.
    func speak(_ text: String, maxSeconds: Double = .infinity) async {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        let limit = min(Self.timeLimit(for: trimmed), maxSeconds)

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            pending = c
            currentUtterance = ObjectIdentifier(utterance)
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(limit))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
            synthesizer.speak(utterance)
        }
    }

    /// Stops speech at once and releases a pending `speak`. Safe to call at any time.
    func stop() {
        // Also covers an utterance that is queued but not yet audible; a no-op when idle.
        synthesizer.stopSpeaking(at: .immediate)
        complete()
    }

    private func complete() {
        timeout?.cancel()
        timeout = nil
        currentUtterance = nil
        guard let c = pending else { return }
        pending = nil
        c.resume()
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        // A late callback for an earlier, already stopped utterance must not end the current one.
        guard id == currentUtterance else { return }
        complete()
    }

    // Delegate callbacks may arrive on any thread; hop to the main queue in order.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.utteranceEnded(id) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.utteranceEnded(id) } }
    }
}
