import AppKit
import SwiftUI

/// What voice typing shows on screen: the one floating pill (see FloatingPill.swift). At rest it is a tiny capsule; pointing at it
/// shows Start dictation; while you talk the same window shows the waveform and your words; offline, Retry and other messages
/// appear in it too. There is no second indicator.
@MainActor
final class VoiceOverlay {
    enum Content: Equatable {
        /// The text heard so far; empty until the first words come back.
        case listening(String)
        /// After the key is let go, until the text is typed. The words stay up.
        case transcribing
        case failed(String)
        /// The connection is down: trying again for a moment.
        case reconnecting(String)
        /// Couldn't type it; the sound is saved and Retry is offered.
        case retry(String)
    }

    /// The microphone's loudness right now (RMS), for the waveform and the glow.
    var level: () -> Float = { 0 }
    /// The name of the voice key, shown on the key in the pill.
    var keyName: () -> String = { "" }
    var floatingActions = FloatingPillActions()

    private var pill: FloatingPill?
    private var allowed = false
    private var showAtRest = true

    /// `enabled`: voice typing is on, so there is a pill at all. `showAtRest`: the "Show the floating pill" switch; when it is off
    /// the same pill still appears while you dictate, then goes away.
    func configure(enabled: Bool, showAtRest: Bool) {
        allowed = enabled
        self.showAtRest = showAtRest
        guard enabled else {
            pill?.dismiss()
            pill = nil
            return
        }
        let pill = ensurePill()
        pill.setRestVisible(showAtRest)
    }

    private func ensurePill() -> FloatingPill {
        if let pill { return pill }
        let pill = FloatingPill()
        pill.level = { [weak self] in self?.level() ?? 0 }
        pill.keyName = { [weak self] in self?.keyName() ?? "" }
        pill.state.onStart = { [weak self] in self?.floatingActions.start() }
        pill.state.onStop = { [weak self] in self?.floatingActions.stop() }
        pill.state.onRetry = { [weak self] in self?.floatingActions.retry() }
        pill.state.onDismiss = { [weak self] in self?.floatingActions.dismiss() }
        pill.setRestVisible(showAtRest)
        self.pill = pill
        return pill
    }

    func resetFloatingPosition() { pill?.resetPosition() }
    /// The connection dropped while you were talking (or came back).
    func setConnectionLost(_ lost: Bool) { pill?.state.connectionLost = lost }
    /// A sound is saved, waiting for Retry.
    func setPending(_ pending: Bool) { pill?.state.hasPending = pending }
    /// Whether the pill shows a Stop button while listening.
    func setStopVisible(_ visible: Bool) { pill?.state.showStop = visible }

    func show(_ content: Content) {
        guard allowed else { return }
        ensurePill().show(content)
    }

    func hide() {
        pill?.idle()
    }
}

struct FloatingPillActions {
    var start: () -> Void = {}
    var stop: () -> Void = {}
    var retry: () -> Void = {}
    var dismiss: () -> Void = {}
}
