# prepare_for_mls — switch guest to SELinux MLS.
#
# Map root→sysadm_u (-N, mls store), SELINUXTYPE=mls, /.autorelabel, reboot.
# Under MLS there is no unconfined_u; sysadm_u is the admin login user.
# Relabel is required: MLS contexts carry sensitivity ranges.
#
# Full:     source …/prepare_for_mls.sh; prepare_for_mls
# Split:    prepare_for_mls_configure | _reboot | _force_relabel
# Prefer configure+first reboot in one prepare step (half-switched SSH is fragile).

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

# After reboot into MLS (policy already loaded).
# restorecon may return non-zero on virt FS mounts; do not abort the prepare.
prepare_for_mls_force_relabel() {
    restorecon -RF / 2>&1 | tail -50 || true
}

prepare_for_mls() {
    prepare_for_mls_configure
    prepare_for_mls_reboot
}
