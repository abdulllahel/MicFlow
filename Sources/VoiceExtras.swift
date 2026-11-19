import SwiftUI

/// Listens to the chosen microphone while the picker is on screen, so the level bar moves as you talk and you can see the mic works.
@MainActor
final class MicMonitor: ObservableObject {
    @Published private(set) var level: Float = 0
    @Published private(set) var failed = false
    private let recorder = VoiceRecorder()
    private var timer: Timer?
    private var running = false

    func start(_ device: AudioDevice?) {
        stop()
        guard let device else { failed = true; return }
        do { try recorder.start(device, gain: 1) } catch { failed = true; return }
        failed = false
        running = true
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let rms = self.recorder.level
                let db = 20 * log10(max(rms, 1e-6))
                let heard = min(max((db + 55) / 40, 0), 1)
                self.level = self.level * 0.6 + heard * 0.4
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if running { _ = recorder.stop() }
        running = false
        level = 0
    }

    deinit { timer?.invalidate() }
}

/// Which microphone voice typing uses, with a live level bar, and how the voice indicator looks.
struct MicPickerCard: View {
    @ObservedObject var voice: VoiceTypingModel
    let theme: HomeTheme
    @StateObject private var monitor = MicMonitor()
    @State private var uid = ""

    var body: some View {
        FeatureCard(theme: theme, systemImage: "mic.fill", title: "Microphone and indicator", subtitle: "What voice typing listens to") {
            PillMenu(selection: Binding(get: { uid }, set: { uid = $0; voice.selectMic($0); restart() }),
                     options: voice.micChoices().map { ($0.uid, $0.name) })
            LevelBar(level: monitor.level, active: !monitor.failed)
            Note(text: monitor.failed ? "MicFlow can't listen to this microphone. Pick another one, or allow the microphone in System Settings." : "Say something: the bar moves when this microphone hears you.",
                 isError: monitor.failed)
            Text("Indicator").font(.inter(13))
            HStack(spacing: 6) {
                ForEach(VoiceOverlay.Style.allCases) { style in
                    let selected = voice.overlayStyle == style
                    Button { voice.overlayStyle = style } label: {
                        Text(style.title).font(.inter(12, .semibold))
                            .foregroundStyle(selected ? Palette.ink : Palette.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selected ? Palette.cream : Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if voice.overlayStyle == .line {
                Note(text: "A thin waveform with your words attached above it. Drag it anywhere on the screen; it stays there. The microphone button on it switches microphones.")
            }
        }
        .onAppear { uid = voice.selectedMicUID(); restart() }
        .onDisappear { monitor.stop() }
    }

    private func restart() {
        // Voice typing owns the microphone while a dictation is running.
        guard voice.phase == .idle else { return }
        monitor.start(voice.inputDevice())
    }
}

struct LevelBar: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(level > 0.9 ? Palette.pink : level > 0.7 ? Palette.yellow : Palette.cream)
                    .frame(width: geo.size.width * CGFloat(active ? level : 0))
            }
        }
        .frame(height: 8)
    }
}

/// Transcribe the last dictation again from its saved sound.
struct RecoverCard: View {
    @ObservedObject var voice: VoiceTypingModel
    let theme: HomeTheme

    var body: some View {
        FeatureCard(theme: theme, systemImage: "arrow.counterclockwise.circle.fill", title: "Recover last dictation",
                    subtitle: "If a dictation came out wrong or didn't arrive") {
            if let reason = voice.recoverOffer {
                Note(text: reason + " Recover it from the saved sound?", isError: true)
            }
            if voice.canRecover {
                Note(text: savedText)
                HStack {
                    PillButton(title: voice.recovering ? "Transcribing…" : "Recover last dictation", systemImage: "arrow.clockwise",
                               style: .cream, action: voice.recoverLast)
                    PillButton(title: "Delete the saved sound", style: .outline, action: voice.deleteSavedSound)
                }
            } else {
                Note(text: "MicFlow keeps the sound of your last dictation on this Mac, so you can transcribe it again. Nothing is saved yet.")
            }
            Note(text: "Only the last dictation is kept. It stays on this Mac and is replaced by the next one.")
        }
    }

    private var savedText: String {
        guard let meta = DictationAudio.meta else { return "The last dictation's sound is saved." }
        let when = RelativeDateTimeFormatter().localizedString(for: meta.date, relativeTo: Date())
        let preview = meta.text.isEmpty ? "" : " “\(meta.text.prefix(60))\(meta.text.count > 60 ? "…" : "")”"
        return "Saved \(when) (\(Int(meta.seconds.rounded())) s).\(preview)"
    }
}

/// What MicFlow has learned about you: every line can be edited or deleted.
struct MemoryCard: View {
    @ObservedObject var memory: MemoryStore
    let theme: HomeTheme
    let key: () -> String?
    var signedIn = false
    var syncStatus = ""
    var syncNow: (() -> Void)? = nil
    @State private var newText = ""
    @State private var newKind = MemoryItem.Kind.preference

    var body: some View {
        FeatureCard(theme: theme, systemImage: "brain.head.profile", title: "Memory",
                    subtitle: "\(memory.items.count) thing\(memory.items.count == 1 ? "" : "s") MicFlow knows about you") {
            CheckRow(title: "Learn from how I speak", isOn: $memory.learningOn)
            Note(text: "MicFlow looks at your recent dictations now and then and remembers your job, your field, your preferences and the words you use, so the clean-up spells and words things the way you would. It is kept encrypted on this Mac, and saved encrypted to your Google account so it comes back when you sign in again. What you see here is everything it knows.")
            if memory.items.isEmpty {
                Note(text: "Nothing yet. It fills in as you dictate, or add your own below.")
            }
            ForEach(memory.items) { item in
                MemoryRow(memory: memory, item: item)
            }
            HStack(spacing: 8) {
                PillMenu(selection: $newKind, options: MemoryItem.Kind.allCases.map { ($0, $0.title) })
                    .frame(width: 150)
                PillField(placeholder: "Add something about you", text: $newText, onSubmit: add)
                PillButton(title: "Add", style: .cream, action: add)
            }
            HStack {
                PillButton(title: memory.learning ? "Learning…" : "Learn now", systemImage: "sparkles", style: .outline) { memory.learn(key: key()) }
                if !memory.items.isEmpty { PillButton(title: "Forget everything", style: .outline, action: memory.clear) }
            }
            Note(text: memory.status)
            SyncFooter(what: "Memory", signedIn: signedIn, status: syncStatus, syncNow: syncNow)
        }
    }

    private func add() {
        memory.add(newKind, newText)
        newText = ""
    }
}

private struct MemoryRow: View {
    @ObservedObject var memory: MemoryStore
    let item: MemoryItem
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(item.kind.title).font(.inter(10, .semibold)).foregroundStyle(Palette.ink)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Palette.cream, in: Capsule())
                .frame(width: 96, alignment: .leading)
            TextField("", text: $draft, onCommit: { memory.update(item.id, text: draft) })
                .textFieldStyle(.plain).font(.inter(13))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button { memory.remove(item.id) } label: {
                Image(systemName: "trash").font(.inter(12)).foregroundStyle(Palette.greyOnDark)
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .onAppear { draft = item.text }
        .onChange(of: item.text) { draft = $0 }
    }
}

/// Backup providers: shown only after a Google key is saved. Google answers first; the others step in when it fails or is slow.
struct ProvidersCard: View {
    @ObservedObject var settings: ProviderSettings
    let theme: HomeTheme
    var signedIn = false
    var syncStatus = ""
    var syncNow: (() -> Void)? = nil
    @State private var drafts: [String: String] = [:]

    var body: some View {
        FeatureCard(theme: theme, systemImage: "arrow.triangle.branch", title: "Backup providers",
                    subtitle: "If Google is slow or runs out") {
            Note(text: "Google AI Studio answers first. If it fails, hits its limit, or is slow, MicFlow asks the next provider here, so dictation keeps working inside the same time limits. Add a key to switch one on.")
            SyncFooter(what: "Backup keys", signedIn: signedIn, status: syncStatus, syncNow: syncNow)
            ForEach(BackupProvider.all) { backup in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(backup.name).font(.inter(13, .semibold))
                        Text(backup.note).font(.inter(11)).foregroundStyle(Palette.greyOnDark)
                        Spacer()
                        if settings.saved.contains(backup.id) {
                            PinkSwitch(isOn: Binding(get: { settings.isOn(backup.id) }, set: { settings.setOn(backup.id, $0) }))
                        }
                    }
                    if settings.saved.contains(backup.id) {
                        HStack {
                            Label("Key saved", systemImage: "checkmark.seal.fill").font(.inter(12, .semibold)).foregroundStyle(Palette.cream)
                            Spacer()
                            PillButton(title: settings.testing == backup.id ? "Testing…" : "Test", style: .outline) { settings.test(backup) }
                            PillButton(title: "Remove", style: .outline) { settings.remove(backup.id) }
                        }
                        if let result = settings.results[backup.id] { Note(text: result, isError: result != "Works") }
                    } else {
                        HStack {
                            PillField(placeholder: "Paste your \(backup.name) key", text: Binding(get: { drafts[backup.id] ?? "" }, set: { drafts[backup.id] = $0 }),
                                      secure: true, onSubmit: { save(backup) })
                            PillButton(title: "Save", style: .cream) { save(backup) }
                        }
                        Link("Get a key", destination: backup.keyPage).font(.inter(12, .semibold)).foregroundStyle(Palette.cream)
                    }
                }
            }
        }
    }

    private func save(_ backup: BackupProvider) {
        settings.save(backup.id, key: drafts[backup.id] ?? "")
        drafts[backup.id] = nil
    }
}

/// Says that something syncs through the Google account, and lets you sync right now.
struct SyncFooter: View {
    let what: String
    let signedIn: Bool
    let status: String
    let syncNow: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Note(text: signedIn
                 ? "\(what) sync, sealed, through your Google account, so every device you sign in on has the same copy. A line or key you delete here is deleted there too."
                 : "Sign in with Google to sync your \(what.lowercased()) to your other devices. Until then they stay on this Mac.")
            if signedIn, let syncNow {
                HStack {
                    PillButton(title: "Sync now", systemImage: "arrow.triangle.2.circlepath", style: .outline, action: syncNow)
                    if !status.isEmpty { Text(status).font(.inter(12)).foregroundStyle(Palette.greyOnDark) }
                }
            }
        }
    }
}
