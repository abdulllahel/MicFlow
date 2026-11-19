import Foundation
import CryptoKit

/// The last dictation's sound, kept on this Mac so it can be transcribed again when the text came out wrong (or the
/// connection failed). One recording only: each new dictation replaces it. Deleted by "Delete the saved sound".
enum DictationAudio {
    struct Meta: Codable {
        var date: Date
        var seconds: Double
        var text: String
    }

    static let maxSeconds = 300.0

    private static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicFlow/Last Dictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }
    private static var wavURL: URL { folder.appendingPathComponent("last.wav") }
    private static var metaURL: URL { folder.appendingPathComponent("last.json") }

    static var exists: Bool { FileManager.default.fileExists(atPath: wavURL.path) }
    static var meta: Meta? { (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) } }

    /// Saves the recording as a 16 kHz mono WAV. Call off the main thread.
    static func save(_ samples: [Float], rate: Double) {
        guard samples.count > Int(rate * 0.3) else { return }
        var streamer = PCMStreamer(rate: 16_000)
        guard let pcm = streamer.next(samples, inputRate: rate)?.pcm else { return }
        let data = wav(pcm: pcm.prefix(Int(maxSeconds) * 32_000), rate: 16_000)
        try? data.write(to: wavURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wavURL.path)
        let meta = Meta(date: Date(), seconds: Double(samples.count) / rate, text: "")
        try? JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
    }

    /// Remembers what was typed for this recording.
    static func setText(_ text: String) {
        guard var meta else { return }
        meta.text = text
        try? JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
    }

    static func load() -> Data? { try? Data(contentsOf: wavURL) }

    static func delete() {
        try? FileManager.default.removeItem(at: wavURL)
        try? FileManager.default.removeItem(at: metaURL)
    }

    static func wav(pcm: Data, rate: Int) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); data.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

/// Transcribes a whole recording at once (not live): Google first, then Groq's Whisper if a Groq key is saved.
enum BatchTranscriber {
    static let prompt = """
        Transcribe this recording exactly as spoken. The speaker talks English, Bengali, or both mixed in one sentence. \
        Write English words in English (Latin) letters and Bengali words in Bengali script: never write English in Bengali \
        letters and never translate. Do not add words that were not said and do not summarise. Use normal punctuation, with \
        a full stop only where a thought really ends. Reply with the transcript only.
        """

    static func transcribe(wav: Data, googleKey: String) async -> String? {
        if let text = await google(wav: wav, key: googleKey) { return text }
        if let groq = ProviderKeys.shared.key("groq"), !groq.isEmpty,
           UserDefaults.standard.object(forKey: "provider-on-groq") as? Bool ?? true {
            return await whisper(wav: wav, key: groq)
        }
        return nil
    }

    static func google(wav: Data, key: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt], ["inlineData": ["mimeType": "audio/wav", "data": wav.base64EncodedString()]]]]],
            "generationConfig": ["temperature": 0, "thinkingConfig": ["thinkingLevel": "minimal"]],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = payload
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let parts = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        let text = parts?.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    static func whisper(wav: Data, key: String) async -> String? {
        let boundary = "micflow-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", "whisper-large-v3")
        field("response_format", "json")
        field("temperature", "0")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"last.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["text"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
