#!/bin/bash
# Install COPR selinux-policy-mls, switch guest to MLS, verify ready for tests.
# Env: COPR_REPO (required unless SKIP_COPR_INSTALL=1).
# Optional: COPR_SELINUX_POLICY_MLS_NVR to pin an exact MLS package NVR.
set -eo pipefail

reboot_count="${TMT_REBOOT_COUNT:-0}"

# shellcheck source=/dev/null
source "$TMT_TREE/tmt/prepare_for_mls.sh"

verify_copr_policy_set() {
    local mls_evr policy_evr
    mls_evr=$(rpm -q --qf '%{EVR}' selinux-policy-mls)
    policy_evr=$(rpm -q --qf '%{EVR}' selinux-policy)

    [ "$mls_evr" = "$policy_evr" ] || { echo "FAIL: selinux-policy and selinux-policy-mls EVR mismatch" >&2; exit 1; }

    if [ -n "${COPR_SELINUX_POLICY_MLS_NVR:-}" ] && ! rpm -q selinux-policy-mls | grep -qF "${COPR_SELINUX_POLICY_MLS_NVR}"; then
        echo "FAIL: expected ${COPR_SELINUX_POLICY_MLS_NVR}" >&2
        exit 1
    fi
}

install_copr_policy_set() {
    dnf install -y 'dnf-command(copr)' || true
    dnf -y copr enable "${COPR_REPO:?set COPR_REPO}"
    dnf distro-sync -y --allowerasing selinux-policy
    dnf install -y --allowerasing \
        selinux-policy-devel selinux-policy-mls \
        policycoreutils-python-utils audit
    rpm -q selinux-policy selinux-policy-devel selinux-policy-mls
    verify_copr_policy_set
}

verify_mls_ready() {
    [ "$(getenforce)" = "Enforcing" ] && [ "$(sestatus | awk -F': *' '/Loaded policy name/ {print $2}')" = "mls" ] \
        || { echo "FAIL: system not in enforcing MLS mode" >&2; exit 1; }

    semanage login -l | grep -q 'root.*sysadm_u' \
        || { echo "FAIL: root not mapped to sysadm_u" >&2; exit 1; }

    # --input-logs: do not consume stdin (tmt may attach a pipe).
    if ausearch -m avc,user_avc -i --input-logs -ts boot 2>/dev/null | grep -Eiq 'cloud_init_t|comm="cloud-init"'; then
        echo "FAIL: cloud-init AVC denials found since boot" >&2
        exit 1
    fi

    verify_copr_policy_set
}

mls_checkpoint() {
    echo "=== MLS checkpoint after relabel reboot ==="
    sestatus || true
    echo "=== /.autorelabel ==="
    [ -e /.autorelabel ] && { ls -l /.autorelabel; cat /.autorelabel || true; } || echo "absent"
    echo "=== selinux-autorelabel.service ==="
    systemctl is-active selinux-autorelabel.service || true
    systemctl --no-pager --full status selinux-autorelabel.service || true
    echo "=== ssh_sysadm_login ==="
    getsebool ssh_sysadm_login || true
    echo "=== critical path labels ==="
    ls -Zd / /var /etc /usr || true
}

wait_for_autorelabel() {
    local deadline=$(( $(date +%s) + 1200 )) now
    while [ -e /.autorelabel ] || systemctl is-active --quiet selinux-autorelabel.service 2>/dev/null; do
        now=$(date +%s)
        [ "$now" -lt "$deadline" ] || {
            echo "FAIL: selinux-autorelabel still running after 20m" >&2
            systemctl --no-pager --full status selinux-autorelabel.service >&2 || true
            exit 1
        }
        echo "waiting for selinux-autorelabel / /.autorelabel ($((deadline - now))s left)"
        sleep 15
    done
}

finish_mls_labels() {
    local start end path ctx out
    echo "=== critical path labels before fixfiles ==="
    ls -Zd / /var /etc /usr || true
    echo "=== fixfiles -F restore / (permissive MLS) ==="

    out=$(mktemp)
    start=$(date +%s)

    set +e
    fixfiles -F restore / >"$out" 2>&1
    set -e

    tail -100 "$out"
    if grep -q '^Usage:' "$out"; then
        echo "FAIL: fixfiles rejected arguments" >&2
        rm -f "$out"
        exit 1
    fi
    end=$(date +%s)
    echo "fixfiles duration: $((end - start))s"
    rm -f "$out"

    rm -f /.autorelabel
    systemctl mask selinux-autorelabel.service

    echo "=== critical path labels after fixfiles ==="
    ls -Zd / /var /etc /usr || true
    for path in / /var /etc /usr; do
        ctx=$(ls -Zd "$path" | awk '{print $1}')
        case "$ctx" in
            *unlabeled_t*)
                echo "FAIL: $path still unlabeled_t ($ctx)" >&2
                exit 1
                ;;
        esac
    done
}

case "$reboot_count" in
0)
    if [ "${SKIP_COPR_INSTALL:-0}" != 1 ]; then
        install_copr_policy_set
    else
        dnf install -y policycoreutils-python-utils audit
        verify_copr_policy_set
    fi
    prepare_for_mls_configure
    prepare_for_mls_reboot
    ;;
1)
    mls_checkpoint
    if [ "${MLS_STAY_PERMISSIVE:-0}" = 1 ]; then
        echo "=== ausearch AVC/USER_AVC/SELINUX_ERR since boot ==="
        ausearch -m avc,user_avc,selinux_err,user_selinux_err -i --input-logs -ts boot || true
        echo "=== end ausearch ==="
        exit 0
    fi
    wait_for_autorelabel
    finish_mls_labels
    prepare_for_mls_set_enforcing
    prepare_for_mls_reboot
    ;;
*)
    verify_mls_ready
    ;;
esac
