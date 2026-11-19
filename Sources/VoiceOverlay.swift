import AppKit
import SwiftUI

/// What voice typing shows at the bottom of the screen: a pill with a glowing, flowing gradient
/// edge and a waveform of the voice it hears, and above it a box with the words recognized so far.
@MainActor
final class VoiceOverlay {
    enum Content: Equatable {
        /// The text heard so far; empty until the first words come back.
        case listening(String)
        /// After the key is let go, until the text is typed. The words stay up.
        case transcribing
        case failed(String)
    }

    /// The pill is the original; the line is a small waveform you can drag anywhere, with the preview attached above it.
    enum Style: String, CaseIterable, Identifiable {
        case pill, line
        var id: String { rawValue }
        var title: String { self == .pill ? "Pill" : "Waveform line" }
    }

    var style = Style.pill {
        didSet {
            guard style != oldValue else { return }
            panel?.orderOut(nil)
            panel = nil
        }
    }
    /// The microphones to pick from, the chosen one, and how to choose (the line style shows them in a menu).
    var micChoices: () -> [(uid: String, name: String)] = { [] }
    var selectedMicUID: () -> String = { "" }
    var selectMic: (String) -> Void = { _ in }

    /// The microphone's loudness right now (RMS), for the waveform and the glow.
    var level: () -> Float = { 0 }
    /// The name of the voice key, shown on the key in the pill.
    var keyName: () -> String = { "" }

    private let state = VoiceOverlayState()
    private var panel: NSPanel?
    private var timer: Timer?

    /// Room for the text box above the pill and the glow around it; the panel never changes size,
    /// so nothing jumps as words come in.
    private static let size = CGSize(width: 560, height: 300)
    private static let lineSize = CGSize(width: 380, height: 190)
    private static let lineOriginKey = "voiceLineOrigin"
    private var moveWatch: NSObjectProtocol?

    func show(_ content: Content) {
        state.keyName = keyName()
        if style == .line {
            state.mics = micChoices()
            state.micUID = selectedMicUID()
            state.selectMic = { [weak self] uid in
                self?.state.micUID = uid
                self?.selectMic(uid)
            }
        }
        state.style = style
        switch content {
        case .listening(let text):
            if state.phase != .listening { state.levels = Array(repeating: 0, count: VoiceOverlayState.barCount) }
            state.phase = .listening
            state.text = text
        case .transcribing:
            state.phase = .transcribing
        case .failed(let message):
            state.phase = .failed
            state.text = message
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if style == .line {
            // Stays where the person dragged it; the first time, bottom centre.
            if !panel.isVisible { panel.setFrameOrigin(Self.savedLineOrigin(for: panel.frame.size)) }
        } else {
            let screen = NSScreen.underPointer
            // The pill's bottom edge sits where the old pill's did.
            // Right at the bottom edge of the screen, below the Dock line, so it stays off the app's own controls.
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - Self.size.width / 2, y: screen.frame.minY + 6))
        }
        panel.orderFrontRegardless()
        startMeter()
    }

    func hide() {
        panel?.orderOut(nil)
        timer?.invalidate()
        timer = nil
        state.phase = .hidden
        state.text = ""
    }

    /// Reads the microphone level 30 times a second while showing.
    private func startMeter() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let heard = state.phase == .listening ? Self.loudness(level()) : 0
        // Eases over about a second each way, so the glow breathes with the voice instead of flickering.
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

    private static func savedLineOrigin(for size: CGSize) -> NSPoint {
        if let text = UserDefaults.standard.string(forKey: lineOriginKey) {
            let origin = NSPointFromString(text)
            let frame = CGRect(origin: origin, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return origin }
        }
        let screen = NSScreen.underPointer
        return NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 24)
    }

    private func makeLinePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.lineSize), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = DraggableHostingView(rootView: WaveLineView(state: state))
        if let moveWatch { NotificationCenter.default.removeObserver(moveWatch) }
        moveWatch = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: Self.lineOriginKey)
        }
        return panel
    }

    private func makePanel() -> NSPanel {
        if style == .line { return makeLinePanel() }
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: VoiceOverlayView(state: state))
        return panel
    }
}

@MainActor
final class VoiceOverlayState: ObservableObject {
    enum Phase { case hidden, listening, transcribing, failed }

    static let barCount = 48

    @Published var phase = Phase.hidden
    @Published var text = ""
    @Published var keyName = ""
    @Published var style = VoiceOverlay.Style.pill
    @Published var mics: [(uid: String, name: String)] = []
    @Published var micUID = ""
    var selectMic: (String) -> Void = { _ in }
    /// Recent loudness, oldest first, one per waveform bar.
    @Published var levels = Array(repeating: Float(0), count: barCount)
    /// The loudness, eased slowly, for the glow.
    @Published var smoothed: Float = 0
}

struct VoiceOverlayView: View {
    @ObservedObject var state: VoiceOverlayState

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if !state.text.isEmpty {
                TextBox(text: state.text, isError: state.phase == .failed)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            GlowingPill(state: state)
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.18), value: state.text.isEmpty)
    }
}

/// The words recognized so far. The newest stay in view; older ones scroll off the top.
private struct TextBox: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text)
            .font(.inter(14, .medium))
            .foregroundStyle(isError ? Color(hex: 0xFF8904) : Color(hex: 0xF2F0ED))
            .lineSpacing(2)
            .lineLimit(5)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 460, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x0A1012)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.16)))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
    }
}

/// The pill from the website: a dark capsule with the voice key (it presses down while you talk), teal bars
/// that move with your voice, and a short label. A teal glow rings it while it listens.
private struct GlowingPill: View {
    @ObservedObject var state: VoiceOverlayState

    private static let teal = Color(hex: 0x19D0E8)
    private static let tealSoft = Color(hex: 0xC5F8FF)

    var body: some View {
        let live = state.phase == .listening
        HStack(spacing: 14) {
            keycap(pressed: live)
            content
        }
        .padding(.leading, 12).padding(.trailing, 20).padding(.vertical, 10)
        .background(Capsule().fill(Color(hex: 0x0B1214)))
        .overlay(Capsule().strokeBorder(live ? Self.teal.opacity(0.75) : Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: live ? Self.teal.opacity(0.4 + Double(state.smoothed) * 0.3) : .clear, radius: live ? 22 : 0)
        .shadow(color: .black.opacity(0.6), radius: 14, y: 8)
        .animation(.easeOut(duration: 0.2), value: live)
    }

    /// The voice key, pressed down while you hold (or after you tap) it.
    private func keycap(pressed: Bool) -> some View {
        Text(state.keyName)
            .font(.inter(12, .semibold))
            .foregroundStyle(pressed ? Self.tealSoft : Color(hex: 0xF2F0ED))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x3A4346), Color(hex: 0x242B2D)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color(hex: 0x0C1011), radius: 0, y: pressed ? 1 : 4)
                    .shadow(color: .black.opacity(0.5), radius: pressed ? 2 : 6, y: pressed ? 2 : 6)
            )
            .offset(y: pressed ? 3 : 0)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).colorScheme(.dark)
                Text("Typing…").font(.inter(13, .medium)).foregroundStyle(Color(hex: 0xF2F0ED))
            }
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFF8904))
                Text("Couldn't type").font(.inter(13, .medium)).foregroundStyle(Color(hex: 0xF2F0ED))
            }
        case .listening, .hidden:
            HStack(spacing: 12) {
                Bars(levels: Array(state.levels.suffix(9)), color: Self.teal)
                Text(state.phase == .listening ? "Listening…" : "Hold to talk")
                    .font(.inter(13, .medium)).foregroundStyle(Color(hex: 0xF2F0ED))
            }
        }
    }
}

/// Teal bars for the last moments of sound, newest on the right.
private struct Bars: View {
    let levels: [Float]
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(0.55 + Double(levels[index]) * 0.45))
                    .frame(width: 3, height: 5 + CGFloat(levels[index]) * 20)
            }
        }
        .frame(height: 26)
        .animation(.linear(duration: 1.0 / 30), value: levels)
    }
}


/// A window that moves when you drag anywhere on it that isn't a control.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The small waveform line: the words so far attached above it, the voice drawn as a line, and the microphone in use (a menu to change it).
/// Drag it anywhere; it comes back to the same place next time.
private struct WaveLineView: View {
    @ObservedObject var state: VoiceOverlayState

    private static let teal = Color(hex: 0x19D0E8)

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if !state.text.isEmpty {
                Text(state.text)
                    .font(.inter(13, .medium))
                    .foregroundStyle(state.phase == .failed ? Color(hex: 0xFF8904) : Color(hex: 0xF2F0ED))
                    .lineLimit(4)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 14, style: .continuous)
                        .fill(Color(hex: 0x0A1012)))
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.white.opacity(0.35))
                WaveLine(levels: state.levels, color: state.phase == .failed ? Color(hex: 0xFF8904) : Self.teal)
                    .frame(height: 28)
                status
                micMenu
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(UnevenRoundedRectangle(topLeadingRadius: state.text.isEmpty ? 14 : 0, bottomLeadingRadius: 14, bottomTrailingRadius: 14,
                                               topTrailingRadius: state.text.isEmpty ? 14 : 0, style: .continuous).fill(Color(hex: 0x0B1214)))
        }
        .overlay(alignment: .bottom) { EmptyView() }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(state.phase == .listening ? Self.teal.opacity(0.7) : Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.15), value: state.text.isEmpty)
    }

    @ViewBuilder private var status: some View {
        switch state.phase {
        case .transcribing: ProgressView().controlSize(.small).colorScheme(.dark)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFF8904))
        default:
            Text(state.keyName).font(.inter(10, .semibold)).foregroundStyle(Color(hex: 0xF2F0ED))
                .padding(.horizontal, 7).padding(.vertical, 3).background(Color.white.opacity(0.12), in: Capsule())
        }
    }

    private var micMenu: some View {
        Menu {
            ForEach(state.mics, id: \.uid) { mic in
                Button { state.selectMic(mic.uid) } label: {
                    if mic.uid == state.micUID { Label(mic.name, systemImage: "checkmark") } else { Text(mic.name) }
                }
            }
        } label: {
            Image(systemName: "mic.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0xF2F0ED))
                .frame(width: 24, height: 24).background(Color.white.opacity(0.12), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(state.mics.first { $0.uid == state.micUID }?.name ?? "Microphone")
    }
}

/// The voice as one thin line: flat in silence, rising and falling with the sound, newest on the right.
private struct WaveLine: View {
    let levels: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard levels.count > 1 else { return }
            let mid = size.height / 2
            let step = size.width / CGFloat(levels.count - 1)
            var path = Path()
            for (index, level) in levels.enumerated() {
                let x = CGFloat(index) * step
                // Alternating sides makes a waveform out of a loudness history.
                let amplitude = CGFloat(level) * (size.height / 2 - 1) * (index % 2 == 0 ? 1 : -1)
                let point = CGPoint(x: x, y: mid + amplitude)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}
