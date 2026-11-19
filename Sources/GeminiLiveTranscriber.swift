import Foundation

/// Gemini's live speech-to-text (`gemini-3.5-transcribe-live` over the Live API WebSocket). It only
/// writes down what's said, never replies, and handles English and Bengali mixed in one sentence.
/// "Smart" mode drops filler words and punctuates as it goes. The server finalizes a segment at
/// each pause; releasing the hotkey sends the end of the audio, which flushes the last one.
@MainActor
final class GeminiLiveTranscriber: LiveTranscriber {
    static let model = "gemini-3.5-transcribe-live"
    private static let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    var onText: (String) -> Void = { _ in }

    private let socket: URLSessionWebSocketTask
    private let sender: WebSocketSender
    /// The API takes 16 kHz mono 16-bit PCM.
    private var streamer = PCMStreamer(rate: 16_000)
    private var inputRate: Double
    private var failure: LiveTranscriptionFailure?
    private var closed = false
    /// Audio can only be sent once the server has accepted the setup; until then it waits here.
    private var ready = false
    private var waiting: [[String: Any]] = []

    // Finished segments, and the server's current guess at the one being spoken.
    private var finals = ""
    private var segments: [String] = []
    private var interim = ""
    private var ended = false
    private var finalAfterEnd = false
    private var turnComplete = false
    /// Whether speech was sent since the last finished segment: then a final segment is still due.
    private var speechSinceFinal = false
    /// RMS above this counts as speech rather than silence or background noise.
    private static let speechLevel: Float = 0.02

    var isUsable: Bool { !closed && failure == nil }

    var text: String {
        Self.spaceSentences(Self.join(finals, visibleInterim)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: English written in Bengali letters
    // The recognizer sometimes writes English speech in Bengali letters. Each finished piece with Bengali letters is checked
    // by a quick model that puts English back into English; a guess still being spoken is held back (in an English
    // conversation) until it has been checked, so wrong letters don't flash in the preview.
    private let key: String
    private var pendingFixes = 0
    private var interimFix: (source: String, fixed: String)?
    private var interimFixRunning = false
    private var lastInterimFix = Date.distantPast

    private static func hasBengali(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0980...0x09FF).contains($0.value) }
    }

    /// True once the finished words are mostly Latin letters: an English conversation.
    private var englishContext: Bool {
        let letters = finals.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 12 else { return false }
        let latin = letters.filter { $0.value < 0x0250 }.count
        return Double(latin) / Double(letters.count) >= 0.6
    }

    /// The guess at the piece being spoken, as shown: a Bengali-looking guess in an English conversation waits for its check.
    private var visibleInterim: String {
        guard Self.hasBengali(interim) else { return interim }
        if let fix = interimFix, interim.hasPrefix(fix.source) { return fix.fixed + String(interim.dropFirst(fix.source.count)) }
        return englishContext ? "" : interim
    }

    private func checkInterim() {
        guard Self.hasBengali(interim), !interimFixRunning, Date().timeIntervalSince(lastInterimFix) > 0.7 else { return }
        if interimFix.map({ interim.hasPrefix($0.source) && $0.source.count + 6 >= interim.count }) == true { return }
        interimFixRunning = true
        lastInterimFix = Date()
        let source = interim, before = finals
        Task {
            let fixed = await Polisher.fixScript(source, context: before, key: key)
            interimFixRunning = false
            guard !closed, interim.hasPrefix(source) else { return }
            // No answer within the limit: the guess is shown as it is.
            interimFix = (source, fixed ?? source)
            onText(text)
        }
    }

    private func checkSegment(at index: Int) {
        let original = segments[index]
        guard Self.hasBengali(original) else { return }
        let before = segments.prefix(index).reduce("") { Self.join($0, $1) }
        pendingFixes += 1
        Task {
            let fixed = await Polisher.fixScript(original, context: before, key: key)
            pendingFixes -= 1
            guard let fixed, fixed != original, index < segments.count, segments[index] == original else { return }
            segments[index] = fixed
            finals = segments.reduce("") { Self.join($0, $1) }
            onText(text)
        }
    }

    /// Waits (briefly) for the checks of finished pieces, so the last words are right before they are used.
    private func waitForFixes(upTo limit: Double) async {
        let start = Date()
        while pendingFixes > 0, Date().timeIntervalSince(start) < limit { try? await Task.sleep(nanoseconds: 40_000_000) }
    }

    init(key: String, inputRate: Double) {
        self.key = key
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        socket = URLSession.shared.webSocketTask(with: components.url!)
        sender = WebSocketSender(socket)
        self.inputRate = inputRate
        sender.onError = { [weak self] in self?.fail(Self.describe($0, socket: nil)) }
        socket.resume()
        // Only English and Bengali. With no list it picks from 85+ languages, and Bengali after
        // English could come back as Hindi written in Latin letters. It still mixes the two.
        // No `customVocabulary`: with a word in it, the model writes that word into pauses and
        // unclear sounds even when nobody said it ("Figma" in 2 of 3 tests where it was never
        // spoken, and right without it). The user's words fix spelling afterwards instead.
        let transcription: [String: Any] = ["languageCodes": ["en-US", "bn-BD"], "mode": "SMART"]
        // Sent ahead of everything else; audio waits for `setupComplete`.
        sender.send(["setup": [
            "model": "models/\(Self.model)",
            "generationConfig": ["responseModalities": ["TEXT"]],
            "inputAudioTranscription": transcription,
        ]])
        Task { await receiveLoop() }
    }

    func append(_ samples: [Float], sampleRate: Double) {
        guard !closed else { return }
        inputRate = sampleRate
        guard let chunk = streamer.next(samples, inputRate: sampleRate) else { return }
        if chunk.level > Self.speechLevel { speechSinceFinal = true }
        send(["realtimeInput": ["audio": ["data": chunk.pcm.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    /// Sends the end of the audio and returns what's been heard within about a second, so it can be
    /// pasted at once. Words still on their way come from `settle()`.
    func finish(_ lastSamples: [Float]) async throws -> String {
        append(lastSamples, sampleRate: inputRate)
        send(["realtimeInput": ["audioStreamEnd": true]])
        ended = true
        try await wait(upTo: 0.8)
        if let failure, text.isEmpty { close(); throw failure }
        return text
    }

    /// Waits a few more seconds for the words spoken just before the key was released (the server
    /// runs a little behind the voice), then closes. Returns the full text.
    func settle() async -> String {
        try? await wait(upTo: 3)
        await waitForFixes(upTo: 1.5)
        close()
        return text
    }

    private func wait(upTo limit: Double) async throws {
        let start = Date()
        while failure == nil, !closed, !turnComplete {
            let pending = !interim.isEmpty || speechSinceFinal
            if !pending, finalAfterEnd || Date().timeIntervalSince(start) > 0.3 { break }
            if Date().timeIntervalSince(start) > limit { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    func cancel() { close() }

    // MARK: Socket

    private func send(_ event: [String: Any]) {
        if ready {
            sender.send(event)
        } else {
            waiting.append(event)
        }
    }

    private func receiveLoop() async {
        while !closed {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                if !closed { fail(Self.describe(error, socket: socket)) }
                return
            }
            guard let json = message.json else { continue }
            handle(json)
        }
    }

    private func handle(_ json: [String: Any]) {
        if json["setupComplete"] != nil {
            ready = true
            waiting.forEach(sender.send)
            waiting = []
        }
        if let error = json["error"] as? [String: Any] {
            fail(LiveTranscriptionFailure(message: ProviderName.hide(error["message"] as? String ?? "Model 1 returned an error.")))
        }
        guard let content = json["serverContent"] as? [String: Any] else { return }
        if let final = (content["inputTranscription"] as? [String: Any])?["text"] as? String, !final.isEmpty {
            // The server can repeat a finished segment, or resend it with more words on the end: each part
            // is written down once.
            let norm = { (t: String) in t.lowercased().filter { $0.isLetter || $0.isNumber } }
            let new = norm(final)
            Self.logSegment(final)
            if new.isEmpty {
                segments.append(final)
            } else if let last = segments.last, new.hasPrefix(norm(last)), norm(last).count > 3 {
                segments[segments.count - 1] = final
            } else if !segments.suffix(4).contains(where: { norm($0) == new }), !(norm(finals).hasSuffix(new) && new.count > 8) {
                segments.append(final)
            }
            finals = segments.reduce("") { Self.join($0, $1) }
            interim = ""
            interimFix = nil
            speechSinceFinal = false
            if ended { finalAfterEnd = true }
            if !segments.isEmpty { checkSegment(at: segments.count - 1) }
            onText(text)
        }
        if let guess = (content["interimInputTranscription"] as? [String: Any])?["text"] as? String {
            interim = guess
            checkInterim()
            onText(text)
        }
        if ended, content["turnComplete"] as? Bool == true { turnComplete = true }
    }

    /// The last dictation's raw segments, kept in a small file so a repeated sentence can be traced.
    private static func logSegment(_ text: String) {
        // Only in debug builds: spoken words are never written to disk in the released app.
        #if DEBUG
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MicFlow")
        let url = dir.appendingPathComponent("last-segments.txt")
        let line = "\(Date()): \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        #endif
    }

    private func fail(_ error: LiveTranscriptionFailure) {
        if failure == nil { failure = error }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        socket.cancel(with: .normalClosure, reason: nil)
    }

    /// Joins pieces of text with a space, unless one is already there.
    private static func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty, !b.isEmpty else { return a + b }
        return a.last!.isWhitespace || b.first!.isWhitespace ? a + b : a + " " + b
    }

    /// Segments can arrive glued together ("…ka.কিন্তু", "help.But"): puts a space after a sentence
    /// ending that runs straight into a capital letter or Bengali text. (Lower-case words are left
    /// alone, so web addresses and decimals keep their dots.)
    private static func spaceSentences(_ text: String) -> String {
        text.replacingOccurrences(of: "(?<=[.?!।])(?=[A-Z\\u0980-\\u09FF])", with: " ", options: .regularExpression)
    }

    /// The server explains a refused setup (a bad key, an unknown model) in the close reason.
    private static func describe(_ error: Error, socket: URLSessionWebSocketTask?) -> LiveTranscriptionFailure {
        if let reason = socket?.closeReason.flatMap({ String(data: $0, encoding: .utf8) }), !reason.isEmpty {
            return LiveTranscriptionFailure(message: "Model 1: \(ProviderName.hide(reason))")
        }
        if let error = error as? URLError, error.code == .badServerResponse || error.code == .userAuthenticationRequired {
            return LiveTranscriptionFailure(message: "Model 1 refused the connection. Check your API key.")
        }
        return LiveTranscriptionFailure(message: "Couldn't reach Model 1: \(error.localizedDescription)")
    }
}
