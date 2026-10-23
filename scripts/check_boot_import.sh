#!/bin/sh
# zfs-ha: boot-time import prevention checker.
#
# Verifies the HA pool will NOT be auto-imported at boot. Run on each node.
# Usage: check_boot_import.sh <POOL_NAME>
set -eu

POOL="${1:?usage: $0 <POOL>}"
FAIL=0

echo "== boot-import prevention check for pool '$POOL' =="

# 1. pool cachefile must not be the default one
CF=$(zpool get -H -o value cachefile "$POOL" 2>/dev/null || echo "-")
echo "pool cachefile: $CF"
if [ "$CF" = "/etc/zfs/zpool.cachefile" ] || [ "$CF" = "-" ]; then
    echo "FAIL: pool uses the default cachefile (boot auto-import will grab it)"
    FAIL=1
fi

# 2. default cachefile must not mention the pool
if [ -f /etc/zfs/zpool.cachefile ] && grep -q "$POOL" /etc/zfs/zpool.cachefile 2>/dev/null; then
    echo "FAIL: $POOL appears in /etc/zfs/zpool.cachefile"
    FAIL=1
fi

# 3. scan-based import must be off
if systemctl is-enabled zfs-import-scan.service >/dev/null 2>&1; then
    echo "FAIL: zfs-import-scan.service is enabled (will scan and import everything)"
    FAIL=1
fi

# 4. initramfs must not import
if [ -f /etc/default/zfs ]; then
    if grep -qE "^ZFS_INITRD_IMPORT.*all" /etc/default/zfs 2>/dev/null; then
        echo "FAIL: initramfs set to import all pools"
        FAIL=1
    fi
fi

# 5. pacemaker should be the thing that starts the pool
if ! systemctl is-enabled pacemaker >/dev/null 2>&1; then
    echo "WARN: pacemaker not enabled - nothing will manage the pool at boot"
fi

[ "$FAIL" = "0" ] && echo "PASS: '$POOL' will not be auto-imported at boot"
exit "$FAIL"
