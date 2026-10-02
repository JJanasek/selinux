#!/bin/bash
# Quick: COPR MLS policy, stay permissive, one reboot, then done.
# Env: COPR_REPO (required).
set -eo pipefail

reboot_count="${TMT_REBOOT_COUNT:-0}"

install_copr_mls() {
    local copr_slug="${COPR_REPO:?set COPR_REPO}"
    dnf install -y 'dnf-command(copr)' || true
    dnf -y copr enable "${copr_slug}"
    dnf install -y selinux-policy selinux-policy-devel selinux-policy-mls \
        policycoreutils-python-utils audit
}

case "$reboot_count" in
0)
    install_copr_mls
    # Stay permissive; do not run fixfiles -F onboot (full relabel is slow on TF).
    sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
    sed -i 's/^SELINUXTYPE=.*/SELINUXTYPE=mls/' /etc/selinux/config
    semanage login -N -m -s sysadm_u root
    semanage boolean -N -m --on ssh_sysadm_login
    # Enough labels for cloud-init domain transition without full FS relabel.
    restorecon -RF /usr/bin/cloud-init /usr/lib/systemd/system/cloud-*.service \
        /etc/cloud /var/lib/cloud /usr/libexec/cloud-init 2>/dev/null || true
    mkdir -p /etc/cloud/cloud.cfg.d
    echo 'ssh_deletekeys: false' > /etc/cloud/cloud.cfg.d/99-preserve-ssh-host-keys.cfg
    tmt-reboot -t 900
    ;;
*)
    sestatus || true
    getenforce || true
    ;;
esac
