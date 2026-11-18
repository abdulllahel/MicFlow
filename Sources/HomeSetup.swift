import AppKit
import SwiftUI

/// Whether voice typing still needs its model's key (Model 1 without one). Home then shows the two
/// ways to set it up instead of the dashboard, and every other page shows `VoiceSetupBanner`.
extension VoiceTypingModel {
    var needsKeySetup: Bool {
        #if ADMIN
        // Admin QA: MICFLOW_PREVIEW_NOKEY=1 shows the no-key screens without removing the saved key.
        if ProcessInfo.processInfo.environment["MICFLOW_PREVIEW_NOKEY"] != nil { return engine == .geminiLive }
        #endif
        return engine == .geminiLive && (!hasKey || keyRefused)
    }

    /// The saved key works no more (its account's free plan is off).
    var keyRefused: Bool {
        #if ADMIN
        if ProcessInfo.processInfo.environment["MICFLOW_PREVIEW_KEYOFF"] != nil { return true }
        #endif
        return keyFreePlanOff
    }
}

extension Account {
    /// The Voice typing tab is always there: signing in with Google is optional now.
    var showsVoiceTab: Bool { true }

    /// Signed in with Google, which voice typing (both models) needs.
    var signedInForVoice: Bool {
        #if ADMIN
        // Admin QA: MICFLOW_PREVIEW_SIGNEDOUT=1 shows the signed-out Home without signing out.
        if ProcessInfo.processInfo.environment["MICFLOW_PREVIEW_SIGNEDOUT"] != nil { return false }
        #endif
        return isSignedIn
    }
}

/// Whether Home shows the setup instead of the dashboard: not signed in yet, or Model 1 without a
/// working key.
@MainActor
func voiceNeedsSetup(_ voice: VoiceTypingModel, _ account: Account) -> Bool {
    voice.needsKeySetup
}

/// On every page but Home until voice typing is ready: one line and a button back to Home.
struct VoiceSetupBanner: View {
    @ObservedObject var voice: VoiceTypingModel
    @ObservedObject var account: Account
    let openHome: () -> Void

    var body: some View {
        if voiceNeedsSetup(voice, account) {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.inter(16, .bold)).foregroundStyle(Palette.white)
                    .frame(width: 38, height: 38).background(Palette.pink, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add your API key to use voice typing").font(.inter(15, .bold))
                    Text(voice.keyRefused ? "Your key stopped working. Add a new one on Home."
                         : "It's free and takes about a minute. Home shows the steps.")
                        .font(.inter(12)).foregroundStyle(Palette.ink.opacity(0.7))
                }
                Spacer()
                PillButton(title: "Add key", systemImage: "arrow.right", style: .ink, action: openHome)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.pink, lineWidth: 2))
        }
    }
}
