# prepare_for_mls - correctly configure a system for the SELinux mls
# policy store and reboot into it.
#
# This documents (and implements) the minimal, correct procedure for
# switching a running system from whatever policy it currently boots
# (typically targeted) to mls:
#
#   1. Map the root Linux user to the sysadm_u SELinux user
#      (`semanage login -m -s sysadm_u root`). Under mls there is no
#      unconfined_u/unconfined_r the way targeted/mcs has: sysadm_u is the
#      privileged administrative SELinux user meant to log in at the
#      system's highest configured sensitivity/category range
#      (s0-s15:c0.c1023 in the stock mls policy). Without this mapping,
#      root has no valid SELinux user under mls and login after the switch
#      fails (or silently falls back to a mapping with insufficient
#      clearance to administer the box).
#   2. Point /etc/selinux/config at the mls policy store
#      (`SELINUXTYPE=mls`). This does not take effect until the next boot.
#   3. Schedule a full filesystem relabel (`touch /.autorelabel`). Every
#      file's security context depends on the active policy's file_contexts,
#      which differ between targeted and mls (e.g. mls file contexts carry
#      an explicit sensitivity range); without a full relabel, most files
#      would keep their stale targeted-policy labels; mls interprets those
#      as effectively unlabeled_t and denies access to them.
#   4. Reboot, so the kernel actually loads the mls policy (SELINUXTYPE
#      only controls what `SETLOCALDEFS`/userspace tools and the next boot
#      use; the running kernel keeps enforcing whatever policy it already
#      loaded) and so init runs the scheduled relabel before anything else
#      starts.
#   5. Once back up under the mls kernel policy, force a second,
#      full-context relabel (`restorecon -RF /`). The boot-time relabel
#      from step 3/4 only fixes each file's *type* -- by design, plain
#      restorecon/setfiles never touch the user or role components
#      unless given -F, since those normally don't need fixing. But any
#      file written while the system still ran under the old policy
#      (inevitable: package installs, config edits, ... anything before
#      the reboot) keeps that policy's user forever otherwise. Confirmed
#      on /etc/ld.so.cache: after a full boot-time relabel it still read
#      `unconfined_u:object_r:ld_so_cache_t:s0` -- unconfined_u isn't
#      even a valid SELinux user under mls, so the kernel falls back to
#      unlabeled_t and denies access -- and only restorecon -F, not
#      plain restorecon, actually fixed it. This has to run after the
#      reboot in step 4, not before: setting a context via setxattr is
#      validated against the *currently loaded kernel* policy, so
#      relabeling to mls-only types/ranges while still running the old
#      policy would fail.
#
# Usage:
#   source prepare_for_mls.sh
#   prepare_for_mls
#
# This performs the entire procedure above, including the reboot, and does
# not return (or, under tmt, triggers a tmt-aware reboot that resumes the
# calling test step afterwards -- see prepare_for_mls_reboot below).
#
# Steps 1-3 (configuration), step 4 (the reboot), and step 5 (the
# post-reboot forced relabel) are also available as separate functions --
# prepare_for_mls_configure, prepare_for_mls_reboot, and
# prepare_for_mls_force_relabel -- for callers that need to do additional
# setup -- e.g. staging extra policy modules into the not-yet-active mls
# store -- in between configuring the system and actually rebooting into
# it, or that run each step as its own separate tmt prepare phase (a
# reboot tears down the running script, so anything meant to run after it
# has to live in a call/step that only actually executes post-reboot).

prepare_for_mls_configure() {
    semanage login -m -s sysadm_u root

    sed -i 's/^SELINUXTYPE=.*/SELINUXTYPE=mls/' /etc/selinux/config

    touch /.autorelabel
}

prepare_for_mls_reboot() {
    if command -v tmt-reboot >/dev/null 2>&1; then
        # Running inside a tmt test: use tmt's own reboot primitive so tmt
        # re-establishes the guest connection and resumes this same
        # prepare/execute step afterwards, instead of the plan just failing
        # when the SSH connection drops. tmt re-runs the step from the top
        # on resume, so guard against requesting a second reboot forever.
        if [ "${TMT_REBOOT_COUNT:-0}" -eq 0 ]; then
            tmt-reboot -t 1200
        fi
    else
        reboot
    fi
}

prepare_for_mls_force_relabel() {
    restorecon -RF / 2>&1 | tail -50
}

prepare_for_mls() {
    prepare_for_mls_configure
    prepare_for_mls_reboot
    prepare_for_mls_force_relabel
}
