# Releasing Cell

The **macOS release** GitHub Actions workflow builds a universal app and charging helper for Apple Silicon and Intel. It tests the core, validates release metadata and helper signatures, then creates:

- `Cell-<version>-universal.dmg`: app, Applications shortcut, volume icon and installation guide.
- `Cell-<version>-universal.pkg`: native macOS Installer with branded welcome and completion pages; installs `/Applications/Cell.app`.
- `Cell-<version>-universal.zip`: the app bundle, including its optional charging helper and install/remove scripts.
- `INSTALL.md`, `RELEASE-NOTES.md`, `release-manifest.json` and `SHA256SUMS`.

Unsigned files include `-unsigned` in their names. GitHub also supplies its usual source archives. Download one app format; the PKG and DMG are alternatives. The helper needs no separate download and is activated only through Cell's existing administrator approval flow.

## Trigger a release

Commit and push the changes you want to release, then create and push an annotated version tag. For example, when you choose to release version 1.2.0:

```sh
git tag -a v1.2.0 -m 'Cell 1.2.0'
git push origin v1.2.0
```

Supported tags are `vMAJOR.MINOR.PATCH` and prereleases such as `v1.2.0-beta.1`. Leading zeroes, build metadata and unsafe characters are rejected. The numeric portion becomes the Apple bundle version; the full version appears in Cell's settings and filenames. The GitHub run number becomes `CFBundleVersion`.

After a successful build, a separate job verifies the checksums, uploads every file to a draft release, then publishes it. A failed build publishes nothing. A rerun may complete an existing draft but never replaces a published release. Do not move a published tag; use a new version. An unsigned build or prerelease version is always published as a GitHub **prerelease** and does not become the latest stable release.

For a build without creating a tag or GitHub Release, use **Actions → macOS release → Run workflow** and enter a version. Download `cell-macos-release` from that run's artifacts; they expire after 14 days. This is also the smoke-test path for workflow changes.

## Default: unsigned builds

No Apple credentials are needed to produce files. The default mode is `adhoc`: local code signatures protect bundle integrity and pin the helper, but are not a Developer ID identity. The package is unsigned, and Apple has not notarized the artifacts. Filenames, installation notes, Installer welcome page and GitHub release title make that explicit. Gatekeeper may block these downloads. Use the signed path for ordinary public distribution.

## Enable Developer ID signing and notarization

Obtain your own **Developer ID Application** and **Developer ID Installer** certificates, including their private keys, from your Apple Developer account. Export them as two password-protected `.p12` files using the same strong export password. Also create an App Store Connect **team API key** with access to notarization.

Add these repository secrets in **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `MACOS_APPLICATION_CERTIFICATE` | Single-line base64 of the Application `.p12` |
| `MACOS_INSTALLER_CERTIFICATE` | Single-line base64 of the Installer `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | The export password shared by those two files |
| `MACOS_APPLICATION_IDENTITY` | Full `Developer ID Application: Name (TEAMID)` identity |
| `MACOS_INSTALLER_IDENTITY` | Full `Developer ID Installer: Name (TEAMID)` identity |
| `NOTARY_KEY` | Entire `.p8` private key text, including its real newlines |
| `NOTARY_KEY_ID` | App Store Connect key ID |
| `NOTARY_ISSUER_ID` | Team API key issuer UUID |

To encode a certificate on macOS, use `base64 -i certificate.p12 | tr -d '\n'` and save that output directly as its GitHub secret. Never commit a certificate, password or `.p8` file.

Then set the repository **variable** `MACOS_SIGNING` to `developer-id`. It defaults to `adhoc` if absent. Missing or invalid signing/notarization configuration fails the build; it never silently falls back to unsigned output. Protect release tags and restrict who may modify the workflow or create tags that use these secrets.

The workflow imports certificates into a temporary keychain on an ephemeral GitHub-hosted runner, signs the helper before the app with hardened runtime and secure timestamps, signs the installer with its separate Installer identity, notarizes and staples the app/package/disk image, and performs signature and Gatekeeper checks. Temporary certificates, private key and keychain are removed in an `always()` cleanup step. Only completed artifacts are uploaded. Notarization diagnostic files are retained for seven days on failure. No signing secrets enter the app or release manifest.

Apple references: [Preparing software for notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Customizing notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). Runner: [GitHub macOS 26 image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).

## Build locally

Requires macOS, Xcode, Python 3.10 or later, and the command-line developer tools. Runtime users do not need Python or Xcode.

```sh
make test
make release VERSION=1.2.0-beta.1
```

Files appear under `dist/releases/Cell-1.2.0-beta.1-universal-unsigned/`. Existing release directories are preserved; use a new version or `python3 scripts/release.py build --version VERSION --output NEW_DIRECTORY` for another build. The packager builds in a private staging directory and leaves a running `dist/Cell.app` intact. The manifest records the source commit and whether the working tree had uncommitted changes.

For a signed local release, make your Developer ID identities available in Keychain, and set:

```sh
export CELL_SIGNING=developer-id
export CELL_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export CELL_INSTALLER_IDENTITY='Developer ID Installer: Your Name (TEAMID)'
export CELL_NOTARY_PROFILE='your-existing-notarytool-profile'
make release VERSION=1.2.0
```

`CELL_NOTARY_PROFILE` refers to credentials you already stored with Apple's `notarytool store-credentials`. Alternatively provide `CELL_NOTARY_KEY` (the private-key file path), `CELL_NOTARY_KEY_ID` and `CELL_NOTARY_ISSUER`. `CELL_SIGNING_KEYCHAIN` optionally selects a keychain. Signed releases require notarization; an Apple rejection or timeout prevents publication.

For just a universal app, use `CELL_ARCHS='arm64 x86_64' make app`. Regular `make app` still builds only the host architecture. Both builds explicitly target the app's minimum supported macOS version and verify the app and helper's architecture slices. Ad-hoc universal helper requirements include both architecture hashes so authenticated IPC works on either CPU.

Before a public release, test a downloaded installer on a clean Mac, an Intel Mac, supported older macOS versions and an approved charge-limit crossing. Local packaging checks do not establish that every hardware model supports charge inhibition.
