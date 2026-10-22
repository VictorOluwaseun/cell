#!/bin/bash
# Runs once, only after macOS administrator authorization. No network or sudoers changes.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077
if [ "$(/usr/bin/id -u)" != 0 ]; then echo 'Administrator authorization is required.' >&2; exit 1; fi
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
app="$(cd "$script_dir/../.." && pwd -P)"
helper="$app/Contents/Library/HelperTools/com.cellapp.charge-helper"
daemon_source="$app/Contents/Resources/com.cellapp.charge-helper.plist"
trust_dir='/Library/Application Support/CellChargeHelper'
helper_target='/Library/PrivilegedHelperTools/com.cellapp.charge-helper'
daemon_target='/Library/LaunchDaemons/com.cellapp.charge-helper.plist'
console_uid="$(/usr/bin/stat -f '%u' /dev/console)"
if [ "$console_uid" -le 0 ]; then echo 'Sign in to a Mac user account before installing.' >&2; exit 1; fi
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/codesign --verify --strict "$helper"
requirement="$(/usr/bin/codesign -d -r- "$app" 2>&1 | /usr/bin/sed -n 's/^[# ]*designated => //p')"
if [ -z "$requirement" ]; then echo 'Cell has no valid signing identity.' >&2; exit 1; fi
# Refuse pre-existing writable or symlinked trust locations.
if [ -L "$trust_dir" ]; then echo 'Unsafe helper configuration path.' >&2; exit 1; fi
if [ ! -e "$trust_dir" ]; then /bin/mkdir -m 700 "$trust_dir"; fi
if [ ! -d "$trust_dir" ] || [ "$(/usr/bin/stat -f '%u:%Lp' "$trust_dir")" != '0:700' ]; then
    echo 'The helper configuration directory must be root-owned with mode 700.' >&2; exit 1
fi
if [ -e "$trust_dir/client-trust.plist" ]; then
    old_uid="$(/usr/libexec/PlistBuddy -c 'Print :uid' "$trust_dir/client-trust.plist")"
    if [ "$old_uid" != "$console_uid" ]; then echo 'The charging helper belongs to another Mac user.' >&2; exit 1; fi
fi
stage="$(/usr/bin/mktemp -d "$trust_dir/install.XXXXXX")"
trap '/bin/rm -rf "$stage"' EXIT
/usr/bin/install -o root -g wheel -m 755 "$helper" "$stage/helper"
/usr/bin/install -o root -g wheel -m 644 "$daemon_source" "$stage/daemon.plist"
/usr/bin/codesign --verify --strict "$stage/helper"
/usr/bin/plutil -lint "$stage/daemon.plist" >/dev/null
# Use plutil for proper escaping of the designated requirement.
/usr/bin/plutil -create xml1 "$stage/trust.plist"
/usr/bin/plutil -insert requirement -string "$requirement" "$stage/trust.plist"
/usr/bin/plutil -insert uid -integer "$console_uid" "$stage/trust.plist"
/bin/chmod 600 "$stage/trust.plist"
/bin/launchctl bootout system/com.cellapp.charge-helper 2>/dev/null || true
/bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons
/bin/mv -f "$stage/helper" "$helper_target"
/bin/mv -f "$stage/daemon.plist" "$daemon_target"
/bin/mv -f "$stage/trust.plist" "$trust_dir/client-trust.plist"
/bin/launchctl bootstrap system "$daemon_target"
