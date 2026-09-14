#!/bin/bash
# Full AVC / audit / dmesg capture for MLS COPR debugging (always exit 0).
set -x

echo "=== rpm: selinux-policy-mls / COPR provenance ==="
rpm -q selinux-policy selinux-policy-mls selinux-policy-targeted 2>&1 || true
echo "=== semodule: loaded modules (grep semanage/mls) ==="
semodule -lfull 2>&1 | grep -iE 'mlssemanage|semanage|checkpolicy' || true

echo "=== auditd status ==="
systemctl is-active auditd 2>&1 || true
auditctl -s 2>&1 || true

echo "=== FULL dmesg (entire kernel ring buffer) ==="
dmesg 2>&1 || true

echo "=== journalctl -k -b (full kernel journal this boot) ==="
journalctl -k -b --no-pager 2>&1 || true

echo "=== /var/log/audit/audit.log (full file if present) ==="
if [ -f /var/log/audit/audit.log ]; then
    wc -c /var/log/audit/audit.log 2>&1 || true
    cat /var/log/audit/audit.log 2>&1 || true
else
    echo "(no /var/log/audit/audit.log)"
fi

echo "=== ausearch AVC,USER_AVC,SELINUX_ERR --input-logs -ts boot -i ==="
ausearch -m AVC,USER_AVC,SELINUX_ERR --input-logs -ts boot -i 2>&1 || true

echo "=== ausearch ALL --input-logs -ts recent -i (last 10m wall clock) ==="
ausearch --input-logs -ts recent -i 2>&1 || true

echo "=== ausearch semodule/semanage/test_policy (any message type) ==="
ausearch --input-logs -ts boot -i 2>&1 | grep -iE 'semodule|semanage|test_policy|checkpolicy' || true

exit 0
