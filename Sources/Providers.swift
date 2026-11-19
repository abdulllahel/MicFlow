import CryptoKit
import Foundation
import os

/// A text model MicFlow can ask to clean up or analyse text. Google AI Studio is the primary one; the others
/// are backups that are used only after a Google API key is saved, and only when Google fails or is slow.
protocol TextProvider: Sendable {
    var id: String { get }
    var name: String { get }
    /// The model's answer, nil if it gave none. Throws on an error or a refusal (including a quota error).
    func generate(system: String, user: String, maxTokens: Int, timeout: Double) async throws -> String?
}

struct ProviderFailure: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
    /// A quota or overload error: the provider is left alone for a minute.
    var isQuota: Bool { status == 429 || status >= 500 }
}

// MARK: Providers

struct GoogleProvider: TextProvider {
    let id = "google"
    let name = "Google AI Studio"
    let key: String
    var model = Polisher.model
    private static let base = "https://generativelanguage.googleapis.com/v1beta/models"

    func generate(system: String, user: String, maxTokens: Int, timeout: Double) async throws -> String? {
        var request = URLRequest(url: URL(string: "\(Self.base)/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": user]]]],
            "generationConfig": ["maxOutputTokens": maxTokens, "temperature": 0, "thinkingConfig": ["thinkingLevel": "minimal"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // Google says why, e.g. which quota ran out.
            let reason = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            throw ProviderFailure(status: status, message: "HTTP \(status) \(reason.prefix(300))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let parts = ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        return parts?.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Groq, OpenAI and OpenRouter all speak the same chat-completions protocol.
struct OpenAICompatibleProvider: TextProvider {
    let id: String
    let name: String
    let endpoint: String
    let model: String
    let key: String

    func generate(system: String, user: String, maxTokens: Int, timeout: Double) async throws -> String? {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model, "temperature": 0, "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let reason = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            throw ProviderFailure(status: status, message: "HTTP \(status) \(reason.prefix(300))")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        return message?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Catalog and keys

/// The backup providers a person can add (after their Google key).
struct BackupProvider: Identifiable {
    let id: String
    let name: String
    let keyPage: URL
    let note: String
    let make: @Sendable (String) -> TextProvider

    static let all: [BackupProvider] = [
        BackupProvider(id: "groq", name: "Groq", keyPage: URL(string: "https://console.groq.com/keys")!,
                       note: "Very fast, with a free plan.",
                       make: { OpenAICompatibleProvider(id: "groq", name: "Groq", endpoint: "https://api.groq.com/openai/v1/chat/completions",
                                                        model: "llama-3.3-70b-versatile", key: $0) }),
        BackupProvider(id: "openrouter", name: "OpenRouter", keyPage: URL(string: "https://openrouter.ai/keys")!,
                       note: "One key for many models.",
                       make: { OpenAICompatibleProvider(id: "openrouter", name: "OpenRouter", endpoint: "https://openrouter.ai/api/v1/chat/completions",
                                                        model: "meta-llama/llama-3.3-70b-instruct", key: $0) }),
        BackupProvider(id: "openai", name: "OpenAI", keyPage: URL(string: "https://platform.openai.com/api-keys")!,
                       note: "Paid.",
                       make: { OpenAICompatibleProvider(id: "openai", name: "OpenAI", endpoint: "https://api.openai.com/v1/chat/completions",
                                                        model: "gpt-4o-mini", key: $0) }),
    ]
}

/// The backup providers' keys, each in MicFlow's encrypted secrets folder (see KeychainSecret). Read once and kept.
final class ProviderKeys: @unchecked Sendable {
    static let shared = ProviderKeys()
    private let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private let loaded = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    private func secret(_ id: String) -> KeychainSecret { KeychainSecret(service: "local.micboost.provider-\(id)") }

    func key(_ id: String) -> String? {
        if loaded.withLock({ $0.contains(id) }) { return cache.withLock { $0[id] } }
        let value = secret(id).load()
        loaded.withLock { _ = $0.insert(id) }
        if let value { cache.withLock { $0[id] = value } }
        return value
    }

    func has(_ id: String) -> Bool { loaded.withLock { $0.contains(id) } ? cache.withLock { $0[id] != nil } : secret(id).exists() }

    func set(_ id: String, _ key: String) {
        secret(id).save(key)
        cache.withLock { $0[id] = key }
        loaded.withLock { _ = $0.insert(id) }
    }

    func remove(_ id: String) {
        secret(id).delete()
        cache.withLock { _ = $0.removeValue(forKey: id) }
        loaded.withLock { _ = $0.insert(id) }
    }
}

// MARK: The chain

enum ProviderChain {
    /// Seconds after which the next provider is tried even if the first hasn't failed (same as the old second request).
    static let hedge = 0.35
    /// Providers that just failed with a quota or server error, and until when. They go to the back of the line.
    private static let cooling = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])
    /// Who answered last, for the settings screen.
    static let lastAnswer = OSAllocatedUnfairLock<String>(initialState: "")

    /// The saved order of provider ids ("google" and the backups). Empty until the user reorders, which means Google first.
    static let orderKey = "provider-order"
    static var savedOrder: [String] { UserDefaults.standard.stringArray(forKey: orderKey) ?? [] }
    static var defaultOrder: [String] { ["google"] + BackupProvider.all.map(\.id) }

    /// Every provider id in the order they are asked: the saved order first, then anything it doesn't mention in the default order.
    static func fullOrder(_ saved: [String] = savedOrder) -> [String] {
        let known = Set(defaultOrder)
        var seen = Set<String>()
        var list = saved.filter { known.contains($0) && seen.insert($0).inserted }
        list += defaultOrder.filter { !seen.contains($0) }
        return list
    }

    /// The providers that can answer (Google needs its key; a backup needs a key and its switch on), in the saved order, with
    /// Google first until the user reorders. Backups exist only once a Google key is saved.
    static func providers(googleKey: String?) -> [TextProvider] {
        guard let googleKey, !googleKey.isEmpty else { return [] }
        var available: [String: TextProvider] = ["google": GoogleProvider(key: googleKey)]
        for backup in BackupProvider.all where UserDefaults.standard.object(forKey: "provider-on-\(backup.id)") as? Bool ?? true {
            if let key = ProviderKeys.shared.key(backup.id), !key.isEmpty { available[backup.id] = backup.make(key) }
        }
        return orderedByHealth(fullOrder().compactMap { available[$0] })
    }

    static func orderedByHealth(_ list: [TextProvider]) -> [TextProvider] {
        let now = Date()
        let cold = cooling.withLock { dict -> Set<String> in
            dict = dict.filter { $0.value > now }
            return Set(dict.keys)
        }
        return list.filter { !cold.contains($0.id) } + list.filter { cold.contains($0.id) }
    }

    static func markCooling(_ id: String, seconds: Double = 60) {
        cooling.withLock { $0[id] = Date().addingTimeInterval(seconds) }
    }

    static func resetHealth() { cooling.withLock { $0.removeAll() } }

    /// Asks the providers in order. The next one starts when the one before fails (error, quota) or has taken `hedge`
    /// seconds, and the first answer wins. Nil when nothing answers within `timeLimit` seconds. With only Google
    /// saved, the second request goes to Google again (the old behaviour).
    static func run(system: String, user: String, maxTokens: Int, googleKey: String?, timeLimit: Double, label: String = "request") async -> String? {
        await run(providers: providers(googleKey: googleKey), system: system, user: user, maxTokens: maxTokens, timeLimit: timeLimit, label: label)
    }

    static func run(providers: [TextProvider], system: String, user: String, maxTokens: Int, timeLimit: Double, label: String = "request") async -> String? {
        guard !providers.isEmpty else { return nil }
        var sequence = providers
        if providers.count == 1 { sequence.append(providers[0]) }
        let failed = OSAllocatedUnfairLock<Set<Int>>(initialState: [])
        let started = Date()
        let result: (name: String, text: String)? = await withTaskGroup(of: (timer: Bool, name: String, text: String?).self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeLimit * 1_000_000_000))
                return (true, "", nil)
            }
            for (index, provider) in sequence.enumerated() {
                group.addTask {
                    // Waits for its turn: `hedge` seconds per place in line, or until the one before has failed.
                    let turn = Double(index) * hedge
                    let begin = Date()
                    while Date().timeIntervalSince(begin) < turn {
                        if index > 0, failed.withLock({ $0.contains(index - 1) }) { break }
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        if Task.isCancelled { return (false, provider.name, nil) }
                    }
                    guard !Task.isCancelled else { return (false, provider.name, nil) }
                    let remaining = max(0.2, timeLimit - Date().timeIntervalSince(started))
                    do {
                        if let text = try await provider.generate(system: system, user: user, maxTokens: maxTokens, timeout: remaining), !text.isEmpty {
                            return (false, provider.name, text)
                        }
                    } catch {
                        if !Task.isCancelled {
                            voiceLog.info("\(provider.name, privacy: .public) failed (\(label, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                            if (error as? ProviderFailure)?.isQuota ?? false { markCooling(provider.id) }
                        }
                    }
                    failed.withLock { _ = $0.insert(index) }
                    return (false, provider.name, nil)
                }
            }
            var answer: (String, String)?
            var failures = 0
            while let item = await group.next() {
                if let text = item.text { answer = (item.name, text); break }
                if item.timer { break }
                failures += 1
                if failures == sequence.count { break }
            }
            group.cancelAll()
            return answer
        }
        guard let result else { return nil }
        lastAnswer.withLock { $0 = result.name }
        voiceLog.info("\(result.name, privacy: .public) answered (\(label, privacy: .public)) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return result.text
    }

    // MARK: Self test (run with `MicFlow --selftest-providers`)

    private struct Mock: TextProvider {
        let id: String
        var name: String { id }
        var delay = 0.0
        var failure: ProviderFailure?
        var answer = "ok"
        func generate(system: String, user: String, maxTokens: Int, timeout: Double) async throws -> String? {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if let failure { throw failure }
            return "\(answer)-\(id)"
        }
    }

    static func selfTest() async -> [String] {
        var lines: [String] = []
        func check(_ title: String, _ passed: Bool, _ detail: String = "") { lines.append("\(passed ? "PASS" : "FAIL") \(title) \(detail)") }
        func timed(_ providers: [TextProvider], limit: Double) async -> (String?, Double) {
            let start = Date()
            let answer = await run(providers: providers, system: "", user: "", maxTokens: 8, timeLimit: limit)
            return (answer, Date().timeIntervalSince(start))
        }
        // 1. Google answers: nobody else is asked.
        var r = await timed([Mock(id: "google"), Mock(id: "groq")], limit: 0.8)
        check("primary answers", r.0 == "ok-google", "\(r)")
        // 2. Google fails with a 429: Groq answers at once, well before the hedge.
        r = await timed([Mock(id: "google", failure: ProviderFailure(status: 429, message: "quota")), Mock(id: "groq")], limit: 0.8)
        check("falls back on 429", r.0 == "ok-groq" && r.1 < 0.25, "\(r)")
        // 3. Google is slow: Groq answers after the hedge.
        r = await timed([Mock(id: "google", delay: 3), Mock(id: "groq")], limit: 0.8)
        check("falls back on slow primary", r.0 == "ok-groq" && r.1 > 0.3 && r.1 < 0.6, "\(r)")
        // 4. Everything fails: nil, quickly.
        r = await timed([Mock(id: "google", failure: ProviderFailure(status: 500, message: "x")), Mock(id: "groq", failure: ProviderFailure(status: 401, message: "x"))], limit: 0.8)
        check("all fail gives nil", r.0 == nil && r.1 < 0.5, "\(r)")
        // 5. The time limit holds.
        r = await timed([Mock(id: "google", delay: 5), Mock(id: "groq", delay: 5)], limit: 0.5)
        check("time limit holds", r.0 == nil && r.1 < 0.75, "\(r)")
        // 6. A provider that hit its quota goes to the back for a minute.
        resetHealth()
        markCooling("google")
        let order = orderedByHealth([Mock(id: "google"), Mock(id: "groq")]).map(\.id)
        check("cooling provider goes last", order == ["groq", "google"], "\(order)")
        resetHealth()
        // 6b. The saved order is applied; Google stays first until it is changed; unknown ids are dropped.
        check("default order has Google first", fullOrder([]).first == "google")
        check("saved order wins", fullOrder(["groq", "zzz", "google"]) == ["groq", "google", "openrouter", "openai"], "\(fullOrder(["groq", "zzz", "google"]))")
        // 7. Backups appear only with a Google key.
        check("no providers without a Google key", providers(googleKey: nil).isEmpty && providers(googleKey: "").isEmpty)
        check("Google alone with only its key", providers(googleKey: "k").first?.id == "google")
        // 8. The garble detector, the stray-letter filter, the memory parser and the saved-sound format.
        check("English is not garbled", !TextGuard.looksGarbled("Hello, how are you today? I will send the file soon."))
        check("Bengali is not garbled", !TextGuard.looksGarbled("আমি ওটা পরীক্ষা করে দেখি, তারপর বলব ভালো লাগবে কি না।"))
        check("mixed is not garbled", !TextGuard.looksGarbled("আমি এখন office এ আছি, send the report."))
        check("byte noise is garbled", TextGuard.looksGarbled("¤¨ ¡¢£ ¿¾½ Ã¤Â¦ ÃƒÂ¢ @#$ ~~|"))
        check("stray Gurmukhi letter removed", TextGuard.sanitize("ভয়েਸগুলো") == "ভয়েগুলো")
        let parsed = MemoryStore.parse("Sure: [{\"kind\":\"job\",\"text\":\"Product designer\"},{\"kind\":\"x\",\"text\":\"Uses Figma daily\"},{\"text\":\"\"}] done")
        check("memory parser", parsed.count == 2 && parsed[0].kind == .job && parsed[1].kind == .other, "\(parsed.map(\.text))")
        let wav = DictationAudio.wav(pcm: Data(count: 3200), rate: 16_000)
        check("wav header", wav.count == 44 + 3200 && String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        lines += CrossSync.selfTest()
        return lines
    }

    /// `MicFlow --selftest-providers` prints the results and exits. Runs before anything else starts, so it never touches a MicFlow that is already open.
    static func selfTestIfAsked() {
        guard CommandLine.arguments.contains("--selftest-providers") else { return }
        final class Box: @unchecked Sendable { var lines: [String] = [] }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.lines = await selfTest(); done.signal() }
        done.wait()
        print(box.lines.joined(separator: "\n"))
        exit(box.lines.contains { $0.hasPrefix("FAIL") } ? 1 : 0)
    }
}

// MARK: Settings

/// What the settings screen shows: which backups have keys, and a test button for each.
@MainActor
final class ProviderSettings: ObservableObject {
    @Published private(set) var saved: Set<String> = Set(BackupProvider.all.map(\.id).filter { ProviderKeys.shared.has($0) })
    @Published private(set) var testing: String?
    @Published private(set) var results: [String: String] = [:]
    @Published private(set) var lastAnswer = ""
    /// Bumped whenever a key or switch changes (here or from another device), so the account copy is saved.
    @Published private(set) var revision = 0

    /// What the account shares: every provider's key, the order and the switches, each with the time it last changed. Kept
    /// here too, encrypted, so a delete survives a restart and keys of providers this Mac doesn't use are never lost.
    private var state = ProviderSyncState()
    private static let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MicFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ProvidersSync.sealed")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.file), let box = try? AES.GCM.SealedBox(combined: data),
           let plain = try? AES.GCM.open(box, using: KeychainSecret.key), let text = String(data: plain, encoding: .utf8),
           let stored = CrossSync.decodeProviders(text) { state = stored }
        reconcile()
        if let list = state.order?.list { UserDefaults.standard.set(list, forKey: ProviderChain.orderKey) }
    }

    /// The order shown and used: the account's order if there is one, else Google first.
    var order: [String] { ProviderChain.fullOrder(state.order?.list ?? ProviderChain.savedOrder) }

    /// Moves a provider one place up (-1) or down (+1). The new order is dated now, so it wins on the other devices too.
    func move(_ id: String, by step: Int) {
        var list = order
        guard let i = list.firstIndex(of: id), list.indices.contains(i + step) else { return }
        list.swapAt(i, i + step)
        state.order = .init(list: list, t: CrossSync.nowMs())
        UserDefaults.standard.set(list, forKey: ProviderChain.orderKey)
        changed()
        objectWillChange.send()
    }

    func isOn(_ id: String) -> Bool { UserDefaults.standard.object(forKey: "provider-on-\(id)") as? Bool ?? true }

    func setOn(_ id: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "provider-on-\(id)")
        state.enabled[id] = .init(on: on, t: CrossSync.nowMs())
        changed()
        objectWillChange.send()
    }

    func save(_ id: String, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ProviderKeys.shared.set(id, trimmed)
        saved.insert(id)
        results[id] = nil
        state.keys[id] = .init(key: trimmed, t: CrossSync.nowMs(), deleted: false)
        changed()
    }

    func remove(_ id: String) {
        ProviderKeys.shared.remove(id)
        saved.remove(id)
        results[id] = nil
        state.keys[id] = .init(key: "", t: CrossSync.nowMs(), deleted: true)
        changed()
    }

    // MARK: Account sync

    /// Keys and switches set before sync existed (or changed outside the screen) become entries with today's time.
    private func reconcile() {
        var touched = false
        for backup in BackupProvider.all {
            if let key = ProviderKeys.shared.key(backup.id), !key.isEmpty, state.keys[backup.id]?.key != key || state.keys[backup.id]?.deleted == true {
                state.keys[backup.id] = .init(key: key, t: CrossSync.nowMs(), deleted: false)
                touched = true
            }
            if let on = UserDefaults.standard.object(forKey: "provider-on-\(backup.id)") as? Bool, state.enabled[backup.id]?.on != on {
                state.enabled[backup.id] = .init(on: on, t: CrossSync.nowMs())
                touched = true
            }
        }
        if touched { persist() }
    }

    /// The Google key also travels under `providers.keys.google`; it is dated from when this Mac last saw it change.
    private func mirror(googleKey: String?) {
        guard let googleKey, !googleKey.isEmpty, state.keys["google"]?.key != googleKey || state.keys["google"]?.deleted == true else { return }
        state.keys["google"] = .init(key: googleKey, t: CrossSync.nowMs(), deleted: false)
    }

    /// The state to send to the account.
    func syncState(googleKey: String?) -> ProviderSyncState {
        mirror(googleKey: googleKey)
        persist()
        return state
    }

    /// Merges what the account holds into this Mac (see CrossSync) and writes the result into the keys and switches here.
    /// Returns the merged state, and whether this Mac changed.
    @discardableResult
    func merge(remote: ProviderSyncState, googleKey: String?) -> (merged: ProviderSyncState, changed: Bool) {
        mirror(googleKey: googleKey)
        let merged = CrossSync.mergeProviders(local: state, remote: remote)
        let didChange = merged != state
        state = merged
        if let list = merged.order?.list { UserDefaults.standard.set(list, forKey: ProviderChain.orderKey) }
        for backup in BackupProvider.all {
            if let entry = merged.keys[backup.id] {
                if entry.deleted, ProviderKeys.shared.has(backup.id) { ProviderKeys.shared.remove(backup.id); saved.remove(backup.id) }
                else if !entry.deleted, !entry.key.isEmpty, ProviderKeys.shared.key(backup.id) != entry.key { ProviderKeys.shared.set(backup.id, entry.key); saved.insert(backup.id) }
            }
            if let flag = merged.enabled[backup.id], UserDefaults.standard.object(forKey: "provider-on-\(backup.id)") as? Bool != flag.on {
                UserDefaults.standard.set(flag.on, forKey: "provider-on-\(backup.id)")
            }
        }
        persist()
        if didChange { revision += 1; objectWillChange.send() }
        return (merged, didChange)
    }

    private func changed() {
        revision += 1
        persist()
    }

    private func persist() {
        guard let text = CrossSync.encodeProviders(state), let sealed = try? AES.GCM.seal(Data(text.utf8), using: KeychainSecret.key).combined else { return }
        try? sealed.write(to: Self.file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }

    func test(_ backup: BackupProvider) {
        guard let key = ProviderKeys.shared.key(backup.id), testing == nil else { return }
        testing = backup.id
        Task {
            let answer: String?
            var message = ""
            do {
                answer = try await backup.make(key).generate(system: "Reply with the single word OK.", user: "ping", maxTokens: 8, timeout: 8)
            } catch {
                answer = nil
                message = error.localizedDescription
            }
            results[backup.id] = answer != nil ? "Works" : (message.isEmpty ? "No answer" : message)
            lastAnswer = ProviderChain.lastAnswer.withLock { $0 }
            testing = nil
        }
    }
}
