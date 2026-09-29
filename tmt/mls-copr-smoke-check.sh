#!/bin/bash
# AC1 gate: MLS enforcing + no cloud-init related AVC denials.
set -eu

mode=$(sestatus | awk -F': *' '/^Current mode:/ {print $2}')
policy=$(sestatus | awk -F': *' '/^Loaded policy name:/ {print $2}')
echo "SELinux: mode=${mode} policy=${policy}"
[ "$mode" = enforcing ] || { echo "FAIL: not enforcing" >&2; exit 1; }
[ "$policy" = mls ] || { echo "FAIL: policy is not mls" >&2; exit 1; }

login_map=$(semanage login -l | awk '$1 == "root" {print; exit}')
echo "root login mapping: ${login_map}"
echo "$login_map" | grep -q sysadm_u || {
    echo "FAIL: root is not mapped to sysadm_u" >&2
    exit 1
}

# Prefer journal evidence that cloud-init finished under MLS boot.
if systemctl is-active --quiet cloud-init.service 2>/dev/null \
    || systemctl is-active --quiet cloud-final.service 2>/dev/null \
    || [ -f /run/cloud-init/result.json ]; then
    echo "cloud-init: present (service or result.json)"
else
    echo "WARN: cloud-init status unclear; still checking AVC log"
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
# --input-logs: do not consume stdin (tmt may attach a pipe).
ausearch -m avc,user_avc -i --input-logs -ts boot >"$tmpdir/avc.txt" 2>/dev/null || true

# Match cloud-init domain / comm; ignore empty / "no matches".
if grep -Eiq 'cloud_init_t|comm="cloud-init"|comm=cloud-init' "$tmpdir/avc.txt"; then
    echo "FAIL: cloud-init related AVC denials since boot:" >&2
    grep -Ei 'cloud_init_t|comm="cloud-init"|comm=cloud-init' "$tmpdir/avc.txt" >&2 || true
    exit 1
fi

echo "PASS: MLS enforcing, root→sysadm_u, no cloud-init AVCs since boot"
