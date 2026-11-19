import AppKit
import SwiftUI

/// One of your devices as it travels in the account's settings (plain JSON under `devices`, the same on Mac, Android and Windows):
/// {"v":1,"items":{"<deviceId>":{"name":"Pixel 7a","platform":"android","seen":<ms>,"t":<ms>,"deleted":false}}}
struct DeviceEntry: Equatable {
    var name: String
    /// "mac", "android" or "windows".
    var platform: String
    /// When the device last said it was running (ms since 1970). Not a "change": a heartbeat never beats a delete.
    var seen: Int64
    /// When the entry last changed (ms since 1970): registered, renamed or removed.
    var t: Int64
    var deleted: Bool
}

enum DeviceSync {
    static let key = "devices"
    static let tombstoneLifetimeMs: Int64 = 90 * 24 * 3600 * 1000
    /// A device counts as connected when it was seen within this long.
    static let connectedWindowMs: Int64 = 15 * 60 * 1000

    static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

    /// Per device: the larger change time wins; at the same time a delete wins; with the same change, the later `seen`.
    static func merge(local: [String: DeviceEntry], remote: [String: DeviceEntry], now: Int64 = nowMs()) -> [String: DeviceEntry] {
        var result = local
        for (id, theirs) in remote {
            guard let mine = result[id] else { result[id] = theirs; continue }
            if theirs.t != mine.t {
                if theirs.t > mine.t { result[id] = theirs }
            } else if theirs.deleted != mine.deleted {
                if theirs.deleted { result[id] = theirs }
            } else if theirs.seen > mine.seen {
                var updated = mine
                updated.seen = theirs.seen
                result[id] = updated
            }
        }
        return result.filter { !($0.value.deleted && now - $0.value.t > tombstoneLifetimeMs) }
    }

    static func connected(_ entry: DeviceEntry, now: Int64 = nowMs()) -> Bool {
        !entry.deleted && now - entry.seen <= connectedWindowMs
    }

    /// The `devices` value for the account's settings (a JSON object, not a sealed blob).
    static func encode(_ items: [String: DeviceEntry]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (id, entry) in items {
            out[id] = ["name": entry.name, "platform": entry.platform, "seen": entry.seen, "t": entry.t, "deleted": entry.deleted]
        }
        return ["v": 1, "items": out]
    }

    /// Reads the account's `devices` (an object, or the same JSON as text).
    static func decode(_ value: Any?) -> [String: DeviceEntry]? {
        var root = value as? [String: Any]
        if root == nil, let text = value as? String, let data = text.data(using: .utf8) {
            root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let items = root?["items"] as? [String: Any] else { return nil }
        var result: [String: DeviceEntry] = [:]
        for (id, raw) in items {
            guard let item = raw as? [String: Any] else { continue }
            result[id] = DeviceEntry(name: item["name"] as? String ?? "Device", platform: (item["platform"] as? String ?? "").lowercased(),
                                     seen: (item["seen"] as? NSNumber)?.int64Value ?? 0, t: (item["t"] as? NSNumber)?.int64Value ?? 0,
                                     deleted: item["deleted"] as? Bool ?? false)
        }
        return result
    }

    static func lastSeenText(_ entry: DeviceEntry, now: Date = Date()) -> String {
        if connected(entry, now: Int64(now.timeIntervalSince1970 * 1000)) { return "Connected now" }
        guard entry.seen > 0 else { return "Not seen yet" }
        let date = Date(timeIntervalSince1970: Double(entry.seen) / 1000)
        return "Last seen " + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }
}

/// The devices linked to your account, kept in the account's settings so nothing needs a database change. This Mac adds itself, the
/// list is merged on every sync, and "Delete" marks a device as removed on all of them. A removed device that is still running stops
/// sharing the clipboard and says so; it comes back only when you sign in on it again.
@MainActor
final class ClipboardDevices: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let entry: DeviceEntry
        let isThis: Bool
        var connected: Bool { DeviceSync.connected(entry) }
    }

    @Published private(set) var entries: [String: DeviceEntry]
    /// Bumped on every change here, so the account sync notices there is something to save.
    @Published private(set) var revision = 0
    /// Another device removed this one.
    @Published private(set) var removedHere: Bool
    /// Called when this Mac gets removed (the clipboard must stop) or is back.
    var onRemovedChanged: () -> Void = {}

    let deviceID: String
    private let defaults: UserDefaults
    private let storeKey = "clipboardDevicesList"
    private let name: () -> String
    /// Re-registering ("I'm still here") is saved at most this often.
    private static let heartbeatMs: Int64 = 5 * 60 * 1000

    init(deviceID: String, defaults: UserDefaults = .standard, name: @escaping () -> String = { Host.current().localizedName ?? "Mac" }) {
        self.deviceID = deviceID
        self.defaults = defaults
        self.name = name
        let stored = defaults.string(forKey: storeKey).flatMap { DeviceSync.decode($0) } ?? [:]
        entries = stored
        removedHere = stored[deviceID]?.deleted == true
    }

    var rows: [Row] {
        entries.filter { !$0.value.deleted }
            .map { Row(id: $0.key, entry: $0.value, isThis: $0.key == deviceID) }
            .sorted { a, b in a.isThis != b.isThis ? a.isThis : a.entry.seen > b.entry.seen }
    }
    var connectedCount: Int { rows.filter(\.connected).count }

    /// This Mac says it is here (name, platform, seen = now). Does nothing while it is removed: only signing in again brings it back.
    func registerSelf(force: Bool = false) {
        guard !removedHere else { return }
        let now = DeviceSync.nowMs()
        if var mine = entries[deviceID] {
            let renamed = mine.name != name() || mine.platform != "mac"
            guard force || renamed || now - mine.seen >= Self.heartbeatMs else { return }
            mine.seen = now
            if renamed { mine.name = name(); mine.platform = "mac"; mine.t = now }
            entries[deviceID] = mine
        } else {
            entries[deviceID] = DeviceEntry(name: name(), platform: "mac", seen: now, t: now, deleted: false)
        }
        changed()
    }

    /// After a new sign-in: this Mac joins again, even if it had been removed.
    func reRegister() {
        let now = DeviceSync.nowMs()
        // Newer than the removal even if the removing device's clock ran ahead of this one's.
        let change = max(now, (entries[deviceID]?.t ?? 0) + 1)
        entries[deviceID] = DeviceEntry(name: name(), platform: "mac", seen: now, t: change, deleted: false)
        setRemoved(false)
        changed()
    }

    /// Marks a device as removed (here and, on the next sync, everywhere).
    func remove(_ id: String) {
        guard var entry = entries[id], !entry.deleted else { return }
        entry.deleted = true
        entry.t = max(DeviceSync.nowMs(), entry.t + 1)
        entries[id] = entry
        if id == deviceID { setRemoved(true) }
        changed()
    }

    /// Brings in the account's list. Returns whether the merged list holds something the account doesn't (so it must be saved).
    @discardableResult
    func merge(remote: [String: DeviceEntry]) -> Bool {
        let merged = DeviceSync.merge(local: entries, remote: remote)
        let differs = merged != remote
        if merged != entries { entries = merged; persist(); revision += 1 }
        setRemoved(entries[deviceID]?.deleted == true)
        return differs
    }

    /// What goes into the account's settings.
    func syncObject() -> [String: Any] { DeviceSync.encode(entries) }
    var isEmpty: Bool { entries.isEmpty }

    private func setRemoved(_ value: Bool) {
        guard value != removedHere else { return }
        removedHere = value
        onRemovedChanged()
    }

    private func changed() {
        persist()
        revision += 1
    }

    private func persist() {
        guard let data = try? JSONSerialization.data(withJSONObject: DeviceSync.encode(entries), options: [.sortedKeys]) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: storeKey)
    }
}

/// The list inside the Universal Clipboard card: how many devices are connected right now, their names and platform, when each was
/// last seen, and a Delete button (with a confirmation) for each.
struct ClipboardDevicesList: View {
    @ObservedObject var devices: ClipboardDevices
    var signedIn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if devices.removedHere {
                Note(text: "This Mac was removed from your devices, so it no longer shares the clipboard. Sign in again to link it.", isError: true)
            }
            HStack {
                Text("Your devices").font(.inter(13, .bold))
                Spacer()
                Text(summary).font(.inter(12, .semibold)).foregroundStyle(Color(hex: 0x6FE39A))
            }
            if devices.rows.isEmpty {
                Note(text: signedIn ? "No devices yet. They appear here after the next sync." : "Sign in to see your devices.")
            }
            ForEach(devices.rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: icon(row.entry.platform))
                        .font(.inter(14, .semibold)).frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.18), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(row.entry.name).font(.inter(13, .bold)).lineLimit(1)
                            if row.isThis { Text("This Mac").font(.inter(10, .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color(hex: 0xFFB413), in: Capsule()).foregroundStyle(Color(hex: 0x141414)) }
                        }
                        HStack(spacing: 5) {
                            Circle().fill(row.connected ? Color(hex: 0x6FE39A) : Color.white.opacity(0.4)).frame(width: 7, height: 7)
                            Text(platformName(row.entry.platform) + " · " + DeviceSync.lastSeenText(row.entry)).font(.inter(11)).opacity(0.85)
                        }
                    }
                    Spacer()
                    Button { confirmDelete(row) } label: {
                        Image(systemName: "trash.fill").font(.inter(13, .semibold)).foregroundStyle(Color(hex: 0xFF8904))
                            .frame(width: 30, height: 30).background(Color.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain).help("Delete \(row.entry.name)")
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var summary: String {
        let n = devices.connectedCount
        return n == 1 ? "1 device connected now" : "\(n) devices connected now"
    }

    private func icon(_ platform: String) -> String {
        switch platform {
        case "android": return "iphone"
        case "windows": return "pc"
        default: return "laptopcomputer"
        }
    }

    private func platformName(_ platform: String) -> String {
        switch platform {
        case "android": return "Android"
        case "windows": return "Windows"
        case "mac": return "Mac"
        default: return "Device"
        }
    }

    private func confirmDelete(_ row: ClipboardDevices.Row) {
        let alert = NSAlert()
        alert.messageText = "Delete \(row.entry.name)?"
        alert.informativeText = row.isThis
            ? "This Mac will stop sharing the clipboard with your other devices until you sign in again."
            : "\(row.entry.name) is removed from your devices. If it is running, it stops sharing the clipboard and shows that it was removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { devices.remove(row.id) }
    }
}
