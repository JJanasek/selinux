#!/bin/bash
set -eo pipefail

# Merged prepare script for tmt/mls-final.fmf, covering (in order) what used
# to be 4 separate prepare phases: MLS+permissive setup, custom policy
# module build/load, the MLS-switch reboot + relabel, and the enforcing
# switch + second reboot.
#
# This whole script is ONE tmt prepare phase, so tmt re-runs it from the top
# every time it comes back from a tmt-reboot triggered inside it, bumping
# TMT_REBOOT_COUNT each time (0 on the very first run, 1 after the first
# reboot, 2 after the second) -- see tmt's PrepareShell.go(), which keeps a
# single RebootContext (and its reboot_counter) alive across the whole
# phase and re-queues the same script on every reboot it handles. Branch on
# that count instead of guarding each old script separately.
reboot_count="${TMT_REBOOT_COUNT:-0}"

case "$reboot_count" in
0)
    # --- was mls-final-prepare-1-mls-permissive.sh ---
    dnf install -y selinux-policy-mls policycoreutils-python-utils audit

    source $TMT_TREE/tmt/prepare_for_mls.sh
    prepare_for_mls_configure

    # Stay permissive for the initial relabel reboot
    sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

    # Preserve SSH host keys across reboots to maintain tmt connection
    mkdir -p /etc/cloud/cloud.cfg.d
    echo 'ssh_deletekeys: false' > /etc/cloud/cloud.cfg.d/99-preserve-ssh-host-keys.cfg

    # Capture the context cloud-init actually runs under via a bootcmd
    # subprocess (inherits cloud-init's live domain, no exec transition of
    # its own) -- cloud-init-main.service is too short-lived to catch later.
    cat > /etc/cloud/cloud.cfg.d/98-selinux-context-check.cfg <<'CICFG'
bootcmd:
  - [ sh, -c, "id -Z > /var/log/cloud-init-selinux-context.log 2>&1" ]
CICFG

    # Reset cloud-init state to force a full run under MLS
    cloud-init clean --logs

    # --- was mls-final-prepare-2-build-modules.sh ---
    dnf install -y policycoreutils-devel

    # Stage missing interface files
    cp $TMT_TREE/tmt/mls-cloudinit-fix/networkmanager-manage-rw-conf.if /usr/share/selinux/devel/include/contrib/
    cp $TMT_TREE/tmt/mls-cloudinit-fix/ssh-read-server-keys.if /usr/share/selinux/devel/include/contrib/
    cp $TMT_TREE/tmt/mls-cloudinit-fix/sysnetwork-manage-config-sockets.if /usr/share/selinux/devel/include/system/

    mkdir -p /root/build && cd /root/build
    cp $TMT_TREE/tmt/mls-cloudinit-fix/cloudform.* .
    cp $TMT_TREE/tmt/mls-ssh-pipes-fix/mlssshpipes.te .
    cp $TMT_TREE/tmt/mls-udev-ptrace-fix/udevptrace.te .

    # Five narrowly-targeted udev_t fixes that replace the old blanket
    # `semanage permissive -n -a udev_t` workaround; see each module's own
    # .te comment block for the AVC it closes.
    cp $TMT_TREE/tmt/mls-udev-nsfs-fix/udevnsfs.te .
    cp $TMT_TREE/tmt/mls-udev-rlimit-fix/udevrlimit.te .
    cp $TMT_TREE/tmt/mls-udev-cgroup-fix/udevcgroup.te .
    cp $TMT_TREE/tmt/mls-udev-kobjectuevent-fix/udevkobjectuevent.te .
    cp $TMT_TREE/tmt/mls-udev-tmpfs-fix/udevtmpfs.te .

    make -f /usr/share/selinux/devel/Makefile cloudform.pp mlssshpipes.pp udevptrace.pp udevnsfs.pp udevrlimit.pp udevcgroup.pp udevkobjectuevent.pp udevtmpfs.pp

    # Load modules into the inactive MLS store (-n) without hot-reloading
    semodule -n -i cloudform.pp mlssshpipes.pp udevptrace.pp udevnsfs.pp udevrlimit.pp udevcgroup.pp udevkobjectuevent.pp udevtmpfs.pp
    semodule -l | grep -E '^(cloudform|mlssshpipes|udevptrace|udevnsfs|udevrlimit|udevcgroup|udevkobjectuevent|udevtmpfs)\b'

    # --- was mls-final-prepare-3-reboot-relabel.sh, reboot half only ---
    # prepare_for_mls_reboot's own TMT_REBOOT_COUNT==0 guard is what
    # actually fires tmt-reboot here. The relabel half
    # (prepare_for_mls_force_relabel) needs the freshly-booted MLS kernel
    # policy to validate against, so it must run only after this reboot
    # completes -- see the "1)" case below, not here.
    prepare_for_mls_reboot
    ;;

1)
    # --- was mls-final-prepare-3-reboot-relabel.sh, post-reboot half ---
    source $TMT_TREE/tmt/prepare_for_mls.sh
    prepare_for_mls_force_relabel

    # --- was mls-final-prepare-4-enforcing.sh ---
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
    ;;

*)
    # Both reboots already happened (TMT_REBOOT_COUNT >= 2); all prepare
    # work is done and the execute step runs next.
    :
    ;;
esac
