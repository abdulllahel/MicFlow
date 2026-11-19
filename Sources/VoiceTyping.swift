import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Voice typing in the style of Wispr Flow: hold a voice key and speak, release it, and the
/// transcript is pasted into whatever app has focus and left on the clipboard.
/// - Gemini Live streams the recording to Gemini's live transcription while you speak, so the text
///   (English, Bengali, or both mixed, tidied up) is ready about half a second after you let go.
/// - The free Chrome engine uses Chrome's built-in speech recognition, which listens in one
///   language at a time, so it has one key for Bengali and one for English.
@MainActor
final class VoiceTypingModel: ObservableObject {
    enum Phase: Equatable {
        case idle, listening, transcribing
    }

    enum Engine: String, CaseIterable, Identifiable {
        case geminiLive, chrome
        var id: String { rawValue }
        var title: String { self == .geminiLive ? "Model 1 (Recommended)" : "Model 2" }
        /// The short name, for the badge on the Voice page.
        var shortTitle: String { self == .geminiLive ? "Model 1" : "Model 2" }
    }

    /// Which voice key was pressed. With Chrome it's the language to listen in; Gemini Live uses
    /// only the first key and works the language out itself.
    enum VoiceKey {
        case bengali, english
        var language: String { self == .bengali ? "bn-BD" : "en-US" }
    }

    private enum Keys {
        static let enabled = "voiceTypingEnabled"
        static let tapToTalk = "voiceTypingTapToTalk"
        static let livePreview = "voiceTypingLivePreview"
        static let hotkey = "voiceTypingHotkey"
        static let hotkeyName = "voiceTypingHotkeyName"
        static let englishHotkey = "voiceTypingEnglishHotkey"
        static let englishHotkeyName = "voiceTypingEnglishHotkeyName"
        static let engine = "voiceTypingEngine"
        static let myWords = "voiceTypingMyWords"
        static let mixUps = "voiceTypingMixUps"
        static let fixMixUps = "voiceTypingFixMixUps"
        static let polish = "voiceTypingPolish"
        static let yourInstructions = "voiceTypingYourInstructions"
        static let instructionsEnabled = "voiceTypingInstructionsEnabled"
        static let screenContext = "voiceTypingScreenContext"
        static let floatingPill = "floatingPillEnabled"
    }

    /// Presses shorter than this are ignored, so tapping a voice key (e.g. Ctrl in a shortcut) does nothing.
    private static let minimumHold: TimeInterval = 0.3

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled); applyEnabled() }
    }
    @Published private(set) var hasKey = KeychainSecret.geminiKey.exists()
    /// The saved key was refused because Google turned off the free plan for its Google account:
    /// Home then asks for a new key (the old one is kept until a new one replaces it).
    @Published private(set) var keyFreePlanOff = UserDefaults.standard.bool(forKey: "keyFreePlanOff")

    private func noteProblem(_ message: String) {
        guard message.contains(ProviderName.freePlanOff), !keyFreePlanOff else { return }
        keyFreePlanOff = true
        UserDefaults.standard.set(true, forKey: "keyFreePlanOff")
    }

    private func keyChanged() {
        if cachedKey != nil { keyRemovedByYou = false }
        keyFreePlanOff = false
        UserDefaults.standard.removeObject(forKey: "keyFreePlanOff")
    }
    /// Press the key once to start and again to stop, instead of holding it while you talk.
    /// Words the system dictionary doesn't know, with a recording of how you say each.
    let dictionary = PersonalDictionary()
    /// The last dictation's sound, kept so a new word can be saved with how it was said.
    private var lastSamples: [Float] = []
    private var lastRate: Double = 48_000
    @Published var tapToTalk: Bool {
        didSet { defaults.set(tapToTalk, forKey: Keys.tapToTalk) }
    }
    /// Show the words in the pill while you talk. On by default.
    @Published var showLivePreview: Bool {
        didSet { defaults.set(showLivePreview, forKey: Keys.livePreview) }
    }
    /// Gemini Live's key, and Chrome's Bengali key.
    @Published private(set) var hotkey: Int64
    @Published private(set) var hotkeyName: String
    /// Chrome's English key; nil until one is chosen.
    @Published private(set) var englishHotkey: Int64?
    @Published private(set) var englishHotkeyName: String?
    @Published var engine: Engine {
        didSet {
            defaults.set(engine.rawValue, forKey: Keys.engine)
            showingError = false
            if engine == .geminiLive { loadKeyIfNeeded() }
            applyEngine()
            rebuildTap()
            updateStatus()
        }
    }
    /// The user's own words (names, brands, terms), spelled their way in the typed text.
    @Published private(set) var myWords: [String]
    /// Words the user says in a way that comes out as another word; fixed after dictation.
    @Published private(set) var mixUps: [MixUp]
    @Published var fixMixUps: Bool {
        didSet { defaults.set(fixMixUps, forKey: Keys.fixMixUps) }
    }
    /// Whether clean-up uses your instructions.
    /// Whether clean-up also gets what's on the screen (read through Accessibility) for context.
    @Published var screenContext: Bool {
        didSet { defaults.set(screenContext, forKey: Keys.screenContext) }
    }
    /// The screen text read when the key went down; used for this dictation only.
    private var screenText = ""

    @Published var instructionsEnabled: Bool {
        didSet { defaults.set(instructionsEnabled, forKey: Keys.instructionsEnabled) }
    }
    /// Your own instructions for clean-up, added to MicFlow's.
    @Published var yourInstructions: String {
        didSet { defaults.set(yourInstructions, forKey: Keys.yourInstructions) }
    }
    /// Whether the text is cleaned up (punctuation, grammar, filler words, mix-ups) after it's pasted.
    @Published var polish: Bool {
        didSet { defaults.set(polish, forKey: Keys.polish) }
    }
    @Published private(set) var phase = Phase.idle
    /// The key being captured in the panel, if any.
    @Published private(set) var capturing: VoiceKey?
    @Published private(set) var status = ""
    @Published private(set) var statusIsError = false
    @Published private(set) var needsAccessibility = false

    /// What MicFlow learns about the speaker, shown and editable in the Memory card.
    let memory = MemoryStore()
    /// Backup providers (Groq and others), shown once a Google key is saved.
    let providerSettings = ProviderSettings()
    /// A recording of the last dictation is saved, so it can be transcribed again.
    @Published private(set) var canRecover = DictationAudio.exists
    /// Set when the last text looked like noise: a reason to offer "Recover last dictation".
    @Published var recoverOffer: String?
    @Published private(set) var recovering = false
    /// The small always-visible pill at rest (on by default). It is the only dictation indicator: with this off it still appears
    /// while you dictate.
    @Published var floatingPillEnabled: Bool {
        didSet { defaults.set(floatingPillEnabled, forKey: Keys.floatingPill); applyPill() }
    }
    /// A recording that couldn't be typed is saved and waiting for Retry.
    @Published private(set) var pendingRetry = RetryStore.exists
    /// The connection dropped while you were talking (the voice is still being saved here).
    private var connectionLost = false
    /// Started with the pill's button, not a key: the pill shows a Stop button.
    private var startedByPill = false
    private var streamTicks = 0
    /// The microphones to pick from (uid, name), the chosen one's uid, and how to choose: set by the Sound tab's model.
    var micChoices: () -> [(uid: String, name: String)] = { [] }
    var selectedMicUID: () -> String = { "" }
    var selectMic: (String) -> Void = { _ in }

    /// The device to record from (for Gemini Live), chosen by the Sound tab.
    var inputDevice: () -> AudioDevice? = { nil }
    /// How much louder to make the microphone while dictating (linear).
    var inputGain: () -> Float = { 1 }

    private let defaults = UserDefaults.standard
    private let recorder = VoiceRecorder()
    private let overlay = VoiceOverlay()
    private let pasteStatus = PasteStatus()
    /// Every dictation, for the Home window.
    let log = DictationLog()
    private let chrome = ChromeSpeechBridge()
    private var tap: EventTap?
    private var permissionTimer: Timer?
    private var pressedAt: Date?
    private var pressedKey: VoiceKey?
    private var captureMonitor: Any?
    /// Keeps the last failure on screen until the next dictation or a settings change.
    private var showingError = false

    /// Read from the Keychain once and kept: reading it on every dictation could show a password
    /// box, which blocks the app and makes macOS switch off its key listener.
    private var cachedKey: String?
    /// The saved Google key, once read (for the Memory card's "Learn now").
    var currentKey: String? { cachedKey }
    private var loadingKey = false
    private var live: LiveTranscriber?
    private var streamTimer: Timer?
    private var sentSamples = 0
    /// Your key presses and clicks, and the dictations pasted, counted to tell whether a pasted text
    /// has been touched before its cleaned-up version arrives.
    private var activity = 0
    private var dictations = 0
    private var activityTap: EventTap?

    private var readyText: String {
        guard engine == .chrome else { return "Hold \(hotkeyName), speak English or Bengali, and let go." }
        guard let englishHotkeyName else { return "Hold \(hotkeyName) and speak Bengali. Choose an English key above for English." }
        return "Hold \(hotkeyName) for Bengali or \(englishHotkeyName) for English, speak, and let go."
    }

    init() {
        defaults.register(defaults: [Keys.enabled: false, Keys.hotkey: Int64(kVK_RightControl), Keys.hotkeyName: "Right Ctrl",
                                     Keys.engine: Engine.geminiLive.rawValue, Keys.fixMixUps: true, Keys.polish: true,
                                     Keys.tapToTalk: false, Keys.livePreview: true])
        // Earlier engines: "gemini" (record, then upload) becomes Gemini Live; "whisper" became Chrome.
        let savedEngine = defaults.string(forKey: Keys.engine) ?? ""
        engine = savedEngine == "gemini" ? .geminiLive : savedEngine == "whisper" ? .chrome : Engine(rawValue: savedEngine) ?? .geminiLive
        enabled = defaults.bool(forKey: Keys.enabled)
        tapToTalk = defaults.bool(forKey: Keys.tapToTalk)
        showLivePreview = defaults.bool(forKey: Keys.livePreview)
        hotkey = (defaults.object(forKey: Keys.hotkey) as? NSNumber)?.int64Value ?? Int64(kVK_RightControl)
        hotkeyName = defaults.string(forKey: Keys.hotkeyName) ?? "Right Ctrl"
        englishHotkey = (defaults.object(forKey: Keys.englishHotkey) as? NSNumber)?.int64Value
        englishHotkeyName = defaults.string(forKey: Keys.englishHotkeyName)
        myWords = defaults.stringArray(forKey: Keys.myWords) ?? []
        mixUps = defaults.data(forKey: Keys.mixUps).flatMap { try? JSONDecoder().decode([MixUp].self, from: $0) } ?? []
        fixMixUps = defaults.bool(forKey: Keys.fixMixUps)
        polish = defaults.bool(forKey: Keys.polish)
        yourInstructions = defaults.string(forKey: Keys.yourInstructions) ?? ""
        // Mix-ups were replaced by the personal dictionary: they stop being used.
        if !defaults.bool(forKey: "mixUpsRetired") { defaults.set(true, forKey: "mixUpsRetired"); fixMixUps = false; defaults.set(false, forKey: Keys.fixMixUps) }
        instructionsEnabled = defaults.object(forKey: Keys.instructionsEnabled) as? Bool ?? true
        screenContext = defaults.bool(forKey: Keys.screenContext)
        floatingPillEnabled = defaults.object(forKey: Keys.floatingPill) as? Bool ?? true
        // Both engines use the key for the clean-up.
        loadKeyIfNeeded()
        overlay.level = { [recorder] in recorder.level }
        overlay.keyName = { [weak self] in self?.hotkeyName ?? "" }
        overlay.floatingActions = FloatingPillActions(start: { [weak self] in self?.startFromPill() },
                                                      stop: { [weak self] in self?.stopFromPill() },
                                                      retry: { [weak self] in self?.retryPending() },
                                                      dismiss: { [weak self] in self?.dismissPending() })
        dictionary.onPronunciationsChanged = { [weak self] in self?.syncPronunciations($0) }
        dictionary.importPronunciations(from: mixUps)
        applyEnabled()
        dictionary.adopt(myWords)
        dictionary.addToWordList = { [weak self] in self?.addWord($0) }
        dictionary.removeFromWordList = { [weak self] in self?.removeWord($0) }
    }

    // MARK: Settings

    /// Reads the saved key once, then saves it again so this build of the app owns the Keychain item
    /// and later launches can read it without asking.
    /// Reads the key from the Keychain in the background: macOS may ask you to allow it first, and
    /// MicFlow must keep working while that question is up.
    private func loadKeyIfNeeded() {
        guard cachedKey == nil, hasKey, !loadingKey else { return }
        loadingKey = true
        Task.detached {
            let key = KeychainSecret.geminiKey.load()
            // Saved again so it's stored for this build of MicFlow and macOS stops asking.
            if let key { KeychainSecret.geminiKey.save(key) }
            await MainActor.run {
                self.loadingKey = false
                if let key, self.cachedKey == nil { self.cachedKey = key }
            }
        }
    }

    /// Checks the key and saves it; returns why it was refused, or nil when it's saved.
    func saveKeyChecked(_ key: String) async -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // A brand-new key can take a few seconds to start working.
            var lastError: Error?
            for attempt in 0..<4 {
                do { try await GeminiClient.check(key: key); lastError = nil; break } catch { lastError = error }
                if attempt < 3 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            }
            if let lastError { throw lastError }
            KeychainSecret.geminiKey.save(key)
            cachedKey = key
            hasKey = true
            keyChanged()
            showingError = false
            updateStatus()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func saveKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            showingError = false
            setStatus("Checking your key…")
            do {
                try await GeminiClient.check(key: key)
                KeychainSecret.geminiKey.save(key)
                cachedKey = key
                hasKey = true
                keyChanged()
                updateStatus()
            } catch {
                showingError = true
                setStatus("That key didn't work: \(error.localizedDescription)", error: true)
            }
        }
    }

    /// What's saved to your account when you're signed in (the key goes separately, sealed: see
    /// `keyUpload` and KeyVault).
    func savedPreferences() -> SavedPreferences {
        SavedPreferences(instructions: yourInstructions, instructions_enabled: instructionsEnabled,
                         my_words: myWords, mix_ups: mixUps, api_key: nil)
    }

    /// The key for the account's sealed copy: the key in use, or a clear after you removed it.
    var keyUpload: PreferenceSync.KeyUpload {
        if let cachedKey { return .set(cachedKey) }
        return keyRemovedByYou ? .clear : .keep
    }
    private var keyRemovedByYou = false

    /// Brings back what your account has: words and mix-ups are added to the ones here, and the
    /// account's instructions and API key (unlocked) are used if it has them.
    func apply(_ saved: SavedPreferences, apiKey: String?) {
        if !saved.instructions.isEmpty { yourInstructions = saved.instructions }
        instructionsEnabled = saved.instructions_enabled
        for word in saved.my_words { addWord(word) }
        for mixUp in saved.mix_ups where !mixUps.contains(where: { $0.heard == mixUp.heard && $0.meant == mixUp.meant })
            && !(mixUp.meaning == "pronunciation" && dictionary.wasDeleted(heard: mixUp.heard, meant: mixUp.meant)) {
            mixUps.append(mixUp)
        }
        saveMixUps()
        dictionary.importPronunciations(from: saved.mix_ups)
        // The account's key is used when this Mac has none (or Google refused the one here); a
        // working key on this Mac stays, and is what gets saved to the account.
        if let key = apiKey, !key.isEmpty, key != cachedKey, !hasKey || keyFreePlanOff {
            KeychainSecret.geminiKey.save(key)
            cachedKey = key
            hasKey = true
            keyChanged()
            updateStatus()
        }
    }

    /// Logging out takes the key off this Mac too (it isn't "removed by you": the account keeps its
    /// locked copy, which comes back at the next sign-in).
    func forgetKeyOnThisMac() {
        showingError = false
        KeychainSecret.geminiKey.delete()
        cachedKey = nil
        hasKey = false
        keyFreePlanOff = false
        UserDefaults.standard.removeObject(forKey: "keyFreePlanOff")
        updateStatus()
    }

    func removeKey() {
        showingError = false
        KeychainSecret.geminiKey.delete()
        cachedKey = nil
        hasKey = false
        keyRemovedByYou = true
        keyChanged()
        updateStatus()
    }

    // MARK: Personal dictionary

    func addWord(_ word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !myWords.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        myWords.append(word)
        defaults.set(myWords, forKey: Keys.myWords)
    }

    func removeWord(_ word: String) {
        myWords.removeAll { $0 == word }
        defaults.set(myWords, forKey: Keys.myWords)
    }

    func addMixUp(heard: String, meant: String, meaning: String) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let meant = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !meant.isEmpty, heard.caseInsensitiveCompare(meant) != .orderedSame else { return }
        mixUps.append(MixUp(heard: heard, meant: meant, meaning: meaning.trimmingCharacters(in: .whitespacesAndNewlines)))
        saveMixUps()
    }

    func removeMixUp(_ mixUp: MixUp) {
        mixUps.removeAll { $0.id == mixUp.id }
        saveMixUps()
    }

    private func saveMixUps() {
        defaults.set(try? JSONEncoder().encode(mixUps), forKey: Keys.mixUps)
    }

    /// Waits for the next key press in the panel and makes it that voice key.
    func captureHotkey(_ key: VoiceKey) {
        stopCapture()
        capturing = key
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let code = Int64(event.keyCode)
            // A modifier counts when it goes down, not when it's released.
            if event.type == .flagsChanged {
                guard KeyNames.modifierFlags[code] != nil,
                      KeyNames.isDown(code, in: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))) else { return event }
            }
            self.setHotkey(key, code, name: KeyNames.name(code, characters: event.type == .keyDown ? event.charactersIgnoringModifiers : nil))
            return nil
        }
    }

    func cancelCapture() { stopCapture() }

    private func setHotkey(_ key: VoiceKey, _ code: Int64, name: String) {
        switch key {
        case .bengali:
            hotkey = code
            hotkeyName = name
            defaults.set(code, forKey: Keys.hotkey)
            defaults.set(name, forKey: Keys.hotkeyName)
            // One key can't mean both languages.
            if englishHotkey == code { clearEnglishHotkey() }
        case .english:
            guard code != hotkey else {
                stopCapture()
                showingError = true
                setStatus("\(name) is already the Bengali key. Pick a different key for English.", error: true)
                return
            }
            englishHotkey = code
            englishHotkeyName = name
            defaults.set(code, forKey: Keys.englishHotkey)
            defaults.set(name, forKey: Keys.englishHotkeyName)
        }
        stopCapture()
        showingError = false
        rebuildTap()
        updateStatus()
    }

    private func clearEnglishHotkey() {
        englishHotkey = nil
        englishHotkeyName = nil
        defaults.removeObject(forKey: Keys.englishHotkey)
        defaults.removeObject(forKey: Keys.englishHotkeyName)
    }

    private func stopCapture() {
        if let captureMonitor { NSEvent.removeMonitor(captureMonitor) }
        captureMonitor = nil
        capturing = nil
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Running

    func shutDown() {
        cancelRecording()
        tap?.remove()
        activityTap?.remove()
        chrome.stop()
    }

    /// Opens MicFlow's voice typing page in Chrome (in the background) if it isn't open already.
    func openChromePage() {
        chrome.start()
        chrome.openPageIfNeeded()
    }

    /// Chrome's page bridge only runs while voice typing is on with Chrome chosen.
    private func applyEngine() {
        if enabled, engine == .chrome { chrome.start() } else { chrome.stop() }
    }

    /// The voice keys in use for the current engine.
    private var activeKeys: [(VoiceKey, Int64)] {
        var keys: [(VoiceKey, Int64)] = [(.bengali, hotkey)]
        if engine == .chrome, let englishHotkey { keys.append((.english, englishHotkey)) }
        return keys
    }

    /// When every voice key is a modifier (Ctrl, Option…), the tap only listens, so keystrokes in
    /// other apps never wait for MicFlow. Other keys have to be held back so they don't type.
    private func rebuildTap() {
        tap?.remove()
        tap = nil
        guard enabled else { return }
        let listenOnly = activeKeys.allSatisfy { KeyNames.modifierFlags[$0.1] != nil }
        tap = EventTap(types: [.flagsChanged, .keyDown, .keyUp], listenOnly: listenOnly) { [unowned self] type, event in
            MainActor.assumeIsolated { self.handleKey(type, event) }
        }
        activityTap?.remove()
        activityTap = EventTap(types: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown], listenOnly: true) { [unowned self] _, event in
            if event.getIntegerValueField(.eventSourceUserData) != PastedText.syntheticMarker {
                MainActor.assumeIsolated { self.activity += 1 }
            }
            return true
        }
        updateStatus()
    }

    /// What's missing before this engine can type, if anything.
    private var engineProblem: String? {
        switch engine {
        case .geminiLive:
            return hasKey ? nil : "Add your API key in the API key card to start, or click Set it up for me."
        case .chrome:
            if !chrome.chromeInstalled { return "Model 2 needs Google Chrome installed." }
            return chrome.isConnected ? nil : "Waiting for the MicFlow tab in Chrome. Click \"Open the Model 2 tab\" below."
        }
    }

    /// The pill exists while voice typing is on; the setting decides whether it also stays on screen at rest.
    private func applyPill() {
        overlay.configure(enabled: enabled, showAtRest: floatingPillEnabled)
        overlay.setPending(pendingRetry)
    }

    func resetPillPosition() { overlay.resetFloatingPosition() }

    private func applyEnabled() {
        applyPill()
        permissionTimer?.invalidate()
        permissionTimer = nil
        applyEngine()
        rebuildTap()
        guard enabled else {
            cancelRecording()
            setStatus("")
            return
        }
        if !AXIsProcessTrusted() {
            AccessibilityPrompt.askOnce()
        }
        // Re-checks until Accessibility is granted, and notices Chrome's tab connecting or closing.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        updateStatus()
    }

    private func updateStatus() {
        guard enabled, let tap else { return }
        needsAccessibility = !(AXIsProcessTrusted() && tap.install())
        if !needsAccessibility { activityTap?.install() }
        if needsAccessibility {
            tap.remove()
            setStatus("Voice typing needs Accessibility permission to hear the voice keys and type the text.", error: true)
        } else if showingError {
            // Leave the last error up.
        } else if let problem = engineProblem {
            setStatus(problem, error: true)
        } else if phase == .idle {
            setStatus(readyText)
        }
    }

    private func setStatus(_ text: String, error: Bool = false) {
        status = text
        statusIsError = error
    }

    private func handleKey(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard let (voiceKey, keyCode) = activeKeys.first(where: { $0.1 == code }) else {
            // Another key while holding a modifier voice key means a shortcut like Ctrl+C, not dictation.
            if type == .keyDown, pressedAt != nil, let pressed = pressedKey,
               KeyNames.modifierFlags[pressed == .bengali ? hotkey : englishHotkey ?? -1] != nil {
                cancelRecording()
            }
            return true
        }
        if KeyNames.modifierFlags[keyCode] != nil {
            // Modifier voice key: watch it go down and up, and let it through so shortcuts still work.
            if type == .flagsChanged {
                KeyNames.isDown(keyCode, in: event.flags) ? keyDown(voiceKey) : keyUp(voiceKey)
            }
            return true
        }
        guard type == .keyDown || type == .keyUp else { return true }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { keyDown(voiceKey) }
        } else {
            keyUp(voiceKey)
        }
        return false
    }

    /// Set while the app is paused by its blocking pop-up.
    var isLocked = false

    /// A problem when the key is pressed, shown on the Voice page and, since you're usually in
    /// another app, at the bottom of the screen for a few seconds.
    private func startProblem(_ message: String) {
        noteProblem(message)
        showingError = true
        setStatus(message, error: true)
        overlay.show(.failed(message))
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .idle, self.status == shown else { return }
                self.overlay.hide()
            }
        }
    }

    /// Voice typing (both models) needs a Google sign-in first. Set by the app.
    var isSignedIn: () -> Bool = { true }
    var openHome: () -> Void = {}

    private func keyDown(_ key: VoiceKey) {
        // Tap to talk: the same key, pressed again while listening, ends the dictation.
        if tapToTalk, phase == .listening, pressedKey == key { finishListening(key); return }
        guard phase == .idle, pressedAt == nil, !isLocked else { return }
        guard isSignedIn() else {
            startProblem("Sign in with Google in MicFlow to start voice typing. It sets everything up for you.")
            openHome()
            return
        }
        switch engine {
        case .chrome:
            guard chrome.isConnected else {
                chrome.openPageIfNeeded()
                startProblem("Open the MicFlow tab in Chrome (it just opened) and allow the microphone, then try again.")
                return
            }
            chrome.beginListening(language: key.language)
            // Chrome does the listening; MicFlow records only to show the waveform.
            if let input = inputDevice() { try? recorder.start(input, gain: inputGain()) }
        case .geminiLive:
            guard let cachedKey else {
                if hasKey {
                    loadKeyIfNeeded()
                    startProblem("Getting your API key from the Keychain. If macOS asks, click Always Allow, then try again.")
                } else {
                    startProblem("Voice typing isn't set up yet: open MicFlow's Home to finish it (about a minute).")
                    openHome()
                }
                return
            }
            guard let input = inputDevice() else {
                startProblem("No microphone found. Pick one in MicFlow › Sound.")
                return
            }
            do {
                try recorder.start(input, gain: inputGain())
            } catch {
                startProblem(error.localizedDescription)
                return
            }
            screenText = ""
            if screenContext {
                Task.detached { [weak self] in
                    let text = ScreenContext.capture()
                    await MainActor.run { self?.screenText = text }
                }
            }
            connectionLost = false
            overlay.setConnectionLost(false)
            streamTicks = 0
            let live = GeminiLiveTranscriber(key: cachedKey, inputRate: recorder.sampleRate)
            live.onText = { [weak self] text in
                guard let self, self.showLivePreview else { return }
                self.overlay.show(.listening(text))
            }
            self.live = live
            sentSamples = 0
            // Sends what's been recorded every 0.1 s, while the key is held.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.streamNewAudio() }
            }
            RunLoop.main.add(timer, forMode: .common)
            streamTimer = timer
        }
        if polish, let cachedKey { Polisher.warmUp(key: cachedKey) }
        pressedAt = Date()
        pressedKey = key
        phase = .listening
        overlay.setStopVisible(tapToTalk || startedByPill)
        overlay.show(.listening(""))
    }

    private func streamNewAudio() {
        guard let live else { return }
        let new = recorder.samples(from: sentSamples)
        sentSamples += new.count
        live.append(new, sampleRate: recorder.sampleRate)
        // The connection dropped: keep recording; the sound stays on this Mac and is sent again afterwards.
        if !connectionLost, !live.isUsable {
            connectionLost = true
            overlay.setConnectionLost(true)
        }
        // Every 5 seconds the recording so far is written to disk, so it survives a crash or a lost connection.
        streamTicks += 1
        if streamTicks % 50 == 0 { saveAudio(recorder.samples(from: 0), rate: recorder.sampleRate) }
    }

    private func keyUp(_ key: VoiceKey) {
        // In tap to talk, letting go does nothing: the next press ends it.
        guard !tapToTalk else { return }
        finishListening(key)
    }

    private func finishListening(_ key: VoiceKey) {
        guard phase == .listening, let pressedAt, pressedKey == key else { return }
        guard Date().timeIntervalSince(pressedAt) >= Self.minimumHold else {
            cancelRecording()
            return
        }
        let heldFor = Date().timeIntervalSince(pressedAt)
        self.pressedAt = nil
        pressedKey = nil
        startedByPill = false
        overlay.setStopVisible(false)
        let connectionLostAtStop = connectionLost
        connectionLost = false
        overlay.setConnectionLost(false)
        phase = .transcribing
        overlay.show(.transcribing)
        showingError = false
        let engine = self.engine

        // Gemini Live: stop recording and hand over the audio not sent yet.
        var lastSamples: [Float] = []
        /// The whole recording, kept so a failed dictation can be sent again (Retry).
        var fullSamples: [Float] = []
        var fullRate = recorder.sampleRate
        let live = self.live
        if engine == .chrome {
            let all = recorder.stop()
            fullSamples = all
            fullRate = recorder.sampleRate
            saveAudio(all, rate: recorder.sampleRate)
        }
        if engine == .geminiLive {
            streamTimer?.invalidate()
            streamTimer = nil
            let all = recorder.stop()
            fullSamples = all
            fullRate = recorder.sampleRate
            lastSamples = all
            lastRate = recorder.sampleRate
            saveAudio(all, rate: recorder.sampleRate)
            lastSamples = sentSamples < all.count ? Array(all[sentSamples...]) : []
            self.live = nil
        }
        Task {
            do {
                var text: String
                var settled = true
                if connectionLostAtStop {
                    live?.cancel()
                    throw GeminiClient.Failure(message: "The connection dropped while you were talking.")
                }
                if engine == .chrome {
                    guard let heard = await chrome.finishListening(), !heard.isEmpty else {
                        throw GeminiClient.Failure(message: "Model 2 didn't hear anything. Check the microphone setting in Chrome.")
                    }
                    text = heard
                } else {
                    guard let live else { throw GeminiClient.Failure(message: "Model 1 didn't start.") }
                    // What's been heard within about a second of letting go; any last words follow.
                    text = try await live.finish(lastSamples)
                    // The popup closes now; words arriving later go only into the pasted text.
                    live.onText = { _ in }
                    if text.isEmpty { text = await live.settle() } else { settled = false }
                }
                let raw = spellMine(text)
                if TextGuard.looksGarbled(text) { offerRecovery("The last dictation came out as unreadable characters.") }
                overlay.hide()
                setStatus(readyText)
                phase = .idle
                guard !raw.isEmpty else { return }
                // Pasted as heard right away; the full, cleaned-up version replaces it when it's back.
                dictations += 1
                let pasted = PastedText.paste(raw, activity: activity, dictation: dictations)
                loadKeyIfNeeded()
                let willPolish = polish && cachedKey != nil
                // Esc while "Further polishing…" shows stops here and keeps the pasted text.
                var cancelled = false
                let work = Task { () -> String in
                    var full = raw
                    if !settled, let live {
                        let settledText = spellMine(await live.settle())
                        if !settledText.isEmpty { full = settledText }
                    }
                    guard willPolish, !Task.isCancelled, let cachedKey,
                          let polished = await Polisher.polish(full, mixUps: (fixMixUps ? mixUps.filter { $0.meaning != "pronunciation" } : []) + dictionary.pronunciationMixUps,
                                                               yourInstructions: instructionsEnabled ? yourInstructions : "",
                                                               screen: screenText, memory: memory.summary,
                                                               key: cachedKey, timeLimit: 0.8) else { return full }
                    return spellMine(polished)
                }
                let statusID = pasteStatus.pasted(polishing: willPolish) {
                    cancelled = true
                    work.cancel()
                    if let live { live.cancel() }
                    voiceLog.info("Clean-up cancelled with Esc")
                }
                let final = await work.value
                pasteStatus.done(statusID)
                guard !cancelled else {
                    log.add(pasted.text, seconds: heldFor)
                    afterDictation(pasted.text)
                    dictionary.learn(from: pasted.text, samples: lastSamples, sampleRate: lastRate)
                    return
                }
                guard final != pasted.text else {
                    log.add(final, seconds: heldFor)
                    afterDictation(final)
                    dictionary.learn(from: final, samples: lastSamples, sampleRate: lastRate)
                    return
                }
                let outcome = pasted.replace(with: final, activityNow: activity, dictationNow: dictations)
                voiceLog.info("Cleaned-up text \(outcome.rawValue, privacy: .public)")
                // The clipboard always gets the final words, unless you've copied something since.
                if NSPasteboard.general.changeCount == pasted.clipboardChange {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(final, forType: .string)
                }
                log.add(final, seconds: heldFor)
                afterDictation(final)
                return
            } catch {
                noteProblem(error.localizedDescription)
                showingError = true
                setStatus("Couldn't transcribe: \(error.localizedDescription)", error: true)
                // The sound is saved first; then it is sent again for a couple of seconds, and Retry shows if that fails too.
                await recoverFromFailure(samples: fullSamples, rate: fullRate, seconds: heldFor, reason: error.localizedDescription)
            }
            phase = .idle
        }
    }

    // MARK: Recover and memory

    private func saveAudio(_ samples: [Float], rate: Double) {
        Task.detached(priority: .utility) { [weak self] in
            DictationAudio.save(samples, rate: rate)
            await MainActor.run { self?.canRecover = DictationAudio.exists }
        }
    }

    private func afterDictation(_ text: String) {
        DictationAudio.setText(text)
        memory.noteDictation(text, key: cachedKey)
    }

    private func offerRecovery(_ reason: String) {
        recoverOffer = reason
        MicFlowNotifier.shared.notifyRecover(reason)
    }

    func dismissRecoverOffer() { recoverOffer = nil }

    /// Transcribes the saved sound of the last dictation again, in one piece, and types the result (or, if MicFlow is in front, copies it).
    func recoverLast() {
        guard !recovering, phase == .idle, let wav = DictationAudio.load() else {
            setStatus("There is no saved dictation to recover.", error: true)
            return
        }
        loadKeyIfNeeded()
        guard let key = cachedKey else { setStatus("Add your Google key first (Voice page).", error: true); return }
        recovering = true
        recoverOffer = nil
        phase = .transcribing
        overlay.show(.transcribing)
        Task {
            let heard = await BatchTranscriber.transcribeOrdered(wav: wav, googleKey: key)
            recovering = false
            phase = .idle
            guard let heard else {
                overlay.show(.failed("Couldn't transcribe the saved sound. Check your internet connection and try again."))
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                overlay.hide()
                return
            }
            overlay.hide()
            _ = deliverRecovered(heard, seconds: DictationAudio.meta?.seconds ?? 0)
        }
    }

    /// Types (or, if MicFlow is in front, copies) the text of a recording transcribed afterwards. False when there was no text.
    @discardableResult
    private func deliverRecovered(_ heard: String, seconds: Double) -> Bool {
        let text = spellMine(TextGuard.stripStops(TextGuard.sanitize(heard)))
        guard !text.isEmpty else { return false }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            setStatus("Recovered. It is on your clipboard: paste it where you want it.")
        } else {
            dictations += 1
            _ = PastedText.paste(text, activity: activity, dictation: dictations)
            setStatus("Recovered and typed.")
        }
        log.add(text, seconds: seconds)
        DictationAudio.setText(text)
        return true
    }

    // MARK: Offline retry

    /// A dictation couldn't be typed (no connection, or the provider failed). Its sound is saved on this Mac; for a couple of seconds
    /// it is sent again by itself, and if that fails too the pill shows Retry. Without enough sound there is nothing to retry, so
    /// the problem is shown for a few seconds as before.
    private func recoverFromFailure(samples: [Float], rate: Double, seconds: Double, reason: String) async {
        guard RetryStore.save(samples, rate: rate, reason: reason), let wav = RetryStore.load() else {
            overlay.show(.failed(reason))
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            overlay.hide()
            return
        }
        pendingRetry = true
        overlay.setPending(true)
        loadKeyIfNeeded()
        let key = cachedKey
        overlay.show(.reconnecting("Connection problem. Trying again…"))
        let result = await RetryPolicy.run { await BatchTranscriber.transcribeOrdered(wav: wav, googleKey: key) }
        if let heard = result.value, finishRetry(heard, seconds: seconds) { return }
        overlay.show(.retry("Couldn't reach the speech service. Your recording is saved on this Mac. Tap Retry when you're back online."))
    }

    /// Types a retried recording and clears it. False when it had no words.
    private func finishRetry(_ heard: String, seconds: Double) -> Bool {
        guard deliverRecovered(heard, seconds: seconds) else { return false }
        RetryStore.delete()
        pendingRetry = false
        overlay.setPending(false)
        overlay.hide()
        return true
    }

    /// The pill's Retry button: sends the saved sound to the providers again (in the saved order).
    func retryPending() {
        guard phase == .idle, !recovering, let wav = RetryStore.load() else {
            if !RetryStore.exists { dismissPending() }
            return
        }
        loadKeyIfNeeded()
        let key = cachedKey
        let seconds = RetryStore.meta?.seconds ?? 0
        recovering = true
        phase = .transcribing
        overlay.show(.reconnecting("Retrying…"))
        Task {
            let heard = await RetryPolicy.limited(60) { await BatchTranscriber.transcribeOrdered(wav: wav, googleKey: key) }
            recovering = false
            phase = .idle
            if let heard, finishRetry(heard, seconds: seconds) { return }
            overlay.show(.retry("Still can't reach the speech service. Your recording is saved on this Mac. Try again when you're online."))
        }
    }

    /// Drops the saved sound (Dismiss).
    func dismissPending() {
        RetryStore.delete()
        pendingRetry = false
        overlay.setPending(false)
        overlay.hide()
    }

    // MARK: Start from the pill

    /// The pill's Start dictation button: the same as pressing the voice key, ended with the pill's Stop button.
    func startFromPill() {
        guard enabled, phase == .idle, !isLocked else { return }
        startedByPill = true
        keyDown(.bengali)
        if phase != .listening { startedByPill = false }
    }

    func stopFromPill() {
        guard phase == .listening, let key = pressedKey else { return }
        finishListening(key)
    }

    // MARK: Pronunciations

    /// Spells your words your way, and puts the written form wherever the transcript has a pronunciation from the dictionary.
    private func spellMine(_ text: String) -> String {
        MyWords.spell(MyWords.applyPronunciations(text, dictionary.pronunciations), myWords)
    }

    /// Pronunciations travel with your other preferences as mix-ups marked "pronunciation".
    private func syncPronunciations(_ entries: [PersonalDictionary.Entry]) {
        let mirrored: [MixUp] = entries.compactMap { entry in
            guard let sounds = entry.sounds, !sounds.isEmpty else { return nil }
            return MixUp(id: PersonalDictionary.stableID(heard: sounds, meant: entry.word), heard: sounds, meant: entry.word, meaning: "pronunciation")
        }
        mixUps.removeAll { $0.meaning == "pronunciation" }
        mixUps.append(contentsOf: mirrored)
        saveMixUps()
    }

    func deleteSavedSound() {
        DictationAudio.delete()
        canRecover = false
    }

    private func cancelRecording() {
        guard pressedAt != nil else { return }
        pressedAt = nil
        pressedKey = nil
        startedByPill = false
        connectionLost = false
        overlay.setConnectionLost(false)
        overlay.setStopVisible(false)
        chrome.cancelListening()
        streamTimer?.invalidate()
        streamTimer = nil
        live?.cancel()
        live = nil
        _ = recorder.stop()
        phase = .idle
        overlay.hide()
    }
}
