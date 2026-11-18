import AppKit
import SwiftUI

/// The first thing a new person sees on Voice typing: three steps with pictures (scroll down), a big
/// button to the API key provider to make their own API key, and a field to paste it. The key is checked
/// right away; a wrong key gets the exact reason and what to do about it.
struct KeyOnboarding: View {
    @ObservedObject var voice: VoiceTypingModel
    @ObservedObject var account: Account
    let theme: HomeTheme
    @State private var key = ""
    @State private var checking = false
    @State private var problem: String?
    @State private var celebrate = false
    /// The three pictures appear only after the person clicks Create API key.
    @State private var showGuide = false

    private static let studioURL = URL(string: "https://aistudio.google.com/apikey")!

    private let steps: [(title: String, text: String, picture: String)] = [
        ("Open the key provider", "Click the big button below. Sign in with your Google account if it asks.", "KeyGuide-1"),
        ("Create an API key", "Click “Create API key”, pick any project (or let Google make one), then confirm.", "KeyGuide-2"),
        ("Copy it and paste it here", "Click the copy icon next to your new key, come back to MicFlow and paste it in the box.", "KeyGuide-3"),
    ]

    var body: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    VStack(spacing: 12) {
                        PageSticker(systemImage: "waveform").padding(.bottom, 2)
                        Text("Add your API key to start voice typing").font(.display(36)).multilineTextAlignment(.center)
                        Text("It takes about a minute and it's free. Click Create API key to see the three steps.")
                            .font(.inter(15, .medium)).foregroundStyle(Palette.ink.opacity(0.75))
                    }
                    .foregroundStyle(Palette.heroInk)
                    .frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, 24)
                    .background(Palette.hero, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

                    // The main action: a big box for the key.
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Paste your API key").font(.inter(17, .heavy))
                        HStack(spacing: 10) {
                            SecureField("Paste your API key here", text: $key)
                                .textFieldStyle(.plain).font(.inter(18, .semibold))
                                .padding(.horizontal, 18).padding(.vertical, 16)
                                .background(Color(hex: 0xF2F2F0), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .onSubmit(check)
                            PillButton(title: checking ? "Checking…" : "Save key", systemImage: "key.fill", style: .yellow, action: check)
                        }
                        if let problem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.inter(13, .semibold)).foregroundStyle(Palette.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Your key stays on this Mac. If you log in with Google, a locked copy also stays in your account, so your other devices can use it.")
                            .font(.inter(12)).foregroundStyle(Palette.greyOnLight)
                    }
                    .padding(22)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.hair))
                    .foregroundStyle(Palette.panelText)

                    Button {
                        NSWorkspace.shared.open(Self.studioURL)
                        withAnimation { showGuide = true }
                    } label: {
                        Label("Create API key", systemImage: "arrow.up.right.square")
                            .font(.inter(18, .heavy)).foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                            .background(Palette.orange, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    // The three pictures show up only after Create API key was clicked.
                    if showGuide {
                        ForEach(steps.indices, id: \.self) { index in stepCard(index) }
                    }

                    // Someone who used MicFlow before: their account may already hold the key.
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Used MicFlow before?").font(.inter(14, .bold))
                            Text("Log in with Google and your key and settings come back.").font(.inter(12)).foregroundStyle(Palette.ink.opacity(0.7))
                        }
                        Spacer()
                        GoogleSignInButton(title: "Log in with Google", size: .large, isWorking: account.isWorking) { account.signIn() }
                    }
                    .padding(18)
                    .background(Palette.cream, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .foregroundStyle(Palette.ink)
                }
                .padding(.bottom, 20)
            }
            if celebrate { Confetti().allowsHitTesting(false).transition(.opacity) }
        }
    }

    private func stepCard(_ index: Int) -> some View {
        let step = steps[index]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(index + 1)").font(.inter(14, .heavy)).foregroundStyle(Palette.ink)
                    .frame(width: 30, height: 30).background(Palette.cream, in: Circle())
                Text(step.title).font(.inter(17, .bold))
            }
            Text(step.text).font(.inter(14)).foregroundStyle(Palette.ink.opacity(0.75))
            if let image = Bundle.main.image(forResource: step.picture) {
                Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.ink.opacity(0.08)))
            } else if index == 2 {
                CopyKeyIllustration()
            }
        }
        .foregroundStyle(Palette.panelText)
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.hair))
    }

    private func check() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !checking else { return }
        checking = true; problem = nil
        Task {
            let result = await voice.saveKeyChecked(trimmed)
            checking = false
            if let result { problem = result; return }
            key = ""
            withAnimation { celebrate = true }
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            withAnimation { celebrate = false }
        }
    }
}

/// A short burst of confetti.
struct Confetti: View {
    private struct Piece: Identifiable { let id = UUID(); let x: CGFloat; let delay: Double; let drift: CGFloat; let color: Color; let size: CGFloat }
    @State private var fall = false
    private let pieces: [Piece] = (0..<70).map { _ in
        Piece(x: .random(in: 0...1), delay: .random(in: 0...0.6), drift: .random(in: -60...60),
              color: [Palette.pink, Palette.yellow, Palette.orange, Palette.lavender, Palette.cream].randomElement()!, size: .random(in: 7...13))
    }

    var body: some View {
        GeometryReader { geometry in
            ForEach(pieces) { piece in
                RoundedRectangle(cornerRadius: 2).fill(piece.color).frame(width: piece.size, height: piece.size * 0.6)
                    .rotationEffect(.degrees(fall ? 540 : 0))
                    .position(x: piece.x * geometry.size.width + (fall ? piece.drift : 0), y: fall ? geometry.size.height + 40 : -20)
                    .animation(.easeIn(duration: 2.4).delay(piece.delay), value: fall)
            }
        }
        .onAppear { fall = true }
    }
}

/// Step 3's picture, drawn here so no real key is ever shown: a key row with its copy button.
private struct CopyKeyIllustration: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill").foregroundStyle(Palette.cream)
            Text("AIzaSy•••••••••••••••••••••••••").font(.system(size: 14, design: .monospaced)).foregroundStyle(Palette.white)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc.fill")
                Text("Copy")
            }
            .font(.inter(13, .bold)).foregroundStyle(Palette.ink)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Palette.yellow, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.pink, lineWidth: 2).padding(-4))
        }
        .padding(18)
        .background(Color(hex: 0x232323), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
