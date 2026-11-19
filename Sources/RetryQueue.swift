import Foundation

/// The sound of a dictation that couldn't be typed (no internet, or the provider failed), kept on this Mac until it has been
/// transcribed or you dismiss it. It lives apart from "the last dictation" (Recover.swift), so a later dictation can't replace
/// it. Always local: nothing is uploaded until you (or the automatic retry) send it for transcription.
enum RetryStore {
    struct Meta: Codable {
        var date: Date
        var seconds: Double
        var reason: String
    }

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicFlow/Pending Retry", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }
    private static var wavURL: URL { folder.appendingPathComponent("pending.wav") }
    private static var metaURL: URL { folder.appendingPathComponent("pending.json") }

    static var exists: Bool { FileManager.default.fileExists(atPath: wavURL.path) }
    static var meta: Meta? { (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) } }
    static func load() -> Data? { try? Data(contentsOf: wavURL) }

    /// Saves a recording (any sample rate) as a 16 kHz mono WAV. Returns whether there was enough sound to keep.
    @discardableResult
    static func save(_ samples: [Float], rate: Double, reason: String = "") -> Bool {
        guard samples.count > Int(rate * 0.3) else { return false }
        var streamer = PCMStreamer(rate: 16_000)
        guard let pcm = streamer.next(samples, inputRate: rate)?.pcm else { return false }
        let data = DictationAudio.wav(pcm: pcm.prefix(Int(DictationAudio.maxSeconds) * 32_000), rate: 16_000)
        do { try data.write(to: wavURL, options: .atomic) } catch { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wavURL.path)
        let meta = Meta(date: Date(), seconds: Double(samples.count) / rate, reason: reason)
        try? JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
        return true
    }

    static func delete() {
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: metaURL)
    }
}

/// How long to keep trying by itself before the Retry button shows.
enum RetryPolicy {
    /// The automatic retry window: "a couple of seconds".
    static let window = 4.0
    /// Pause between automatic attempts.
    static let pause = 1.0

    /// Tries `attempt` until it gives an answer or `window` seconds have passed. Each attempt is cut off after `attemptLimit`
    /// seconds. `sleep` and `clock` are injectable so the policy can be tested without waiting.
    static func run<T: Sendable>(window: Double = RetryPolicy.window, pause: Double = RetryPolicy.pause, attemptLimit: Double = 3,
                                 clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                                 sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                                 attempt: @escaping @Sendable () async -> T?) async -> (value: T?, attempts: Int) {
        let start = clock()
        var attempts = 0
        repeat {
            attempts += 1
            if let value = await limited(attemptLimit, attempt) { return (value, attempts) }
            guard clock() - start + pause < window else { break }
            await sleep(pause)
        } while clock() - start < window
        return (nil, attempts)
    }

    /// The answer of `work`, or nil if it takes longer than `limit` seconds.
    static func limited<T: Sendable>(_ limit: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

extension BatchTranscriber {
    /// Transcribes a whole recording with the providers that can take audio, in the order saved in the settings (Google first until you
    /// reorder), skipping any that is switched off or has no key. Nil when none answers.
    static func transcribeOrdered(wav: Data, googleKey: String?) async -> String? {
        for id in ProviderChain.fullOrder() {
            guard UserDefaults.standard.object(forKey: "provider-on-\(id)") as? Bool ?? true else { continue }
            switch id {
            case "google":
                if let key = googleKey, !key.isEmpty, let text = await google(wav: wav, key: key) { return text }
            case "groq":
                if let key = ProviderKeys.shared.key("groq"), !key.isEmpty, let text = await whisper(wav: wav, key: key) { return text }
            default:
                continue
            }
        }
        return nil
    }
}
