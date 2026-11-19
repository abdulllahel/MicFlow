import AppKit
import SwiftUI

/// The banner at the top of Home when a new version is out. Its words come from the CMS; versions
/// older than the CMS's minimum get the stronger "out of date" words.
/// Shown when settings from another of your devices were brought in: a restart makes MicFlow use them.
struct SettingsRestartBanner: View {
    @ObservedObject var model: BoostModel

    var body: some View {
        if model.settingsRestartNeeded {
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.inter(18, .bold))
                    .foregroundStyle(Palette.pink)
                    .frame(width: 40, height: 40)
                    .background(Palette.cream, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings from your other device arrived").font(.inter(15, .bold))
                    Text("Restart MicFlow to use them. It takes a second.")
                        .font(.inter(12)).foregroundStyle(Palette.ink.opacity(0.7))
                }
                Spacer()
                PillButton(title: "Restart MicFlow", systemImage: "arrow.clockwise") { model.restartToApplySettings() }
            }
            .padding(16)
            .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 22))
            .foregroundStyle(Palette.ink)
        }
    }
}

/// The optional sign-in: a slim banner on every page until the person signs in with Google.
struct LoginBanner: View {
    @ObservedObject var account: Account

    var body: some View {
        if account.isConfigured && !account.isSignedIn {
            HStack(spacing: 12) {
                Image(systemName: "icloud.and.arrow.up.fill").font(.inter(16, .bold)).foregroundStyle(Palette.pink)
                Text("Log in with Google to keep all your devices in sync.").font(.inter(14, .semibold))
                Spacer()
                GoogleSignInButton(title: "Log in with Google", size: .regular, isWorking: account.isWorking) { account.signIn() }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hair))
            .foregroundStyle(Palette.white)
        }
    }
}

struct UpdateBanner: View {
    @ObservedObject var updater: Updater
    @ObservedObject var store: SiteContentStore

    var body: some View {
        if case .available(let version, _) = updater.state {
            let notice = store.content.update ?? .standard
            let outdated = notice.minimumVersion.map { Updater.isNewer($0, than: updater.currentVersion) } ?? false
            HStack(spacing: 14) {
                Image(systemName: outdated ? "exclamationmark.triangle.fill" : "sparkles")
                    .font(.inter(18, .bold))
                    .foregroundStyle(outdated ? Palette.white : Palette.pink)
                    .frame(width: 40, height: 40)
                    .background(outdated ? Palette.orange : Palette.cream, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(outdated ? notice.outdatedTitle ?? notice.title : notice.title)
                        .font(.inter(15, .bold))
                    Text((outdated ? notice.outdatedSubtitle ?? notice.subtitle : notice.subtitle) + "  (MicFlow \(version))")
                        .font(.inter(12))
                        .foregroundStyle((outdated ? Palette.ink : Palette.white).opacity(0.7))
                        .lineLimit(2)
                    if let problem = updater.lastError {
                        HStack(spacing: 6) {
                            Text(problem).font(.inter(11, .semibold)).foregroundStyle(Palette.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Link("Download", destination: URL(string: "https://micflow.abdullahel.com/download.html")!)
                                .font(.inter(11, .bold))
                        }
                    }
                }
                Spacer()
                PillButton(title: "Update now", systemImage: "arrow.down.circle", style: outdated ? .ink : .cream, action: updater.install)
            }
            .foregroundStyle(outdated ? Palette.ink : Palette.white)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(outdated ? Palette.yellow : Palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(outdated ? .clear : Palette.hair))
        } else if case .installing(let step) = updater.state {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(step).font(.inter(13, .semibold))
                Spacer()
            }
            .foregroundStyle(Palette.white)
            .padding(14)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hair))
        }
    }
}

/// Covers the whole window while your blocking pop-up is on. It can't be closed; it goes away by
/// itself once its condition is met (or you turn it off in the CMS).
struct BlockerView: View {
    let blocker: SiteContent.Blocker
    @ObservedObject var updater: Updater
    var signIn: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "hand.raised.fill")
                    .font(.inter(22, .bold)).foregroundStyle(Palette.white)
                    .frame(width: 48, height: 48).background(Palette.orange, in: Circle())
                Text(blocker.title).font(.display(30))
                if !blocker.message.isEmpty {
                    Text(blocker.message).font(.inter(14)).fixedSize(horizontal: false, vertical: true)
                }
                Text("MicFlow's shortcuts and features are paused until then.")
                    .font(.inter(12)).foregroundStyle(Palette.greyOnLight)
                HStack(spacing: 8) {
                    switch blocker.condition {
                    case .update:
                        if case .installing(let step) = updater.state {
                            ProgressView().controlSize(.small)
                            Text(step).font(.inter(13))
                        } else {
                            PillButton(title: "Update now", systemImage: "arrow.down.circle", style: .ink) {
                                if case .available = updater.state { updater.install() } else { updater.check() }
                            }
                        }
                    case .signIn:
                        if let signIn { PillButton(title: "Sign in with Google", systemImage: "person.crop.circle", style: .ink, action: signIn) }
                    case .always:
                        EmptyView()
                    }
                    if let title = blocker.buttonTitle, !title.isEmpty, let link = blocker.buttonLink.flatMap(URL.init(string:)) {
                        PillButton(title: title, systemImage: "arrow.up.right", style: .orange) { NSWorkspace.shared.open(link) }
                    }
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(28)
            .frame(width: 460, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(radius: 30)
        }
    }
}

/// On Home, while voice typing can't work yet: what's missing, with the button that fixes it.
struct SetupBanner: View {
    @ObservedObject var voice: VoiceTypingModel
    let openVoice: () -> Void

    var body: some View {
        if voice.enabled, voice.needsAccessibility {
            banner("Allow MicFlow in Accessibility",
                   "Without it, MicFlow can't hear your voice key or type for you.",
                   button: "Open Accessibility Settings", action: voice.openAccessibilitySettings)
        }
    }

    private func banner(_ title: String, _ detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.inter(18, .bold)).foregroundStyle(Palette.white)
                .frame(width: 40, height: 40).background(Palette.orange, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.inter(15, .bold))
                Text(detail).font(.inter(12)).foregroundStyle(Palette.ink.opacity(0.7))
            }
            Spacer()
            PillButton(title: button, systemImage: "arrow.right", style: .ink, action: action)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
