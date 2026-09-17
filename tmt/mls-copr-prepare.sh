#!/bin/bash
# COPR selinux-policy triple, MLS enforcing, sysadm_t + TF SSH. Env: COPR_REPO, COPR_SELINUX_POLICY_MLS_NVR.
set -eo pipefail

reboot_count="${TMT_REBOOT_COUNT:-0}"

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

case "$reboot_count" in
0)
    [ "${STS_KERNEL:-}" = local ] && dnf install -y kernel-devel
    if [ "${SKIP_COPR_INSTALL:-0}" != 1 ]; then
        install_copr_policy_set
    else
        dnf install -y policycoreutils-python-utils audit
        verify_copr_policy_set
    fi
    sed -i 's/^SELINUXTYPE=.*/SELINUXTYPE=mls/' /etc/selinux/config
    semanage login -N -m -s sysadm_u root
    touch /.autorelabel
    sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
    mkdir -p /etc/cloud/cloud.cfg.d
    echo 'ssh_deletekeys: false' > /etc/cloud/cloud.cfg.d/99-preserve-ssh-host-keys.cfg
    cloud-init clean --logs
    tmt-reboot -t 1200
    ;;
1)
    restorecon -RF / 2>&1 | tail -50
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
    mode=$(sestatus | awk -F': *' '/^Current mode:/ {print $2}')
    policy=$(sestatus | awk -F': *' '/^Loaded policy name:/ {print $2}')
    [ "$mode" = enforcing ] && [ "$policy" = mls ] || {
        echo "FAIL: expected enforcing MLS" >&2
        exit 1
    }
    verify_copr_policy_set
    ;;
esac
