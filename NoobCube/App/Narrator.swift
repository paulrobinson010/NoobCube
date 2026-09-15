import AVFoundation
import SwiftUI

/// Reads instructions aloud.
///
/// The app is aimed at a child who cannot read yet, so nothing important is
/// ever text-only. Every instruction goes through here, can be muted, and can
/// be repeated on demand.
@MainActor
final class Narrator: ObservableObject {

    @Published var isMuted: Bool {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: Self.muteKey)
            if isMuted { stop() }
        }
    }

    /// The last thing said, so the repeat button has something to say again.
    @Published private(set) var lastPhrase: String?

    private static let muteKey = "NoobCube.narrator.muted"
    private let synthesiser = AVSpeechSynthesizer()

    init() {
        isMuted = UserDefaults.standard.bool(forKey: Self.muteKey)
        configureAudioSession()
    }

    /// Say something, replacing whatever is being said.
    ///
    /// The phrase is remembered even when muted, so unmuting and pressing
    /// repeat says the right thing.
    func say(_ phrase: String) {
        lastPhrase = phrase
        guard !isMuted else { return }
        speak(phrase)
    }

    /// Say the last instruction again, ignoring mute: the child pressed play.
    func repeatLast() {
        guard let phrase = lastPhrase else { return }
        speak(phrase)
    }

    func stop() {
        synthesiser.stopSpeaking(at: .immediate)
    }

    private func speak(_ phrase: String) {
        synthesiser.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: phrase)
        // A little slower than normal, with a gap before it starts, so a young
        // child can follow along.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 1.05
        utterance.preUtteranceDelay = 0.1
        utterance.voice = Self.preferredVoice()
        synthesiser.speak(utterance)
    }

    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        // Prefer a higher quality voice when the device has one downloaded.
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    private func configureAudioSession() {
        // Mix with anything else playing and duck it, rather than stopping it.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio,
                                 options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)
    }
}

/// The mute and repeat pair that sits with every spoken instruction.
struct NarratorControls: View {
    @ObservedObject var narrator: Narrator

    var body: some View {
        HStack(spacing: 12) {
            Button {
                narrator.repeatLast()
            } label: {
                Label("Say it again", systemImage: "play.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
            }
            .disabled(narrator.lastPhrase == nil)
            .accessibilityLabel("Say the instruction again")

            Button {
                narrator.isMuted.toggle()
            } label: {
                Image(systemName: narrator.isMuted ? "speaker.slash.circle.fill" : "speaker.wave.2.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(narrator.isMuted ? Theme.muted : Theme.accent)
            }
            .accessibilityLabel(narrator.isMuted ? "Turn the voice on" : "Turn the voice off")
        }
    }
}
