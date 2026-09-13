# prepare_for_mls — switch a guest from targeted to the MLS policy store.
#
# Steps: SELINUXTYPE=mls, map root to sysadm_u (semanage -N), touch
# /.autorelabel, reboot, then restorecon -RF / after MLS is active.
#
# Exposed as prepare_for_mls_configure, prepare_for_mls_reboot,
# prepare_for_mls_force_relabel so callers can semodule -n between configure
# and reboot (see tmt/mls-final-prepare.sh).
#
# After configure(), the kernel still runs the old policy; new SSH sessions
# before reboot can fail — run configure through reboot in one step.

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

prepare_for_mls_force_relabel() {
    restorecon -RF / 2>&1 | tail -50
}

prepare_for_mls() {
    prepare_for_mls_configure
    prepare_for_mls_reboot
    prepare_for_mls_force_relabel
}
