# MicFlow: User Flow Test Plan (paste into your testing / analysis tool)

## 0. Your role and the output wanted

You are a senior QA automation engineer and code reviewer. Test and analyse the MicFlow product described below. Run each flow where you can (build, run, automate, read logs). Where you cannot run something (real microphone, a physical phone, a second Mac), analyse the code paths listed and mark the result "code review only".

Produce ONE report with these sections:
1. Executive summary: top 10 problems by severity.
2. Results table, one row per test case: ID | Result (PASS / FAIL / BLOCKED / CODE-REVIEW-ONLY) | Severity (Blocker / Major / Minor / Polish) | What happened | Expected | File and line to change | Suggested fix.
3. Edge-case findings and race conditions.
4. Security and privacy findings.
5. Performance and battery findings.
6. UX and copy problems (confusing text, wrong labels, wrong destinations).
7. Missing features or improvements, ranked by user impact.
8. A short list of tests you could not run and what is needed to run them.

Do not change code unless asked. Do not print or share any secrets (API keys, tokens, pairing codes). Never open or read the folder `~/Library/Application Support/MicFlow/Secrets`.

---

## 1. Product overview

MicFlow is voice typing and capture tooling for people in Bangladesh who speak English, Bengali, or both mixed in one sentence.

- **Mac app** (Swift, SwiftUI/AppKit). Hold a key (default Right Control), speak, release, and the words are pasted in the focused app. Also: screenshots, screen recording, OCR, Figma zoom, mouse and keyboard tools, sound boost, universal clipboard, window layouts, personal dictionary, history sync.
- **Android app** (Kotlin, Jetpack Compose). Accessibility service shows a mic bubble next to text fields. Tap, speak, words appear in the field.
- **Website** (static HTML built by Python, Cloudflare Pages): `https://micflow.abdullahel.com`. The only official place to download the DMG and APK.
- **Backend**: Supabase (auth with Google, clipboard items, pairing, dictation history). Speech and clean-up use the user's own free API key provider (Gemini) API key.
- **Closed source**: users never see the source. Downloads come only from the website.

---

## 2. File locations (everything is under `/Users/abdullahel/Documents/MicFlow`)

### Mac app: `/Users/abdullahel/Documents/MicFlow/MicFlow-Admin`
Build: `./build.sh` (output `build/MicFlow.app`). Installed copy: `/Applications/MicFlow.app`. Bundle id `local.micboost.MicBoost`. Code is in `Sources/`:

| Area | File |
|---|---|
| App start, menu bar, single instance | `Sources/MicFlowApp.swift` |
| Home window, sidebar, theme, pill buttons | `Sources/HomeWindow.swift` |
| All Home pages (Voice, Capture, Sound, Mouse, Keyboard, Figma, Settings) | `Sources/HomePages.swift` |
| First-run API key flow, Google login | `Sources/KeyOnboarding.swift`, `Sources/AppControl.swift` |
| Voice typing core (hold/tap, listening, paste, clean-up) | `Sources/VoiceTyping.swift`, `Sources/VoiceTypingParts.swift` |
| Live speech-to-text over WebSocket | `Sources/GeminiLiveTranscriber.swift` |
| Clean-up prompt and screen context | `Sources/Polisher.swift`, `Sources/ScreenContext.swift` |
| Pasting and replacing text in the focused field | `Sources/PastedText.swift`, `Sources/PasteStatus.swift` |
| Voice pill and live preview box | `Sources/VoiceOverlay.swift` |
| Personal dictionary (auto-learn) | `Sources/PersonalDictionary.swift` |
| Secrets storage (encrypted files) | `Sources/VoiceTypingParts.swift` (`KeychainSecret`) |
| Login and session | `Sources/Backend.swift` |
| Universal clipboard (pairing, 6-char code, QR) | `Sources/UniversalClipboard.swift` |
| History sync | `Sources/HistorySync.swift` |
| Screenshots, recording, upload card, toasts | `Sources/Capture.swift`, `Sources/ScreenRecorder.swift`, `Sources/RecordingControls.swift` |
| Upload to Google Drive / image host | `Sources/DriveUploader.swift`, `Sources/ImageHost.swift` |
| Sound helper install (BlackHole) | `Sources/SoundHelperInstaller.swift` |
| Window layouts | `Sources/WindowLayout.swift` |
| Updates | `Sources/Updater.swift` |
| Figma zoom, tracking speed | `Sources/FigmaZoom.swift`, `Sources/TrackingSpeed.swift` |
| Permission prompts | `AccessibilityPrompt` in `Sources/HomeWindow.swift` |

Logs and data: `~/Library/Application Support/MicFlow/` (`last-segments.txt` holds the last dictation's raw speech segments; safe to read). System log subsystem: filter the Console app for "MicFlow".

### Android app: `/Users/abdullahel/Documents/MicFlow/MicFlow-Android`
Build: `./gradlew installDebug` (needs `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`). Debug build id: `com.micflow.android.dev`. Code: `app/src/main/java/com/micflow/android/`

| Area | File |
|---|---|
| Accessibility service, mic bubble, live preview, insert text | `MicFlowService.kt` |
| Home, settings, onboarding screens | `ui/HomeScreen.kt`, `ui/SettingsScreen.kt`, `ui/KeyOnboarding.kt`, `ui/Theme.kt` |
| Main activity | `MainActivity.kt` |
| Universal clipboard (send, receive, tile) | `UniversalClipboard.kt` |
| History sync | `HistorySync.kt` |
| Updates and notifications | `Online.kt`, `Notifications.kt` |
Phone logs: `adb logcat -d | grep -E "MicFlow"` (adb is at `/opt/homebrew/share/android-commandlinetools/platform-tools/adb`).

### Website: `/Users/abdullahel/Documents/MicFlow/MicFlow-Website`
Generator `build.py`; styles `site/style.css`; scripts `site/js/site.js` (animations) and `site/js/download.js` (download progress and install walkthrough); update feed `site/update.json`; downloads `site/downloads/`; publishing `release.py`. Deploys on push to `main`.

### Other
Existing automated checker: `/Users/abdullahel/Documents/MicFlow/phase-check.sh`.

---

## 3. Environments and test data

Use these combinations. Mark each case with the environment used.

| ID | Environment |
|---|---|
| E1 | Mac, fresh install (no preferences, no files in Application Support, no permissions granted) |
| E2 | Mac, existing install upgraded from an older version (old keychain items present) |
| E3 | Mac, second user account on the same Mac |
| E4 | Mac, no internet / Wi-Fi off mid-test |
| E5 | Android Pixel 7a (Android 14/15), fresh install |
| E6 | Android, accessibility service switched off, then on |
| E7 | Mac and Android signed in to the SAME Google account |
| E8 | Mac and Android signed in to DIFFERENT Google accounts |
| E9 | Mac with an external microphone, Bluetooth headset, and built-in mic |
| E10 | Browsers: Safari, Chrome, Firefox on desktop; Chrome on Android for the website |

Test data: a valid API key; an invalid key (random string); an expired/revoked key; Bengali sentence "আমাদের দেখা করা উচিত"; English sentence; mixed sentence "Please send me the file, আমি আজ আসতে পারব না"; a 10-second, 2-minute, and 10-minute dictation; text with numbers, URLs, emails; empty speech (silence).

Target apps for typing: Notes, TextEdit, Safari text fields, Chrome (Gmail, Google Docs, Slack web), Slack app, VS Code, Terminal, Figma, password fields, read-only fields. Android: Keep, WhatsApp, Telegram, Messenger, Facebook (comment box and @mention box), Instagram, Gmail, Chrome, Notes, Settings search.

---

## 4. Personas

- **P1 First-time user**: not technical, downloads from the website, follows the install guide.
- **P2 Returning user**: has used MicFlow before, wants to log in and get settings and history back.
- **P3 Power user**: uses clipboard sync, window layouts, dictionary, recording and annotations daily.
- **P4 Bilingual Bangladeshi user**: dictates Bengali and English constantly, in chat and email.
- **P5 Privacy-conscious user**: does not want data stored or sent anywhere unexpectedly.
- **P6 Hostile or careless user**: denies permissions, pastes wrong keys, goes offline, double-clicks everything, force-quits.

---

## 5. Test flows

For every flow: run the happy path, then every edge case, and note anything slow (>1 s without feedback), confusing, or inconsistent.

### FLOW A: Website and download (P1, E10)
Files: `MicFlow-Website/build.py`, `site/style.css`, `site/js/site.js`, `site/js/download.js`, `site/update.json`, `site/downloads/`

- A1 Open the home page on desktop and phone width. Check hero demo animation, each section, footer links, no horizontal scroll, no layout shift.
- A2 Visit every inner page and every link in the nav and footer; check for 404s and wrong copy.
- A3 Download page, Mac: click Download. Expect real progress bar, file saves, install walkthrough advances (Download, Open the file, Drag to Applications, Open first time, Permissions, API key, Hold and talk).
- A4 Download page, Android: same with `#android`.
- A5 Edge: user on iPhone or Windows (no matching download); `fetch` or `ReadableStream` unsupported; download fails midway; offline; click Download twice; switch OS tab during download; Back button; direct link to `#android`.
- A6 `update.json` correctness: version numbers, file names and sizes match files in `site/downloads/`; Cloudflare 25 MiB file limit versus the DMG and APK sizes.
- A7 Accessibility: keyboard navigation, focus rings, contrast of grey text on dark, `prefers-reduced-motion`, alt text, heading order.
- A8 SEO and performance: titles, meta descriptions, Open Graph, font loading, image sizes, Lighthouse score.
- A9 Confirm no page still says the project is open source or links to old public GitHub repos. Report every mention of "GitHub", "open source".

### FLOW B: Mac install and first run (P1, E1)
Files: `MicFlowApp.swift`, `HomeWindow.swift` (AccessibilityPrompt, sidebar), `KeyOnboarding.swift`

- B1 Open DMG, drag to Applications, open. Gatekeeper warning is expected (self-signed): check the instruction text matches what macOS really shows.
- B2 First launch: Home window opens on Voice typing. Check the API key box is first, "Create API key" reveals three steps, "Used MicFlow before? Log in with Google" is visible.
- B3 Permission prompts: Microphone, Accessibility, Input Monitoring, Screen Recording. Count how many prompts and password requests appear in total. Target: each shown once, in a sensible order, with clear explanation. Report any that repeat.
- B4 Edge: deny each permission; grant later in System Settings; revoke while the app runs; app moved out of /Applications (see `InstallLocation.offerMoveIfNeeded`); two copies running (see `SingleInstance.ensure`).
- B5 Quit and reopen: no password prompts, no repeated permission dialogs, window layout restored.
- B6 Upgrade (E2): old keychain items migrate once into `~/Library/Application Support/MicFlow/Secrets`; afterwards no keychain prompts. Check that a failed or denied migration is handled and does not lose the key.
- B7 Second user account (E3): independent settings, no cross-reading of secrets.

### FLOW C: API key setup (P1, P6)
Files: `KeyOnboarding.swift`, `VoiceTypingParts.swift`, `GeminiLiveTranscriber.swift`

- C1 Paste a valid key, expect validation then confetti and success state.
- C2 Edge: invalid key, key with spaces or newline, empty key, very long text, key for a different Google product, revoked key, rate-limited key (free-tier limit), offline while validating.
- C3 Replace the key later; remove the key; verify the file is deleted and the UI returns to the right state.
- C4 Check error messages never say "Gemini" or "Google" if the product hides provider names (`ProviderName.hide`): list any leaks.

### FLOW D: Sign-in, account, sync (P2, P3)
Files: `Backend.swift`, `AppControl.swift`, `SignInButton.swift` (GoogleSignInButton), `HistorySync.swift`, Android `ui/SettingsScreen.kt`, `HistorySync.kt`

- D1 Sign in with Google on Mac (system browser session). Cancel midway, close browser, deny consent, wrong account, network drop.
- D2 Signed-out state: banner shown, features that need login are gated and explain why. Signed-in state: profile picture position (known issue: profile picture bottom-left may not show).
- D3 Sign out: key is kept; history and clipboard stop; UI is consistent (known past bug: Android Account card contradicted itself).
- D4 Session expiry and token refresh while the app is running; sign in on a second device.
- D5 Settings and dictation history sync across Mac and Android: encrypted, filter by device, delete an item, large history, clock differences, conflict when both devices change settings offline.
- D6 Privacy: confirm history text is end-to-end encrypted and unreadable on the server; check what metadata is stored.

### FLOW E: Voice typing on Mac, hold to talk and tap to talk (P4, all)
Files: `VoiceTyping.swift`, `GeminiLiveTranscriber.swift`, `PastedText.swift`, `PasteStatus.swift`, `Polisher.swift`, `VoiceOverlay.swift`, `PersonalDictionary.swift`

- E-1 Hold Right Control, speak English, release: text pasted into TextEdit. Measure delay from release to text.
- E-2 Same with Bengali and mixed sentences. Known bugs to retest: (a) Bengali coming out as English letters (e.g. "amader dekha kora uchit"); (b) a sentence pasted two or more times. Read `~/Library/Application Support/MicFlow/last-segments.txt` after each run to compare what the server sent with what was pasted.
- E-3 Tap-to-talk mode: tap once to start, tap again to stop; tap during processing; very short taps.
- E-4 Live preview box on and off; pill position at bottom of screen (it must not cover other UI, including the "Further polishing…" pill); key name inside the pill; multi-monitor and different Spaces; full-screen apps.
- E-5 Clean-up (polish) on and off; "Further polishing… Press Esc"; press Esc during it; time limit 2 s; typing or clicking while it runs (it must keep the user's edits); a second dictation started while the first is polishing.
- E-6 Screen context setting (off by default): turn on, dictate a reply in Slack/Gmail/Messages, check wording uses names and terms from the screen; check password fields are never read; check large windows and slow apps do not delay the dictation; check nothing from the screen is pasted into the output.
- E-7 Personal dictionary: add words; auto-learn from edits after paste; remove; verify it does not corrupt text; sync across devices.
- E-8 "Your instructions" field: 2,000-character limit, effects on output, conflicts with strict limits.
- E-9 Edge: silence only; background noise; whispering; very loud; 10-minute dictation; interrupting with Esc; releasing the key instantly; switching apps while speaking; target app loses focus; password field; read-only field; empty clipboard restore; user clipboard content overwritten (verify behaviour and whether the clipboard is restored or intentionally kept).
- E-10 Network edge: offline at start, offline mid-sentence, slow network, server error, key quota exceeded. Error text must be understandable.
- E-11 Hotkey edge: Right Control while another app uses it; Figma and VS Code shortcuts; holding the key during sleep; key stuck; remapping the key; two modifiers at once.
- E-12 Microphone edge: no mic; unplug mic mid-recording; Bluetooth headset switching to low-quality mode; input gain boost up to 96x (clipping, noise).
- E-13 Compare pasted text against intended: punctuation, capitalisation, spacing between segments, Bengali punctuation (।), numbers, duplicated words.

### FLOW F: Android voice typing (P4, E5, E6)
Files: `MicFlowService.kt`, `ui/KeyOnboarding.kt`, `ui/HomeScreen.kt`

- F1 First run: install APK, allow unknown sources, accessibility service on, microphone, API key. Check each screen's wording and that the flow matches the Mac flow.
- F2 Mic bubble appears next to any editable field and hides otherwise; drag to move; size and opacity settings; tap to start and stop; auto-stop after silence.
- F3 Live preview in every app: normal fields (words appear while speaking), Google Keep (append-only preview, no flicker, text must stay after stopping), WhatsApp, Telegram, Messenger, Instagram, Facebook comment box. Facebook @mention box: no live preview, single paste at the end, text must go after the name, not inside it.
- F4 Known past bugs to recheck: Keep text disappearing; Keep crash "Attempting to apply an edit while another edit is being applied"; flicker; text pasted inside @mention; floating bubble at the top of the screen (must not appear any more).
- F5 Clean-up step on Android; fallback when polish times out (2.5 s); copy-to-clipboard fallback message when the field refuses text.
- F6 Edge: password fields (bubble must not show); multiple fields; rotating the phone; keyboard open/closed; split screen; switching apps mid-recording; incoming call; screen off; microphone used by another app; permission revoked; service killed by battery optimisation; Do Not Disturb.
- F7 Battery and performance: idle drain of the accessibility service; memory; CPU while recording.
- F8 Accessibility of MicFlow's own screens (TalkBack, font scale 200%).

### FLOW G: Universal clipboard (P3, E7, E8)
Files: Mac `UniversalClipboard.swift`; Android `UniversalClipboard.kt`, `MicFlowService.kt` (`sendClipboardSoon`), `ui/SettingsScreen.kt`

- G1 Pairing: 6-character code and QR on Mac; join on Android. Wrong code, expired code, code used twice, different accounts (E8, expect a clear "log in first / same account" message), phone signed out.
- G2 Mac to Android: copy text, copy an image, copy a large image (compression and size limit), copy a file, copy rapidly many times. Android must NOT show a "Copied from…" toast any more.
- G3 Android to Mac (known to be unreliable before the latest fix): copy text in Chrome, Messages, WhatsApp, Keep, Settings; copy via long-press menu, via an app's own Copy button, via keyboard clipboard; copy while the screen is locked; copy while MicFlow is in the background. Record how long until it appears on the Mac, and check the phone log: `adb logcat -d | grep -E "MicFlow|Clipboard"`.
- G4 Loops: copying on one device must not bounce back to the other; MicFlow's own dictated text must not be sent as clipboard.
- G5 Security: items encrypted with the shared key; 5-minute cleanup of old rows; no clipboard content stored on the server in plain text; sensitive clips (passwords from password managers) are not sent (check `IS_SENSITIVE` handling).
- G6 Quick Settings tile "send clipboard" works.
- G7 The 1-pixel focus window used to read the clipboard: check it does not steal focus in a harmful way, does not drop text selection unexpectedly, does not flash, and is removed in every case.
- G8 Edge: offline, reconnect, websocket drop, token expiry, two Macs and one phone, battery saver.

### FLOW H: Capture: screenshots (P3)
Files: `Capture.swift`, `HomePages.swift` (CapturePage), `ImageHost.swift`

- H1 Screenshot area, window, full screen, delayed (countdown), OCR text capture; shortcuts; change a shortcut; conflict with system shortcuts.
- H2 Preview on and off (default off), copy to clipboard, save location, quick-access panel actions (annotate, copy, upload, reveal).
- H3 Upload to image host: needs the user's image-host key; link copied; toast "Upload complete. The link is copied to your clipboard."; wrong key; offline.
- H4 Edge: multiple monitors with different scales, Retina, screen with full-screen app, protected content (black frames), Screen Recording permission missing or revoked.

### FLOW I: Capture: screen recording, controls, annotations, audio, upload (P3)
Files: `ScreenRecorder.swift`, `RecordingControls.swift`, `Capture.swift`, `DriveUploader.swift`, `SoundHelperInstaller.swift`

- I1 Start a recording of an area and of a full screen. The control panel (timer, Pause/Resume, Stop, Draw) must NOT appear in the video; drawings (pen, arrow, rectangle, colours, undo, clear) MUST appear in the video. Verify by playing the file.
- I2 Pause and resume several times: video length excludes paused time, no frozen frame, no audio drift, no crash on the writer (timestamps).
- I3 Audio: microphone only, system sound only, both, neither. Check the "Record the sound on this Mac" setting (default off); check levels, sync, clipping. Check whether the BlackHole helper is needed and installed on demand with a single restart.
- I4 Drawing mode off: clicks pass through to apps below; drawings remain. Draw across multiple monitors (overlay covers the recorded screen only).
- I5 Stop from the panel, from the menu bar item, from the shortcut, from the quit menu (must save first), when the system stops it, when Screen Recording permission is removed.
- I6 Upload video: "Uploading to Google Drive" (not GitHub), progress, "Link copied", toast, link opens; first upload asks for Drive permission (`drive.file` scope); Drive shows "video is still being processed" for a while (known, cannot be bypassed): check the UI explains this to the user.
- I7 Edge: very long recordings (30+ min) and memory; low disk space; sleep during recording; display change during recording; two quick starts; stop immediately after start (no frames).

### FLOW J: Window layouts (P3)
Files: `WindowLayout.swift`
- J1 Save a layout, restore after reboot or power cut automatically; apps that are not running; windows on a disconnected monitor; Spaces; apps that refuse resize; minimised windows.

### FLOW K: Sound, mouse, keyboard, Figma tools (P3)
Files: `HomePages.swift` (SoundPage, MousePage, KeyboardPage, FigmaPage), `TrackingSpeed.swift`, `FigmaZoom.swift`, `SoundHelperInstaller.swift`
- K1 Sound boost up to 96x: warnings for loudness; speaker/headphones switching; crackling.
- K2 Tracking speed maximum (13.5) with a red warning; reset.
- K3 Keyboard shortcut editing, control vs command note; removing remappings; conflicts.
- K4 Figma zoom scroll only applies on the canvas (not in menus/panels); other apps unaffected.

### FLOW L: Updates and enforcement (P1, P3)
Files: `Updater.swift`, `Online.kt`, `Notifications.kt`, website `update.json`, `release.py`
- L1 New version available: notification, one-click install on Mac, relaunch, preference and permission retention (signature must stay the same so macOS does not re-ask).
- L2 Edge: corrupt download, offline, version older than minimum (blocked screen, hidden from normal users), website down, `update.json` malformed.
- L3 Android update flow and notification.

### FLOW M: Look and feel consistency (P1)
- M1 Mac vs Android vs website: same palette (graphite and teal), Inter body font, serif headlines, one theme, no light/dark switch. List mismatches.
- M2 Voice pill vs website pill: same look.
- M3 Copy review: every label, error, and toast for clarity, tone, spelling, and Bengali/English consistency.

### FLOW N: Security and privacy review (P5)
- N1 Where each secret is stored (`~/Library/Application Support/MicFlow/Secrets`, AES-GCM locked to the Mac's hardware ID); file permissions; what is lost if the file is copied to another Mac; what a malware with the user's rights could read.
- N2 What leaves the machine: audio and text to Google (user's key), screen text if the context setting is on, clipboard (encrypted), history (encrypted), update checks. List every network host contacted.
- N3 Logs: confirm no API keys, tokens, pairing codes, or dictated text are written to logs or `last-segments.txt` beyond what is documented (note `last-segments.txt` DOES contain raw dictated text: judge whether it should be kept, limited, or encrypted).
- N4 Supabase row-level security: a user cannot read another user's rows; anon key exposure is expected; confirm no service key in the app or website.
- N5 Hardened runtime, signing, notarisation status; the local self-signed certificate means Gatekeeper warns users: assess the impact and options.
- N6 Android: accessibility service scope (what events it reads), clipboard handling, sensitive flags, exported components in the manifest, backup settings.

### FLOW O: Resilience and soak
- O1 Run the Mac app for 8 hours with dictations every few minutes: memory, CPU, file handle count, WebSocket leaks.
- O2 Kill the app during dictation, during upload, during recording; reopen: no corrupted state, partial files cleaned or recoverable.
- O3 Sleep/wake, lock screen, fast user switching, network change (Wi-Fi to hotspot).

---

## 6. Known open issues to confirm or close

1. Bengali sometimes returned as English letters; clean-up now asks to convert it, speech model itself may still produce it.
2. Repeated sentence in live transcription: de-duplication added; verify with `last-segments.txt`.
3. Android Keep live preview (append-only) not verified in the field.
4. Android to Mac clipboard: new focus-window method untested.
5. Mac Right Control "does nothing" earlier: re-verify after the signing change and a single Accessibility grant.
6. Keychain prompts: should be zero for new users; old Macs have one migration round (image-host key still in keychain until used).
7. Profile picture bottom-left on Mac: cause unknown.
8. Android first-run flow not yet restructured to match Mac.
9. Android personal dictionary has no audio-based learning yet.
10. Site still serves old builds (Mac 2.9 and Android 2.1) until `release.py` is run.
11. Source repositories to be made private only after new versions ship.
12. Google OAuth branding re-verification pending; Drive scope is `drive.file`.
13. The admin app may still publish About/posts to an old GitHub folder.
14. Signing certificate exists only on one Mac: builds from another machine will have a different signature and re-trigger permission prompts.

---

## 7. How to report each defect

For every FAIL or improvement, give: Test ID; environment; exact steps; expected vs actual; severity; user impact (who and how often); file path and the function or line to change; a concrete fix suggestion in plain words; whether it needs a design decision from the product owner.
