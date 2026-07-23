# Release build and signing

This is the repeatable checklist for every official Speaky release. If the release certificate or GitHub secrets have not been configured yet, complete [Maintainer release-signing setup](maintainer-setup.md) first.

## Identity model

macOS associates Accessibility approval with an app's bundle identity and code-signing designated requirement, not only its display name.

| Build | Display name | Bundle identifier | Signing |
| --- | --- | --- | --- |
| Debug | Speaky Debug | `com.bedriyan.speaky.debug` | Ad hoc by default |
| Official Release | Speaky | `com.bedriyan.speaky` | Stable self-signed identity |

Debug builds remain separate from an installed release. Because an ad-hoc Debug build has a changing code-hash identity, contributors may occasionally need to reauthorize **Speaky Debug**.

## 1. Prepare the release

Before building:

- Start from the exact commit intended for release.
- Confirm the working tree contains no accidental local changes.
- Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
- Confirm the exact dependencies and tracked `Package.resolved` lock file contain only intentional changes.
- Use Xcode 26.3 (`17C529`) and XcodeGen 2.46.0, matching the release workflow.
- Generate the Xcode project successfully.
- Run the full test suite.
- Review user-facing changes and release notes.
- Obtain the previous official `Speaky.app` for identity comparison.

Do not proceed when tests, dependency resolution, or supported-architecture builds are failing.

The direct package versions in `project.yml` are the versions exercised by this release process; `Package.resolved` locks their transitive graph. FluidAudio 0.13.2 is deliberate: it preserves the Swift 6 actor-based `AsrManager` API while fixing the Intel compilation failure present in 0.12.6 and 0.13.1. Treat every dependency change as a separate reviewed update and regenerate the lock file only after both architecture builds and tests pass.

```bash
xcodegen generate
xcodebuild test \
  -project Speaky.xcodeproj \
  -scheme Speaky \
  -configuration Debug \
  -destination 'platform=macOS' \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile
```

## 2. Build locally

Confirm that the canonical identity is available:

```bash
security find-identity -v -p codesigning
openssl x509 \
  -inform DER \
  -in build/signing/Speaky-Open-Source-Release.cer \
  -noout \
  -enddate
```

The certificate must have at least 30 days of validity remaining. Follow the
expiry-migration plan in
[Maintainer release-signing setup](maintainer-setup.md#7-plan-certificate-expiry)
instead of bypassing this release check.

If `SPEAKY_SIGNING_KEYCHAIN` points to a custom keychain, add that keychain to
the user search list before building. Preserve any existing entries in the same
command; `codesign` cannot use an identity from a keychain that is absent from
this list:

```bash
security list-keychains -d user
security list-keychains -d user -s \
  /absolute/path/to/release.keychain-db \
  "$HOME/Library/Keychains/login.keychain-db"
```

Then build both release architectures:

```bash
SPEAKY_SIGNING_IDENTITY='<40-character certificate SHA-1>' \
SPEAKY_SIGNING_CERTIFICATE="$PWD/build/signing/Speaky-Open-Source-Release.cer" \
./build.sh separate
```

The build script:

- Requires the tracked `Package.resolved` and forbids automatic dependency resolution.
- Validates the release bundle identifier and executable.
- Asserts the exact architecture slices before naming each artifact.
- Signs every embedded framework, dynamic library, extension, and login item before the outer application.
- Signs the main application with only its microphone entitlement.
- Keeps hardened runtime enabled for stable signed releases.
- Embeds a designated requirement anchored to the release certificate and `com.bedriyan.speaky`.
- Rejects a certificate that does not match the selected private identity.
- Verifies the certificate anchor, runtime policy, microphone-only entitlement allowlist, and completed app before packaging it.
- Confirms every nested code object uses hardened runtime and the same release certificate as the outer app.
- Verifies each completed DMG's checksum before reporting it as an output.

The output DMGs are written to `build/`.

Speaky does not bundle an automatic updater. This keeps library validation enabled and avoids update-related helper processes and signing keys.

## 3. Build with GitHub Actions

Alternatively:

1. Create the final semantic-version tag, such as `v2.1.0`, on the reviewed current `main` commit.
2. Open the repository's **Actions** tab.
3. Select **Build self-signed release**.
4. Set **Use workflow from** to `main`.
5. Choose **Run workflow** and enter that exact existing tag.
6. After the test job passes, verify its logged tag and commit SHA before approving the protected `release-signing` environment.
7. Download the `Speaky-self-signed-vX.Y.Z` artifact.

The workflow runs only from `main` and accepts only a `vMAJOR.MINOR.PATCH` tag
that points to the exact selected `main` commit, matches the version in
`project.yml`, and contains the current release-contract marker. Tests run in a
separate job before the protected environment exposes its signing secrets. The
signing job checks out the exact tested commit SHA and fails if the tag moves or
does not match the selected `main` SHA. The workflow builds Apple Silicon and
Intel DMGs, asserts their slices, verifies them, removes all temporary signing
material, and only then uploads the DMGs with `SHA256SUMS.txt`. It does not
publish a GitHub Release.

## 4. Verify the artifacts

### Verify bundle metadata and signature

For each extracted application:

```bash
codesign --verify --deep --strict /path/to/Speaky.app
/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleIdentifier' \
  /path/to/Speaky.app/Contents/Info.plist
```

The bundle identifier must be:

```text
com.bedriyan.speaky
```

Inspect the entitlements:

```bash
codesign -d --entitlements :- /path/to/Speaky.app
```

The Release app must contain the microphone entitlement. It must not contain `com.apple.security.cs.disable-library-validation` or `com.apple.security.get-task-allow`.

### Compare identity with the previous release

```bash
./scripts/verify-app-identity.sh \
  /path/to/new/Speaky.app \
  /path/to/previous/Speaky.app
```

Do not publish if the designated requirements differ unexpectedly. A changed requirement can make macOS treat the update as a new Accessibility client.

### Verify architectures

```bash
lipo -archs /path/to/Speaky.app/Contents/MacOS/Speaky
```

Confirm the Apple Silicon build contains `arm64` and the Intel build contains `x86_64`.

### Test real installations

On clean test machines:

1. Install each DMG into `/Applications`.
2. Confirm the app survives first launch.
3. Complete onboarding and download the intended default model.
4. Grant microphone and Accessibility permissions.
5. Record, transcribe, and auto-paste text.
6. Confirm the menu bar item remains available.
7. Install the new version over the previous stable release and confirm Accessibility remains granted.

### Generate checksums

```bash
(
  cd build
  shasum -a 256 Speaky-*.dmg > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
```

The manifest contains artifact-root filenames without a `build/` prefix, so it
works after downloading and extracting the GitHub Actions artifact. Publish
this exact verified manifest with the release.

## 5. Publish the GitHub Release

The maintainer should:

1. Use the already verified version tag and commit.
2. Create a GitHub Release for that tag.
3. Attach the verified Apple Silicon and Intel DMGs.
4. Include their SHA-256 checksums.
5. Describe important changes and known limitations.
6. Link to [Install Speaky on macOS](end-user-installation.md).
7. For the first stable signed release, highlight the one-time Accessibility migration.

Do not rebuild artifacts after verification. Publish the exact files that were tested.

## Ad-hoc builds are local-only

The build script never silently falls back to ad-hoc signing. For an unpublished local test DMG, opt in explicitly:

```bash
SPEAKY_ALLOW_ADHOC=1 ./build.sh silicon
```

Ad-hoc builds:

- Have a changing designated requirement.
- May require Accessibility approval after every rebuild.
- Disable hardened runtime on the final ad-hoc signatures.
- Use the production bundle identifier; prefer **Speaky Debug** for routine contributor testing and do not install an ad-hoc Release alongside an official release.
- Must not be published as official releases.

## Expected limitations of the free release path

- This free self-signed release process does not notarize the app.
- Gatekeeper will require users to approve the first launch.
- macOS always requires the user to grant microphone and Accessibility permissions.
- The stable certificate preserves identity continuity; it does not make the maintainer an Apple-identified developer.

## Failure handling

Stop the release when:

- The canonical signing identity is unavailable.
- The public `.cer` does not match the private signing identity.
- The certificate expires within 30 days.
- The tracked package lock is missing, changed during generation, or cannot satisfy the build.
- `codesign --verify` fails.
- The new and previous designated requirements differ.
- A Release app contains `get-task-allow`.
- A Release app disables library validation.
- An artifact contains architecture slices other than those declared by its filename.
- A supported architecture cannot build or launch.
- End-to-end recording, transcription, or auto-paste fails.

Do not work around a signing failure by publishing the ad-hoc fallback.
