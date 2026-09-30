import AVFoundation
import SwiftUI

/// Reads instructions aloud.
///
/// The app is aimed at a child who cannot read yet, so nothing important is
/// ever text-only. Every instruction goes through here, can be muted, and can
/// be repeated on demand.
@MainActor
final class Narrator: NSObject, ObservableObject {

    // MARK: - Pointing at buttons

    /// Every button the narrator can point at while it explains a choice.
    ///
    /// A child who cannot read can hear "press the green button with the tick",
    /// but has to find it — so while those words are said, that button glows
    /// and a hand points at it. See ``View/pointedAt(_:by:)``.
    enum ButtonName: String, Hashable, Sendable {
        case carryOn, showMeYourCube, smartCube
        case startSolving
        case thatsMyCube, scanMap
        case showEachMove, doItMyself, doneThisBit, showMeAfterAll
        case lookAgain, keepGoing, playAgain
        case next, playThrough, turnedIt
        case solveThis, looksDifferent, solvedNow
        case palette, paintHere
        case openSettings, cubeList
        case goBack, looksRight, lookAtMyCube
        case retakeSide, restartScan
        case headerCamera, headerHome, headerRepeat, headerMute
        case slower
        case methodBeginner, methodFaster, methodSpeedcuber
    }

    /// One sentence of an explanation, and the button it is about, if any.
    struct Part: Sendable {
        let words: String
        let button: ButtonName?

        init(_ words: String, pointingAt button: ButtonName? = nil) {
            self.words = words
            self.button = button
        }
    }

    /// The button being talked about right now.
    @Published private(set) var pointingAt: ButtonName?

    private var lastExplanation: [Part] = []
    private var buttonFor: [ObjectIdentifier: ButtonName] = [:]
    private var speakingNow: ObjectIdentifier?

    /// Muted for now — never for next time.
    ///
    /// It used to be remembered, so one stray tap on the speaker made every
    /// launch after it silent. For a child who cannot read, a silent app is a
    /// screen of words and nothing else, and nothing on it says why. Each time
    /// the app opens, the voice is back.
    @Published var isMuted = false {
        didSet {
            if isMuted { stop() }
        }
    }

    /// The last thing said, so the repeat button has something to say again.
    @Published private(set) var lastPhrase: String?

    private static let muteKey = "NoobCube.narrator.muted"
    private let synthesiser = AVSpeechSynthesizer()

    override init() {
        super.init()
        // Anything a previous version stored is forgotten, so an old "muted"
        // cannot come back either.
        UserDefaults.standard.removeObject(forKey: Self.muteKey)
        synthesiser.delegate = self
        configureAudioSession()
    }

    /// Explain a choice: each sentence in turn, pointing at each button as it
    /// is talked about.
    ///
    /// Muted, nothing lights up: the pointing goes with the words, and a
    /// button lit with nothing said about it is only a distraction. The
    /// repeat button still says it all, pointing and all.
    func explain(_ parts: [Part]) {
        lastExplanation = parts
        lastPhrase = parts.map(\.words).joined(separator: " ")
        guard !isMuted else { return stopPointing() }
        speak(parts)
    }

    /// Say something, replacing whatever is being said.
    ///
    /// The phrase is remembered even when muted, so unmuting and pressing
    /// repeat says the right thing.
    func say(_ phrase: String) {
        let alreadySaying = phrase == lastPhrase && synthesiser.isSpeaking
        lastPhrase = phrase
        lastExplanation = []
        guard !isMuted else { return }
        // Saying the same sentence again while it is still being said stops it
        // and starts it from the beginning, which comes out as a stutter. The
        // child asking for it again goes through `repeatLast`, which does not
        // come through here.
        guard !alreadySaying else { return }
        speak(phrase)
    }

    /// Say the last instruction again, ignoring mute: the child pressed play.
    func repeatLast() {
        if !lastExplanation.isEmpty { return speak(lastExplanation) }
        guard let phrase = lastPhrase else { return }
        speak(phrase)
    }

    func stop() {
        synthesiser.stopSpeaking(at: .immediate)
        stopPointing()
    }

    private func speak(_ phrase: String) {
        speak([Part(phrase)])
    }

    /// Queue the sentences one after another; the synthesiser says them in
    /// order, and says when each one starts, which is when its button lights.
    private func speak(_ parts: [Part]) {
        synthesiser.stopSpeaking(at: .immediate)
        stopPointing()
        for (index, part) in parts.enumerated() {
            let utterance = AVSpeechUtterance(string: part.words)
            // A little slower than normal, with a gap before it starts, so a
            // young child can follow along — and a breath between choices.
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
            utterance.pitchMultiplier = 1.05
            utterance.preUtteranceDelay = index == 0 ? 0.1 : 0.25
            utterance.voice = Self.preferredVoice()
            if let button = part.button { buttonFor[ObjectIdentifier(utterance)] = button }
            synthesiser.speak(utterance)
        }
    }

    private func stopPointing() {
        buttonFor = [:]
        speakingNow = nil
        pointingAt = nil
    }

    fileprivate func started(_ utterance: ObjectIdentifier) {
        speakingNow = utterance
        pointingAt = buttonFor[utterance]
    }

    fileprivate func ended(_ utterance: ObjectIdentifier) {
        buttonFor[utterance] = nil
        guard speakingNow == utterance else { return }
        speakingNow = nil
        pointingAt = nil
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

extension Narrator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.started(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }
}

// MARK: - Showing which button is meant

extension View {
    /// Light this button up, with a hand pointing at it, while the narrator is
    /// talking about it.
    func pointedAt(_ button: Narrator.ButtonName, by narrator: Narrator,
                   small: Bool = false) -> some View {
        modifier(PointedAt(narrator: narrator, button: button, small: small))
    }
}

private struct PointedAt: ViewModifier {
    @ObservedObject var narrator: Narrator
    let button: Narrator.ButtonName
    /// A little round button, like the ones along the top: the hand goes
    /// underneath pointing up, rather than on top of it.
    var small = false

    private var isPointed: Bool { narrator.pointingAt == button }

    @ViewBuilder
    func body(content: Content) -> some View {
        if small { smallBody(content) } else { bigBody(content) }
    }

    private func smallBody(_ content: Content) -> some View {
        content
            .overlay {
                Circle()
                    .strokeBorder(Theme.attention, lineWidth: 3)
                    .padding(-6)
                    .opacity(isPointed ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if isPointed {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.attention)
                        .padding(6)
                        .background(Circle().fill(Theme.ink))
                        .phaseAnimator([false, true]) { hand, nudged in
                            hand.offset(y: nudged ? 30 : 40)
                        } animation: { _ in .easeInOut(duration: 0.45) }
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .scaleEffect(isPointed ? 1.2 : 1)
            .zIndex(isPointed ? 1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPointed)
    }

    private func bigBody(_ content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius + 6, style: .continuous)
                    .strokeBorder(Theme.attention, lineWidth: 4)
                    .padding(-7)
                    .opacity(isPointed ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                if isPointed {
                    Image(systemName: "hand.point.left.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.attention)
                        .padding(8)
                        .background(Circle().fill(Theme.ink))
                        .phaseAnimator([false, true]) { hand, nudged in
                            hand.offset(x: nudged ? -8 : 4)
                        } animation: { _ in .easeInOut(duration: 0.45) }
                        .padding(.trailing, 6)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .scaleEffect(isPointed ? 1.04 : 1)
            .zIndex(isPointed ? 1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPointed)
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
                    .foregroundStyle(Theme.attention)
            }
            .disabled(narrator.lastPhrase == nil)
            .pointedAt(.headerRepeat, by: narrator, small: true)
            .accessibilityLabel("Say the instruction again")

            Button {
                narrator.isMuted.toggle()
            } label: {
                Image(systemName: narrator.isMuted ? "speaker.slash.circle.fill" : "speaker.wave.2.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(narrator.isMuted ? Theme.muted : Theme.attention)
            }
            .accessibilityLabel(narrator.isMuted ? "Turn the voice on" : "Turn the voice off")
        }
    }
}
