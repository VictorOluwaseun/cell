#!/usr/bin/env python3
"""Build macOS release artifacts with Apple tools and the Python standard library."""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass

ROOT = Path(__file__).resolve().parent.parent
VERSION_PATTERN = re.compile(r"v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?", re.ASCII)


@dataclass(frozen=True)
class Version:
    display: str
    bundle: str
    prerelease: bool

    @classmethod
    def parse(cls, value: str) -> Version:
        match = VERSION_PATTERN.fullmatch(value)
        if not match or any(part.isdigit() and len(part) > 1 and part[0] == "0"
                            for part in (match[4] or "").split(".")):
            raise ValueError("Use a version such as v1.2.0 or v1.2.0-beta.1 (no build metadata).")
        return cls(value.removeprefix("v"), ".".join(match.groups()[:3]), bool(match[4]))


def metadata(value: str, build: str, signing: str) -> dict:
    version = Version.parse(value)
    if not re.fullmatch(r"[1-9][0-9]{0,8}", build, re.ASCII):
        raise ValueError("Build number must be a positive integer of at most nine digits.")
    if signing not in ("adhoc", "developer-id"):
        raise ValueError("CELL_SIGNING must be adhoc or developer-id.")
    return {"version": version.display, "bundle_version": version.bundle, "build": build,
            "signing": signing, "prerelease": version.prerelease or signing == "adhoc",
            "stem": f"Cell-{version.display}-universal" + ("-unsigned" if signing == "adhoc" else "")}


def run(*arguments: object, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run([str(arg) for arg in arguments], check=True, **kwargs)


def zip_app(app: Path, destination: Path) -> None:
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, destination)


def write_checksums(directory: Path) -> None:
    lines = []
    for path in sorted(directory.iterdir()):
        if path.is_file() and path.name != "SHA256SUMS":
            digest = hashlib.sha256()
            with path.open("rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(chunk)
            lines.append(f"{digest.hexdigest()}  {path.name}\n")
    (directory / "SHA256SUMS").write_text("".join(lines), encoding="utf-8")


def signing_environment(signing: str) -> dict[str, str]:
    environment = os.environ.copy()
    if signing == "adhoc":
        environment["CELL_SIGNING_IDENTITY"] = "-"
        return environment
    if not environment.get("CELL_SIGNING_IDENTITY", "").startswith("Developer ID Application: "):
        raise ValueError("A Developer ID Application identity is required for signed releases.")
    if not environment.get("CELL_INSTALLER_IDENTITY", "").startswith("Developer ID Installer: "):
        raise ValueError("A Developer ID Installer identity is required for signed releases.")
    if not environment.get("CELL_NOTARY_PROFILE"):
        for name in ("CELL_NOTARY_KEY", "CELL_NOTARY_KEY_ID", "CELL_NOTARY_ISSUER"):
            if not environment.get(name):
                raise ValueError(f"Missing {name}; signed releases require notarization credentials.")
        if not Path(environment["CELL_NOTARY_KEY"]).is_file():
            raise ValueError("CELL_NOTARY_KEY must point to the App Store Connect private key file.")
    return environment


def notarize(path: Path, label: str, environment: dict[str, str]) -> None:
    if environment.get("CELL_NOTARY_PROFILE"):
        authentication = ["--keychain-profile", environment["CELL_NOTARY_PROFILE"]]
        if environment.get("CELL_SIGNING_KEYCHAIN"):
            authentication += ["--keychain", environment["CELL_SIGNING_KEYCHAIN"]]
    else:
        authentication = ["--key", environment["CELL_NOTARY_KEY"], "--key-id", environment["CELL_NOTARY_KEY_ID"],
                          "--issuer", environment["CELL_NOTARY_ISSUER"]]
    logs = ROOT / ".build/release-logs"
    logs.mkdir(parents=True, exist_ok=True)
    print(f"Notarizing {label}…", flush=True)
    result = subprocess.run(["xcrun", "notarytool", "submit", str(path), *authentication,
                             "--wait", "--timeout", "20m", "--output-format", "json"], capture_output=True, text=True)
    (logs / f"{label}-submission.json").write_text(result.stdout, encoding="utf-8")
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(f"Notarization of {label} did not return JSON: {result.stderr}") from None
    if result.returncode or response.get("status") != "Accepted":
        if response.get("id"):
            subprocess.run(["xcrun", "notarytool", "log", response["id"], str(logs / f"{label}-details.json"), *authentication], check=False)
        raise RuntimeError(f"Notarization of {label} failed; inspect .build/release-logs.")


def staple(path: Path) -> None:
    run("xcrun", "stapler", "staple", path)
    run("xcrun", "stapler", "validate", path)


def make_package(app: Path, destination: Path, staging: Path, info: dict, environment: dict[str, str]) -> None:
    root = staging / "pkg-root"
    run("ditto", app, root / "Applications/Cell.app")
    components = staging / "components.plist"
    run("pkgbuild", "--analyze", "--root", root, components)
    values = plistlib.loads(components.read_bytes())
    for value in values:
        value.update(BundleIsRelocatable=False, BundleIsVersionChecked=True,
                     BundleHasStrictIdentifier=True, BundleOverwriteAction="upgrade")
    components.write_bytes(plistlib.dumps(values))
    component = staging / "Cell-component.pkg"
    run("pkgbuild", "--root", root, "--component-plist", components, "--identifier", "com.cellapp.battery.pkg",
        "--version", info["bundle_version"], "--install-location", "/", "--ownership", "recommended", component)
    resources = staging / "installer-resources"
    resources.mkdir()
    notice = "" if info["signing"] == "developer-id" else '<p class="notice">Unsigned community build. Apple has not notarized this download.</p>'
    # Installer adapts text colors for dark mode; avoid fixed light backgrounds.
    style = "body{font:12px -apple-system,Helvetica,sans-serif;line-height:1.4;margin:16px}h1{font-size:28px;letter-spacing:-1px;margin:0 0 8px}h2{font-size:17px;margin:8px 0}p{margin:8px 0}.brand{color:#7961c8}.notice{font-weight:bold}li{margin:8px 0}"
    pages = {
        "welcome.html": f'<h1><span class="brand">cell</span></h1><h2>A little clarity for every charge.</h2><p>Version {html.escape(info["version"])} · macOS 14 or later · Apple Silicon &amp; Intel</p><p>Live battery readings, app energy, charging profiles, alerts and reports. All history stays on your Mac.</p>{notice}<p class="muted">Quit Cell before upgrading. The installer places Cell in Applications. Charging control is an optional setup inside the app.</p>',
        "conclusion.html": '<h1>You’re ready to charge ahead.</h1><ol><li>Open <b>Cell</b> from Applications.</li><li>Allow notifications in <b>Charge alerts</b> when you want reminders.</li><li>For a charging limit, open <b>Charging limit → Install charging helper…</b> and approve the macOS prompt.</li></ol><p class="muted">The package does not activate charging control. If Cell asks to reinstall its helper after an update, approve that from inside Cell.</p>',
    }
    for name, body in pages.items():
        (resources / name).write_text(f'<!doctype html><html><head><meta charset="utf-8"><style>{style}</style></head><body>{body}</body></html>', encoding="utf-8")
    distribution = ET.Element("installer-gui-script", minSpecVersion="2")
    ET.SubElement(distribution, "title").text = f'Cell {info["version"]}'
    ET.SubElement(distribution, "welcome", file="welcome.html", **{"mime-type": "text/html"})
    ET.SubElement(distribution, "conclusion", file="conclusion.html", **{"mime-type": "text/html"})
    ET.SubElement(distribution, "options", customize="never", **{"require-scripts": "false", "hostArchitectures": "arm64,x86_64"})
    ET.SubElement(distribution, "domains", enable_anywhere="false", enable_currentUserHome="false", enable_localSystem="true")
    allowed = ET.SubElement(ET.SubElement(distribution, "volume-check"), "allowed-os-versions")
    ET.SubElement(allowed, "os-version", min="14.0")
    ET.SubElement(ET.SubElement(distribution, "choices-outline"), "line", choice="cell")
    choice = ET.SubElement(distribution, "choice", id="cell", visible="false", title="Cell")
    ET.SubElement(choice, "pkg-ref", id="com.cellapp.battery.pkg")
    ET.SubElement(distribution, "pkg-ref", id="com.cellapp.battery.pkg", version=info["bundle_version"], onConclusion="none").text = component.name
    path = staging / "Distribution.xml"
    ET.ElementTree(distribution).write(path, encoding="utf-8", xml_declaration=True)
    signing = []
    if info["signing"] == "developer-id":
        signing = ["--sign", environment["CELL_INSTALLER_IDENTITY"], "--timestamp"]
        if environment.get("CELL_SIGNING_KEYCHAIN"):
            signing += ["--keychain", environment["CELL_SIGNING_KEYCHAIN"]]
    run("productbuild", "--distribution", path, "--resources", resources, "--package-path", staging, *signing, destination)


def installation_notes(info: dict) -> str:
    trust = ("This release is Developer ID signed and notarized by Apple." if info["signing"] == "developer-id" else
             "This is an unsigned (ad-hoc signed) community build. It is not notarized by Apple. macOS may block installation or opening; for normal distribution, use a Developer ID signed and notarized release.")
    return f"""# Install Cell {info['version']}

macOS 14 or later. The app and charging helper contain Apple Silicon and Intel code.

{trust}

Choose one installation method:

- **DMG:** open the disk image and drag Cell to the Applications shortcut. Eject the image and open Cell from Applications.
- **PKG:** quit Cell, open the installer and follow its steps. It installs only `/Applications/Cell.app`.
- **ZIP:** extract the app and move Cell.app into Applications.

Do not run the app from inside the mounted disk image. Quit Cell before replacing an older version.

## Optional charging control

The charging helper, its installer and removal scripts are already bundled inside Cell.app. No separate helper download is needed. Open **Charging limit → Install charging helper…** to authorize setup. Installation leaves the charging limit disabled until you enable it. Do not copy the helper into system folders yourself. After an update, reinstall the helper from Cell if requested.

## Removal

If you installed the charging helper, use **Charging limit → Remove helper…** before moving Cell.app to Trash. This releases Cell's charge inhibition and removes the daemon. Your history and preferences remain on the Mac. Clear history from Cell settings if you want to remove recorded readings.

## Verify downloads

From the folder containing the downloaded release files, run `shasum -a 256 -c SHA256SUMS`. Download all listed files for a full manifest check, or compare the checksum line for the file you chose.
"""


def build(info: dict, output: Path) -> None:
    if sys.platform != "darwin":
        raise ValueError("Release packaging requires macOS and Xcode.")
    if output.exists():
        raise ValueError(f"Output already exists: {output}. Choose a new --output directory.")
    environment = signing_environment(info["signing"])
    output.parent.mkdir(parents=True, exist_ok=True)
    (ROOT / ".build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cell-release.", dir=ROOT / ".build") as directory:
        staging = Path(directory)
        assets = staging / "assets"
        assets.mkdir()
        app = staging / "Cell.app"
        environment.update(CELL_ARCHS="arm64 x86_64", CELL_APP_OUTPUT=str(app), CELL_VERSION=info["bundle_version"],
                           CELL_RELEASE_VERSION=info["version"], CELL_BUILD_NUMBER=info["build"])
        run(ROOT / "scripts/build-app.sh", "release", env=environment, cwd=ROOT)
        run(app / "Contents/MacOS/Cell", "--validate-charge-installer")
        if info["signing"] == "developer-id":
            submission = staging / "notarization-app.zip"
            zip_app(app, submission)
            notarize(submission, "app", environment)
            staple(app)
            run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
        zip_app(app, assets / f'{info["stem"]}.zip')
        package = assets / f'{info["stem"]}.pkg'
        make_package(app, package, staging, info, environment)
        if info["signing"] == "developer-id":
            notarize(package, "pkg", environment)
            staple(package)
            run("pkgutil", "--check-signature", package)
            run("spctl", "--assess", "--type", "install", "--verbose=2", package)
        notes = installation_notes(info)
        payload = staging / "dmg-root"
        payload.mkdir()
        run("ditto", app, payload / "Cell.app")
        (payload / "Applications").symlink_to("/Applications", target_is_directory=True)
        (payload / "Install Cell.md").write_text(notes, encoding="utf-8")
        shutil.copy2(app / "Contents/Resources/Cell.icns", payload / ".VolumeIcon.icns")
        run("SetFile", "-a", "C", payload)
        image = assets / f'{info["stem"]}.dmg'
        run("hdiutil", "create", "-volname", f'Cell {info["version"]}', "-srcfolder", payload,
            "-fs", "HFS+", "-format", "UDZO", "-imagekey", "zlib-level=9", image)
        if info["signing"] == "developer-id":
            signing = ["--force", "--sign", environment["CELL_SIGNING_IDENTITY"], "--timestamp"]
            if environment.get("CELL_SIGNING_KEYCHAIN"):
                signing += ["--keychain", environment["CELL_SIGNING_KEYCHAIN"]]
            run("codesign", *signing, image)
            notarize(image, "dmg", environment)
            staple(image)
        run("hdiutil", "verify", image)
        (assets / "INSTALL.md").write_text(notes, encoding="utf-8")
        (assets / "RELEASE-NOTES.md").write_text(f"## Downloads\n\n{notes}\n", encoding="utf-8")
        commit = run("git", "rev-parse", "HEAD", cwd=ROOT, capture_output=True, text=True).stdout.strip()
        dirty = bool(run("git", "status", "--porcelain", cwd=ROOT, capture_output=True, text=True).stdout)
        manifest = {**info, "commit": commit, "source_dirty": dirty, "architectures": ["arm64", "x86_64"],
                    "minimum_macos": "14.0", "notarized": info["signing"] == "developer-id"}
        (assets / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        write_checksums(assets)
        # Only complete sets reach the output directory; leave previous releases intact.
        with tempfile.TemporaryDirectory(prefix=".cell-assets-", dir=output.parent) as temporary:
            ready = Path(temporary) / output.name
            shutil.copytree(assets, ready)
            ready.rename(output)
    print(f"Release files: {output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("metadata", "build"))
    parser.add_argument("--version", required=True, help="v1.2.0 or v1.2.0-beta.1")
    parser.add_argument("--build", default=os.environ.get("CELL_BUILD_NUMBER", "1"))
    parser.add_argument("--signing", default=os.environ.get("CELL_SIGNING", "adhoc"), choices=("adhoc", "developer-id"))
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    try:
        info = metadata(arguments.version, arguments.build, arguments.signing)
        if arguments.command == "metadata":
            print(json.dumps(info, indent=2))
            if os.environ.get("GITHUB_OUTPUT"):
                with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
                    for key, value in info.items():
                        stream.write(f"{key}={str(value).lower() if isinstance(value, bool) else value}\n")
        else:
            output = arguments.output or ROOT / "dist/releases" / info["stem"]
            build(info, output.resolve())
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
