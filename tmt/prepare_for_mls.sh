# prepare_for_mls — configure a guest for the SELinux MLS policy store.
#
# Minimal procedure to switch from the default policy (usually targeted) to mls:
#
#   1. Map Linux root to SELinux user sysadm_u
#      (`semanage login -N -m -s sysadm_u root`). Under MLS there is no
#      unconfined_u the way targeted/MCS has; sysadm_u is the admin login
#      user (range s0-s15:c0.c1023 in stock MLS). `-N` writes the mapping
#      into the not-yet-active mls store without hot-loading it under the
#      still-running targeted policy.
#   2. Set SELINUXTYPE=mls in /etc/selinux/config (takes effect next boot).
#   3. Schedule a full relabel (`touch /.autorelabel`). MLS file contexts
#      carry sensitivity ranges; keeping targeted labels leaves objects
#      effectively unlabeled under MLS.
#   4. Reboot so the kernel loads MLS and init runs the scheduled relabel.
#
# After configure(), the kernel still runs the old policy. Prefer running
# configure through the first reboot in one prepare step so new SSH sessions
# are not attempted against a half-switched system.
#
# Usage (full configure + reboot):
#   source "$TMT_TREE/tmt/prepare_for_mls.sh"
#   prepare_for_mls
#
# Split API (COPR install / staging between configure and reboot):
#   prepare_for_mls_configure
#   prepare_for_mls_reboot          # tmt-reboot or reboot
#   prepare_for_mls_force_relabel  # after MLS is loaded (next reboot count)

prepare_for_mls_configure() {
    sed -i 's/^SELINUXTYPE=.*/SELINUXTYPE=mls/' /etc/selinux/config
    semanage login -N -m -s sysadm_u root
    touch /.autorelabel
}

prepare_for_mls_reboot() {
    if command -v tmt-reboot >/dev/null 2>&1; then
        if [ "${TMT_REBOOT_COUNT:-0}" -eq 0 ]; then
            tmt-reboot -t 1200
        fi
    else
        reboot
    fi
}

# Run only after the guest has rebooted into MLS (policy already loaded).
prepare_for_mls_force_relabel() {
    restorecon -RF / 2>&1 | tail -50
}

prepare_for_mls() {
    prepare_for_mls_configure
    prepare_for_mls_reboot
}
