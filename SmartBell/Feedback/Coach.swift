//
//  Coach.swift
//  SmartBell — Feedback
//
//  All user feedback during a workout: a buzz per rep, the rep number spoken aloud,
//  one spoken form cue after a bad rep, and spoken workout guidance (set / rest
//  announcements). Each channel can be switched off in Settings (UserDefaults keys below).
//

import Foundation
import AVFoundation
import UIKit

/// Haptic + spoken feedback. The phone is usually in a pocket during a set (it also powers
/// the ESP32), so a buzz and a short spoken cue are the useful channels.
@MainActor
final class Coach {
    // UserDefaults keys for the on/off switches (read by @AppStorage in the settings UI).
    nonisolated static let speakCountKey = "speakCount"
    nonisolated static let speakCuesKey = "speakCues"
    nonisolated static let hapticsKey = "haptics"
    nonisolated static let speakGuidanceKey = "speakGuidance"

    private let synth = AVSpeechSynthesizer()
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notify = UINotificationFeedbackGenerator()
    private var lastCue: FormIssue?             // for the "don't repeat within 6 s" rule
    private var lastCueTime = Date.distantPast

    // Settings, read fresh each time; a missing key defaults to on.
    private var speakCount: Bool { UserDefaults.standard.object(forKey: Self.speakCountKey) as? Bool ?? true }
    private var speakCues: Bool { UserDefaults.standard.object(forKey: Self.speakCuesKey) as? Bool ?? true }
    private var speakGuidance: Bool { UserDefaults.standard.object(forKey: Self.speakGuidanceKey) as? Bool ?? true }
    private var haptics: Bool { UserDefaults.standard.object(forKey: Self.hapticsKey) as? Bool ?? true }

    /// Call at the start of a set. Audio session: speak over (and briefly lower) any music;
    /// prepare() warms the haptic engines so the first buzz isn't delayed.
    func beginSet() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        impact.prepare()
        notify.prepare()
        lastCue = nil
    }

    /// Release audio so other apps' music returns to full volume.
    func endSet() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// A rep was just counted: buzz and say the number.
    func repCounted(_ n: Int) {
        if haptics { impact.impactOccurred() }
        if speakCount { say("\(n)") }
    }

    /// Rep analysis is ready (~0.3 s after counting). Good rep: success buzz.
    /// Bad rep: warning buzz + speak the top-priority cue (issues are already sorted).
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
        say(top.cueText(generic: r.isGeneric))
    }

    /// Workout guidance (set announcements, rest timer). Can be muted separately from rep counts.
    func guide(_ text: String) {
        if speakGuidance { say(text) }
    }

    /// Rest is over: strong buzz + "Go".
    func restOver() {
        if haptics { notify.notificationOccurred(.success) }
    }

    /// Queue text for speech (utterances play one after another).
    func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.52   // slightly faster than the 0.5 default, so cues stay short
        synth.speak(u)
    }
}
