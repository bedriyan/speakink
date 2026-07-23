# Install Speaky on macOS

This guide is for people installing an official Speaky release from GitHub. You do not need Xcode, Terminal experience, a signing certificate, or a developer account.

The v2.0.4 artifacts predate Speaky's stable self-signed release process. The release notes will identify the first version built with that process.

## Requirements

- macOS 15 or later.
- A supported Apple Silicon or Intel Mac.
- Permission to install applications in `/Applications`.
- Microphone permission.
- Accessibility permission for automatic pasting.

## 1. Download the correct DMG

Download Speaky only from the official repository's [GitHub Releases](https://github.com/bedriyan/speaky/releases).

| Mac | Download |
| --- | --- |
| Apple Silicon: M1, M2, M3, M4, or later | Apple Silicon DMG |
| Intel processor | Intel DMG |

You can identify your Mac from **Apple menu → About This Mac**.

If the release provides SHA-256 checksums, optionally verify the download in Terminal:

```bash
shasum -a 256 ~/Downloads/Speaky-*.dmg
```

The result must exactly match the checksum published with the GitHub Release.

## 2. Install Speaky

1. Open the downloaded DMG.
2. Drag **Speaky** into the **Applications** folder.
3. Eject the Speaky disk image.
4. Open **Applications** and launch **Speaky**.

Keep only one installed copy of Speaky, preferably `/Applications/Speaky.app`.

## 3. Approve the first launch

Speaky releases are not notarized by Apple. macOS may report that Apple cannot check the app for malicious software.

Only continue if the DMG came from the official GitHub Release and, when provided, its checksum matches.

After attempting to open Speaky:

1. Open **System Settings**.
2. Select **Privacy & Security**.
3. Scroll down to **Security**.
4. Click **Open Anyway** next to the Speaky message.
5. Authenticate with your Mac password or Touch ID.
6. Confirm **Open**.

Apple documents this process in [Safely open apps on your Mac](https://support.apple.com/en-us/102445). The **Open Anyway** button appears only after macOS has blocked a launch and may be available for a limited time.

Do not disable Gatekeeper globally. Do not import or trust a certificate supplied by another person.

## 4. Grant microphone access

Speaky needs the microphone to record speech.

1. Accept the microphone request when Speaky displays it.
2. If access was previously denied, open **System Settings → Privacy & Security → Microphone**.
3. Enable **Speaky**.
4. Quit and reopen Speaky if macOS requests it.

## 5. Grant Accessibility access

Accessibility allows Speaky to paste completed transcriptions into the active application.

1. Open Speaky's settings.
2. Find **Accessibility Access** and select **Grant Access**.
3. In **System Settings → Privacy & Security → Accessibility**, enable **Speaky**.
4. Authenticate if requested.
5. Quit and reopen Speaky if the status does not update immediately.

Speaky cannot grant this permission to itself. Keep one installed copy to avoid ambiguous permission entries.

## 6. Finish onboarding and test

1. Select or download a transcription model.
2. Choose the microphone input.
3. Configure the recording shortcut.
4. Place the cursor in a text field.
5. Start recording, speak, and stop recording.
6. Confirm that Speaky transcribes and pastes the text.

Model downloads can be large and may take several minutes.

## Upgrading from an older ad-hoc release

Older releases and local builds may use changing ad-hoc identities and can create duplicate Speaky entries in Accessibility settings. Complete this cleanup once when moving to the first release whose notes confirm the stable self-signed identity:

1. Quit every running Speaky copy.
2. Open **System Settings → Privacy & Security → Accessibility**.
3. Select each existing Speaky entry and remove it with the minus button.
4. Delete obsolete Speaky applications, keeping no old copies in Applications, Downloads, or mounted DMGs.
5. Install the new release as `/Applications/Speaky.app`.
6. Launch it and grant microphone and Accessibility permissions once.

Later official updates should preserve Accessibility permission while the maintainer keeps the same signing identity. Manually downloaded updates may still require Gatekeeper approval because the app is not notarized.

Speaky does not update itself automatically. Download future versions from the same official GitHub Releases page, verify their checksums, and replace the existing app in `/Applications`.

## Troubleshooting

### Open Anyway is missing

Try to open Speaky once, dismiss the warning, and return to **System Settings → Privacy & Security**. macOS shows **Open Anyway** only after it has blocked that specific app.

### Multiple Speaky entries appear in Accessibility

Quit Speaky, remove every Speaky entry, delete obsolete app copies, and reinstall one official copy in `/Applications`.

### Microphone access is denied

Enable Speaky in **System Settings → Privacy & Security → Microphone**, then restart the app.

### Auto-paste does not work

Confirm Speaky is enabled in **System Settings → Privacy & Security → Accessibility**. Transcription can succeed without Accessibility, but Speaky cannot paste into another app.

### Recording cannot start

In Speaky settings, select a specific available input device instead of an unavailable or disconnected device. Also verify that the device works in **System Settings → Sound → Input**.

### A managed Mac blocks the app

Work or school security policies can prevent users from overriding Gatekeeper or granting Accessibility. Contact the organization's administrator; do not disable security controls.

## Security limitations

Self-signing gives official releases a stable application identity, but it does not provide Apple notarization.

For the safest installation:

- Download only from the official GitHub Release.
- Verify published checksums.
- Keep only one installed copy.
- Do not run commands that globally disable macOS security.
- Install future updates only from the same official project.
