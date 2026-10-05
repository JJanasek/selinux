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
    [ "$mls_evr" = "$policy_evr" ] || {
        echo "FAIL: selinux-policy and selinux-policy-mls EVR mismatch" >&2
        exit 1
    }
    if [ -n "${COPR_SELINUX_POLICY_MLS_NVR:-}" ] \
        && ! rpm -q selinux-policy-mls | grep -qF "${COPR_SELINUX_POLICY_MLS_NVR}"; then
        echo "FAIL: expected ${COPR_SELINUX_POLICY_MLS_NVR}" >&2
        exit 1
    fi
}

install_copr_policy_set() {
    local copr_slug="${COPR_REPO:?set COPR_REPO}"
    local pinned_mls_nvr suffix arch
    local -a pkgs

    dnf install -y 'dnf-command(copr)' || true
    dnf -y copr enable "${copr_slug}"

    if [ -n "${COPR_SELINUX_POLICY_MLS_NVR:-}" ]; then
        pinned_mls_nvr="${COPR_SELINUX_POLICY_MLS_NVR}"
        suffix="${pinned_mls_nvr#selinux-policy-mls-}"
        arch="${suffix##*.}"
        suffix="${suffix%."$arch"}"
        pkgs=(
            "selinux-policy-${suffix}.${arch}"
            "selinux-policy-devel-${suffix}.${arch}"
            "selinux-policy-mls-${suffix}.${arch}"
        )
    else
        pkgs=(selinux-policy selinux-policy-devel selinux-policy-mls)
    fi

    dnf install -y "${pkgs[@]}" policycoreutils-python-utils audit
    verify_copr_policy_set
}

# After the enforcing reboot: MLS enforcing, root is sysadm_u, no cloud-init AVCs.
verify_mls_ready() {
    local mode policy login_map tmpdir as_rc
    mode=$(sestatus | awk -F': *' '/^Current mode:/ {print $2}')
    policy=$(sestatus | awk -F': *' '/^Loaded policy name:/ {print $2}')
    [ "$mode" = enforcing ] && [ "$policy" = mls ] || {
        echo "FAIL: expected enforcing MLS (got mode=${mode} policy=${policy})" >&2
        exit 1
    }
    login_map=$(semanage login -l | awk '$1 == "root" {print; exit}')
    echo "$login_map" | grep -q sysadm_u || {
        echo "FAIL: root not mapped to sysadm_u (${login_map})" >&2
        exit 1
    }
    tmpdir=$(mktemp -d)
    # --input-logs: do not consume stdin (tmt may attach a pipe).
    # ausearch: 0=matches, 1=none, >=2=error
    set +e
    ausearch -m avc,user_avc -i --input-logs -ts boot >"$tmpdir/avc.txt" 2>/dev/null
    as_rc=$?
    set -e
    if [ "$as_rc" -ge 2 ]; then
        echo "FAIL: ausearch failed (rc=$as_rc)" >&2
        rm -rf "$tmpdir"
        exit 1
    fi
    if grep -Eiq 'cloud_init_t|comm="cloud-init"' "$tmpdir/avc.txt"; then
        echo "FAIL: cloud-init related AVC denials since boot:" >&2
        grep -Ei 'cloud_init_t|comm="cloud-init"' "$tmpdir/avc.txt" >&2 || true
        rm -rf "$tmpdir"
        exit 1
    fi
    rm -rf "$tmpdir"
    verify_copr_policy_set
}

# Preserve SSH host keys: Testing Farm reconnects after reboot; cloud-init
# must not rotate keys or SSH verification fails.
preserve_ssh_host_keys() {
    mkdir -p /etc/cloud/cloud.cfg.d
    echo 'ssh_deletekeys: false' > /etc/cloud/cloud.cfg.d/99-preserve-ssh-host-keys.cfg
}

mls_checkpoint() {
    echo "=== MLS checkpoint after relabel reboot ==="
    sestatus || true
    echo "=== /.autorelabel ==="
    if [ -e /.autorelabel ]; then
        ls -l /.autorelabel
        cat /.autorelabel || true
    else
        echo "absent"
    fi
    echo "=== selinux-autorelabel.service ==="
    systemctl is-active selinux-autorelabel.service || true
    systemctl --no-pager --full status selinux-autorelabel.service || true
    echo "=== ssh_sysadm_login ==="
    getsebool ssh_sysadm_login || true
    echo "=== critical path labels ==="
    ls -Zd / /var /etc /usr || true
}

# tmt can resume on SSH before on-boot autorelabel finishes.
wait_for_autorelabel() {
    local deadline now
    deadline=$(( $(date +%s) + 1200 ))
    while [ -e /.autorelabel ] \
        || systemctl is-active --quiet selinux-autorelabel.service 2>/dev/null; do
        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            echo "FAIL: selinux-autorelabel still running after 20m" >&2
            systemctl --no-pager --full status selinux-autorelabel.service >&2 || true
            exit 1
        fi
        echo "waiting for selinux-autorelabel / /.autorelabel ($((deadline - now))s left)"
        sleep 15
    done
}

# On-boot fixfiles -F often finishes too fast for a full MLS relabel on TF.
# Finish under permissive, refuse enforcing if critical paths stay unlabeled.
finish_mls_labels() {
    local start end path ctx
    echo "=== critical path labels before fixfiles ==="
    ls -Zd / /var /etc /usr || true
    echo "=== fixfiles -F / (permissive MLS) ==="
    start=$(date +%s)
    fixfiles -F / 2>&1 | tail -100 || true
    end=$(date +%s)
    echo "fixfiles duration: $((end - start))s"
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
    if [ "${STS_KERNEL:-}" = local ]; then
        dnf install -y kernel-devel
    fi
    if [ "${SKIP_COPR_INSTALL:-0}" != 1 ]; then
        install_copr_policy_set
    else
        dnf install -y policycoreutils-python-utils audit
        verify_copr_policy_set
    fi
    preserve_ssh_host_keys
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
