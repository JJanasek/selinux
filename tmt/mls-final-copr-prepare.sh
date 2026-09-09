#!/bin/bash
set -eo pipefail

# EXPERIMENTAL variant of mls-final-prepare.sh (tmt/mls-final-copr-test.fmf).
#
# Validates a selinux-policy pull request as an actual, real Packit/COPR-
# built selinux-policy-mls RPM (COPR project packit/fedora-selinux-selinux-
# policy-${PR_NUMBER}, auto-created per-PR by Packit's copr_build job),
# instead of manually building/loading standalone .te modules on top of an
# unpatched package (that's what mls-final-prepare.sh still does,
# unchanged, for the production tmt/mls-final.fmf plan).
#
# Requires $PR_NUMBER (the selinux-policy PR number) to be set in the
# environment -- see mls-final-copr-test.fmf's `environment:` block. This
# script is otherwise generic across PRs; it does NOT hardcode any NVR, so
# no manual update is needed as a PR gets new commits/rebuilds.
#
# NOTE: as originally written/validated against PR #3380
# (https://github.com/fedora-selinux/selinux-policy/pull/3380, "Enable
# cloud-init under MLS" + the udev_t MLS-boot-hang fix, 2 commits) --
# confirmed via the GitHub API on 2026-09-09 against PR #3380 HEAD commit
# c3fbc760b9: rpm-build check-runs all "success" for chroots fedora-44-
# x86_64, fedora-45-x86_64, fedora-rawhide-x86_64.
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
    # --- COPR-based install of the real PR's package, replacing the plain
    # `dnf install -y selinux-policy-mls` + manual module build/load for
    # cloudform/udevnsfs/udevrlimit/udevcgroup/udevkobjectuevent/udevtmpfs ---
    #
    # PLAIN `dnf install -y selinux-policy-mls` (tried first, see PR/commit
    # history) does NOT reliably pick up the COPR build: dnf/dnf5 compares
    # EVR across ALL enabled repos regardless of enable order or which repo
    # is "new", and Fedora-Rawhide's own fast-moving repo can easily already
    # contain a *higher*-release selinux-policy-mls build than Packit's PR
    # snapshot (observed live: rawhide's own 45.15-2.fc46 beat a Packit PR
    # build's own dist-tagged release on plain EVR comparison, even with
    # the COPR repo enabled and no errors) -- so the "real PR package"
    # silently never got installed at all.
    #
    # Fix: instead of hardcoding one PR's NVR (which goes stale on every
    # new COPR rebuild), dynamically look up the *actual* repo id dnf
    # assigned the just-enabled COPR project, then query and pin the
    # highest NVR that repo (and only that repo) currently publishes for
    # selinux-policy-mls. Passing dnf a fully-qualified N-V-R.A (not just
    # the bare name) makes it install that exact build regardless of what
    # higher-EVR builds exist elsewhere, because Packit/COPR builds always
    # carry a unique dist-tag suffix (.prNNNN.<n>.g<hash>) that no regular
    # Fedora-repo build will ever coincidentally match.
    copr_project="fedora-selinux-selinux-policy-${PR_NUMBER:?PR_NUMBER must be set, e.g. 3380}"
    dnf install -y 'dnf-command(copr)' || true
    dnf -y copr enable "packit/${copr_project}"

    copr_repoid=$(dnf -y repolist --enabled | awk -v p="$copr_project" '$0 ~ p {print $1; exit}')
    if [ -z "$copr_repoid" ]; then
        echo "FAIL: could not find an enabled repo id for COPR project packit/${copr_project}" >&2
        dnf -y repolist --enabled >&2
        exit 1
    fi
    echo "Resolved COPR repo id: $copr_repoid"

    # NOTE: dnf5's repoquery --qf/--queryformat, unlike dnf4's, does NOT
    # append an implicit newline after each formatted package (it matches
    # rpm --query behavior instead) -- an explicit '\n' in the format
    # string is required, or multiple matches (e.g. several COPR builds
    # for the same PR after multiple pushes) get concatenated together
    # onto one unseparated line, corrupting the NVR passed to dnf install.
    pinned_nvr=$(dnf -y repoquery --repo="$copr_repoid" --qf '%{name}-%{evr}.%{arch}\n' selinux-policy-mls | sort -V | tail -n1)
    if [ -z "$pinned_nvr" ]; then
        echo "FAIL: repoquery found no selinux-policy-mls build in repo $copr_repoid" >&2
        exit 1
    fi
    echo "Pinning to COPR-built NVR: $pinned_nvr"

    dnf install -y "$pinned_nvr" policycoreutils-python-utils audit

    # Provenance check: confirm the installed package actually is that
    # exact PR #3380 COPR build and not some other (e.g. regular Fedora
    # repo) build of selinux-policy-mls.
    {
        echo "=== rpm -q selinux-policy-mls ==="
        rpm -q selinux-policy-mls
        echo "=== dnf repoquery --installed (repo id) ==="
        dnf -y repoquery --installed --qf '%{name}-%{evr}.%{arch}  [from_repo: %{from_repo}]\n' selinux-policy-mls
        echo "=== dnf copr list ==="
        dnf -y copr list
    } | tee /root/copr-provenance.log

    if ! grep -q "\.pr${PR_NUMBER}\." /root/copr-provenance.log; then
        echo "FAIL: installed selinux-policy-mls release does not contain '.pr${PR_NUMBER}.' -- COPR package was NOT picked up" >&2
        exit 1
    fi
    echo "PASS: selinux-policy-mls release string confirms it came from the PR #${PR_NUMBER} COPR build"

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
