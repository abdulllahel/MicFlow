import Foundation
import CryptoKit

/// One thing MicFlow knows about the speaker.
struct MemoryItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case job, skill, preference, style, vocabulary, other
        var title: String {
            switch self {
            case .job: return "Job"
            case .skill: return "Skill or field"
            case .preference: return "Preference"
            case .style: return "Writing style"
            case .vocabulary: return "Words I use"
            case .other: return "Other"
            }
        }
    }
    var id = UUID()
    var kind: Kind
    var text: String
    var date = Date()
    /// Learned from what was said (false: written by the person).
    var learned = true
    /// When it last changed, in milliseconds (nil on lines saved before sync existed: their date is used).
    var stamp: Int64?
    var time: Int64 { stamp ?? Int64(date.timeIntervalSince1970 * 1000) }
    /// The id this line has on every device (see CrossSync.memoryID).
    var syncID: String { CrossSync.memoryID(text) }

    /// The name of the kind on the wire: job, skill, preference, style or word (the same on every platform).
    var wireKind: String { kind.wire }
}

extension MemoryItem.Kind {
    var wire: String {
        switch self {
        case .job: return "job"
        case .skill: return "skill"
        case .preference: return "preference"
        case .style, .other: return "style"
        case .vocabulary: return "word"
        }
    }

    init(wire: String) {
        switch wire {
        case "job": self = .job
        case "skill": self = .skill
        case "preference": self = .preference
        case "style": self = .style
        case "word", "vocabulary": self = .vocabulary
        default: self = .other
        }
    }
}

/// A deleted line, remembered for 90 days so an old copy on another device can't bring it back.
struct MemoryTombstone: Codable, Equatable {
    var id: String
    var t: Int64
}

private struct MemoryFile: Codable {
    var items: [MemoryItem]
    var tombstones: [MemoryTombstone]
}

/// What MicFlow learns from how you speak: your job, your field, your preferences and the words you use. It makes the clean-up
/// choose better spellings and tone. Everything is shown in the Memory card, where each line can be edited or deleted. It is kept
/// on this Mac in an encrypted file (AES-GCM, the key never leaves the Mac), and, while you are signed in, a second copy sealed
/// with your account's key is saved to your account so it comes back when you sign in again.
@MainActor
final class MemoryStore: ObservableObject {
    @Published private(set) var items: [MemoryItem] = []
    private var tombstones: [MemoryTombstone] = []
    @Published private(set) var status = ""
    @Published private(set) var learning = false
    @Published var learningOn: Bool {
        didSet { UserDefaults.standard.set(learningOn, forKey: "memoryLearning") }
    }
    /// Bumped on every change, so account sync can tell when to save.
    @Published private(set) var revision = 0

    /// Set once the account's copy has been read, so an empty copy here never replaces what the account holds.
    var pulledFromAccount = false
    private static let limit = 80
    private var recent: [String] = []
    private var lastLearned = Date.distantPast
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MicFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Memory.sealed")
    }()

    init() {
        learningOn = UserDefaults.standard.object(forKey: "memoryLearning") as? Bool ?? true
        let stored = Self.open(try? Data(contentsOf: file))
        items = stored?.items ?? []
        tombstones = stored?.tombstones ?? []
    }

    // MARK: Editing

    func add(_ kind: MemoryItem.Kind, _ text: String) {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !clean.isEmpty, !items.contains(where: { $0.syncID == CrossSync.memoryID(clean) }) else { return }
        var item = MemoryItem(kind: kind, text: clean, learned: false)
        item.stamp = CrossSync.nowMs()
        forget(item.syncID)
        items.append(item)
        changed()
    }

    func update(_ id: UUID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard clean != items[index].text else { return }
        let old = items[index]
        if clean.isEmpty { items.remove(at: index) } else if items.contains(where: { $0.id != id && $0.syncID == CrossSync.memoryID(clean) }) {
            items.remove(at: index)
        } else {
            items[index].text = clean
            items[index].learned = false
            items[index].date = Date()
            items[index].stamp = CrossSync.nowMs()
        }
        // The old wording is a delete, so other devices drop it too.
        if old.syncID != CrossSync.memoryID(clean) { tombstones.removeAll { $0.id == old.syncID }; tombstones.append(MemoryTombstone(id: old.syncID, t: CrossSync.nowMs())) }
        if !clean.isEmpty { forget(CrossSync.memoryID(clean)) }
        changed()
    }

    func setKind(_ id: UUID, _ kind: MemoryItem.Kind) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].kind = kind
        items[index].stamp = CrossSync.nowMs()
        changed()
    }

    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        tombstone(item.syncID)
        changed()
    }

    func clear() {
        for item in items { tombstone(item.syncID) }
        items = []
        recent = []
        changed()
    }

    /// Remembers that a line was deleted now.
    private func tombstone(_ id: String) {
        tombstones.removeAll { $0.id == id }
        tombstones.append(MemoryTombstone(id: id, t: CrossSync.nowMs()))
    }

    /// A line that is (re)added is no longer deleted.
    private func forget(_ id: String) { tombstones.removeAll { $0.id == id } }

    // MARK: What the clean-up reads

    /// A short description for the clean-up prompt.
    var summary: String {
        guard !items.isEmpty else { return "" }
        var lines: [String] = []
        for kind in MemoryItem.Kind.allCases {
            let texts = items.filter { $0.kind == kind }.map(\.text)
            if !texts.isEmpty { lines.append("\(kind.title): " + texts.joined(separator: "; ")) }
        }
        return String(lines.joined(separator: "\n").prefix(900))
    }

    // MARK: Learning

    /// Called after each dictation. Every few dictations (and at most every two minutes) the recent ones are looked at.
    func noteDictation(_ text: String, key: String?) {
        guard learningOn else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 12, !TextGuard.looksGarbled(clean) else { return }
        recent.append(String(clean.prefix(600)))
        if recent.count > 12 { recent.removeFirst(recent.count - 12) }
        if recent.count >= 6, Date().timeIntervalSince(lastLearned) > 120 { learn(key: key) }
    }

    /// Looks at the recent dictations and adds what they show about the speaker. Nothing is invented: only things the speaker said.
    func learn(key: String?) {
        guard !learning, let key, !recent.isEmpty else { return }
        learning = true
        lastLearned = Date()
        let batch = recent
        recent = []
        let known = items.map { "\($0.kind.rawValue): \($0.text)" }.joined(separator: "\n")
        Task {
            defer { learning = false }
            let system = """
                You build a small private profile of a speaker from their dictated messages (English, Bengali or mixed). \
                Find durable facts the speaker clearly showed or stated: their job or role, the field or skills they work in, \
                preferences about how they write (tone, language, formatting), and names, brands or technical terms they use \
                often (spelled the way they write them).
                Rules: only facts that are clear from the messages; never guess. Skip anything about health, money, passwords, \
                addresses, phone numbers, other people's private matters, and one-off events. Each fact is a short phrase in the \
                language the speaker used. Do not repeat facts that are already known. At most 6 new facts; an empty list is fine.
                Reply with only a JSON array like [{"kind":"job","text":"Product designer at a software company"}], where kind is \
                one of job, skill, preference, style, vocabulary, other.
                """
            let user = "Already known:\n\(known.isEmpty ? "(nothing)" : known)\n\nRecent messages:\n" + batch.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            guard let answer = await ProviderChain.run(system: system, user: user, maxTokens: 500, googleKey: key, timeLimit: 25, label: "memory") else {
                recent = batch + recent
                return
            }
            var added = 0
            for var fact in Self.parse(answer) where !items.contains(where: { $0.syncID == fact.syncID }) {
                fact.stamp = CrossSync.nowMs()
                forget(fact.syncID)
                items.append(fact)
                added += 1
            }
            trimToLimit()
            status = added > 0 ? "Learned \(added) new thing\(added == 1 ? "" : "s")." : "Nothing new learned."
            if added > 0 { changed() }
        }
    }

    nonisolated static func parse(_ answer: String) -> [MemoryItem] {
        guard let start = answer.firstIndex(of: "["), let end = answer.lastIndex(of: "]"), start < end,
              let data = String(answer[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let facts: [MemoryItem] = array.compactMap { entry in
            guard let text = (entry["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), text.count >= 3 else { return nil }
            let clean = TextGuard.sanitize(text)
            guard !TextGuard.looksGarbled(clean) else { return nil }
            let kind = (entry["kind"] as? String).flatMap(MemoryItem.Kind.init(rawValue:)) ?? .other
            return MemoryItem(kind: kind, text: String(clean.prefix(200)))
        }
        return Array(facts.prefix(6))
    }

    // MARK: Storage

    private func changed() {
        revision += 1
        save()
    }

    private func save() {
        trimTombstones()
        guard let json = try? JSONEncoder().encode(MemoryFile(items: items, tombstones: tombstones)),
              let sealed = try? AES.GCM.seal(json, using: KeychainSecret.key).combined else { return }
        try? sealed.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The oldest lines go when there are more than the limit; they are deleted everywhere, not just here.
    private func trimToLimit() {
        guard items.count > Self.limit else { return }
        let dropped = items.sorted { $0.time < $1.time }.prefix(items.count - Self.limit)
        let ids = Set(dropped.map(\.id))
        for item in dropped { tombstone(item.syncID) }
        items.removeAll { ids.contains($0.id) }
    }

    private func trimTombstones() {
        let now = CrossSync.nowMs()
        tombstones.removeAll { now - $0.t > CrossSync.tombstoneLifetimeMs }
    }

    /// The new file holds lines and tombstones; the first versions held only the lines.
    private static func open(_ data: Data?) -> MemoryFile? {
        guard let data, let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: KeychainSecret.key) else { return nil }
        if let file = try? JSONDecoder().decode(MemoryFile.self, from: plain) { return file }
        return (try? JSONDecoder().decode([MemoryItem].self, from: plain)).map { MemoryFile(items: $0, tombstones: []) }
    }

    // MARK: Account sync

    /// Every line and every delete, in the form shared with the other devices.
    func syncEntries() -> [SyncEntry] {
        items.map { SyncEntry(id: $0.syncID, kind: $0.wireKind, text: $0.text, t: $0.time, deleted: false) }
            + tombstones.map { SyncEntry(id: $0.id, kind: "", text: "", t: $0.t, deleted: true) }
    }

    /// Merges the account's lines in (see CrossSync) and keeps the result. Returns the merged entries, and whether this Mac
    /// changed. Lines from other devices are never lost: anything not understood is kept as it came.
    @discardableResult
    func merge(remote: [SyncEntry]) -> (merged: [SyncEntry], changed: Bool) {
        let merged = CrossSync.mergeMemory(local: syncEntries(), remote: remote)
        var next: [MemoryItem] = []
        for entry in merged where !entry.deleted {
            if var existing = items.first(where: { $0.syncID == entry.id }) {
                if existing.time != entry.t || existing.wireKind != entry.kind {
                    existing.kind = MemoryItem.Kind(wire: entry.kind)
                    existing.text = entry.text
                    existing.stamp = entry.t
                    existing.date = Date(timeIntervalSince1970: Double(entry.t) / 1000)
                }
                next.append(existing)
            } else {
                var item = MemoryItem(kind: MemoryItem.Kind(wire: entry.kind), text: String(entry.text.prefix(200)))
                item.stamp = entry.t
                item.date = Date(timeIntervalSince1970: Double(entry.t) / 1000)
                next.append(item)
            }
        }
        next.sort { $0.time < $1.time }
        let nextTombs = merged.filter(\.deleted).map { MemoryTombstone(id: $0.id, t: $0.t) }
        let didChange = next != items || Set(nextTombs.map(\.id)) != Set(tombstones.map(\.id))
        guard didChange else { return (merged, false) }
        items = next
        tombstones = nextTombs
        trimToLimit()
        changed()
        return (syncEntries(), true)
    }
}
