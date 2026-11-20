import Foundation
import AVFoundation
import UIKit

/// Haptic + spoken feedback. The phone is usually in a pocket during a set (it also powers
/// the ESP32), so a buzz and a short spoken cue are the useful channels.
@MainActor
final class Coach {
    nonisolated static let speakCountKey = "speakCount"
    nonisolated static let speakCuesKey = "speakCues"
    nonisolated static let hapticsKey = "haptics"
    nonisolated static let speakGuidanceKey = "speakGuidance"

    private let synth = AVSpeechSynthesizer()
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notify = UINotificationFeedbackGenerator()
    private var lastCue: FormIssue?
    private var lastCueTime = Date.distantPast

    private var speakCount: Bool { UserDefaults.standard.object(forKey: Self.speakCountKey) as? Bool ?? true }
    private var speakCues: Bool { UserDefaults.standard.object(forKey: Self.speakCuesKey) as? Bool ?? true }
    private var speakGuidance: Bool { UserDefaults.standard.object(forKey: Self.speakGuidanceKey) as? Bool ?? true }
    private var haptics: Bool { UserDefaults.standard.object(forKey: Self.hapticsKey) as? Bool ?? true }

    func beginSet() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        impact.prepare()
        notify.prepare()
        lastCue = nil
    }

    func endSet() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func repCounted(_ n: Int) {
        if haptics { impact.impactOccurred() }
        if speakCount { say("\(n)") }
    }

    func repAnalysed(_ r: RepResult) {
        guard let top = r.issues.first else {
            if haptics && r.counted { notify.notificationOccurred(.success) }
            lastCue = nil
            return
        }
        if haptics { notify.notificationOccurred(.warning) }
        guard speakCues else { return }
        // Don't nag: the same cue at most every 6 s.
        if top == lastCue && Date().timeIntervalSince(lastCueTime) < 6 { return }
        lastCue = top
        lastCueTime = Date()
        say(top.cue)
    }

    /// Workout guidance (set announcements, rest timer). Can be muted separately from rep counts.
    func guide(_ text: String) {
        if speakGuidance { say(text) }
    }

    /// Rest is over: strong buzz + "Go".
    func restOver() {
        if haptics { notify.notificationOccurred(.success) }
    }

    func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.52
        synth.speak(u)
    }
}
