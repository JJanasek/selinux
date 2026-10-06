#!/bin/bash
# PASS if MLS is permissive and ausearch finds no AVC/SELINUX_ERR since boot.
set -eu

echo "=== sestatus ==="
sestatus || true

mode=$(sestatus | awk -F': *' '/^Current mode:/ {print $2}')
policy=$(sestatus | awk -F': *' '/^Loaded policy name:/ {print $2}')
[ "$mode" = permissive ] && [ "$policy" = mls ] || {
    echo "FAIL: expected permissive MLS (got mode=${mode} policy=${policy})" >&2
    exit 1
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# ausearch: 0=matches, 1=none, >=2=error
set +e
ausearch -m avc,user_avc,selinux_err,user_selinux_err -i --input-logs -ts boot \
    >"$tmpdir/avc.txt" 2>/dev/null
as_rc=$?
set -e

if [ "$as_rc" -ge 2 ]; then
    echo "FAIL: ausearch failed (rc=$as_rc)" >&2
    exit 1
fi

echo "=== ausearch AVC/USER_AVC/SELINUX_ERR since boot ==="
if [ -s "$tmpdir/avc.txt" ]; then
    cat "$tmpdir/avc.txt"
else
    echo "(no matches)"
fi
echo "=== end ausearch ==="

if [ "$as_rc" -eq 0 ]; then
    echo "FAIL: AVC or SELINUX_ERR found since boot" >&2
    exit 1
fi

echo "PASS: no AVC/SELINUX_ERR since boot"
