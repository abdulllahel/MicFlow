import AppKit
import ApplicationServices
import SwiftUI

/// Remembers where your windows are, and puts them back after a restart or a power cut. Every few
/// minutes it saves each app's windows (position, size, order). When your Mac has just started, it
/// reopens the apps that aren't running, in the order they were stacked, and moves their windows
/// back. It needs Accessibility permission, which MicFlow already uses. macOS doesn't let apps
/// control Spaces (separate desktops), so windows return to the desktop you're on.
@MainActor
final class WindowLayoutManager: ObservableObject {
    struct SavedWindow: Codable, Equatable {
        var title: String
        var x: Double, y: Double, width: Double, height: Double
    }
    struct SavedApp: Codable, Equatable {
        var bundleID: String
        var name: String
        /// 0 is the app in front; higher numbers are further back.
        var depth: Int
        var windows: [SavedWindow]
    }

    @Published var restoreAfterRestart: Bool {
        didSet { UserDefaults.standard.set(restoreAfterRestart, forKey: "windowLayoutRestore") }
    }
    @Published private(set) var lastSaved: Date?
    @Published private(set) var status = ""

    private var timer: Timer?
    private let file: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("MicFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("window-layout.json")
    }()

    init() {
        UserDefaults.standard.register(defaults: ["windowLayoutRestore": true])
        restoreAfterRestart = UserDefaults.standard.bool(forKey: "windowLayoutRestore")
        lastSaved = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    func start() {
        // Right after the Mac starts, bring the saved layout back before the first save overwrites it.
        if restoreAfterRestart, ProcessInfo.processInfo.systemUptime < 15 * 60, let saved = load(), !saved.isEmpty {
            Task { await restore(saved, waitFirst: 20) }
        } else {
            saveNow()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    // MARK: Saving

    func saveNow() {
        guard AXIsProcessTrusted() else { status = "Allow MicFlow in Accessibility settings to save your windows."; return }
        // Front-to-back order of apps, from the window list.
        var depth: [pid_t: Int] = [:]
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
                if let pid = info[kCGWindowOwnerPID as String] as? Int32, depth[pid] == nil { depth[pid] = depth.count }
            }
        }
        var apps: [SavedApp] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            guard let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { continue }
            let windows = Self.windows(of: app.processIdentifier)
            guard !windows.isEmpty else { continue }
            apps.append(SavedApp(bundleID: bundleID, name: app.localizedName ?? bundleID, depth: depth[app.processIdentifier] ?? 99, windows: windows))
        }
        guard !apps.isEmpty, let data = try? JSONEncoder().encode(apps.sorted { $0.depth < $1.depth }) else { return }
        try? data.write(to: file, options: .atomic)
        lastSaved = Date()
        status = "Saved \(apps.count) app\(apps.count == 1 ? "" : "s")."
    }

    private static func windows(of pid: pid_t) -> [SavedWindow] {
        let element = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success, (minimized as? Bool) == true { return nil }
            guard let position = point(window, kAXPositionAttribute), let size = size(window, kAXSizeAttribute), size.width > 80, size.height > 60 else { return nil }
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            return SavedWindow(title: (title as? String) ?? "", x: position.x, y: position.y, width: size.width, height: size.height)
        }
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        var result = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &result) ? result : nil
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        var result = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &result) ? result : nil
    }

    private func load() -> [SavedApp]? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([SavedApp].self, from: $0) }
    }

    // MARK: Restoring

    func restoreNow() {
        guard let saved = load(), !saved.isEmpty else { status = "No saved layout yet."; return }
        Task { await restore(saved, waitFirst: 0) }
    }

    private func restore(_ saved: [SavedApp], waitFirst: Double) async {
        guard AXIsProcessTrusted() else { status = "Allow MicFlow in Accessibility settings to restore your windows."; return }
        if waitFirst > 0 { try? await Task.sleep(nanoseconds: UInt64(waitFirst * 1_000_000_000)) }
        status = "Restoring your windows…"
        // Open the apps that aren't running, from the back of the stack to the front, so the order matches.
        for app in saved.sorted(by: { $0.depth > $1.depth }) {
            if NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        // Moves each window back (an app can take a while to show its windows, so it tries for a minute).
        var remaining = saved
        for _ in 0..<30 where !remaining.isEmpty {
            remaining = remaining.filter { !place($0) }
            if remaining.isEmpty { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        // The app that was in front goes back in front.
        if let front = saved.first, let running = NSRunningApplication.runningApplications(withBundleIdentifier: front.bundleID).first {
            running.activate()
        }
        status = remaining.isEmpty ? "Your windows are back." : "Put back what could be; \(remaining.count) app\(remaining.count == 1 ? "" : "s") didn't open in time."
    }

    /// Moves an app's windows to where they were. True when the app has its windows on screen.
    private func place(_ app: SavedApp) -> Bool {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first else { return false }
        let element = AXUIElementCreateApplication(running.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement], !windows.isEmpty else { return false }
        var unused = windows
        for saved in app.windows {
            // The window with the same title first, otherwise the next one left.
            let index = unused.firstIndex { window in
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                return (title as? String) == saved.title
            } ?? (unused.isEmpty ? nil : 0)
            guard let index else { continue }
            let window = unused.remove(at: index)
            var size = CGSize(width: saved.width, height: saved.height)
            var origin = CGPoint(x: saved.x, y: saved.y)
            if let sizeValue = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) }
            if let originValue = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue) }
        }
        return true
    }
}

/// Settings card: on/off, save now, restore now.
struct WindowLayoutCard: View {
    @ObservedObject var layout: WindowLayoutManager
    let theme: HomeTheme

    var body: some View {
        FeatureCard(theme: theme, systemImage: "macwindow.on.rectangle", title: "Window layout",
                    subtitle: "Get your windows back after a restart", isOn: $layout.restoreAfterRestart) {
            Note(text: "MicFlow remembers where your windows are. After a restart or a power cut it reopens your apps and puts the windows back where they were. Separate desktops (Spaces) can't be restored by any app, so windows return to the desktop you're on.")
            HStack(spacing: 8) {
                PillButton(title: "Save now", systemImage: "square.and.arrow.down", style: .cream) { layout.saveNow() }
                PillButton(title: "Restore now", systemImage: "arrow.uturn.backward", style: .outline) { layout.restoreNow() }
            }
            if let saved = layout.lastSaved {
                Note(text: "Last saved \(saved.formatted(.relative(presentation: .named))).")
            }
            if !layout.status.isEmpty { Note(text: layout.status) }
        }
    }
}
