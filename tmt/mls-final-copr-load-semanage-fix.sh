#!/bin/bash
set -eo pipefail

# Build and load mlssemanageaccess on enforcing MLS (COPR base + local overlay).
# Module build deps (selinux-policy-devel) must be installed in prepare *before*
# the pinned COPR selinux-policy-mls — see mls-final-copr-prepare.sh case 0.
# Set LOAD_MLS_SEMANAGE_ACCESS_FIX=0 to skip (COPR-only runs).

if [ "${LOAD_MLS_SEMANAGE_ACCESS_FIX:-1}" = 0 ]; then
    echo "LOAD_MLS_SEMANAGE_ACCESS_FIX=0: skip guest semanage fix module"
    exit 0
fi

mode=$(sestatus | awk -F': *' '/^Current mode:/ {print $2}')
policy=$(sestatus | awk -F': *' '/^Loaded policy name:/ {print $2}')
reboot_count="${TMT_REBOOT_COUNT:-0}"
echo "mlssemanageaccess: TMT_REBOOT_COUNT=${reboot_count} mode=${mode} policy=${policy}"
if [ "$mode" != "enforcing" ] || [ "$policy" != "mls" ]; then
    echo "FAIL: expected enforcing MLS before loading fix, got mode=${mode} policy=${policy}" >&2
    exit 1
fi

if [ -n "${COPR_SELINUX_POLICY_MLS_NVR:-}" ]; then
    if ! rpm -q selinux-policy-mls | grep -qF "${COPR_SELINUX_POLICY_MLS_NVR}"; then
        echo "FAIL: selinux-policy-mls no longer pinned to ${COPR_SELINUX_POLICY_MLS_NVR}" >&2
        rpm -q selinux-policy-mls >&2
        exit 1
    fi
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
if [ ! -f /usr/share/selinux/devel/Makefile ]; then
    echo "FAIL: /usr/share/selinux/devel/Makefile missing — install selinux-policy-devel before COPR in prepare" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$te" "$work/"
(
    cd "$work"
    make -f /usr/share/selinux/devel/Makefile mlssemanageaccess.pp
)

echo "Loading mlssemanageaccess on MLS store (COPR base + local overlay)"
semodule -i "$work/mlssemanageaccess.pp"
semodule -lfull | grep -E '^mlssemanageaccess\b' || {
    echo "FAIL: mlssemanageaccess not listed after semodule -i" >&2
    exit 1
}
echo "mlssemanageaccess loaded OK; $(rpm -q selinux-policy-mls)"
