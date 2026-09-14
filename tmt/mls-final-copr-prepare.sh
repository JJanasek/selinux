#!/bin/bash
set -eo pipefail

# MLS prepare for COPR-validated selinux-policy PRs (mls-final-copr-test.fmf).
# Install selinux-policy-mls from COPR (Packit PR or fork COPR_REPO), then MLS
# switch and two reboots. Set SKIP_COPR_INSTALL=1 when Testing Farm already
# installed the build via --fedora-copr-build.
reboot_count="${TMT_REBOOT_COUNT:-0}"

verify_copr_mls_pin() {
    if [ -n "${COPR_SELINUX_POLICY_MLS_NVR:-}" ]; then
        if ! rpm -q selinux-policy-mls | grep -qF "${COPR_SELINUX_POLICY_MLS_NVR}"; then
            echo "FAIL: selinux-policy-mls is not ${COPR_SELINUX_POLICY_MLS_NVR}" >&2
            rpm -q selinux-policy-mls selinux-policy selinux-policy-devel >&2
            exit 1
        fi
    fi
}

case "$reboot_count" in
0)
    # Devel headers/Makefile before COPR: installing selinux-policy-devel after
    # the pinned COPR MLS on TF downgrades policy (testing-farm-tag-repository).
    dnf install -y checkpolicy policycoreutils-devel selinux-policy-devel

    if [ "${SKIP_COPR_INSTALL:-0}" != 1 ]; then
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
        if [ -z "$copr_repoid" ]; then
            echo "FAIL: no enabled repo for ${copr_slug}" >&2
            exit 1
        fi

        if [ -n "${COPR_SELINUX_POLICY_MLS_NVR:-}" ]; then
            pinned_nvr="${COPR_SELINUX_POLICY_MLS_NVR}"
        else
            candidates=$(dnf -y repoquery --repo="$copr_repoid" --qf '%{name}-%{evr}.%{arch}\n' selinux-policy-mls | sort -V)
            if [ -n "${COPR_RELEASE_MATCH:-}" ]; then
                pinned_nvr=$(printf '%s\n' "$candidates" | grep -F "${COPR_RELEASE_MATCH}" | tail -n1)
                if [ -z "$pinned_nvr" ]; then
                    echo "FAIL: no selinux-policy-mls matching COPR_RELEASE_MATCH=${COPR_RELEASE_MATCH} in ${copr_repoid}" >&2
                    printf '%s\n' "$candidates" >&2
                    exit 1
                fi
            else
                pinned_nvr=$(printf '%s\n' "$candidates" | tail -n1)
            fi
        fi
        if [ -z "$pinned_nvr" ]; then
            echo "FAIL: no selinux-policy-mls in repo ${copr_repoid}" >&2
            exit 1
        fi
        echo "Installing COPR build: ${pinned_nvr}"
        dnf install -y "$pinned_nvr" policycoreutils-python-utils audit

        echo "COPR provenance: $(rpm -q selinux-policy-mls selinux-policy 2>/dev/null || true)"
        if [ -n "${PR_NUMBER:-}" ] && ! rpm -q selinux-policy-mls | grep -qF ".pr${PR_NUMBER}."; then
            echo "FAIL: selinux-policy-mls is not from PR #${PR_NUMBER} COPR" >&2
            rpm -q selinux-policy-mls >&2
            exit 1
        fi
        if [ -n "${COPR_RELEASE_MATCH:-}" ] && ! rpm -q selinux-policy-mls | grep -qF "${COPR_RELEASE_MATCH}"; then
            echo "FAIL: installed selinux-policy-mls does not match COPR_RELEASE_MATCH=${COPR_RELEASE_MATCH}" >&2
            rpm -q selinux-policy-mls >&2
            exit 1
        fi
        verify_copr_mls_pin
    else
        echo "SKIP_COPR_INSTALL=1: using selinux-policy-mls already on guest: $(rpm -q selinux-policy-mls)"
        dnf install -y policycoreutils-python-utils audit
        verify_copr_mls_pin
    fi

    # shellcheck source=/dev/null
    source "$TMT_TREE/tmt/prepare_for_mls.sh"
    prepare_for_mls_configure

    sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

    mkdir -p /etc/cloud/cloud.cfg.d
    echo 'ssh_deletekeys: false' > /etc/cloud/cloud.cfg.d/99-preserve-ssh-host-keys.cfg
    cloud-init clean --logs

    MLS_SEMANAGE_FIX_PHASE=configure bash "$TMT_TREE/tmt/mls-final-copr-load-semanage-fix.sh"

    prepare_for_mls_reboot
    ;;

1)
    # shellcheck source=/dev/null
    source "$TMT_TREE/tmt/prepare_for_mls.sh"
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
    sestatus
    mode=$(sestatus | awk -F': *' '/^Current mode:/ {print $2}')
    policy=$(sestatus | awk -F': *' '/^Loaded policy name:/ {print $2}')
    if [ "$mode" != "enforcing" ] || [ "$policy" != "mls" ]; then
        echo "FAIL: expected enforcing MLS, got mode=${mode} policy=${policy}" >&2
        exit 1
    fi

    # Same TMT_REBOOT_COUNT as this prepare step (>=2); do not use a second
    # prepare task — per-step reboot counters reset and skip logic breaks.
    MLS_SEMANAGE_FIX_PHASE=verify bash "$TMT_TREE/tmt/mls-final-copr-load-semanage-fix.sh"
    ;;
esac
