#!/bin/bash
set -eo pipefail

if [ "${TMT_REBOOT_COUNT:-0}" -eq 0 ]; then
    rm -f /.autorelabel
    systemctl mask selinux-autorelabel.service

    # Root's SSH session maps to sysadm_u/sysadm_r/sysadm_t, but
    # sshd_session_t's transition into admin domains is gated behind
    # this tunable (off by default). Without it every post-reboot SSH
    # command fails with a denied "Permission denied".
    semanage boolean -n -m --on ssh_sysadm_login

    # Defense-in-depth alongside the real fix in cloudform.te:
    # cloud-init.target ships with no static [Install] section, so give
    # it a static symlink in case the generator's runtime enablement
    # doesn't run.
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /usr/lib/systemd/system/cloud-init.target /etc/systemd/system/multi-user.target.wants/cloud-init.target

    # Rebuild the policy store so the boolean change above is baked
    # into what the reboot below actually loads.
    semodule -DB

    cloud-init clean --logs
    sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
    tmt-reboot -t 1200
fi
