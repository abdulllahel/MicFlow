import AppKit
import ApplicationServices

/// Makes swiping up and down on the mouse zoom the Figma canvas, by adding Control to vertical
/// scrolls while Figma is the frontmost app. Figma's own "Use scroll wheel zoom" only applies to
/// notched scroll wheels; the Magic Mouse scrolls smoothly like a trackpad, which Figma pans with.
/// Sideways swipes are left alone, so they still move the canvas left and right. `zoomAmount`
/// scales each zoom swipe.
final class FigmaZoomController {
    enum State: Equatable {
        case off, needsAccessibility, running
    }

    static let figmaBundleIDs: Set<String> = ["com.figma.Desktop"]

    /// Multiplier on how far each swipe zooms, 1 = Figma's normal.
    var zoomAmount: Double = 1
    var onStateChange: ((State) -> Void)?
    private(set) var state = State.off

    private lazy var tap = EventTap(types: [.scrollWheel]) { [unowned self] _, event in
        self.handle(event)
        return true
    }
    private var figmaIsFrontmost = false
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        if !AXIsProcessTrusted() {
            AccessibilityPrompt.askOnce()
        }
        updateFrontmostApp(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.updateFrontmostApp(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        // Re-checks until Accessibility permission is granted.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        tap.remove()
        setState(.off)
    }

    private func update() {
        guard AXIsProcessTrusted(), tap.install() else {
            tap.remove()
            setState(.needsAccessibility)
            return
        }
        setState(.running)
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }

    /// True while swipes are being turned into zoom, so other scroll features can stay out of the way.
    var isZoomingFrontmostApp: Bool { state == .running && figmaIsFrontmost }

    private func updateFrontmostApp(_ app: NSRunningApplication?) {
        figmaIsFrontmost = app?.bundleIdentifier.map(Self.figmaBundleIDs.contains) ?? false
    }

    /// Figma's side panels, top bar and bottom toolbar are scrolled normally; only the canvas zooms.
    /// The canvas is found from the window's position (Figma doesn't tell other apps where its canvas is),
    /// so these margins are a best guess for Figma's standard layout.
    private static let leftPanel: CGFloat = 250, rightPanel: CGFloat = 250, topBar: CGFloat = 50
    private static let toolbarWidth: CGFloat = 460, toolbarHeight: CGFloat = 72

    private var cachedWindow: (rect: CGRect, at: Date)?

    /// Figma's biggest on-screen window, in the same top-left coordinates as events.
    private func figmaWindowRect() -> CGRect? {
        if let cachedWindow, Date().timeIntervalSince(cachedWindow.at) < 0.4 { return cachedWindow.rect }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let rects = list.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier, (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        }
        let biggest = rects.max { $0.width * $0.height < $1.width * $1.height }
        if let biggest { cachedWindow = (biggest, Date()) }
        return biggest
    }

    /// Whether the pointer is over Figma's canvas (not a panel, the top bar or the bottom toolbar).
    private func isOverCanvas(_ point: CGPoint) -> Bool {
        guard let window = figmaWindowRect(), window.contains(point) else { return false }
        let canvas = CGRect(x: window.minX + Self.leftPanel, y: window.minY + Self.topBar,
                            width: window.width - Self.leftPanel - Self.rightPanel, height: window.height - Self.topBar)
        guard canvas.contains(point) else { return false }
        let toolbar = CGRect(x: window.midX - Self.toolbarWidth / 2, y: window.maxY - Self.toolbarHeight,
                             width: Self.toolbarWidth, height: Self.toolbarHeight)
        return !toolbar.contains(point)
    }

    private func handle(_ event: CGEvent) {
        guard figmaIsFrontmost, isOverCanvas(event.location) else { return }
        let vertical = abs(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        let horizontal = abs(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        guard vertical >= horizontal else { return }
        event.flags.insert(.maskControl)
        if zoomAmount != 1 { event.scaleScrollDeltas(by: zoomAmount) }
    }
}
