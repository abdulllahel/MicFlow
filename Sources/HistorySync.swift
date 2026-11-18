import Foundation

/// Dictation history across your linked devices. Each dictation is sealed on this Mac with the key
/// your devices share (see UniversalClipboard) and sent to your account; the other devices fetch and
/// open it. Only dictations made after sync is on are sent. The server holds only sealed text.
@MainActor
final class HistorySync {
    private let log: DictationLog
    private let account: Account
    private let clipboard: UniversalClipboard
    private var timer: Timer?
    private var lastSeen = UserDefaults.standard.string(forKey: "historyLastSeen") ?? "1970-01-01T00:00:00.000Z"

    init(log: DictationLog, account: Account, clipboard: UniversalClipboard) {
        self.log = log; self.account = account; self.clipboard = clipboard
    }

    func start() {
        log.onAdded = { [weak self] entry in Task { await self?.push(entry) } }
        log.onRemoved = { [weak self] entry in Task { await self?.delete(entry) } }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pull() }
        }
        Task { await pull() }
    }

    private func push(_ entry: DictationLog.Entry) async {
        guard account.isSignedIn, let token = try? await account.token(),
              let plain = Self.wire(entry), let sealed = clipboard.sealHistory(plain) else { return }
        _ = try? await Backend.request("POST", "/rest/v1/dictation_history", json: [
            "device": clipboard.deviceID, "device_name": Host.current().localizedName ?? "Mac",
            "spoken_at": ISO8601DateFormatter.withFraction.string(from: entry.date), "data": sealed.base64EncodedString(),
        ], token: token)
    }

    /// A dictation deleted here is deleted from your account too, so it doesn't come back on another device.
    private func delete(_ entry: DictationLog.Entry) async {
        guard account.isSignedIn, let token = try? await account.token(), let device = entry.device, !device.isEmpty else { return }
        _ = try? await Backend.request("DELETE", "/rest/v1/dictation_history", query: [
            URLQueryItem(name: "device", value: "eq.\(device)"),
            URLQueryItem(name: "spoken_at", value: "eq.\(ISO8601DateFormatter.withFraction.string(from: entry.date))")], token: token)
    }

    func pull() async {
        guard account.isSignedIn, let token = try? await account.token() else { return }
        let query = [URLQueryItem(name: "select", value: "data,created_at"), URLQueryItem(name: "device", value: "neq.\(clipboard.deviceID)"),
                     URLQueryItem(name: "created_at", value: "gt.\(lastSeen)"), URLQueryItem(name: "order", value: "created_at.asc"),
                     URLQueryItem(name: "limit", value: "200")]
        guard let data = try? await Backend.request("GET", "/rest/v1/dictation_history", query: query, token: token),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !rows.isEmpty else { return }
        var entries: [DictationLog.Entry] = []
        var lastOpened: String?
        for row in rows {
            guard let text = row["data"] as? String, let sealed = Data(base64Encoded: text), let plain = clipboard.openHistory(sealed),
                  let entry = Self.entry(from: plain) else { continue }
            entries.append(entry)
            lastOpened = row["created_at"] as? String
        }
        log.merge(entries)
        // Moves on only past what could be opened: older items sent before this device was linked
        // stay available for when it is.
        if let created = lastOpened,
           let date = ISO8601DateFormatter.withFraction.date(from: created.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression))
                ?? ISO8601DateFormatter().date(from: created) {
            lastSeen = ISO8601DateFormatter.withFraction.string(from: date.addingTimeInterval(0.001))
            UserDefaults.standard.set(lastSeen, forKey: "historyLastSeen")
        }
    }

    /// The same plain format the phone uses (dates in milliseconds since 1970).
    private static func wire(_ entry: DictationLog.Entry) -> Data? {
        let object: [String: Any] = ["id": entry.id.uuidString, "date": Int64(entry.date.timeIntervalSince1970 * 1000), "text": entry.text,
                                     "words": entry.words, "seconds": entry.seconds,
                                     "device": entry.device ?? "", "deviceName": entry.deviceName ?? "Mac", "platform": entry.platform ?? "mac"]
        return try? JSONSerialization.data(withJSONObject: object)
    }

    private static func entry(from data: Data) -> DictationLog.Entry? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let text = o["text"] as? String,
              let ms = (o["date"] as? NSNumber)?.doubleValue, let words = o["words"] as? Int else { return nil }
        let id = (o["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        return DictationLog.Entry(id: id, date: Date(timeIntervalSince1970: ms / 1000), text: text, words: words,
                                  seconds: (o["seconds"] as? NSNumber)?.doubleValue ?? 0,
                                  device: o["device"] as? String, deviceName: o["deviceName"] as? String, platform: o["platform"] as? String)
    }
}
