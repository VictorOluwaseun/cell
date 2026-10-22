#!/bin/bash
# Ephemeral GitHub-hosted runner only. No credentials are written into release files.
set -euo pipefail
umask 077
signing_dir="${RUNNER_TEMP:?This script is for GitHub Actions}/cell-signing"
case "${1:-}" in
prepare)
    for name in MACOS_APPLICATION_CERTIFICATE MACOS_INSTALLER_CERTIFICATE MACOS_CERTIFICATE_PASSWORD NOTARY_KEY; do
        if [ -z "${!name:-}" ]; then echo "Missing GitHub Actions secret: $name" >&2; exit 1; fi
    done
    mkdir -m 700 "$signing_dir"
    security list-keychains -d user > "$signing_dir/search-list"
    python3 - "$signing_dir" <<'PY'
import base64, os, pathlib, sys
directory = pathlib.Path(sys.argv[1])
for secret, name in [('MACOS_APPLICATION_CERTIFICATE', 'application.p12'), ('MACOS_INSTALLER_CERTIFICATE', 'installer.p12')]:
    (directory / name).write_bytes(base64.b64decode(os.environ[secret], validate=True))
(directory / 'AuthKey.p8').write_text(os.environ['NOTARY_KEY'])
PY
    cell_keychain_password="$(openssl rand -hex 32)"
    printf '::add-mask::%s\n' "$cell_keychain_password"
    keychain="$signing_dir/release.keychain-db"
    security create-keychain -p "$cell_keychain_password" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$cell_keychain_password" "$keychain"
    python3 - "$keychain" "$signing_dir/search-list" <<'PY'
import pathlib, shlex, subprocess, sys
previous = shlex.split(pathlib.Path(sys.argv[2]).read_text())
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', sys.argv[1], *previous], check=True)
PY
    for certificate in application installer; do
        security import "$signing_dir/$certificate.p12" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/productbuild -T /usr/bin/productsign >/dev/null
    done
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$cell_keychain_password" "$keychain" >/dev/null
    rm -f "$signing_dir/application.p12" "$signing_dir/installer.p12"
    printf 'CELL_SIGNING_KEYCHAIN=%s\nCELL_NOTARY_KEY=%s\n' "$keychain" "$signing_dir/AuthKey.p8" >> "${GITHUB_ENV:?}"
    ;;
cleanup)
    if [ -f "$signing_dir/search-list" ]; then
        python3 - "$signing_dir/search-list" <<'PY'
import pathlib, shlex, subprocess, sys
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *shlex.split(pathlib.Path(sys.argv[1]).read_text())], check=True)
PY
    fi
    if [ -f "$signing_dir/release.keychain-db" ]; then security delete-keychain "$signing_dir/release.keychain-db"; fi
    if [ -d "$signing_dir" ]; then rm -rf "$signing_dir"; fi
    ;;
*) echo 'Use prepare or cleanup.' >&2; exit 1;;
esac
