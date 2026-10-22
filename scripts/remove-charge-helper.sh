#!/bin/bash
# Cell disables its limit and confirms charging was released before invoking this.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
if [ "$(/usr/bin/id -u)" != 0 ]; then echo 'Administrator authorization is required.' >&2; exit 1; fi
/bin/launchctl bootout system/com.cellapp.charge-helper
/bin/rm -f /Library/LaunchDaemons/com.cellapp.charge-helper.plist
/bin/rm -f /Library/PrivilegedHelperTools/com.cellapp.charge-helper
# Retain the root-owned state and trust record for recovery/reinstallation.
