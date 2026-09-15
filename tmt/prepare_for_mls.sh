# Switch guest from targeted to MLS (two reboots via caller).
# Call prepare_for_mls_configure, then reboot, then prepare_for_mls_force_relabel.

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
