#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
build_flags=()
# Local release bundles do not need a separate debug-symbol bundle.
if [ "$configuration" = release ]; then build_flags+=(-debug-info-format none); fi
./scripts/swift.sh build -c "$configuration" "${build_flags[@]}"
bin_path="$(./scripts/swift.sh build -c "$configuration" --show-bin-path)"
mkdir -p "$PWD/dist"
staging="$(mktemp -d "$PWD/.build/cell-package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Cell.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/HelperTools"
cp "$bin_path/Cell" "$app/Contents/MacOS/Cell"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$bin_path/CellChargeHelper" "$app/Contents/Library/HelperTools/com.cellapp.charge-helper"
cp Resources/com.cellapp.charge-helper.plist "$app/Contents/Resources/"
cp scripts/install-charge-helper.sh scripts/remove-charge-helper.sh "$app/Contents/Resources/"
codesign --force --sign - --identifier com.cellapp.charge-helper "$app/Contents/Library/HelperTools/com.cellapp.charge-helper"
codesign -d -r- "$app/Contents/Library/HelperTools/com.cellapp.charge-helper" 2>&1 | sed -n 's/^[# ]*designated => //p' > "$app/Contents/Resources/helper-requirement.txt"
if [ ! -s "$app/Contents/Resources/helper-requirement.txt" ]; then
    echo 'Could not extract the helper signing requirement.' >&2; exit 1
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift scripts/make-icon.swift "$PWD/.build/Cell.iconset" "$app/Contents/Resources/Cell.icns"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
codesign --verify --strict -R "=$(cat "$app/Contents/Resources/helper-requirement.txt")" "$app/Contents/Library/HelperTools/com.cellapp.charge-helper"
# Keep mapped executable files intact when updating an app that is still open.
# Rename the completed bundle instead of overwriting its running Mach-O files.
destination="$PWD/dist/Cell.app"
if [ -e "$destination" ]; then mv "$destination" "$staging/Previous.app"; fi
if ! mv "$app" "$destination"; then
    if [ -e "$staging/Previous.app" ]; then mv "$staging/Previous.app" "$destination"; fi
    exit 1
fi
printf 'Built %s\n' "$destination"
