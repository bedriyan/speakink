# Maintainer release-signing setup

This guide is for the maintainer who prepares official Speaky releases. Complete it once before producing the first stable self-signed release. For the steps repeated for every version, see [Release build and signing](build-signing.md).

## What this setup provides

Speaky uses one long-lived self-signed code-signing certificate to give official releases a stable macOS identity. Keeping the same certificate, bundle identifier, and designated requirement allows macOS to recognize future releases as updates of the same Accessibility client.

This free signing method does **not** notarize Speaky. Users will still need to approve the first launch through macOS Privacy & Security. This project intentionally documents only the free release path.

## Prerequisites

Use a trusted Mac with:

- Xcode 26.3 (`17C529`) for release parity with CI.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0.
- OpenSSL 1.1.1 or newer.
- Permission to administer the repository's protected GitHub environments.
- A secure backup location for the release identity and its password.

Before enabling releases, also confirm that:

- The exact package versions in `project.yml` and the tracked `Package.resolved` still resolve.
- The app builds on every supported architecture.
- The test suite passes.

Speaky intentionally has no bundled automatic-update framework. Adding one requires a separate security review, update-signing design, and end-to-end update tests.

## 1. Generate the release identity

Choose a long random password and generate the identity exactly once:

```bash
read -s SPEAKY_CERTIFICATE_PASSWORD
export SPEAKY_CERTIFICATE_PASSWORD
./scripts/create-self-signed-certificate.sh
unset SPEAKY_CERTIFICATE_PASSWORD
```

Enter the password only at the local shell prompt. Do not place it in shell history.

The command creates:

| File | Purpose | Secret? |
| --- | --- | --- |
| `build/signing/Speaky-Open-Source-Release.p12` | Certificate and private signing key | Yes |
| `build/signing/Speaky-Open-Source-Release.cer` | Public certificate used in the designated requirement | No |

The script refuses to replace an existing identity. Do not bypass that protection during normal release work.

Record the certificate fingerprint and expiry date shown by the script. You can
inspect them again at any time:

```bash
openssl x509 \
  -inform DER \
  -in build/signing/Speaky-Open-Source-Release.cer \
  -noout \
  -fingerprint \
  -sha256 \
  -enddate
```

## 2. Back up the identity

Store these items in a secure location separate from the repository:

- The `.p12` file.
- Its password.
- The public `.cer` file.
- A note identifying the certificate as the canonical Speaky release identity.
- The certificate's SHA-256 fingerprint and expiry date.

Never commit, publish, email, or attach the `.p12` to a GitHub Release. Anyone who obtains it and its password can sign applications that match Speaky's release identity.

Losing or replacing the private key breaks identity continuity. Users would then need to grant Accessibility again for releases signed by the replacement certificate.

Create calendar reminders well before expiry. The release build refuses a
certificate with less than 30 days of validity remaining.

## 3. Install the identity on a release Mac

Import the `.p12` into the login keychain:

```bash
read -s SPEAKY_CERTIFICATE_PASSWORD
export SPEAKY_CERTIFICATE_PASSWORD
security import \
  build/signing/Speaky-Open-Source-Release.p12 \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$SPEAKY_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign
unset SPEAKY_CERTIFICATE_PASSWORD
```

Run the import only on the trusted release Mac. The `security import -P` interface necessarily passes the password as a process argument for the short lifetime of that command.

Then:

1. Open **Keychain Access**.
2. Find **Speaky Open Source Release**.
3. Open the certificate and expand **Trust**.
4. Set **Code Signing** to **Always Trust**.
5. Close the certificate window and authenticate if requested.

Confirm that macOS recognizes it as a valid code-signing identity:

```bash
security find-identity -v -p codesigning
```

The output must include **Speaky Open Source Release**. Record the 40-character SHA-1 hash shown before the certificate name; release builds select the identity by that exact hash rather than by a potentially ambiguous name.

Only release machines need this trust setting. End users must not import or trust the maintainer certificate.

## 4. Configure GitHub Actions

The manual [Build self-signed release workflow](../.github/workflows/self-signed-release.yml) imports the same identity into an ephemeral macOS runner and uploads Apple Silicon and Intel DMGs as workflow artifacts.

In **Settings → Environments**, create an environment named exactly `release-signing`, then:

1. Add required reviewers who understand the release checklist.
2. Prevent self-approval when the repository plan supports that control.
3. Allow deployments only from the repository's default branch, `main`.
4. Store the following as **environment secrets**, not repository-wide secrets.

| Secret | Value |
| --- | --- |
| `SPEAKY_SIGNING_CERTIFICATE_P12` | Base64-encoded `.p12` file |
| `SPEAKY_SIGNING_CERTIFICATE_PASSWORD` | Password used when the `.p12` was generated |

On macOS, copy the base64 value with:

```bash
base64 -i build/signing/Speaky-Open-Source-Release.p12 | pbcopy
```

Paste that value into `SPEAKY_SIGNING_CERTIFICATE_P12`. Do not store the encoded value in a file tracked by Git.

The workflow must be dispatched with **Use workflow from: main**. Its
`release_tag` input identifies the source to build, but it is not the workflow
execution ref used by GitHub Environment branch restrictions. Before approving
the `release-signing` environment, a reviewer must verify:

- The selected workflow ref is `main`.
- The requested semantic-version tag is the intended release.
- The release tag points to the exact selected `main` workflow commit.
- The test job's `Validated release source` message shows that tag and commit SHA.
- The tag still points to that SHA.

The workflow also enforces the `main` ref in code, accepts an existing
semantic-version tag only when it points to the exact selected `main` commit,
validates it against `project.yml`, and has read-only repository permissions.
Tags created before the release contract in
`.github/release-contract-version` are rejected. The build job checks out the
exact commit SHA that passed the test job and repeats the `main`-SHA and tag
checks before importing the signing identity. The protected Environment
restriction is the security boundary; the in-workflow checks are defense in
depth.

CI pins Xcode 26.3 (`17C529`) and downloads XcodeGen 2.46.0 with a fixed SHA-256 checksum. Tests and builds are restricted to the tracked `Package.resolved` graph. Tests run before the protected signing job requests approval or imports the key. Actions are pinned to immutable commit SHAs. Artifacts are retained briefly and are not published automatically.

The signing certificate, private key, trusted entry, and temporary keychain are
removed immediately after the verified build and before the artifact-upload
action runs.

The private key is the highest-risk release asset. Keep an offline backup. If the project does not need CI signing, the maintainer may omit the environment secrets and build only on the secured release Mac.

## 5. Prove identity continuity before the first release

Before publishing:

1. Produce two test builds from different source revisions using the same certificate.
2. Extract both `Speaky.app` bundles.
3. Compare them with:

```bash
./scripts/verify-app-identity.sh \
  /path/to/new/Speaky.app \
  /path/to/previous/Speaky.app
```

The comparison must report that both builds share the same designated requirement.

## 6. Plan the first-release migration

Older ad-hoc releases used changing code-hash identities. The first release produced with this stable self-signed process is therefore a one-time migration:

- Mention the Accessibility cleanup in the release notes.
- Link users to [Install Speaky on macOS](end-user-installation.md#upgrading-from-an-older-ad-hoc-release).
- Explain that later releases preserve Accessibility only while the same signing identity is retained.

## 7. Plan certificate expiry

The default certificate lifetime is 3,650 days. Certificate expiry is therefore
a planned identity migration, not an indefinite guarantee.

Renewing the certificate changes its certificate hash—and therefore Speaky's
designated-requirement anchor—even if the same private key is reused. Users will
need to grant Accessibility to the replacement identity.

Well before expiry:

1. Announce the migration and the required Accessibility reauthorization.
2. Generate and securely back up the replacement identity without overwriting the old one.
3. Update the protected CI secrets and release-Mac identity together.
4. Build and verify the first replacement-signed release.
5. Confirm the new requirement intentionally differs from the expiring identity.
6. Publish cleanup and reauthorization instructions with that release.

Never silently regenerate or replace an expired certificate, and never weaken
the build's expiry check to publish one last release.

## Permanent release rules

- Generate the release identity once.
- Record and monitor its fingerprint and expiry date.
- Keep its private key restricted to release maintainers and CI secrets.
- Never publish an ad-hoc build as an official release.
- Never silently replace or regenerate the certificate.
- Do not add an automatic updater without a separate security review and signed-update test plan.
- Remove access for maintainers who no longer prepare releases.
- Test and verify every artifact before publishing it.
- If the identity expires, is lost, or is compromised, disclose the migration and require users to reauthorize the new identity.
