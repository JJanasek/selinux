#!/bin/bash
# Restart all cloud-init stages (like a normal boot), then dump AVCs since boot.
set -eu

echo "=== sestatus ==="
sestatus || true

echo "=== cloud-init unit files ==="
systemctl list-unit-files 'cloud-init*' 'cloud-config*' 'cloud-final*' 'cloud-init-local*' 2>/dev/null || true

echo "=== restart cloud-init services (local -> init -> config -> final) ==="
# Order matches a normal cloud-init boot sequence.
for unit in cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
        echo "--- systemctl restart $unit ---"
        systemctl restart "$unit" || echo "WARN: $unit restart failed (rc=$?)"
        systemctl --no-pager --full status "$unit" || true
    else
        echo "SKIP: $unit not present"
    fi
done

echo "=== ps -eZ | cloud ==="
ps -eZ | grep -i cloud || true

echo "=== ausearch AVC/USER_AVC since boot ==="
ausearch -m avc,user_avc -i --input-logs -ts boot || true
echo "=== end ausearch ==="
