<p align="center">
  <img src="https://raw.githubusercontent.com/bedriyan/speaky/main/app-icon.png" width="128" height="128" alt="Speaky Icon">
</p>

<h1 align="center">Speaky</h1>

<p align="center">
  <strong>Voice-to-text for macOS, powered by on-device AI</strong><br>
  Press a hotkey, speak, and the transcription is pasted at your cursor.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B-black?style=flat-square" alt="macOS 15+">
  <img src="https://img.shields.io/badge/swift-6.0-F5A622?style=flat-square" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License">
</p>

<p align="center">
  <a href="https://github.com/bedriyan/speaky/releases/latest"><strong>Download Latest Release</strong></a>
</p>

---

## Download

| Build | Architecture | Default Engine |
|-------|-------------|----------------|
| [**Speaky-Apple-Silicon.dmg**](https://github.com/bedriyan/speaky/releases/latest/download/Speaky-2.0.4-Apple-Silicon.dmg) | Apple Silicon (M1/M2/M3/M4) | Parakeet V3 |
| [**Speaky-Intel.dmg**](https://github.com/bedriyan/speaky/releases/latest/download/Speaky-2.0.4-Intel.dmg) | Intel (x86_64) | Whisper Medium Q5 |

> **Release identity note:** The v2.0.4 artifacts predate the stable self-signed release process documented in this repository. The maintainer should identify the first release produced with the new process in its release notes.

### Installation

1. Download the DMG for your Mac.
2. Open the DMG and drag **Speaky** to the **Applications** folder.
3. Open Speaky from Applications.
4. If macOS blocks the first launch, open **System Settings → Privacy & Security**, select **Open Anyway**, and confirm.
5. Grant microphone and Accessibility access when requested.

> **Why is approval needed?** Speaky releases are not notarized by Apple. Only approve an app downloaded from the official GitHub Release.

See [Install Speaky on macOS](docs/end-user-installation.md) for architecture selection, checksum verification, permissions, upgrades, and troubleshooting.

### Accessibility permissions across updates

Beginning with the first release produced by the documented free signing process, official Speaky releases should use the same stable identity so macOS recognizes updates as the same Accessibility client. Contributor builds use a separate **Speaky Debug** identity and separate mutable data.

If an older ad-hoc build created duplicate Speaky entries in System Settings, follow the [one-time upgrade cleanup](docs/end-user-installation.md#upgrading-from-an-older-ad-hoc-release).

## Features

- **Customizable Hotkey** — Set any keyboard shortcut you want to start/stop recording from anywhere
- **Push-to-Talk & Hands-Free** — Hold to record, or tap to toggle
- **Local Transcription** — The app ships with default models (Parakeet V3 for Apple Silicon, Whisper Medium Q5 for Intel), but you can download any model from the built-in list or import your own custom Whisper model
- **Cloud Transcription** — Optionally use Groq Whisper API for fast cloud-based transcription with your own API key
- **Auto-Paste** — Transcribed text is pasted at your cursor automatically
- **Smart Text Cleanup** — Removes filler words, fixes capitalization and spacing
- **Sound Effects** — Audio cues when recording starts and transcription completes (can be disabled in Settings)
- **Speaky Mascot** — Animated character shows recording/transcribing state in the notch and main window
- **Dynamic Notch Overlay** — Live waveform, timer, and Speaky animation in the macOS notch
- **System Audio Muting** — Optionally mutes system audio while recording
- **Multi-Model Support** — Download and switch between 10+ transcription models
- **Custom Model Import** — Import your own Whisper `.bin` models

## Supported Models

The app comes with a default model pre-downloaded during onboarding, but you can switch to any of these at any time:

| Model | Type | Size | Speed | Accuracy | Platform |
|-------|------|------|-------|----------|----------|
| Parakeet V3 | Local (CoreML) | ~494 MB | 5/5 | 5/5 | Apple Silicon |
| Whisper Medium Q5 | Local (whisper.cpp) | ~539 MB | 3/5 | 4/5 | Both |
| Groq Whisper | Cloud (API) | — | 5/5 | 5/5 | Both |
| Whisper Medium | Local (whisper.cpp) | ~1.5 GB | 2/5 | 4/5 | Both |
| Whisper Small | Local (whisper.cpp) | ~466 MB | 4/5 | 3/5 | Both |
| Whisper Small Q5 | Local (whisper.cpp) | ~190 MB | 4/5 | 3/5 | Both |
| Whisper Base | Local (whisper.cpp) | ~142 MB | 5/5 | 2/5 | Both |
| Whisper Base Q5 | Local (whisper.cpp) | ~60 MB | 5/5 | 2/5 | Both |
| Whisper Tiny | Local (whisper.cpp) | ~75 MB | 5/5 | 1/5 | Both |
| Whisper Large v1 | Local (whisper.cpp) | ~2.9 GB | 1/5 | 4/5 | Both |
| Whisper Large v2 | Local (whisper.cpp) | ~2.9 GB | 1/5 | 5/5 | Both |

You can also import any custom Whisper `.bin` model via Settings > Advanced > Import Custom Whisper Model.

## Build from Source

Speaky uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 to generate the Xcode project.

```bash
# Install xcodegen
brew install xcodegen
xcodegen --version  # Must report Version: 2.46.0

# Generate the project
xcodegen generate

# Routine contributor builds use "Speaky Debug" and
# com.bedriyan.speaky.debug so they do not conflict with an installed release.
xcodebuild \
  -project Speaky.xcodeproj \
  -scheme Speaky \
  -configuration Debug \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  build

# Unpublished local DMGs require an explicit ad-hoc opt-in
SPEAKY_ALLOW_ADHOC=1 ./build.sh              # Universal binary
SPEAKY_ALLOW_ADHOC=1 ./build.sh silicon      # Apple Silicon only
SPEAKY_ALLOW_ADHOC=1 ./build.sh intel        # Intel only
SPEAKY_ALLOW_ADHOC=1 ./build.sh separate     # Both architectures + DMGs
```

The packaging script fails closed unless it receives the canonical stable identity or the explicit local-only ad-hoc opt-in. Release maintainers should complete [Maintainer release-signing setup](docs/maintainer-setup.md) once, then follow [Release build and signing](docs/build-signing.md) for every version.

Prefer the Debug build for day-to-day development. An ad-hoc Release DMG uses the production bundle identifier, must not be published, and should not be installed alongside an official release.

## Architecture

```
Speaky/
├── SpeakyApp.swift                 # App entry point
├── AppState.swift                  # Central state (@Observable, @MainActor)
├── AppDelegate.swift               # Menu bar setup
├── Models/
│   ├── Settings.swift              # App preferences (UserDefaults)
│   ├── Transcription.swift         # SwiftData model
│   └── TranscriptionModel.swift    # Model metadata + availability
├── Services/
│   ├── AudioRecorder.swift         # AVAudioEngine → 16kHz mono WAV
│   ├── AudioControlService.swift   # System volume mute/unmute
│   ├── SoundEffectService.swift    # Start/end recording sound effects
│   ├── PasteService.swift          # CGEvent-based Cmd+V paste
│   ├── HotkeyManager.swift         # Global keyboard shortcuts
│   ├── ModelManager.swift          # Model download + cache
│   ├── TextCleanupService.swift    # Filler word removal
│   ├── CleanupService.swift        # Auto-delete old transcriptions
│   ├── DeviceGuard.swift           # Audio device disconnect protection
│   └── Transcription/
│       ├── TranscriptionEngine.swift   # Protocol
│       ├── WhisperEngine.swift         # Local (whisper.cpp)
│       ├── ParakeetEngine.swift        # Local (CoreML, Apple Silicon)
│       └── GroqEngine.swift            # Cloud (Groq API)
├── Utilities/
│   ├── Constants.swift             # App-wide constants
│   ├── Theme.swift                 # Colors, gradients, button styles
│   ├── KeychainHelper.swift        # Secure API key storage
│   ├── AudioFileLoader.swift       # Audio file loading
│   ├── AudioLevelMonitor.swift     # Real-time audio levels
│   └── WAVWriter.swift             # WAV file encoding
├── Views/
│   ├── MainWindow/
│   │   ├── MainWindowView.swift    # Main app window with Speaky animation
│   │   └── SettingsView.swift      # Settings + model management
│   ├── MenuBar/
│   │   └── MenuBarView.swift       # Menu bar dropdown
│   ├── Onboarding/                 # First-launch setup flow
│   ├── Overlay/
│   │   └── NotchOverlayView.swift  # Dynamic notch recording UI
│   └── Shared/
│       ├── SpeakyAnimation.swift   # Animation state enum
│       ├── SpeakyAnimationView.swift # APNG animation player
│       └── LanguagePicker.swift    # Language selection
└── Resources/
    ├── Speaky/                     # APNG mascot animations
    ├── Sounds/                     # Start/end sound effects
    └── Assets.xcassets/            # App icon + colors
```

## Dependencies

| Package | Purpose |
|---------|---------|
| [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) | whisper.cpp Swift wrapper |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | Global hotkey recording |
| [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) | Notch overlay UI |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Parakeet engine (Apple Silicon) |

## Requirements

- macOS 15.0+ (Sequoia)
- Microphone permission
- Accessibility permission (for auto-paste)

## License

MIT
