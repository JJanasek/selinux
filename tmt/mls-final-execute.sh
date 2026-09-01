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
# ausearch itself also exits 1 on "nothing found" (see EXIT STATUS in
# ausearch(8)), which combined with pipefail would abort this whole script
# right here whenever the boot is actually AVC-clean -- exactly the case
# this check exists to confirm. || true guards against that, same as the
# grep -c below.
avc_dump=$(ausearch -m AVC,USER_AVC --input-logs -ts "$boot_date" "$boot_time" 2>/dev/null || true)
avc_count=$(echo "$avc_dump" | { grep -c '^type=AVC\|^type=USER_AVC' || true; })
echo "=== AVC/USER_AVC denials this boot: $avc_count (informational only) ==="
[ "$avc_count" -gt 0 ] && echo "$avc_dump"

# Simpler regression sanity check requested alongside the boot-time-based
# dump above: '-ts recent' means "last 10 wall-clock minutes", not "since
# boot", so it must run here, right after boot, to actually cover the boot.
# Also re-check the stdin-swallowing bug (see boot-time dump's comment
# above) independently for '-ts recent', since it takes a different
# ausearch code path and was not verified against that bug before.
recent_dump_no_input_logs=$(ausearch -m AVC,USER_AVC -ts recent 2>/dev/null || true)
recent_count_no_input_logs=$(echo "$recent_dump_no_input_logs" | { grep -c '^type=AVC\|^type=USER_AVC' || true; })
recent_dump=$(ausearch -m AVC,USER_AVC --input-logs -ts recent 2>/dev/null || true)
recent_count=$(echo "$recent_dump" | { grep -c '^type=AVC\|^type=USER_AVC' || true; })
echo "=== ausearch -ts recent, no --input-logs: $recent_count_no_input_logs AVC/USER_AVC ==="
echo "=== ausearch -ts recent, with --input-logs: $recent_count AVC/USER_AVC (informational only) ==="
if [ "$recent_count_no_input_logs" -ne "$recent_count" ]; then
    echo "WARNING: '-ts recent' result differs with/without --input-logs -- same stdin bug as '-ts <date> <time>'"
fi
if [ "$recent_count" -ne "$avc_count" ]; then
    echo "WARNING: '-ts recent' ($recent_count) disagrees with the boot-time-based check above ($avc_count)"
fi
[ "$recent_count" -gt 0 ] && echo "$recent_dump"
