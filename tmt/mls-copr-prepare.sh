#!/bin/bash
# Install COPR selinux-policy-mls, switch guest to MLS, verify ready for tests.
# Env: COPR_REPO (required unless SKIP_COPR_INSTALL=1).
# Optional: COPR_SELINUX_POLICY_MLS_NVR to pin an exact MLS package NVR.
set -eo pipefail

reboot_count="${TMT_REBOOT_COUNT:-0}"

# shellcheck source=/dev/null
source "$TMT_TREE/tmt/prepare_for_mls.sh"

verify_copr_policy_set() {
    local mls_evr policy_evr
    mls_evr=$(rpm -q --qf '%{EVR}' selinux-policy-mls)
    policy_evr=$(rpm -q --qf '%{EVR}' selinux-policy)
    [ "$mls_evr" = "$policy_evr" ] || {
        echo "FAIL: selinux-policy and selinux-policy-mls EVR mismatch" >&2
        exit 1
    }
    if [ -n "${COPR_SELINUX_POLICY_MLS_NVR:-}" ] \
        && ! rpm -q selinux-policy-mls | grep -qF "${COPR_SELINUX_POLICY_MLS_NVR}"; then
        echo "FAIL: expected ${COPR_SELINUX_POLICY_MLS_NVR}" >&2
        exit 1
    fi
}

install_copr_policy_set() {
    local copr_slug="${COPR_REPO:?set COPR_REPO}"
    local pinned_mls_nvr suffix arch
    local -a pkgs

    dnf install -y 'dnf-command(copr)' || true
    dnf -y copr enable "${copr_slug}"

    if [ -n "${COPR_SELINUX_POLICY_MLS_NVR:-}" ]; then
        pinned_mls_nvr="${COPR_SELINUX_POLICY_MLS_NVR}"
        suffix="${pinned_mls_nvr#selinux-policy-mls-}"
        arch="${suffix##*.}"
        suffix="${suffix%."$arch"}"
        pkgs=(
            "selinux-policy-${suffix}.${arch}"
            "selinux-policy-devel-${suffix}.${arch}"
            "selinux-policy-mls-${suffix}.${arch}"
        )
    else
        pkgs=(selinux-policy selinux-policy-devel selinux-policy-mls)
    fi

    dnf install -y "${pkgs[@]}" policycoreutils-python-utils audit
    verify_copr_policy_set
}

# After the enforcing reboot: MLS enforcing, root is sysadm_u, no cloud-init AVCs.
verify_mls_ready() {
    local mode policy login_map tmpdir as_rc
    mode=$(sestatus | awk -F': *' '/^Current mode:/ {print $2}')
    policy=$(sestatus | awk -F': *' '/^Loaded policy name:/ {print $2}')
    [ "$mode" = enforcing ] && [ "$policy" = mls ] || {
        echo "FAIL: expected enforcing MLS (got mode=${mode} policy=${policy})" >&2
        exit 1
    }
    login_map=$(semanage login -l | awk '$1 == "root" {print; exit}')
    echo "$login_map" | grep -q sysadm_u || {
        echo "FAIL: root not mapped to sysadm_u (${login_map})" >&2
        exit 1
    }
    tmpdir=$(mktemp -d)
    # --input-logs: do not consume stdin (tmt may attach a pipe).
    # ausearch: 0=matches, 1=none, >=2=error
    set +e
    ausearch -m avc,user_avc -i --input-logs -ts boot >"$tmpdir/avc.txt" 2>/dev/null
    as_rc=$?
    set -e
    if [ "$as_rc" -ge 2 ]; then
        echo "FAIL: ausearch failed (rc=$as_rc)" >&2
        rm -rf "$tmpdir"
        exit 1
    fi
    if grep -Eiq 'cloud_init_t|comm="cloud-init"' "$tmpdir/avc.txt"; then
        echo "FAIL: cloud-init related AVC denials since boot:" >&2
        grep -Ei 'cloud_init_t|comm="cloud-init"' "$tmpdir/avc.txt" >&2 || true
        rm -rf "$tmpdir"
        exit 1
    fi
    rm -rf "$tmpdir"
    verify_copr_policy_set
}

# Preserve SSH host keys: Testing Farm reconnects after reboot; cloud-init
# must not rotate keys or SSH verification fails.
preserve_ssh_host_keys() {
    mkdir -p /etc/cloud/cloud.cfg.d
    echo 'ssh_deletekeys: false' > /etc/cloud/cloud.cfg.d/99-preserve-ssh-host-keys.cfg
}

case "$reboot_count" in
0)
    if [ "${STS_KERNEL:-}" = local ]; then
        dnf install -y kernel-devel
    fi
    if [ "${SKIP_COPR_INSTALL:-0}" != 1 ]; then
        install_copr_policy_set
    else
        dnf install -y policycoreutils-python-utils audit
        verify_copr_policy_set
    fi
    preserve_ssh_host_keys
    prepare_for_mls_configure
    prepare_for_mls_reboot
    ;;
1)
    # Autorelabel from fixfiles -F onboot has finished; switch to enforcing.
    prepare_for_mls_set_enforcing
    prepare_for_mls_reboot
    ;;
*)
    verify_mls_ready
    ;;
esac
