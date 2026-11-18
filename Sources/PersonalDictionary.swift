import AppKit
import SwiftUI

/// Words a normal dictionary doesn't know (brand names, jargon, local or made-up words), with a
/// recording of how you say each one. MicFlow learns them as you talk: an unknown word you say a
/// second time is added, with a small note at the bottom of the screen. They are always spelled your
/// way, and clean-up is told they are real words.
@MainActor
final class PersonalDictionary: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var word: String
        /// The file name of the recording in the clips folder, if there is one.
        var clip: String?
    }

    @Published private(set) var entries: [Entry] = []
    /// Set by the voice model: adds the word to the list used for spelling and clean-up.
    var addToWordList: (String) -> Void = { _ in }
    var removeFromWordList: (String) -> Void = { _ in }

    private let defaults = UserDefaults.standard
    private let key = "personalDictionaryEntries"
    private let countsKey = "personalDictionaryCounts"
    private var player: NSSound?
    private let chip = LearnedWordChip()
    private let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("MicFlow/Word Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    init() {
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Words saved before the dictionary had recordings join it without one.
    func adopt(_ words: [String]) {
        var changed = false
        for word in words where !entries.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
            entries.append(Entry(word: word)); changed = true
        }
        if changed { save() }
    }

    func add(_ word: String, samples: [Float]? = nil, sampleRate: Double = 48_000, announce: Bool = false) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !entries.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) else { return }
        var entry = Entry(word: word)
        if let samples, !samples.isEmpty {
            let name = "\(entry.id.uuidString).wav"
            // At most the last eight seconds: enough to hear how the word is said.
            let kept = Array(samples.suffix(Int(sampleRate * 8)))
            if Self.writeWAV(kept, sampleRate: sampleRate, to: folder.appendingPathComponent(name)) { entry.clip = name }
        }
        entries.append(entry)
        save()
        addToWordList(word)
        if announce { chip.show("Added “\(word)” to your dictionary") }
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        if let clip = entry.clip { try? FileManager.default.removeItem(at: folder.appendingPathComponent(clip)) }
        removeFromWordList(entry.word)
        save()
    }

    func play(_ entry: Entry) {
        guard let clip = entry.clip else { return }
        player?.stop()
        player = NSSound(contentsOf: folder.appendingPathComponent(clip), byReference: true)
        player?.play()
    }

    /// Looks at a finished dictation: a word the system dictionary doesn't know, said a second time,
    /// is added with the recording of this dictation.
    func learn(from text: String, samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        var counts = defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
        let checker = NSSpellChecker.shared
        var seen = Set<String>()
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { word, _, _, _ in
            guard let word, word.count >= 3, word.count <= 24, word.allSatisfy({ $0.isLetter && $0.isASCII }) else { return }
            let lower = word.lowercased()
            guard seen.insert(lower).inserted else { return }
            if self.entries.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) { return }
            // Known to the system dictionary: not new.
            guard checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound else { return }
            counts[lower, default: 0] += 1
            if counts[lower]! >= 2 {
                counts[lower] = nil
                self.add(word, samples: samples, sampleRate: sampleRate, announce: true)
            }
        }
        if counts.count > 400 { counts = [:] }
        defaults.set(counts, forKey: countsKey)
    }

    private func save() { defaults.set(try? JSONEncoder().encode(entries), forKey: key) }

    private static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) -> Bool {
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        data.append("RIFF".data(using: .ascii)!); u32(36 + bytes); data.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        data.append("data".data(using: .ascii)!); u32(bytes)
        for sample in samples { var v = Int16(max(-1, min(1, sample)) * 32767).littleEndian; data.append(Data(bytes: &v, count: 2)) }
        return (try? data.write(to: url)) != nil
    }
}

/// A small chip at the bottom of the screen: "Added “word” to your dictionary".
@MainActor
final class LearnedWordChip {
    private var panel: NSPanel?
    private var work: DispatchWorkItem?

    func show(_ text: String) {
        let view = NSHostingView(rootView: Text(text)
            .font(.inter(13, .bold)).foregroundStyle(Palette.ink)
            .padding(.horizontal, 16).padding(.vertical, 9).background(Palette.cream, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let panel = self.panel ?? NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        panel.setContentSize(view.frame.size)
        do { let screen = NSScreen.underPointer; panel.setFrameOrigin(NSPoint(x: screen.frame.midX - view.frame.width / 2, y: screen.frame.minY + 60)) }
        panel.orderFrontRegardless()
        self.panel = panel
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: item)
    }
}

/// The dictionary panel on the Preferences page.
struct PersonalDictionaryPanel: View {
    @ObservedObject var dictionary: PersonalDictionary
    @State private var newWord = ""

    var body: some View {
        WhitePanel {
            HStack(alignment: .firstTextBaseline) {
                Text("Personal dictionary").font(.display(24))
                Text("brands, jargon, local and made-up words").font(.inter(12)).foregroundStyle(Palette.greyOnLight)
                Spacer()
            }
            Text("MicFlow adds words it doesn't know as you talk (after you say one a second time) and keeps a recording of how you said it. Tap play to hear it.")
                .font(.inter(12)).foregroundStyle(Palette.greyOnLight)
            if dictionary.entries.isEmpty {
                Text("No words yet.").font(.inter(13)).foregroundStyle(Palette.greyOnLight)
            }
            ForEach(dictionary.entries) { entry in
                HStack(spacing: 10) {
                    Text(entry.word).font(.inter(14, .bold))
                    Spacer()
                    if entry.clip != nil {
                        Button { dictionary.play(entry) } label: {
                            Label("Play", systemImage: "play.circle.fill").font(.inter(12, .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Palette.pink).help("Hear how you said it")
                    }
                    Button { dictionary.remove(entry) } label: {
                        Image(systemName: "minus.circle.fill").font(.inter(18)).foregroundStyle(Palette.orange)
                    }
                    .buttonStyle(.plain).help("Remove \(entry.word)")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Palette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack {
                PillField(placeholder: "Add a word", text: $newWord, onDark: false, onSubmit: add)
                PillButton(title: "Add word", systemImage: "plus", style: .yellow, action: add)
            }
        }
    }

    private func add() {
        dictionary.add(newWord)
        newWord = ""
    }
}
