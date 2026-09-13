#!/bin/bash
set -eo pipefail

# MLS prepare for COPR-validated selinux-policy PRs (mls-final-copr-test.fmf).
# Requires PR_NUMBER. Flow: pin COPR selinux-policy-mls (MLS fixes must be in
# that RPM) → MLS switch → two reboots (permissive relabel, then enforcing).
reboot_count="${TMT_REBOOT_COUNT:-0}"

case "$reboot_count" in
0)
    copr_project="fedora-selinux-selinux-policy-${PR_NUMBER:?PR_NUMBER must be set}"
    dnf install -y 'dnf-command(copr)' || true
    dnf -y copr enable "packit/${copr_project}"

    copr_repoid=$(dnf -y repolist --enabled | awk -v p="$copr_project" '$0 ~ p {print $1; exit}')
    if [ -z "$copr_repoid" ]; then
        echo "FAIL: no enabled repo for packit/${copr_project}" >&2
        exit 1
    fi

    # dnf picks highest EVR across all repos; pin the COPR build explicitly.
    # dnf5 repoquery --qf needs an explicit \n or multiple NVRs glue together.
    pinned_nvr=$(dnf -y repoquery --repo="$copr_repoid" --qf '%{name}-%{evr}.%{arch}\n' selinux-policy-mls | sort -V | tail -n1)
    if [ -z "$pinned_nvr" ]; then
        echo "FAIL: no selinux-policy-mls in repo ${copr_repoid}" >&2
        exit 1
    fi
    echo "Installing COPR build: ${pinned_nvr}"
    dnf install -y "$pinned_nvr" policycoreutils-python-utils audit

    if ! rpm -q selinux-policy-mls | grep -qF ".pr${PR_NUMBER}."; then
        echo "FAIL: selinux-policy-mls is not from PR #${PR_NUMBER} COPR" >&2
        rpm -q selinux-policy-mls >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$TMT_TREE/tmt/prepare_for_mls.sh"
    prepare_for_mls_configure

    sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

    mkdir -p /etc/cloud/cloud.cfg.d
    echo 'ssh_deletekeys: false' > /etc/cloud/cloud.cfg.d/99-preserve-ssh-host-keys.cfg
    cat > /etc/cloud/cloud.cfg.d/98-selinux-context-check.cfg <<'CICFG'
bootcmd:
  - [ sh, -c, "id -Z > /var/log/cloud-init-selinux-context.log 2>&1" ]
CICFG
    cloud-init clean --logs

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
    ;;
esac
