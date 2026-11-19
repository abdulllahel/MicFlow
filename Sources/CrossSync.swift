import CryptoKit
import Foundation

/// One memory line as it travels between devices (the same JSON on Mac, Android and Windows).
struct SyncEntry: Equatable {
    var id: String
    var kind: String
    var text: String
    /// Milliseconds since 1970 of the last change.
    var t: Int64
    var deleted: Bool
}

/// What the account holds about the backup providers, as it travels between devices.
struct ProviderSyncState: Equatable {
    struct KeyEntry: Equatable { var key: String; var t: Int64; var deleted: Bool }
    struct Flag: Equatable { var on: Bool; var t: Int64 }
    struct Order: Equatable { var list: [String]; var t: Int64 }
    var keys: [String: KeyEntry] = [:]
    var order: Order?
    var enabled: [String: Flag] = [:]
    var isEmpty: Bool { keys.isEmpty && order == nil && enabled.isEmpty }
}

/// Memory and backup-provider keys shared between every device signed in to the same Google account.
///
/// Both travel as sealed blobs (KeyVault, the same lock as the Google key) in the account's settings, under `memory` and
/// `providers`. Every device pulls the account's copy, merges, and pushes the merge, so an edit or a delete made on one
/// device reaches the others and a stale copy never brings a deleted line back: a delete is kept as a dated tombstone for
/// 90 days. The rule per item: the larger change time wins; at the same time a delete wins.
enum CrossSync {
    static let memoryKey = "memory"
    static let providersKey = "providers"
    /// The key older Macs used for their memory (a plain list of lines).
    static let legacyMemoryKey = "micflowMemory"
    static let tombstoneLifetimeMs: Int64 = 90 * 24 * 3600 * 1000

    static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// The id of a memory line: the first 16 bytes of the SHA-256 of its normalized text, as 32 lowercase hex digits.
    /// Normalized: trimmed, lower case, white space collapsed to single spaces, Unicode NFC.
    static func memoryID(_ text: String) -> String {
        let normalized = text.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .precomposedStringWithCanonicalMapping
        return SHA256.hash(data: Data(normalized.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the change at (`t`, `deleted`) beats `other`.
    private static func beats(_ t: Int64, _ deleted: Bool, _ otherT: Int64, _ otherDeleted: Bool) -> Bool {
        if t != otherT { return t > otherT }
        return deleted && !otherDeleted
    }

    // MARK: Merging

    static func mergeMemory(local: [SyncEntry], remote: [SyncEntry], now: Int64 = nowMs()) -> [SyncEntry] {
        var byID: [String: SyncEntry] = [:]
        var order: [String] = []
        for entry in local where byID[entry.id] == nil { byID[entry.id] = entry; order.append(entry.id) }
        for entry in remote {
            if let mine = byID[entry.id] {
                if beats(entry.t, entry.deleted, mine.t, mine.deleted) { byID[entry.id] = entry }
            } else {
                byID[entry.id] = entry
                order.append(entry.id)
            }
        }
        return order.compactMap { byID[$0] }.filter { !($0.deleted && now - $0.t > tombstoneLifetimeMs) }
    }

    static func mergeProviders(local: ProviderSyncState, remote: ProviderSyncState, now: Int64 = nowMs()) -> ProviderSyncState {
        var merged = local
        for (id, entry) in remote.keys {
            if let mine = merged.keys[id] {
                if beats(entry.t, entry.deleted, mine.t, mine.deleted) { merged.keys[id] = entry }
            } else {
                merged.keys[id] = entry
            }
        }
        merged.keys = merged.keys.filter { !($0.value.deleted && now - $0.value.t > tombstoneLifetimeMs) }
        if let theirs = remote.order, theirs.t > (merged.order?.t ?? Int64.min) { merged.order = theirs }
        for (id, flag) in remote.enabled where flag.t > (merged.enabled[id]?.t ?? Int64.min) { merged.enabled[id] = flag }
        return merged
    }

    // MARK: JSON

    static func encodeMemory(_ entries: [SyncEntry]) -> String? {
        let items: [[String: Any]] = entries.map {
            ["id": $0.id, "kind": $0.kind, "text": $0.deleted ? "" : $0.text, "t": $0.t, "deleted": $0.deleted]
        }
        return json(["v": 2, "items": items])
    }

    /// The v2 format, or an older one: a plain list of `{kind, text}` lines (changed at time 0, or their own date).
    static func decodeMemory(_ text: String) -> [SyncEntry]? {
        guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let array: [[String: Any]]
        if let object = value as? [String: Any] { array = object["items"] as? [[String: Any]] ?? [] }
        else if let list = value as? [[String: Any]] { array = list }
        else { return nil }
        return array.compactMap { item in
            guard let body = item["text"] as? String else { return nil }
            let deleted = item["deleted"] as? Bool ?? false
            guard deleted || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let id = (item["id"] as? String).flatMap { $0.count == 32 && $0.allSatisfy(\.isHexDigit) ? $0.lowercased() : nil } ?? memoryID(body)
            let t = (item["t"] as? NSNumber)?.int64Value ?? 0
            return SyncEntry(id: id, kind: item["kind"] as? String ?? "preference", text: body, t: t, deleted: deleted)
        }
    }

    static func encodeProviders(_ state: ProviderSyncState) -> String? {
        var keys: [String: Any] = [:]
        for (id, entry) in state.keys { keys[id] = ["key": entry.deleted ? "" : entry.key, "t": entry.t, "deleted": entry.deleted] }
        var enabled: [String: Any] = [:]
        for (id, flag) in state.enabled { enabled[id] = ["on": flag.on, "t": flag.t] }
        var root: [String: Any] = ["v": 1, "keys": keys, "enabled": enabled]
        if let order = state.order { root["order"] = ["list": order.list, "t": order.t] }
        return json(root)
    }

    static func decodeProviders(_ text: String) -> ProviderSyncState? {
        guard let data = text.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var state = ProviderSyncState()
        for (id, value) in root["keys"] as? [String: Any] ?? [:] {
            guard let entry = value as? [String: Any] else { continue }
            state.keys[id.lowercased()] = .init(key: entry["key"] as? String ?? "", t: (entry["t"] as? NSNumber)?.int64Value ?? 0,
                                                deleted: entry["deleted"] as? Bool ?? false)
        }
        if let order = root["order"] as? [String: Any], let list = order["list"] as? [String] {
            state.order = .init(list: list, t: (order["t"] as? NSNumber)?.int64Value ?? 0)
        }
        for (id, value) in root["enabled"] as? [String: Any] ?? [:] {
            guard let flag = value as? [String: Any], let on = flag["on"] as? Bool else { continue }
            state.enabled[id.lowercased()] = .init(on: on, t: (flag["t"] as? NSNumber)?.int64Value ?? 0)
        }
        return state
    }

    private static func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Sealed blobs in the account's settings

    static func sealedMemory(_ entries: [SyncEntry], user: String) -> String? { encodeMemory(entries).flatMap { KeyVault.seal($0, user: user) } }
    static func sealedProviders(_ state: ProviderSyncState, user: String) -> String? { encodeProviders(state).flatMap { KeyVault.seal($0, user: user) } }

    /// The account's memory lines (`memory`, or the older `micflowMemory`), nil if it has none or they can't be opened.
    static func remoteMemory(_ settings: [String: Any]?, user: String) -> [SyncEntry]? {
        var merged: [SyncEntry]?
        for key in [legacyMemoryKey, memoryKey] {
            guard let sealed = settings?[key] as? String, let text = KeyVault.open(sealed, user: user), let entries = decodeMemory(text) else { continue }
            merged = merged.map { mergeMemory(local: $0, remote: entries) } ?? entries
        }
        return merged
    }

    static func remoteProviders(_ settings: [String: Any]?, user: String) -> ProviderSyncState? {
        guard let sealed = settings?[providersKey] as? String, let text = KeyVault.open(sealed, user: user) else { return nil }
        return decodeProviders(text)
    }

    // MARK: Self test

    static func selfTest() -> [String] {
        var lines: [String] = []
        func check(_ title: String, _ passed: Bool, _ detail: String = "") { lines.append("\(passed ? "PASS" : "FAIL") \(title) \(detail)") }
        let day: Int64 = 24 * 3600 * 1000
        let now: Int64 = 1_900_000_000_000
        // Ids are the same on every platform.
        check("id ignores case and spacing", memoryID("  Product   Designer ") == memoryID("product designer") && memoryID("a").count == 32)
        check("id of 'hello' matches the shared spec", memoryID("hello") == "2cf24dba5fb0a30e26e83b2ac5b9e29e", memoryID("hello"))
        let a = SyncEntry(id: memoryID("uses figma"), kind: "skill", text: "Uses Figma", t: now - 10 * day, deleted: false)
        // A deleted on Mac A beats the stale copy still on Mac B.
        let deletedOnA = SyncEntry(id: a.id, kind: "skill", text: "", t: now - day, deleted: true)
        var merged = mergeMemory(local: [deletedOnA], remote: [a], now: now)
        check("delete beats a stale copy", merged.count == 1 && merged[0].deleted)
        merged = mergeMemory(local: [a], remote: [deletedOnA], now: now)
        check("delete beats a stale copy (other direction)", merged.count == 1 && merged[0].deleted)
        // A newer edit wins.
        var edited = a; edited.t = now - day; edited.kind = "job"
        merged = mergeMemory(local: [a], remote: [edited], now: now)
        check("newer edit wins", merged.first?.kind == "job" && merged.first?.t == edited.t)
        // Re-adding after a delete wins when it is newer.
        var readded = a; readded.t = now
        merged = mergeMemory(local: [deletedOnA], remote: [readded], now: now)
        check("a newer re-add beats the delete", merged.first?.deleted == false)
        // Same time: the delete wins.
        var tie = deletedOnA; tie.t = a.t
        merged = mergeMemory(local: [a], remote: [tie], now: now)
        check("a delete wins a tie", merged.first?.deleted == true)
        // Lines only one side has are all kept.
        let other = SyncEntry(id: memoryID("works at a studio"), kind: "job", text: "Works at a studio", t: now, deleted: false)
        check("union keeps both", mergeMemory(local: [a], remote: [other], now: now).count == 2)
        // Tombstones are purged after 90 days, and not before.
        let old = SyncEntry(id: "x", kind: "", text: "", t: now - 91 * day, deleted: true)
        let recent = SyncEntry(id: "y", kind: "", text: "", t: now - 89 * day, deleted: true)
        merged = mergeMemory(local: [old, recent], remote: [], now: now)
        check("tombstone purged after 90 days", merged.map(\.id) == ["y"], "\(merged.map(\.id))")
        // The JSON round-trips and an older plain list is understood.
        let text = encodeMemory([a, deletedOnA])
        check("memory json round trip", text.flatMap(decodeMemory)?.count == 2 && text.flatMap(decodeMemory)?.first == a)
        check("older memory list read", decodeMemory("[{\"kind\":\"job\",\"text\":\"Designer\"}]")?.first?.text == "Designer")
        // Providers: per key, the larger time wins; a delete wins a tie; foreign providers are kept.
        var mine = ProviderSyncState()
        mine.keys["groq"] = .init(key: "old", t: now - day, deleted: false)
        mine.enabled["groq"] = .init(on: true, t: now - day)
        var theirs = ProviderSyncState()
        theirs.keys["groq"] = .init(key: "new", t: now, deleted: false)
        theirs.keys["deepgram"] = .init(key: "dg", t: now, deleted: false)
        theirs.enabled["groq"] = .init(on: false, t: now)
        theirs.order = .init(list: ["google", "groq"], t: now)
        var result = mergeProviders(local: mine, remote: theirs, now: now)
        check("newer key wins", result.keys["groq"]?.key == "new")
        check("foreign provider kept", result.keys["deepgram"]?.key == "dg")
        check("newer switch and order win", result.enabled["groq"]?.on == false && result.order?.list == ["google", "groq"])
        mine.keys["groq"] = .init(key: "", t: now, deleted: true)
        result = mergeProviders(local: mine, remote: theirs, now: now)
        check("a key delete wins a tie", result.keys["groq"]?.deleted == true)
        mine.keys["groq"] = .init(key: "", t: now - 100 * day, deleted: true)
        result = mergeProviders(local: mine, remote: ProviderSyncState(), now: now)
        check("key tombstone purged after 90 days", result.keys["groq"] == nil)
        let blob = encodeProviders(theirs)
        check("providers json round trip", blob.flatMap(decodeProviders) == theirs)
        // Sealing with the account's own lock works, and another account can't open it.
        if let sealed = sealedProviders(theirs, user: "user-1") {
            check("sealed providers open for the same user only", remoteProviders([providersKey: sealed], user: "user-1") == theirs
                  && remoteProviders([providersKey: sealed], user: "user-2") == nil)
        } else { check("sealed providers", false) }
        return lines
    }
}
