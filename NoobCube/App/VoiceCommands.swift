import AVFoundation
import Speech

/// What can be said instead of pressed.
enum VoiceCommand: String, Sendable {
    /// "Next" or "done": the move is made, show the next one.
    case next
    /// "Back": go back a move.
    case back

    /// The words that mean each one. A few near misses too, because a
    /// recogniser hearing a five year old say "next" writes down "necks"
    /// often enough to matter.
    static let words: [String: VoiceCommand] = [
        "next": .next, "necks": .next, "nex": .next,
        "done": .next,
        "back": .back,
    ]

    /// The first command among these words, skipping the positions already
    /// ruled out. Returns where it was, so it can be ruled out in turn.
    static func first(in words: [String], skipping ruledOut: Set<Int> = []) -> (command: VoiceCommand, word: String, at: Int)? {
        for (index, raw) in words.enumerated() where !ruledOut.contains(index) {
            let word = normalised(raw)
            if let command = Self.words[word] { return (command, word, index) }
        }
        return nil
    }

    /// Every way of writing this one down.
    var spellings: Set<String> {
        Set(Self.words.filter { $0.value == self }.map(\.key))
    }

    static func normalised(_ word: String) -> String {
        word.lowercased().filter(\.isLetter)
    }
}

/// Listening for "next", "done" and "back" while a solve is on screen, so a
/// child with both hands on the cube does not have to put it down to press.
///
/// Off until someone turns it on, because it needs the microphone and asking
/// for that is a grown-up's decision; remembered once it is on. Recognition
/// happens on the phone when the phone can do it, and only the three words
/// are acted on — nothing heard is kept.
///
/// The app talks a lot, and says "next" and "back" itself, so a word is
/// ignored when it could be the app's own voice coming back in through the
/// microphone (``isOwnVoice``). A child talking over it with a word it is
/// not saying is still heard.
@MainActor
final class VoiceCommands: ObservableObject {

    enum State: Equatable {
        case off
        case listening
        /// The microphone or speech recognition was refused.
        case notAllowed
        /// No recogniser for this language, or no microphone.
        case unavailable
    }

    @Published private(set) var state: State = .off

    /// Whether they want it on. Remembered between launches.
    @Published private(set) var isWanted: Bool

    /// The word just acted on, for a moment, so the screen can show it heard.
    @Published private(set) var heard: String?

    /// Do what the word says. Returns whether there was anything to do.
    var onCommand: ((VoiceCommand, String) -> Bool)?

    /// Whether this could be the app's own voice, heard back.
    var isOwnVoice: ((VoiceCommand) -> Bool)?

    private static let wantedKey = "NoobCube.voice.wanted"

    private let recogniser = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private let sink = BufferSink()
    private var task: SFSpeechRecognitionTask?
    /// Bumped every time recognition starts again, so a late answer from a
    /// finished one is recognised as stale and dropped.
    private var generation = 0
    /// Words in this go that were the app's own voice.
    private var ruledOut: Set<Int> = []
    /// Whether the solve screen is up. Listening happens only then.
    private var isOnScreen = false
    private var recentFailures: [Date] = []
    private var clearHeard: Task<Void, Never>?
    private var interruptions: NSObjectProtocol?

    init() {
        isWanted = UserDefaults.standard.bool(forKey: Self.wantedKey)
        interruptions = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.ended.rawValue
            Task { @MainActor in
                // A phone call stops the microphone; afterwards, carry on.
                guard let self, ended, self.isOnScreen, self.isWanted else { return }
                self.stopListening()
                await self.startListening()
            }
        }
    }

    // MARK: - Turning it on and off

    /// The microphone button.
    func toggle() async {
        if isWanted {
            isWanted = false
            UserDefaults.standard.set(false, forKey: Self.wantedKey)
            stopListening()
            return
        }
        isWanted = true
        UserDefaults.standard.set(true, forKey: Self.wantedKey)
        await startListening()
        if state != .listening {
            // Refused or impossible: do not come back on by itself next time.
            isWanted = false
            UserDefaults.standard.set(false, forKey: Self.wantedKey)
        }
    }

    /// The solve screen came or went, or the app went into the background.
    func screenIsShowing(_ showing: Bool) async {
        isOnScreen = showing
        if showing, isWanted {
            await startListening()
        } else {
            stopListening()
        }
    }

    /// Whether asking would put up the system's question, so the app can say
    /// "ask a grown-up" first.
    var needsToAsk: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
            || AVAudioApplication.shared.recordPermission == .undetermined
    }

    private func allowed() async -> Bool {
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    private func startListening() async {
        guard state != .listening else { return }
        guard await allowed() else {
            state = .notAllowed
            return
        }
        // Asked and answered; still wanted, and still on the solve screen?
        guard isWanted, isOnScreen, state != .listening else { return }
        guard let recogniser, recogniser.isAvailable else {
            state = .unavailable
            return
        }

        AppAudio.configure(listening: true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            AppAudio.configure(listening: false)
            state = .unavailable
            return
        }
        let sink = self.sink
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            sink.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            AppAudio.configure(listening: false)
            state = .unavailable
            return
        }
        state = .listening
        beginRecognising()
    }

    private func stopListening() {
        generation += 1
        task?.cancel()
        task = nil
        sink.set(nil)
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        if state == .listening {
            AppAudio.configure(listening: false)
            state = .off
        } else if !isWanted {
            state = .off
        }
    }

    // MARK: - Recognising

    /// A fresh go at recognising, with nothing heard yet.
    private func beginRecognising() {
        guard state == .listening, let recogniser else { return }
        generation += 1
        let thisGo = generation
        task?.cancel()
        ruledOut = []

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .confirmation
        request.contextualStrings = ["next", "done", "back"]
        if recogniser.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        sink.set(request)

        task = recogniser.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let words = result?.bestTranscription.segments.map(\.substring) ?? []
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                self?.handle(words: words, isFinal: isFinal, failed: failed, go: thisGo)
            }
        }
    }

    private func handle(words: [String], isFinal: Bool, failed: Bool, go: Int) {
        guard go == generation, state == .listening else { return }

        while let found = VoiceCommand.first(in: words, skipping: ruledOut) {
            if isOwnVoice?(found.command) == true {
                ruledOut.insert(found.at)
                continue
            }
            if onCommand?(found.command, found.word) == true {
                show(found.word)
            }
            // Start again with nothing heard, so the same word is never acted
            // on twice as the recogniser keeps refining what it heard.
            beginRecognising()
            return
        }

        if isFinal || failed {
            // A go ends by itself after a pause, or on an error; either way,
            // listen again. Only a string of quick failures slows it down.
            // Only errors count: a go finishing after a quiet spell is normal.
            let now = Date()
            if failed { recentFailures.append(now) }
            recentFailures = recentFailures.filter { now.timeIntervalSince($0) < 60 }
            if recentFailures.count > 40 {
                // Something is wrong with recognising on this phone just now,
                // not a pause in the talking. The buttons still work.
                stopListening()
                state = .unavailable
                return
            }
            if recentFailures.filter({ now.timeIntervalSince($0) < 5 }).count > 4 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, go == self.generation else { return }
                    self.beginRecognising()
                }
            } else {
                beginRecognising()
            }
        }
    }

    private func show(_ word: String) {
        heard = word
        clearHeard?.cancel()
        clearHeard = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard !Task.isCancelled else { return }
            self?.heard = nil
        }
    }
}

/// Hands the microphone's sound to whichever recognition request is current.
/// The microphone calls in on its own thread, so this is the one thing both
/// sides touch, behind a lock.
private final class BufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = self.request
        self.request = request
        lock.unlock()
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }
}
