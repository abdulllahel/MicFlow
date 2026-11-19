import AppKit
import SwiftUI

// The recording's control panel and drawing tools. The panel is a MicFlow window, so it never
// appears in the video; the drawing layer is let through to the recorder, so drawings do.

enum AnnotationTool: String, CaseIterable {
    case pen, arrow, rectangle

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        }
    }
}

@MainActor
final class RecordingControlsModel: ObservableObject {
    @Published var paused = false
    @Published var drawing = false
    @Published var tool: AnnotationTool = .pen
    @Published var color: NSColor = .systemRed

    static let colors: [NSColor] = [.systemRed, .systemYellow, NSColor(red: 0.1, green: 0.82, blue: 0.91, alpha: 1), .white]

    private var banked: TimeInterval = 0
    private var runStart: Date? = Date()

    /// Time recorded so far, without the paused parts.
    func elapsed() -> TimeInterval { banked + (runStart.map { Date().timeIntervalSince($0) } ?? 0) }

    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        if value, let start = runStart { banked += Date().timeIntervalSince(start); runStart = nil }
        if !value { runStart = Date() }
        paused = value
    }
}

@MainActor
final class RecordingControls {
    let model = RecordingControlsModel()
    private let overlay: AnnotationOverlay
    private let panel: NSPanel
    /// The drawing layer's window, which the recorder keeps in the video.
    var overlayWindowID: CGWindowID { CGWindowID(overlay.windowNumber) }

    init(screen: NSScreen, pause: @escaping () -> Void, resume: @escaping () -> Void, stop: @escaping () -> Void) {
        overlay = AnnotationOverlay(screen: screen)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = ControlsView(model: model, togglePause: { [weak self] in
            guard let self else { return }
            if self.model.paused { self.model.setPaused(false); resume() } else { self.model.setPaused(true); pause() }
        }, stop: stop, undo: { [weak self] in self?.overlay.canvas.undo() },
           clear: { [weak self] in self?.overlay.canvas.clear() })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        panel.setContentSize(size)
        panel.contentView = hosting
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 24))
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.sync() }
        }.store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    /// Shows the drawing layer first, so the recorder can be told about it, then the panel.
    func showOverlay() { overlay.orderFrontRegardless() }

    func showPanel() {
        panel.orderFrontRegardless()
        sync()
    }

    private func sync() {
        overlay.canvas.tool = model.tool
        overlay.canvas.color = model.color
        overlay.ignoresMouseEvents = !model.drawing
        if let hosting = panel.contentView {
            let size = hosting.fittingSize
            if abs(size.width - panel.frame.width) > 1 {
                var frame = panel.frame
                frame.origin.x += (frame.width - size.width) / 2
                frame.size = size
                panel.setFrame(frame, display: true)
            }
        }
    }

    func close() {
        panel.orderOut(nil)
        overlay.orderOut(nil)
    }
}

import Combine

private struct ControlsView: View {
    @ObservedObject var model: RecordingControlsModel
    let togglePause: () -> Void
    let stop: () -> Void
    let undo: () -> Void
    let clear: () -> Void

    private let teal = Color(red: 0.1, green: 0.82, blue: 0.91)

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(model.paused ? Color.orange : Color.red).frame(width: 9, height: 9)
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let s = Int(model.elapsed())
                    Text(String(format: "%d:%02d", s / 60, s % 60)).font(.inter(14, .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(.white)
            button(model.paused ? "play.fill" : "pause.fill", help: model.paused ? "Resume" : "Pause", action: togglePause)
            button("stop.fill", help: "Stop and save", tint: .red, action: stop)
            Divider().frame(height: 24).overlay(Color.white.opacity(0.2))
            button("pencil.and.scribble", help: model.drawing ? "Stop drawing (keep using your screen)" : "Draw on the screen",
                   tint: model.drawing ? teal : nil) { model.drawing.toggle() }
            if model.drawing {
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    button(tool.symbol, help: tool.rawValue.capitalized, tint: model.tool == tool ? teal : nil) { model.tool = tool }
                }
                ForEach(RecordingControlsModel.colors, id: \.self) { color in
                    Button { model.color = color } label: {
                        Circle().fill(Color(nsColor: color)).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white, lineWidth: model.color == color ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
                button("arrow.uturn.backward", help: "Undo", action: undo)
                button("trash", help: "Clear drawings", action: clear)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Capsule().fill(Color(red: 0.04, green: 0.07, blue: 0.07)))
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .padding(6)
    }

    private func button(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint == nil ? Color.white : (tint == .red ? Color.white : Color.black))
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint ?? Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Drawing layer

/// A see-through window over the whole screen. While drawing is on it takes the mouse; otherwise
/// clicks pass through to the apps below and the drawings stay in place.
final class AnnotationOverlay: NSPanel {
    let canvas: AnnotationCanvas

    init(screen: NSScreen) {
        canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = canvas
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
}

final class AnnotationCanvas: NSView {
    private struct Stroke { var tool: AnnotationTool; var color: NSColor; var points: [NSPoint] }
    private var strokes: [Stroke] = []
    private var current: Stroke?
    var tool: AnnotationTool = .pen
    var color: NSColor = .systemRed

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func undo() { if !strokes.isEmpty { strokes.removeLast(); needsDisplay = true } }
    func clear() { strokes = []; current = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        current = Stroke(tool: tool, color: color, points: [convert(event.locationInWindow, from: nil)])
    }

    override func mouseDragged(with event: NSEvent) {
        guard var stroke = current else { return }
        stroke.points.append(convert(event.locationInWindow, from: nil))
        current = stroke
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let stroke = current, stroke.points.count > 1 { strokes.append(stroke) }
        current = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for stroke in strokes + (current.map { [$0] } ?? []) { draw(stroke) }
    }

    private func draw(_ stroke: Stroke) {
        guard let first = stroke.points.first, let last = stroke.points.last else { return }
        let path = NSBezierPath()
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch stroke.tool {
        case .pen:
            path.move(to: first)
            stroke.points.dropFirst().forEach { path.line(to: $0) }
        case .rectangle:
            path.appendRect(NSRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
        case .arrow:
            path.move(to: first)
            path.line(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            for side in [CGFloat.pi * 0.85, -CGFloat.pi * 0.85] {
                path.move(to: last)
                path.line(to: NSPoint(x: last.x + 20 * cos(angle + side), y: last.y + 20 * sin(angle + side)))
            }
        }
        stroke.color.setStroke()
        path.stroke()
    }
}
