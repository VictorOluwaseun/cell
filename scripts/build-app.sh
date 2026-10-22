#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'Use debug or release.' >&2; exit 1;; esac
read -r -a architectures <<< "${CELL_ARCHS:-$(uname -m)}"
if [ "${#architectures[@]}" -lt 1 ] || [ "${#architectures[@]}" -gt 2 ]; then echo 'Choose arm64, x86_64, or both.' >&2; exit 1; fi
for architecture in "${architectures[@]}"; do
    case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1;; esac
done
if [ "${#architectures[@]}" = 2 ] && [ "${architectures[0]}" = "${architectures[1]}" ]; then echo 'Duplicate architecture.' >&2; exit 1; fi
signing_identity="${CELL_SIGNING_IDENTITY:--}"
signing_flags=(--timestamp=none)
if [ "$signing_identity" != - ]; then
    case "$signing_identity" in 'Developer ID Application: '*) ;; *) echo 'Use a Developer ID Application identity.' >&2; exit 1;; esac
    signing_flags=(--options runtime --timestamp)
    if [ -n "${CELL_SIGNING_KEYCHAIN:-}" ]; then signing_flags+=(--keychain "$CELL_SIGNING_KEYCHAIN"); fi
fi
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
export MACOSX_DEPLOYMENT_TARGET="$minimum_os"
build_flags=(-debug-info-format dwarf)
# Local release bundles do not need a separate debug-symbol bundle.
if [ "$configuration" = release ]; then build_flags=(-debug-info-format none); fi
app_binaries=(); helper_binaries=()
for architecture in "${architectures[@]}"; do
    architecture_flags=(--triple "$architecture-apple-macosx$minimum_os" --scratch-path ".build/$configuration-$architecture")
    ./scripts/swift.sh build -c "$configuration" "${architecture_flags[@]}" "${build_flags[@]}"
    bin_path="$(./scripts/swift.sh build -c "$configuration" "${architecture_flags[@]}" --show-bin-path)"
    app_binaries+=("$bin_path/Cell"); helper_binaries+=("$bin_path/CellChargeHelper")
done
mkdir -p "$PWD/dist"
staging="$(mktemp -d "$PWD/.build/cell-package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Cell.app"
helper="$app/Contents/Library/HelperTools/com.cellapp.charge-helper"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/HelperTools"
lipo -create "${app_binaries[@]}" -output "$app/Contents/MacOS/Cell"
lipo -create "${helper_binaries[@]}" -output "$helper"
for architecture in "${architectures[@]}"; do
    lipo "$app/Contents/MacOS/Cell" -verify_arch "$architecture"
    lipo "$helper" -verify_arch "$architecture"
done
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ -n "${CELL_VERSION:-}" ]; then
    /usr/bin/plutil -replace CFBundleShortVersionString -string "$CELL_VERSION" "$app/Contents/Info.plist"
    /usr/bin/plutil -insert CellReleaseVersion -string "${CELL_RELEASE_VERSION:-$CELL_VERSION}" "$app/Contents/Info.plist"
fi
if [ -n "${CELL_BUILD_NUMBER:-}" ]; then
    /usr/bin/plutil -replace CFBundleVersion -string "$CELL_BUILD_NUMBER" "$app/Contents/Info.plist"
fi
cp Resources/com.cellapp.charge-helper.plist "$app/Contents/Resources/"
cp scripts/install-charge-helper.sh scripts/remove-charge-helper.sh "$app/Contents/Resources/"
codesign --force --sign "$signing_identity" "${signing_flags[@]}" --identifier com.cellapp.charge-helper "$helper"
# An ad-hoc universal binary has a different CDHash per architecture. Pin both.
requirements=()
for architecture in "${architectures[@]}"; do
    requirement="$(codesign -d --arch "$architecture" -r- "$helper" 2>&1 | sed -n 's/^[# ]*designated => //p')"
    if [ -z "$requirement" ]; then echo 'Could not extract the helper signing requirement.' >&2; exit 1; fi
    requirements+=("($requirement)")
done
printf '%s' "${requirements[0]}" > "$app/Contents/Resources/helper-requirement.txt"
if [ "${#requirements[@]}" = 2 ]; then printf ' or %s' "${requirements[1]}" >> "$app/Contents/Resources/helper-requirement.txt"; fi
printf '\n' >> "$app/Contents/Resources/helper-requirement.txt"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift scripts/make-icon.swift "$PWD/.build/Cell.iconset" "$app/Contents/Resources/Cell.icns"
# Sign inside out without rewriting the helper's signature.
codesign --force --sign "$signing_identity" "${signing_flags[@]}" "$app"
codesign --verify --deep --strict --all-architectures "$app"
codesign --verify --strict --all-architectures -R "=$(cat "$app/Contents/Resources/helper-requirement.txt")" "$helper"
# Keep mapped executable files intact when updating an app that is still open.
# Rename the completed bundle instead of overwriting its running Mach-O files.
destination="${CELL_APP_OUTPUT:-$PWD/dist/Cell.app}"
mkdir -p "$(dirname "$destination")"
if [ -e "$destination" ]; then mv "$destination" "$staging/Previous.app"; fi
if ! mv "$app" "$destination"; then
    if [ -e "$staging/Previous.app" ]; then mv "$staging/Previous.app" "$destination"; fi
    exit 1
fi
printf 'Built %s\n' "$destination"
