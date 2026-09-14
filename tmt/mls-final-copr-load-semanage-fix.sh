#!/bin/bash
set -eo pipefail

# Load mlssemanageaccess local module after MLS enforcing is up (reboot_count >= 2).
# Diagnostic overlay: proves whether remaining run/main failures are COPR policy
# gaps vs something else. Set LOAD_MLS_SEMANAGE_ACCESS_FIX=0 to skip.

if [ "${LOAD_MLS_SEMANAGE_ACCESS_FIX:-1}" = 0 ]; then
    echo "LOAD_MLS_SEMANAGE_ACCESS_FIX=0: skip guest semanage fix module"
    exit 0
fi

# TMT tracks TMT_REBOOT_COUNT per prepare *step*, not plan-wide. After the COPR
# prepare step finishes its two reboots, this step's counter is still 0 — gate
# on runtime MLS state instead.
reboot_count="${TMT_REBOOT_COUNT:-0}"
mode=$(sestatus | awk -F': *' '/^Current mode:/ {print $2}')
policy=$(sestatus | awk -F': *' '/^Loaded policy name:/ {print $2}')
echo "mlssemanageaccess prepare: TMT_REBOOT_COUNT=${reboot_count} mode=${mode} policy=${policy}"
if [ "$mode" != "enforcing" ] || [ "$policy" != "mls" ]; then
    echo "FAIL: expected enforcing MLS before loading fix, got mode=${mode} policy=${policy}" >&2
    exit 1
fi

if semodule -lfull 2>/dev/null | grep -q '^mlssemanageaccess\b'; then
    echo "mlssemanageaccess already loaded — reinstall to pick up .te changes"
    semodule -r mlssemanageaccess 2>/dev/null || true
fi

fixdir="${TMT_TREE:?}/tmt/mls-semanage-access-fix"
te="${fixdir}/mlssemanageaccess.te"
if [ ! -f "$te" ]; then
    echo "FAIL: missing ${te}" >&2
    exit 1
fi

dnf install -y checkpolicy policycoreutils-devel selinux-policy-devel

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cp "$te" "$work/"
(
    cd "$work"
    checkmodule -M -m -o mlssemanageaccess.mod mlssemanageaccess.te
    semodule_package -o mlssemanageaccess.pp -m mlssemanageaccess.mod
)

echo "Loading mlssemanageaccess on MLS store (COPR base + local overlay)"
semodule -i "$work/mlssemanageaccess.pp"
semodule -lfull | grep -E '^mlssemanageaccess\b' || {
    echo "FAIL: mlssemanageaccess not listed after semodule -i" >&2
    exit 1
}
echo "mlssemanageaccess loaded OK"
