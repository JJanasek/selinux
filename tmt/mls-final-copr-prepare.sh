#!/bin/bash
set -eo pipefail

# EXPERIMENTAL variant of mls-final-prepare.sh (tmt/mls-final-copr-test.fmf).
#
# Validates PR #3380 (https://github.com/fedora-selinux/selinux-policy/pull/3380,
# "Enable cloud-init under MLS" + the udev_t MLS-boot-hang fix, 2 commits) as
# an actual, real Packit/COPR-built selinux-policy-mls RPM, instead of
# manually building/loading standalone .te modules on top of an unpatched
# package (that's what mls-final-prepare.sh still does, unchanged, for the
# production tmt/mls-final.fmf plan).
#
# Confirmed via the GitHub API (check-runs + Packit's own /api/copr-builds
# endpoint) on 2026-09-09 against PR #3380 HEAD commit c3fbc760b9:
#   - COPR project: packit/fedora-selinux-selinux-policy-3380 (owner "packit")
#   - rpm-build check-runs all "success" for chroots: fedora-44-x86_64,
#     fedora-45-x86_64, fedora-rawhide-x86_64
#   - built selinux-policy-mls NVR e.g. 45.15-1.20260901100528187839.pr3380.3.g4eefc83f2.fc44
#
# PR #3380's actual diff (`gh`/GitHub API `pulls/3380` diff) only touches:
#   dist/mls/modules.conf, policy/modules/contrib/cloudform.te,
#   policy/modules/contrib/networkmanager.if, policy/modules/kernel/kernel.if,
#   policy/modules/services/ssh.if, policy/modules/system/sysnetwork.if,
#   policy/modules/system/udev.te
# i.e. it covers this repo's local cloudform + 5 of the 6 udev_t fixes
# (udevnsfs, udevrlimit, udevcgroup, udevkobjectuevent, udevtmpfs -- as
# udev.te changes, not standalone modules there). It does NOT touch
# anything related to mlssshpipes (a backport of unrelated upstream commit
# a589b1b5) or udevptrace (a separate sys_ptrace/noatsecure fix) -- neither
# module appears anywhere in the PR diff, confirmed by grep. Those two
# still have no upstream fix and must keep being built/loaded locally here.
reboot_count="${TMT_REBOOT_COUNT:-0}"

case "$reboot_count" in
0)
    # --- COPR-based install of the real PR #3380 package, replacing the
    # plain `dnf install -y selinux-policy-mls` + manual module build/load
    # for cloudform/udevnsfs/udevrlimit/udevcgroup/udevkobjectuevent/udevtmpfs ---
    dnf install -y 'dnf-command(copr)' || true
    dnf -y copr enable packit/fedora-selinux-selinux-policy-3380
    dnf install -y selinux-policy-mls policycoreutils-python-utils audit

    # Provenance check: confirm the installed package actually came from
    # the COPR repo (Packit tags its builds' release field with
    # ".prNNNN." + the short commit hash) and not a regular Fedora repo.
    {
        echo "=== rpm -q selinux-policy-mls ==="
        rpm -q selinux-policy-mls
        echo "=== dnf repoquery --installed (repo id) ==="
        dnf -y repoquery --installed --qf '%{name}-%{evr}.%{arch}  [repo: %{reponame}]' selinux-policy-mls
        echo "=== dnf copr list ==="
        dnf -y copr list
    } | tee /root/copr-provenance.log

    if ! grep -q '\.pr3380\.' /root/copr-provenance.log; then
        echo "FAIL: installed selinux-policy-mls release does not contain '.pr3380.' -- COPR package was NOT picked up" >&2
        exit 1
    fi
    echo "PASS: selinux-policy-mls release string confirms it came from the PR #3380 COPR build"

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

    # --- Only the two fixes NOT part of PR #3380 still need local
    # build/load: mlssshpipes and udevptrace. cloudform and the other 5
    # udev_t fixes are now expected to already be baked into the
    # COPR-built selinux-policy-mls package installed above. ---
    dnf install -y policycoreutils-devel

    mkdir -p /root/build && cd /root/build
    cp $TMT_TREE/tmt/mls-ssh-pipes-fix/mlssshpipes.te .
    cp $TMT_TREE/tmt/mls-udev-ptrace-fix/udevptrace.te .

    make -f /usr/share/selinux/devel/Makefile mlssshpipes.pp udevptrace.pp

    # Load modules into the inactive MLS store (-n) without hot-reloading
    semodule -n -i mlssshpipes.pp udevptrace.pp
    semodule -l | grep -E '^(mlssshpipes|udevptrace)\b'

    # Same reboot-into-mls step as the production plan.
    prepare_for_mls_reboot
    ;;

1)
    source $TMT_TREE/tmt/prepare_for_mls.sh
    prepare_for_mls_force_relabel

    # Re-confirm provenance survived the MLS-switch reboot (repo enablement
    # is a dnf/system-wide setting, not tied to the old targeted store).
    {
        echo "=== post-reboot rpm -q selinux-policy-mls ==="
        rpm -q selinux-policy-mls
    } | tee -a /root/copr-provenance.log

    rm -f /.autorelabel
    systemctl mask selinux-autorelabel.service

    # Root's SSH session maps to sysadm_u/sysadm_r/sysadm_t, but
    # sshd_session_t's transition into admin domains is gated behind
    # this tunable (off by default). Without it every post-reboot SSH
    # command fails with a denied "Permission denied".
    semanage boolean -n -m --on ssh_sysadm_login

    # Defense-in-depth alongside the real fix in cloudform.te (now shipped
    # in the COPR package): cloud-init.target ships with no static
    # [Install] section, so give it a static symlink in case the
    # generator's runtime enablement doesn't run.
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
