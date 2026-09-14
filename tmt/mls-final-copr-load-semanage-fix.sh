#!/bin/bash
set -eo pipefail

# Build and load mlssemanageaccess into the MLS module store.
# MLS_SEMANAGE_FIX_PHASE:
#   configure — after prepare_for_mls_configure, before first reboot (semodule -n -i)
#   verify    — after MLS enforcing (default when called from prepare case *)
#
# selinux-policy-devel must be installed before pinned COPR in prepare case 0.
# Set LOAD_MLS_SEMANAGE_ACCESS_FIX=0 to skip.

if [ "${LOAD_MLS_SEMANAGE_ACCESS_FIX:-1}" = 0 ]; then
    echo "LOAD_MLS_SEMANAGE_ACCESS_FIX=0: skip guest semanage fix module"
    exit 0
fi

phase="${MLS_SEMANAGE_FIX_PHASE:-verify}"
reboot_count="${TMT_REBOOT_COUNT:-0}"
mode=$(sestatus | awk -F': *' '/^Current mode:/ {print $2}')
policy=$(sestatus | awk -F': *' '/^Loaded policy name:/ {print $2}')
echo "mlssemanageaccess phase=${phase} TMT_REBOOT_COUNT=${reboot_count} mode=${mode} policy=${policy}"

if [ "$phase" = verify ]; then
    if [ "$mode" != "enforcing" ] || [ "$policy" != "mls" ]; then
        echo "FAIL: expected enforcing MLS, got mode=${mode} policy=${policy}" >&2
        exit 1
    fi
    if [ -n "${COPR_SELINUX_POLICY_MLS_NVR:-}" ]; then
        if ! rpm -q selinux-policy-mls | grep -qF "${COPR_SELINUX_POLICY_MLS_NVR}"; then
            echo "FAIL: selinux-policy-mls not ${COPR_SELINUX_POLICY_MLS_NVR}" >&2
            rpm -q selinux-policy-mls >&2
            exit 1
        fi
    fi
    if semodule -l | grep -qE '^mlssemanageaccess\b'; then
        echo "mlssemanageaccess present in module store; $(rpm -q selinux-policy-mls)"
        exit 0
    fi
    echo "FAIL: mlssemanageaccess missing after MLS reboots (configure phase should have run semodule -n -i)" >&2
    semodule -l | grep -i semanage || true
    exit 1
fi

if [ "$phase" != configure ]; then
    echo "FAIL: unknown MLS_SEMANAGE_FIX_PHASE=${phase}" >&2
    exit 1
fi

if [ -n "${COPR_SELINUX_POLICY_MLS_NVR:-}" ]; then
    if ! rpm -q selinux-policy-mls | grep -qF "${COPR_SELINUX_POLICY_MLS_NVR}"; then
        echo "FAIL: selinux-policy-mls not ${COPR_SELINUX_POLICY_MLS_NVR}" >&2
        rpm -q selinux-policy-mls >&2
        exit 1
    fi
fi

fixdir="${TMT_TREE:?}/tmt/mls-semanage-access-fix"
te="${fixdir}/mlssemanageaccess.te"
if [ ! -f "$te" ]; then
    echo "FAIL: missing ${te}" >&2
    exit 1
fi
if [ ! -f /usr/share/selinux/devel/Makefile ]; then
    echo "FAIL: /usr/share/selinux/devel/Makefile missing — install selinux-policy-devel before COPR" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$te" "$work/"
(
    cd "$work"
    make -f /usr/share/selinux/devel/Makefile mlssemanageaccess.pp
)

echo "Installing mlssemanageaccess into next MLS policy (semodule -n -i)"
semodule -n -i "$work/mlssemanageaccess.pp"
semodule -l | grep -E '^mlssemanageaccess\b' || {
    echo "FAIL: mlssemanageaccess not listed after semodule -n -i" >&2
    exit 1
}
echo "mlssemanageaccess staged OK; $(rpm -q selinux-policy-mls)"
