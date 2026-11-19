import AppKit
import CryptoKit
import SwiftUI

/// Words a normal dictionary doesn't know (brand names, jargon, local or made-up words), with a
/// recording of how you say each one. MicFlow learns them as you talk: an unknown word you say a
/// second time is added, with a small note at the bottom of the screen. They are always spelled your
/// way, and clean-up is told they are real words.
@MainActor
final class PersonalDictionary: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        /// How the word is written (what gets typed).
        var word: String
        /// The file name of the recording in the clips folder, if there is one.
        var clip: String?
        /// How the word sounds, in your own letters ("amader"): when the transcript has this, MicFlow types `word` instead.
        var sounds: String?
    }

    @Published private(set) var entries: [Entry] = []
    /// Set by the voice model: adds the word to the list used for spelling and clean-up.
    var addToWordList: (String) -> Void = { _ in }
    var removeFromWordList: (String) -> Void = { _ in }
    /// Told whenever the pronunciation entries change, so they can travel with your other preferences.
    var onPronunciationsChanged: ([Entry]) -> Void = { _ in }

    /// The entries that have a pronunciation, as (what it sounds like, what to write).
    var pronunciations: [(sounds: String, written: String)] {
        entries.compactMap { entry in
            guard let sounds = entry.sounds?.trimmingCharacters(in: .whitespacesAndNewlines), !sounds.isEmpty else { return nil }
            return (sounds, entry.word)
        }
    }

    /// The same entries as clean-up instructions ("heard" → "meant").
    var pronunciationMixUps: [MixUp] {
        pronunciations.map { MixUp(heard: $0.sounds, meant: $0.written, meaning: "pronunciation") }
    }

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

    func add(_ word: String, sounds: String? = nil, samples: [Float]? = nil, sampleRate: Double = 48_000, announce: Bool = false) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let sounds = sounds?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard !word.isEmpty, !entries.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame && ($0.sounds ?? "").caseInsensitiveCompare(sounds ?? "") == .orderedSame }) else { return }
        var entry = Entry(word: word, sounds: sounds)
        markDeleted(entry, false)
        if let samples, !samples.isEmpty {
            let name = "\(entry.id.uuidString).wav"
            // At most the last eight seconds: enough to hear how the word is said.
            let kept = Array(samples.suffix(Int(sampleRate * 8)))
            if Self.writeWAV(kept, sampleRate: sampleRate, to: folder.appendingPathComponent(name)) { entry.clip = name }
        }
        entries.append(entry)
        save()
        addToWordList(word)
        if sounds != nil { onPronunciationsChanged(entries) }
        if announce { chip.show("Added “\(word)” to your dictionary") }
    }

    private let deletedKey = "personalDictionaryDeletedPronunciations"

    /// A pronunciation you deleted here is not brought back by another device that still has it.
    func wasDeleted(heard: String, meant: String) -> Bool {
        (defaults.stringArray(forKey: deletedKey) ?? []).contains(Self.stableID(heard: heard, meant: meant).uuidString)
    }

    private func markDeleted(_ entry: Entry, _ deleted: Bool) {
        guard let sounds = entry.sounds, !sounds.isEmpty else { return }
        var ids = Set(defaults.stringArray(forKey: deletedKey) ?? [])
        let id = Self.stableID(heard: sounds, meant: entry.word).uuidString
        if deleted { ids.insert(id) } else { ids.remove(id) }
        defaults.set(Array(ids), forKey: deletedKey)
    }

    func remove(_ entry: Entry) {
        markDeleted(entry, true)
        entries.removeAll { $0.id == entry.id }
        if let clip = entry.clip { try? FileManager.default.removeItem(at: folder.appendingPathComponent(clip)) }
        // The word leaves the spelling list unless another entry still uses it.
        if !entries.contains(where: { $0.word.caseInsensitiveCompare(entry.word) == .orderedSame }) { removeFromWordList(entry.word) }
        save()
        if entry.sounds != nil { onPronunciationsChanged(entries) }
    }

    /// Changes how an entry sounds and how it is written.
    func update(_ entry: Entry, word: String, sounds: String?) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let sounds = sounds?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard !word.isEmpty, let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let old = entries[index]
        markDeleted(old, true)
        entries[index].word = word
        entries[index].sounds = sounds
        markDeleted(entries[index], false)
        if old.word != word {
            if !entries.contains(where: { $0.word.caseInsensitiveCompare(old.word) == .orderedSame }) { removeFromWordList(old.word) }
            addToWordList(word)
        }
        save()
        onPronunciationsChanged(entries)
    }

    /// Pronunciations other devices saved (they travel as mix-ups marked "pronunciation"); entries already here are kept as they are.
    func importPronunciations(from mixUps: [MixUp]) {
        var changed = false
        for mixUp in mixUps where mixUp.meaning == "pronunciation" {
            guard !wasDeleted(heard: mixUp.heard, meant: mixUp.meant),
                  !entries.contains(where: { $0.word == mixUp.meant && ($0.sounds ?? "").caseInsensitiveCompare(mixUp.heard) == .orderedSame }) else { continue }
            var entry = Entry(word: mixUp.meant, sounds: mixUp.heard)
            entry.id = Self.stableID(heard: mixUp.heard, meant: mixUp.meant)
            entries.append(entry)
            addToWordList(mixUp.meant)
            changed = true
        }
        if changed { save() }
    }

    /// The same id on every Mac for the same pronunciation, so a sync can't make copies.
    nonisolated static func stableID(heard: String, meant: String) -> UUID {
        var bytes = Array(CryptoKit.SHA256.hash(data: Data("\(heard.lowercased())|\(meant)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension MyWords {
    /// Puts the written form wherever the transcript has a word as you say it ("amader" becomes "আমাদের"). Whole words only,
    /// any case; spaces and hyphens inside a multi-word sound may vary. Longer sounds go first.
    static func applyPronunciations(_ text: String, _ list: [(sounds: String, written: String)]) -> String {
        list.sorted { $0.sounds.count > $1.sounds.count }.reduce(text) { text, item in
            let parts = item.sounds.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !parts.isEmpty, !item.written.isEmpty else { return text }
            let pattern = "(?<![\\p{L}\\p{N}])" + parts.joined(separator: "[\\s\\-]+") + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
            return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                  withTemplate: NSRegularExpression.escapedTemplate(for: item.written))
        }
    }
}

/// The dictionary panel on the Preferences page: words you add by how they sound, each with how to write it. Edit or delete any.
struct PersonalDictionaryPanel: View {
    @ObservedObject var dictionary: PersonalDictionary
    @State private var newWord = ""
    @State private var newSounds = ""
    @State private var editing: UUID?
    @State private var editWord = ""
    @State private var editSounds = ""

    var body: some View {
        WhitePanel {
            HStack(alignment: .firstTextBaseline) {
                Text("Personal dictionary").font(.display(24))
                Text("words as you say them").font(.inter(12)).foregroundStyle(Palette.greyOnLight)
                Spacer()
            }
            Text("Add a word by how it sounds when you say it, and how it should be written. Whenever MicFlow hears it, it types your spelling. MicFlow also adds words it doesn't know as you talk (after you say one a second time). You can edit or delete any of them.")
                .font(.inter(12)).foregroundStyle(Palette.greyOnLight)
            if dictionary.entries.isEmpty {
                Text("No words yet.").font(.inter(13)).foregroundStyle(Palette.greyOnLight)
            }
            ForEach(dictionary.entries) { entry in
                if editing == entry.id { editRow(entry) } else { row(entry) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Add a word").font(.inter(13, .bold))
                HStack {
                    PillField(placeholder: "How it sounds (e.g. amader)", text: $newSounds, onDark: false, onSubmit: add)
                    Image(systemName: "arrow.right").foregroundStyle(Palette.greyOnLight)
                    PillField(placeholder: "Write it as (e.g. আমাদের)", text: $newWord, onDark: false, onSubmit: add)
                    PillButton(title: "Add", systemImage: "plus", style: .yellow, action: add)
                }
            }
        }
    }

    private func row(_ entry: PersonalDictionary.Entry) -> some View {
        HStack(spacing: 10) {
            if let sounds = entry.sounds, !sounds.isEmpty {
                Text(sounds).font(.inter(14, .semibold)).foregroundStyle(Palette.greyOnLight)
                Image(systemName: "arrow.right").font(.inter(11, .bold)).foregroundStyle(Palette.pink)
            }
            Text(entry.word).font(.inter(14, .bold))
            Spacer()
            if entry.clip != nil {
                Button { dictionary.play(entry) } label: {
                    Label("Play", systemImage: "play.circle.fill").font(.inter(12, .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.pink).help("Hear how you said it")
            }
            Button {
                editing = entry.id; editWord = entry.word; editSounds = entry.sounds ?? ""
            } label: {
                Image(systemName: "pencil.circle.fill").font(.inter(18)).foregroundStyle(Palette.lavender)
            }
            .buttonStyle(.plain).help("Edit \(entry.word)")
            Button { dictionary.remove(entry) } label: {
                Image(systemName: "minus.circle.fill").font(.inter(18)).foregroundStyle(Palette.orange)
            }
            .buttonStyle(.plain).help("Remove \(entry.word)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func editRow(_ entry: PersonalDictionary.Entry) -> some View {
        HStack(spacing: 8) {
            PillField(placeholder: "How it sounds", text: $editSounds, onDark: false, onSubmit: { save(entry) })
            Image(systemName: "arrow.right").foregroundStyle(Palette.greyOnLight)
            PillField(placeholder: "Write it as", text: $editWord, onDark: false, onSubmit: { save(entry) })
            PillButton(title: "Save", style: .yellow) { save(entry) }
            PillButton(title: "Cancel", style: .outline) { editing = nil }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Palette.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func save(_ entry: PersonalDictionary.Entry) {
        dictionary.update(entry, word: editWord, sounds: editSounds)
        editing = nil
    }

    private func add() {
        dictionary.add(newWord, sounds: newSounds)
        newWord = ""
        newSounds = ""
    }
}
