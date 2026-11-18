import AppKit
import SwiftUI

/// Google's own light "Sign in with Google" button (from Google's branding guidelines): white,
/// a thin grey outline, the four-colour G and dark text, so people recognise it at once.
struct GoogleSignInButton: View {
    enum Size { case regular, large }
    var title = "Sign in with Google"
    var size = Size.large
    var isWorking = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: size == .large ? 14 : 10) {
                if isWorking {
                    Spinner().frame(width: size == .large ? 26 : 18, height: size == .large ? 26 : 18)
                } else if let logo = Bundle.main.url(forResource: "GoogleG", withExtension: "svg").flatMap(NSImage.init(contentsOf:)) {
                    Image(nsImage: logo).resizable().frame(width: size == .large ? 26 : 18, height: size == .large ? 26 : 18)
                }
                Text(isWorking ? "Waiting for Google…" : title)
                    .font(.inter(size == .large ? 19 : 14, .semibold))
                    .foregroundStyle(Color(hex: 0x1F1F1F))
            }
            .padding(.horizontal, size == .large ? 28 : 18)
            .frame(height: size == .large ? 60 : 40)
            .background(Color.white, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(hex: 0x747775), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }
}

/// A dark, clearly visible loading ring (the system one is too faint on cream).
struct Spinner: View {
    @State private var turning = false
    var body: some View {
        Circle().trim(from: 0, to: 0.72)
            .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}
