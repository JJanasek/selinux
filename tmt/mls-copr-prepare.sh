#!/bin/bash
# COPR selinux-policy triple → MLS enforcing (prepare_for_mls) + TF SSH/sysadm.
# Env: COPR_REPO, COPR_SELINUX_POLICY_MLS_NVR (or PR_NUMBER / COPR_RELEASE_MATCH).
# Final leg: enforcing MLS, root→sysadm_u, no cloud-init AVCs since boot.
set -eo pipefail

reboot_count="${TMT_REBOOT_COUNT:-0}"

# shellcheck source=/dev/null
source "$TMT_TREE/tmt/prepare_for_mls.sh"

verify_copr_policy_set() {
    local mls_evr policy_evr
    mls_evr=$(rpm -q --qf '%{EVR}' selinux-policy-mls)
    policy_evr=$(rpm -q --qf '%{EVR}' selinux-policy)
    [ "$mls_evr" = "$policy_evr" ] || { echo "FAIL: policy EVR mismatch" >&2; exit 1; }
    if [ -n "${COPR_SELINUX_POLICY_MLS_NVR:-}" ] \
        && ! rpm -q selinux-policy-mls | grep -qF "${COPR_SELINUX_POLICY_MLS_NVR}"; then
        echo "FAIL: expected ${COPR_SELINUX_POLICY_MLS_NVR}" >&2
        exit 1
    fi
}

install_copr_policy_set() {
    local copr_slug copr_repoid_match copr_repoid pinned_mls_nvr suffix arch
    local -a install_nvrs

    if [ -n "${COPR_REPO:-}" ]; then
        copr_slug="${COPR_REPO}"
        copr_repoid_match="${COPR_REPO##*/}"
    else
        copr_repoid_match="fedora-selinux-selinux-policy-${PR_NUMBER:?set PR_NUMBER or COPR_REPO}"
        copr_slug="packit/${copr_repoid_match}"
    fi

    dnf install -y 'dnf-command(copr)' || true
    dnf -y copr enable "${copr_slug}"
    copr_repoid=$(dnf -y repolist --enabled | awk -v p="$copr_repoid_match" '$0 ~ p {print $1; exit}')
    [ -n "$copr_repoid" ] || { echo "FAIL: no repo for ${copr_slug}" >&2; exit 1; }

    if [ -n "${COPR_SELINUX_POLICY_MLS_NVR:-}" ]; then
        pinned_mls_nvr="${COPR_SELINUX_POLICY_MLS_NVR}"
    else
        local candidates
        candidates=$(dnf -y repoquery --repo="$copr_repoid" --qf '%{name}-%{evr}.%{arch}\n' selinux-policy-mls | sort -V)
        if [ -n "${COPR_RELEASE_MATCH:-}" ]; then
            pinned_mls_nvr=$(printf '%s\n' "$candidates" | grep -F "${COPR_RELEASE_MATCH}" | tail -n1)
        else
            pinned_mls_nvr=$(printf '%s\n' "$candidates" | tail -n1)
        fi
    fi
    [ -n "$pinned_mls_nvr" ] || { echo "FAIL: no selinux-policy-mls in ${copr_repoid}" >&2; exit 1; }

    suffix="${pinned_mls_nvr#selinux-policy-mls-}"
    arch="${suffix##*.}"
    suffix="${suffix%."$arch"}"
    install_nvrs=(
        "selinux-policy-${suffix}.${arch}"
        "selinux-policy-devel-${suffix}.${arch}"
        "selinux-policy-mls-${suffix}.${arch}"
    )
    dnf install -y "${install_nvrs[@]}" policycoreutils-python-utils audit
    verify_copr_policy_set
}

# Final reboot leg: guest is MLS enforcing and usable over SSH as sysadm.
verify_mls_ready() {
    local mode policy login_map tmpdir
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
    # ausearch: 0=matches, 1=none, ≥2=error
    set +e
    ausearch -m avc,user_avc -i --input-logs -ts boot >"$tmpdir/avc.txt" 2>/dev/null
    as_rc=$?
    set -e
    if [ "$as_rc" -ge 2 ]; then
        echo "FAIL: ausearch failed (rc=$as_rc)" >&2
        rm -rf "$tmpdir"
        exit 1
    fi
    if grep -Eiq 'cloud_init_t|comm="cloud-init"|comm=cloud-init' "$tmpdir/avc.txt"; then
        echo "FAIL: cloud-init related AVC denials since boot:" >&2
        grep -Ei 'cloud_init_t|comm="cloud-init"|comm=cloud-init' "$tmpdir/avc.txt" >&2 || true
        rm -rf "$tmpdir"
        exit 1
    fi
    rm -rf "$tmpdir"
    verify_copr_policy_set
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
    prepare_for_mls_configure
    sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
    mkdir -p /etc/cloud/cloud.cfg.d
    echo 'ssh_deletekeys: false' > /etc/cloud/cloud.cfg.d/99-preserve-ssh-host-keys.cfg
    cloud-init clean --logs
    prepare_for_mls_reboot
    ;;
1)
    prepare_for_mls_force_relabel
    rm -f /.autorelabel
    systemctl mask selinux-autorelabel.service
    semanage boolean -n -m --on ssh_sysadm_login
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /usr/lib/systemd/system/cloud-init.target /etc/systemd/system/multi-user.target.wants/cloud-init.target
    semodule -DB
    cloud-init clean --logs
    sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
    tmt-reboot -t 1200
    ;;
*)
    verify_mls_ready
    ;;
esac
