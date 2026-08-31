#!/bin/bash
set -eo pipefail

echo "=== SELinux status ==="
sestatus

echo "=== waiting (up to 120s) for cloud-init to finish ==="
timeout 120 cloud-init status --wait || true

long_status=$(cloud-init status --long) || true
final_status=$(echo "$long_status" | awk -F': ' '/^status:/ {print $2}')
echo "=== cloud-init final status: $final_status ==="

if [ "$final_status" != "done" ]; then
    echo "FAIL: cloud-init did not reach 'done' (got: '$final_status')"
    exit 1
fi

# Confirm cloud-init ran under cloud_init_t via the bootcmd-captured
# id -Z from prepare (cloud-init-main.service is too short-lived to
# catch with ps -eZ after the fact).
context_log=$(cat /var/log/cloud-init-selinux-context.log 2>&1) || true
echo "=== cloud-init's own SELinux context (captured via bootcmd): $context_log ==="
if ! echo "$context_log" | grep -q cloud_init_t; then
    echo "FAIL: cloud-init reported done, but no evidence it ever ran under cloud_init_t"
    exit 1
fi
echo "PASS: cloud-init reached 'done' and ran under cloud_init_t"

# Informational-only tripwire, not part of the pass/fail gate (some
# non-blocking denials are expected even on a fully working boot).
boot_date=$(date -d "$(uptime -s) - 60 seconds" '+%m/%d/%Y' 2>/dev/null || echo today)
boot_time=$(date -d "$(uptime -s) - 60 seconds" '+%H:%M:%S' 2>/dev/null || echo 00:00:00)
# --input-logs: without it, ausearch silently reads stdin instead of the
# real audit log whenever stdin isn't a TTY, returning "<no matches>" /
# exit 0 with no warning.
avc_dump=$(ausearch -m AVC,USER_AVC --input-logs -ts "$boot_date" "$boot_time" 2>/dev/null)
avc_count=$(echo "$avc_dump" | grep -c '^type=AVC\|^type=USER_AVC')
echo "=== AVC/USER_AVC denials this boot: $avc_count (informational only) ==="
[ "$avc_count" -gt 0 ] && echo "$avc_dump"
