import AppKit
import Combine
import SwiftUI

/// Where the always-visible pill sits: its bottom-centre, remembered for each display as an offset from that display's bottom-left
/// corner, so a pill dragged to the top right of one screen is back there next time, and each screen keeps its own place.
enum PillPlacement {
    static let key = "floatingPillPositions"
    static let lastDisplayKey = "floatingPillDisplay"

    /// Bottom centre of the visible area, just above the Dock line.
    static func defaultAnchor(in visible: CGRect) -> CGPoint { CGPoint(x: visible.midX, y: visible.minY + 10) }

    static func save(anchor: CGPoint, screenFrame: CGRect, display: Int, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        all[String(display)] = "\(Double(anchor.x - screenFrame.minX)),\(Double(anchor.y - screenFrame.minY))"
        defaults.set(all, forKey: key)
        defaults.set(display, forKey: lastDisplayKey)
    }

    static func load(display: Int, screenFrame: CGRect, defaults: UserDefaults = .standard) -> CGPoint? {
        guard let text = (defaults.dictionary(forKey: key) as? [String: String])?[String(display)] else { return nil }
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: screenFrame.minX + parts[0], y: screenFrame.minY + parts[1])
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: lastDisplayKey)
    }

    /// The window's origin for a pill anchored at bottom-centre `anchor`, kept inside `visible`.
    static func origin(anchor: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        var x = anchor.x - size.width / 2
        var y = anchor.y
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGPoint(x: x, y: y)
    }
}

/// What the pill shows and what its buttons do.
@MainActor
final class FloatingPillState: ObservableObject {
    enum Phase: Equatable { case idle, listening, transcribing, reconnecting, offline, failed }

    @Published var phase = Phase.idle
    /// The preview while listening, or the message in the other states.
    @Published var text = ""
    @Published var hovering = false
    @Published var keyName = ""
    @Published var levels = Array(repeating: Float(0), count: 14)
    @Published var smoothed: Float = 0
    /// A sound is saved, waiting for Retry.
    @Published var hasPending = false
    /// The connection dropped while you were talking: the voice is still being saved here.
    @Published var connectionLost = false
    /// Show a Stop button while listening (when started from the pill or in tap-to-talk).
    @Published var showStop = false

    var onStart: () -> Void = {}
    var onStop: () -> Void = {}
    var onRetry: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onDrag: (_ ended: Bool) -> Void = { _ in }

    var expanded: Bool { phase == .idle && hovering }

    /// The window size for what's showing. Small when idle, so the pill never covers what's behind it.
    var desiredSize: CGSize {
        switch phase {
        case .idle: return expanded ? CGSize(width: hasPending ? 384 : 300, height: 58) : CGSize(width: 96, height: 32)
        case .listening, .transcribing: return CGSize(width: 390, height: 64 + (text.isEmpty ? 0 : 98))
        case .reconnecting: return CGSize(width: 350, height: 62)
        case .offline, .failed: return CGSize(width: 410, height: 118)
        }
    }
}

/// The pill's colours: the same teal graphite as the rest of the app, cyan accents, pale off-white buttons.
enum PillColors {
    static let indigo = Color(hex: 0x0D1719)    // the pill's surface (the name stays from an earlier palette)
    static let deep = Color(hex: 0x14262A)
    static let pink = Color(hex: 0x19D0E8)      // the accent: dots, glow, wave
    static let yellow = Color(hex: 0xF2F0ED)    // pale buttons
    static let orange = Color(hex: 0xFF8904)    // warnings and errors
    static let mint = Color(hex: 0x6FE39A)
    static let ink = Color(hex: 0x0D1719)       // text on the pale buttons
    static let text = Color(hex: 0xF2F0ED)
    static let rainbow = LinearGradient(colors: [Color(hex: 0x19D0E8), Color(hex: 0x8FC7C9)], startPoint: .leading, endPoint: .trailing)
}

struct FloatingPillView: View {
    @ObservedObject var state: FloatingPillState

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if (state.phase == .listening || state.phase == .transcribing), !state.text.isEmpty { preview }
            pill
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in state.onDrag(false) }
            .onEnded { _ in state.onDrag(true) })
        .animation(.easeOut(duration: 0.16), value: state.phase)
        .animation(.easeOut(duration: 0.16), value: state.expanded)
    }

    private var preview: some View {
        Text(state.text)
            .font(.inter(14, .medium))
            .foregroundStyle(PillColors.text)
            .lineSpacing(2)
            .lineLimit(4)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(PillColors.indigo))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(PillColors.rainbow, lineWidth: 1.2))
            .padding(.horizontal, 6)
    }

    @ViewBuilder private var pill: some View {
        switch state.phase {
        case .idle: idlePill
        case .listening: listeningPill
        case .transcribing: busyPill("Typing…")
        case .reconnecting: busyPill(state.text.isEmpty ? "Retrying…" : state.text)
        case .offline, .failed: messagePill
        }
    }

    @ViewBuilder private var idlePill: some View {
        if state.expanded {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill").font(.inter(12, .bold)).foregroundStyle(PillColors.ink)
                    .frame(width: 26, height: 26).background(PillColors.rainbow, in: Circle())
                Button(action: state.onStart) {
                    Text("Start dictation").font(.inter(13, .bold)).foregroundStyle(PillColors.ink).lineLimit(1).fixedSize()
                        .padding(.horizontal, 14).padding(.vertical, 7).background(PillColors.yellow, in: Capsule())
                }
                .buttonStyle(.plain)
                if state.hasPending {
                    Button(action: state.onRetry) {
                        Text("Retry").font(.inter(13, .bold)).foregroundStyle(PillColors.ink)
                            .padding(.horizontal, 12).padding(.vertical, 7).background(PillColors.pink, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                if !state.keyName.isEmpty {
                    Text(state.keyName).font(.inter(11, .semibold)).foregroundStyle(PillColors.text.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Color.white.opacity(0.16), in: Capsule())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Capsule().fill(PillColors.indigo))
            .overlay(Capsule().strokeBorder(PillColors.rainbow, lineWidth: 1.4))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .transition(.opacity)
        } else {
            Capsule().fill(PillColors.rainbow)
                .frame(width: 46, height: 8)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.65), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if state.hasPending { Circle().fill(PillColors.pink).frame(width: 9, height: 9).overlay(Circle().strokeBorder(.white, lineWidth: 1)).offset(x: 5, y: -4) }
                }
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                .padding(.bottom, 4)
        }
    }

    private var listeningPill: some View {
        HStack(spacing: 12) {
            PillBars(levels: state.levels)
            Text(state.connectionLost ? "Offline · keep talking, it's saved" : "Listening…")
                .font(.inter(13, .semibold)).foregroundStyle(state.connectionLost ? PillColors.orange : PillColors.text)
            if state.showStop {
                Button(action: state.onStop) {
                    Image(systemName: "stop.fill").font(.inter(11, .bold)).foregroundStyle(PillColors.ink)
                        .frame(width: 28, height: 28).background(PillColors.yellow, in: Circle())
                }
                .buttonStyle(.plain).help("Stop and type")
            }
        }
        .padding(.leading, 16).padding(.trailing, state.showStop ? 10 : 18).padding(.vertical, 9)
        .background(Capsule().fill(PillColors.indigo))
        .overlay(Capsule().strokeBorder(state.connectionLost ? AnyShapeStyle(PillColors.orange) : AnyShapeStyle(PillColors.rainbow), lineWidth: 1.6))
        .shadow(color: PillColors.pink.opacity(0.35 + Double(state.smoothed) * 0.3), radius: 16)
        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
    }

    private func busyPill(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).colorScheme(.dark)
            Text(title).font(.inter(13, .semibold)).foregroundStyle(PillColors.text).lineLimit(1)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Capsule().fill(PillColors.indigo))
        .overlay(Capsule().strokeBorder(PillColors.rainbow, lineWidth: 1.4))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
    }

    /// No connection or a failed dictation: what happened, and Retry / Dismiss. The sound is saved on this Mac.
    private var messagePill: some View {
        VStack(spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: state.phase == .offline ? "wifi.slash" : "exclamationmark.triangle.fill")
                    .font(.inter(15, .bold)).foregroundStyle(PillColors.orange)
                Text(state.text).font(.inter(12.5, .medium)).foregroundStyle(PillColors.text)
                    .lineLimit(3).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                if state.hasPending {
                    Button(action: state.onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise").font(.inter(13, .bold)).foregroundStyle(PillColors.ink)
                            .padding(.horizontal, 16).padding(.vertical, 7).background(PillColors.yellow, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button(action: state.onDismiss) {
                    Text("Dismiss").font(.inter(13, .semibold)).foregroundStyle(PillColors.text)
                        .padding(.horizontal, 14).padding(.vertical, 7).overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(PillColors.indigo))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(PillColors.orange, lineWidth: 1.4))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .padding(.horizontal, 6)
    }
}

/// Bars for the last moments of sound, newest on the right.
private struct PillBars: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(PillColors.rainbow)
                    .opacity(0.6 + Double(levels[index]) * 0.4)
                    .frame(width: 3, height: 5 + CGFloat(levels[index]) * 20)
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 1.0 / 30), value: levels)
    }
}

/// A hosting view that tells the pill when the mouse is over it (a tracking area that works even when MicFlow isn't the front app),
/// and takes the first click without needing the app to come forward.
private final class PillHostingView<Content: View>: NSHostingView<Content> {
    var onHover: (Bool) -> Void = { _ in }
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The small pill that is always on screen, like Whisper Flow's: a tiny capsule at rest, a Start dictation button when you point at
/// it, the waveform and your words while you talk, and Retry when a dictation couldn't be typed. Drag it anywhere; each display
/// remembers its place. It floats above other windows on every Space and never takes the keyboard focus.
@MainActor
final class FloatingPill {
    let state = FloatingPillState()
    var level: () -> Float = { 0 }
    var keyName: () -> String = { "" }

    private var panel: PillPanel?
    private var meter: Timer?
    private var changeWatch: AnyCancellable?
    private var screenWatch: NSObjectProtocol?
    private var hoverOff: DispatchWorkItem?
    private var dragStartMouse: CGPoint?
    private var dragStartOrigin: CGPoint?

    var isPresent: Bool { panel?.isVisible == true }
    /// Whether the tiny pill stays on screen when nothing is happening (the "Show the floating pill" switch). When it is off,
    /// the same pill still appears while you dictate and then goes away.
    private var restVisible = true

    func setRestVisible(_ visible: Bool) {
        restVisible = visible
        if visible {
            present()
        } else if state.phase == .idle {
            panel?.orderOut(nil)
        }
    }

    // MARK: Showing

    func present() {
        if panel == nil { makePanel() }
        state.keyName = keyName()
        place()
        panel?.orderFrontRegardless()
    }

    func dismiss() {
        meter?.invalidate(); meter = nil
        panel?.orderOut(nil)
        panel = nil
        changeWatch = nil
        if let screenWatch { NotificationCenter.default.removeObserver(screenWatch) }
        screenWatch = nil
        state.phase = .idle
        state.text = ""
    }

    func show(_ content: VoiceOverlay.Content) {
        if panel == nil { present() }
        if panel?.isVisible != true { place() }
        state.keyName = keyName()
        switch content {
        case .listening(let text):
            if state.phase != .listening { state.levels = Array(repeating: 0, count: state.levels.count) }
            state.phase = .listening
            state.text = text
            startMeter()
        case .transcribing:
            state.phase = .transcribing
        case .failed(let message):
            state.phase = .failed
            state.text = message
        case .reconnecting(let message):
            state.phase = .reconnecting
            state.text = message
        case .retry(let message):
            state.phase = .offline
            state.text = message
        }
        if state.phase != .listening { stopMeter() }
        updateFrame()
        panel?.orderFrontRegardless()
    }

    /// Back to the small resting pill.
    func idle() {
        state.phase = .idle
        state.text = ""
        state.connectionLost = false
        state.showStop = false
        stopMeter()
        updateFrame()
        if !restVisible { panel?.orderOut(nil) }
    }

    func resetPosition() {
        PillPlacement.reset()
        place()
    }

    // MARK: Panel

    private func makePanel() {
        let panel = PillPanel(contentRect: CGRect(origin: .zero, size: state.desiredSize), styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = PillHostingView(rootView: FloatingPillView(state: state))
        host.onHover = { [weak self] inside in self?.hover(inside) }
        panel.contentView = host
        self.panel = panel

        state.onDrag = { [weak self] ended in self?.drag(ended: ended) }
        // The window follows what's showing: its size changes with the state, anchored at the pill's bottom centre.
        changeWatch = state.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateFrame() }
        }
        screenWatch = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    private static func displayID(_ screen: NSScreen) -> Int {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }

    /// The display the pill lives on: the one it was last on, else the main one.
    private func homeScreen() -> NSScreen {
        let last = UserDefaults.standard.integer(forKey: PillPlacement.lastDisplayKey)
        return NSScreen.screens.first { Self.displayID($0) == last && last != 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func place() {
        guard let panel else { return }
        let screen = homeScreen()
        let anchor = PillPlacement.load(display: Self.displayID(screen), screenFrame: screen.frame) ?? PillPlacement.defaultAnchor(in: screen.visibleFrame)
        let size = state.desiredSize
        let origin = PillPlacement.origin(anchor: anchor, size: size, visible: screen.visibleFrame)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    private func updateFrame() {
        guard let panel else { return }
        let size = state.desiredSize
        guard panel.frame.size != size else { return }
        let anchor = CGPoint(x: panel.frame.midX, y: panel.frame.minY)
        let screen = panel.screen ?? homeScreen()
        let origin = PillPlacement.origin(anchor: anchor, size: size, visible: screen.visibleFrame)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    // MARK: Hover and drag

    private func hover(_ inside: Bool) {
        hoverOff?.cancel()
        if inside {
            state.hovering = true
        } else {
            // A short pause, so crossing the gap between the buttons doesn't fold the pill.
            let work = DispatchWorkItem { [weak self] in self?.state.hovering = false }
            hoverOff = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func drag(ended: Bool) {
        guard let panel else { return }
        if ended {
            dragStartMouse = nil
            dragStartOrigin = nil
            let screen = panel.screen ?? homeScreen()
            PillPlacement.save(anchor: CGPoint(x: panel.frame.midX, y: panel.frame.minY), screenFrame: screen.frame, display: Self.displayID(screen))
            return
        }
        let mouse = NSEvent.mouseLocation
        if dragStartMouse == nil { dragStartMouse = mouse; dragStartOrigin = panel.frame.origin }
        guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
        panel.setFrameOrigin(CGPoint(x: startOrigin.x + mouse.x - startMouse.x, y: startOrigin.y + mouse.y - startMouse.y))
    }

    // MARK: Meter

    private func startMeter() {
        guard meter == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meter = timer
    }

    private func stopMeter() {
        meter?.invalidate()
        meter = nil
        state.smoothed = 0
    }

    private func tick() {
        let heard = state.phase == .listening ? Self.loudness(level()) : 0
        state.smoothed = state.smoothed * 0.96 + heard * 0.04
        if state.phase == .listening {
            state.levels.removeFirst()
            state.levels.append(heard)
        }
    }

    /// 0 for silence to 1 for loud speech, on a decibel scale like the ear's.
    private static func loudness(_ rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 55) / 40, 0), 1)
    }
}

/// The setting for the pill on the Voice page: show or hide it, and put it back in its default place.
struct FloatingPillCard: View {
    @ObservedObject var voice: VoiceTypingModel
    let theme: HomeTheme

    var body: some View {
        FeatureCard(theme: theme, systemImage: "capsule.fill", title: "Show the floating pill",
                    subtitle: "One small pill for everything", isOn: $voice.floatingPillEnabled) {
            Note(text: "A tiny pill stays on your screen. Point at it to start dictating; while you talk the same pill shows the waveform and your words, and it also shows Retry and any message. Drag it wherever you like: each display remembers its place. If you switch it off, it still appears while you dictate.")
            HStack {
                PillButton(title: "Reset position", systemImage: "arrow.uturn.backward", style: .cream, action: voice.resetPillPosition)
            }
        }
    }
}
