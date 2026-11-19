import Foundation

/// `MicFlow --selftest-m2` checks the offline retry timing, the pill's remembered places, the pronunciation spelling and the
/// device list merge, prints PASS/FAIL lines and exits. It runs before anything else starts.
enum M2SelfTest {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// A clock the tests move by hand (a sleep moves it forward).
    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0.0
        func read() -> Double { lock.lock(); defer { lock.unlock() }; return now }
        func advance(_ seconds: Double) { lock.lock(); now += seconds; lock.unlock() }
    }

    static func run() async -> [String] {
        var lines: [String] = []
        func check(_ title: String, _ passed: Bool, _ detail: String = "") { lines.append("\(passed ? "PASS" : "FAIL") \(title) \(detail)") }

        // Offline retry: answers on the third try, inside the window.
        do {
            let clock = FakeClock(), tries = Counter()
            let result = await RetryPolicy.run(window: 4, pause: 1, attemptLimit: 3, clock: { clock.read() },
                                               sleep: { clock.advance($0) }) { () -> String? in
                clock.advance(0.2)
                return tries.next() >= 3 ? "text" : nil
            }
            check("retry succeeds on the third attempt", result.value == "text" && result.attempts == 3, "attempts \(result.attempts)")
        }
        // Never answers: gives up once the window has passed, and does not hammer.
        do {
            let clock = FakeClock(), tries = Counter()
            let result = await RetryPolicy.run(window: 4, pause: 1, attemptLimit: 3, clock: { clock.read() },
                                               sleep: { clock.advance($0) }) { () -> String? in
                clock.advance(0.2)
                _ = tries.next()
                return nil
            }
            check("retry gives up after the window", result.value == nil && result.attempts >= 3 && result.attempts <= 5 && clock.read() <= 4.2, "attempts \(result.attempts) at \(clock.read())s")
        }
        // A single attempt that hangs is cut off.
        do {
            let started = Date()
            let value: String? = await RetryPolicy.limited(0.3) { try? await Task.sleep(nanoseconds: 5_000_000_000); return "late" }
            check("a hanging attempt is cut off", value == nil && Date().timeIntervalSince(started) < 1.5)
        }
        // The saved sound for Retry: written, read back, deleted.
        do {
            RetryStore.delete()
            let tone = (0..<48_000).map { Float(sin(Double($0) / 20)) * 0.3 }
            let saved = RetryStore.save(tone, rate: 48_000, reason: "test")
            let wav = RetryStore.load()
            check("retry sound is saved and read back", saved && RetryStore.exists && (wav?.count ?? 0) > 30_000 && wav.map { $0.prefix(4) == Data("RIFF".utf8) } == true, "\(wav?.count ?? 0) bytes")
            RetryStore.delete()
            check("too short a sound is not kept", RetryStore.save([0.1, 0.2], rate: 48_000) == false && !RetryStore.exists)
            check("retry sound is deleted", !RetryStore.exists)
        }
        // The pill's places are kept per display.
        do {
            let suite = UserDefaults(suiteName: "micflow-m2-selftest")!
            suite.removePersistentDomain(forName: "micflow-m2-selftest")
            let screenA = CGRect(x: 0, y: 0, width: 1728, height: 1117), screenB = CGRect(x: 1728, y: 0, width: 2560, height: 1440)
            PillPlacement.save(anchor: CGPoint(x: 300, y: 900), screenFrame: screenA, display: 1, defaults: suite)
            PillPlacement.save(anchor: CGPoint(x: 1728 + 2000, y: 200), screenFrame: screenB, display: 2, defaults: suite)
            check("each display remembers its own place", PillPlacement.load(display: 1, screenFrame: screenA, defaults: suite) == CGPoint(x: 300, y: 900)
                  && PillPlacement.load(display: 2, screenFrame: screenB, defaults: suite) == CGPoint(x: 3728, y: 200))
            // The place survives the display moving (arranged elsewhere): it is an offset from the display's corner.
            let moved = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
            check("a place follows its display", PillPlacement.load(display: 2, screenFrame: moved, defaults: suite) == CGPoint(x: -560, y: 200))
            check("an unknown display has no saved place", PillPlacement.load(display: 9, screenFrame: screenA, defaults: suite) == nil)
            PillPlacement.reset(defaults: suite)
            check("reset forgets the places", PillPlacement.load(display: 1, screenFrame: screenA, defaults: suite) == nil)
            suite.removePersistentDomain(forName: "micflow-m2-selftest")
            let origin = PillPlacement.origin(anchor: CGPoint(x: 5, y: 0), size: CGSize(width: 250, height: 58), visible: screenA)
            check("the pill is kept on screen", origin.x == 0 && origin.y == 0, "\(origin)")
            let top = PillPlacement.origin(anchor: CGPoint(x: 800, y: 1115), size: CGSize(width: 390, height: 160), visible: screenA)
            check("a tall pill near the top moves down to fit", top.y + 160 <= 1117, "\(top)")
        }
        // Pronunciation spelling.
        do {
            let list = [(sounds: "amader", written: "আমাদের"), (sounds: "fig ma", written: "Figma"), (sounds: "dekha", written: "দেখা")]
            check("a pronunciation is replaced by its spelling", MyWords.applyPronunciations("hello amader friends", list) == "hello আমাদের friends")
            check("case does not matter", MyWords.applyPronunciations("Amader desh", list) == "আমাদের desh")
            check("whole words only", MyWords.applyPronunciations("amaderx and xamader", list) == "amaderx and xamader")
            check("a multi-word sound with a hyphen or space", MyWords.applyPronunciations("open fig-ma and fig ma", list) == "open Figma and Figma")
            check("no pronunciations changes nothing", MyWords.applyPronunciations("same text", []) == "same text")
            var entry = PersonalDictionary.Entry(word: "আমাদের", sounds: "amader")
            let data = try? JSONEncoder().encode([entry])
            entry.sounds = nil
            let old = Data(#"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","word":"Figma"}]"#.utf8)
            check("older dictionary entries (no pronunciation) still load",
                  (try? JSONDecoder().decode([PersonalDictionary.Entry].self, from: old))?.first?.sounds == nil
                  && data.flatMap { try? JSONDecoder().decode([PersonalDictionary.Entry].self, from: $0) }?.first?.sounds == "amader")
            check("the same pronunciation has the same id on every Mac", PersonalDictionary.stableID(heard: "Amader", meant: "আমাদের") == PersonalDictionary.stableID(heard: "amader", meant: "আমাদের"))
        }
        // The device list.
        do {
            let day: Int64 = 24 * 3600 * 1000
            let now: Int64 = 1_900_000_000_000
            let pixel = DeviceEntry(name: "Pixel 7a", platform: "android", seen: now - 60_000, t: now - 5 * day, deleted: false)
            let mac = DeviceEntry(name: "MacBook", platform: "mac", seen: now - 20 * 60_000, t: now - 5 * day, deleted: false)
            check("connected means seen within 15 minutes", DeviceSync.connected(pixel, now: now) && !DeviceSync.connected(mac, now: now))
            var removed = pixel
            removed.deleted = true; removed.t = now - day
            var merged = DeviceSync.merge(local: ["p": pixel], remote: ["p": removed], now: now)
            check("a delete on another device removes it here", merged["p"]?.deleted == true)
            // The removed phone is still running and says "I'm here" again (seen is newer, change time the same as before the delete).
            var heartbeat = pixel
            heartbeat.seen = now
            merged = DeviceSync.merge(local: merged, remote: ["p": heartbeat], now: now)
            check("a heartbeat never undoes a delete", merged["p"]?.deleted == true)
            // Signing in again registers it anew (a newer change time).
            var back = pixel
            back.t = now; back.seen = now
            merged = DeviceSync.merge(local: merged, remote: ["p": back], now: now)
            check("signing in again brings a device back", merged["p"]?.deleted == false)
            var tie = pixel
            tie.deleted = true
            merged = DeviceSync.merge(local: ["p": pixel], remote: ["p": tie], now: now)
            check("a delete wins a tie", merged["p"]?.deleted == true)
            var newerSeen = pixel
            newerSeen.seen = now
            merged = DeviceSync.merge(local: ["p": pixel], remote: ["p": newerSeen], now: now)
            check("the later 'seen' is kept", merged["p"]?.seen == now)
            let old = DeviceEntry(name: "Old", platform: "windows", seen: 0, t: now - 91 * day, deleted: true)
            merged = DeviceSync.merge(local: ["o": old, "m": mac], remote: [:], now: now)
            check("a delete mark is purged after 90 days", merged["o"] == nil && merged["m"] != nil)
            let json = DeviceSync.encode(["p": pixel, "m": mac])
            check("devices JSON round trip", DeviceSync.decode(json) == ["p": pixel, "m": mac])
            if let data = try? JSONSerialization.data(withJSONObject: json), let text = String(data: data, encoding: .utf8) {
                check("devices JSON can also be read from text", DeviceSync.decode(text) == ["p": pixel, "m": mac])
            }
            check("the shared format has v and items", (json["v"] as? Int) == 1 && (json["items"] as? [String: Any])?.count == 2)
        }
        // The device list model: this Mac registers, can be removed, and comes back after signing in.
        do {
            let suite = UserDefaults(suiteName: "micflow-m2-selftest-devices")!
            suite.removePersistentDomain(forName: "micflow-m2-selftest-devices")
            let result = await MainActor.run { () -> [(String, Bool)] in
                var out: [(String, Bool)] = []
                let devices = ClipboardDevices(deviceID: "this-mac", defaults: suite, name: { "Test Mac" })
                devices.registerSelf()
                out.append(("this Mac adds itself to the list", devices.rows.count == 1 && devices.rows[0].isThis && devices.connectedCount == 1))
                let phone = DeviceEntry(name: "Pixel 7a", platform: "android", seen: DeviceSync.nowMs(), t: DeviceSync.nowMs(), deleted: false)
                devices.merge(remote: ["pixel": phone])
                out.append(("the phone appears, this Mac first", devices.rows.map(\.id) == ["this-mac", "pixel"] && devices.connectedCount == 2))
                devices.remove("pixel")
                out.append(("deleting hides the phone", devices.rows.map(\.id) == ["this-mac"]))
                // Another device removes this Mac: it must stop and say so.
                var gone = devices.entries["this-mac"]!
                gone.deleted = true; gone.t += 10
                var stopped = false
                devices.onRemovedChanged = { stopped = true }
                devices.merge(remote: ["this-mac": gone])
                out.append(("a removed Mac is told it was removed", devices.removedHere && stopped))
                devices.registerSelf(force: true)
                out.append(("a removed Mac does not re-register by itself", devices.entries["this-mac"]?.deleted == true))
                let removedT = devices.entries["this-mac"]!.t
                devices.reRegister()
                out.append(("signing in again brings it back", !devices.removedHere && devices.entries["this-mac"]?.deleted == false))
                out.append(("re-registering is newer than the removal", devices.entries["this-mac"]!.t > removedT))
                // The removing device's clock runs an hour ahead: re-registering must still win.
                var ahead = devices.entries["this-mac"]!
                ahead.deleted = true; ahead.t = DeviceSync.nowMs() + 3_600_000
                devices.merge(remote: ["this-mac": ahead])
                devices.reRegister()
                out.append(("re-registering beats a removal stamped by a faster clock", !devices.removedHere && devices.entries["this-mac"]!.t > ahead.t))
                let again = ClipboardDevices(deviceID: "this-mac", defaults: suite, name: { "Test Mac" })
                out.append(("the list is kept between launches", again.rows.contains { $0.id == "this-mac" }))
                return out
            }
            for (title, passed) in result { check(title, passed) }
            suite.removePersistentDomain(forName: "micflow-m2-selftest-devices")
        }
        return lines
    }

    static func runIfAsked() {
        guard CommandLine.arguments.contains("--selftest-m2") else { return }
        final class Box: @unchecked Sendable { var lines: [String] = []; var done = false }
        let box = Box()
        // The checks of the device list run on the main actor, so the main thread keeps turning while they run.
        Task { @MainActor in box.lines = await run(); box.done = true }
        while !box.done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        print(box.lines.joined(separator: "\n"))
        exit(box.lines.contains { $0.hasPrefix("FAIL") } ? 1 : 0)
    }
}
