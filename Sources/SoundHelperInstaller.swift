import AppKit
import CryptoKit
import SwiftUI
import Foundation

/// The two small sound helpers (BlackHole 2ch and 16ch) that mic and speaker boost need. They are
/// not in the disk image any more: MicFlow downloads both together when the person turns a boost
/// on, checks them against known fingerprints, opens each installer, and asks for one restart at
/// the end instead of two.
@MainActor
final class SoundHelperInstaller: ObservableObject {
    enum Stage: Equatable {
        case idle, downloading, installFirst, installSecond, restart
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle

    private static let base = "https://micflow.abdullahel.com/downloads/"
    /// The installers' SHA-256, so only the genuine files are ever opened.
    private static let files: [(name: String, sha256: String)] = [
        ("BlackHole2ch.pkg", "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf"),
        ("BlackHole16ch.pkg", "57254e2f76cd40db7f3f715238b1a2cb2bd08819d38abf4087f2944f71a3641a"),
    ]
    private var downloaded: [URL] = []

    /// Downloads both helpers, then opens the first installer.
    func start() {
        guard stage == .idle || { if case .failed = stage { return true } else { return false } }() else { return }
        stage = .downloading
        Task {
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MicFlow Sound Helpers", isDirectory: true)
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var urls: [URL] = []
                for file in Self.files {
                    let (temporary, response) = try await URLSession.shared.download(from: URL(string: Self.base + file.name)!)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
                    let data = try Data(contentsOf: temporary)
                    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw Failure.fingerprint }
                    let target = folder.appendingPathComponent(file.name)
                    try data.write(to: target)
                    urls.append(target)
                }
                downloaded = urls
                stage = .installFirst
                NSWorkspace.shared.open(urls[0])
            } catch {
                stage = .failed((error as? Failure)?.message ?? "MicFlow couldn't download the sound helpers. Check your internet connection and try again.")
            }
        }
    }

    /// The first installer is done (leave its Restart button alone): open the second.
    func firstFinished() {
        guard downloaded.count == 2 else { return }
        stage = .installSecond
        NSWorkspace.shared.open(downloaded[1])
    }

    func secondFinished() { stage = .restart }

    /// Restarts the Mac (macOS asks once to allow it).
    func restartMac() {
        NSAppleScript(source: "tell application \"System Events\" to restart")?.executeAndReturnError(nil)
    }

    private enum Failure: Error {
        case download, fingerprint
        var message: String {
            switch self {
            case .download: return "MicFlow couldn't download the sound helpers. Check your internet connection and try again."
            case .fingerprint: return "The downloaded sound helper didn't match what MicFlow expected, so it was not opened. Try again later."
            }
        }
    }
}

/// Shown at the top of Sound while the helpers are missing: the whole install in one place.
struct SoundHelperCard: View {
    @ObservedObject var installer: SoundHelperInstaller
    let theme: HomeTheme

    var body: some View {
        FeatureCard(theme: theme, systemImage: "arrow.down.circle.fill", title: "Two sound helpers needed",
                    subtitle: "For the microphone and speaker boost") {
            switch installer.stage {
            case .idle:
                Note(text: "To boost your microphone or speakers, MicFlow needs two small free helpers. MicFlow downloads both together; you install each, then restart your Mac once.")
                PillButton(title: "Download and install", systemImage: "arrow.down.to.line", style: .cream, action: installer.start)
            case .downloading:
                Note(text: "Downloading both helpers…")
            case .installFirst:
                Note(text: "Step 1 of 2: finish the installer that just opened (Continue, Agree, Install, your Mac password). When it asks to restart, don't: just close it.")
                PillButton(title: "Done, open the second one", systemImage: "arrow.right", style: .cream, action: installer.firstFinished)
            case .installSecond:
                Note(text: "Step 2 of 2: finish this installer the same way. This time you can restart when it asks, or use the button below.")
                PillButton(title: "Both installed", systemImage: "checkmark", style: .cream, action: installer.secondFinished)
            case .restart:
                Note(text: "One restart and the boost features are ready.")
                PillButton(title: "Restart my Mac", systemImage: "restart", style: .orange, action: installer.restartMac)
            case .failed(let message):
                Note(text: message, isError: true)
                PillButton(title: "Try again", systemImage: "arrow.clockwise", style: .cream, action: installer.start)
            }
        }
    }
}
