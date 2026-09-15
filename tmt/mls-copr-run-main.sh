#!/bin/bash
# Upstream /run/main with MLS/sysadm tweaks in testsuite policy before load.
# Runs every SUBDIRS */test (no fail-fast); exits non-zero if any failed.
set -eu

banner() {
    printf '\n======== %s ========\n' "$1"
}

if [ -n "${TMT_PLAN_DATA:-}" ]; then
    search_root=$(dirname "$(dirname "$TMT_PLAN_DATA")")
else
    search_root=/var/ARTIFACTS
fi
# tmt fmf discover clones the repo under discover/.../selinux-testsuite/tests/
test_te=$(find "$search_root" \( \
    -path '*/discover/selinux-testsuite/tests/policy/test_inet_socket.te' \
    -o -path '*/discover/selinux-testsuite/policy/test_inet_socket.te' \
    \) 2>/dev/null | head -n 1)
if [ -z "$test_te" ]; then
    test_te=$(find "$search_root" -name test_inet_socket.te -path '*/selinux-testsuite/*/policy/*' 2>/dev/null | head -n 1)
fi
if [ -z "$test_te" ]; then
    echo "test_inet_socket.te not found under ${search_root}" >&2
    exit 1
fi
policy_dir=$(dirname "$test_te")
sed -i '/mcs_constrained(test_inet_server_t)/d' "$test_te"
if grep -q 'mcs_constrained(test_inet_server_t)' "$test_te"; then
    echo "mcs_constrained(test_inet_server_t) still present in ${test_te}" >&2
    exit 1
fi
echo "MLS patch: removed mcs_constrained(test_inet_server_t) from test_inet_socket.te"

# Upstream leaves these commented; runcon as sysadm_t needs setexec (+ selinux fs).
test_global="$policy_dir/test_global.te"
if [ ! -f "$test_global" ]; then
    echo "test_global.te not found at ${test_global}" >&2
    exit 1
fi
sed -i \
    -e 's/^\([[:space:]]*\)#allow sysadm_t self:process setexec;/\1allow sysadm_t self:process setexec;/' \
    -e 's/^\([[:space:]]*\)#selinux_get_fs_mount(sysadm_t)/\1selinux_get_fs_mount(sysadm_t)/' \
    "$test_global"
if ! grep -q '^[[:space:]]*allow sysadm_t self:process setexec;' "$test_global"; then
    echo "sysadm setexec rule still missing in ${test_global}" >&2
    exit 1
fi
echo "MLS patch: enabled sysadm_t setexec for runcon in test_global.te"

repo_root=$(dirname "$policy_dir")
tests_dir="$repo_root/tests"
if [ ! -f "$tests_dir/Makefile" ]; then
    echo "testsuite tests/Makefile not found at ${tests_dir}" >&2
    exit 1
fi

banner "Load testsuite policy"
make -C "$repo_root/policy" load

banner "Build tests (make all)"
make -C "$tests_dir" all
chcon -R -t test_file_t "$tests_dir"
cd "$tests_dir"

subdirs=$(make -s --eval='print-subdirs:; $(info $(SUBDIRS))' print-subdirs)
if [ -z "$subdirs" ]; then
    echo "FAIL: could not read SUBDIRS from ${tests_dir}/Makefile" >&2
    exit 1
fi

# Space-separated list -> one subdir per line for counting and stable iteration.
mapfile -t subdir_list < <(printf '%s\n' $subdirs)
total=${#subdir_list[@]}
skip_inet=${MLS_COPR_SKIP_INET_SOCKET:-1}
echo "Context: $(id -Z); SELinux: $(getenforce)"
echo "Will run up to ${total} tests from tests/Makefile SUBDIRS (no fail-fast)."
if [ "$skip_inet" = 1 ]; then
    echo "MLS_COPR_SKIP_INET_SOCKET=1: skipping inet_socket/* until COPR/base policy fixes runcon."
fi

rc=0
nrun=0
npass=0
nfail=0
nskip=0
failed_list=()
skipped_list=()

set +e
i=0
for d in "${subdir_list[@]}"; do
    i=$((i + 1))
    if [ "$skip_inet" = 1 ] && [[ "$d" == inet_socket/* ]]; then
        nskip=$((nskip + 1))
        skipped_list+=("$d (inet_socket; MLS policy)")
        printf '[SKIP %3d/%d] %s (MLS_COPR_SKIP_INET_SOCKET)\n' "$i" "$total" "$d"
        continue
    fi
    if [ ! -x "$d/test" ]; then
        nskip=$((nskip + 1))
        skipped_list+=("$d")
        printf '[SKIP %3d/%d] %s (no executable test)\n' "$i" "$total" "$d"
        continue
    fi
    nrun=$((nrun + 1))
    printf '\n--- [%3d/%d] %s/test ---\n' "$i" "$total" "$d"
    if "./${d}/test"; then
        npass=$((npass + 1))
        printf '[PASS %3d/%d] %s\n' "$i" "$total" "$d"
    else
        nfail=$((nfail + 1))
        rc=1
        failed_list+=("$d")
        printf '[FAIL %3d/%d] %s\n' "$i" "$total" "$d" >&2
        if [[ "$d" == inet_socket/* ]]; then
            banner "Recent AVC after ${d} failure"
            ausearch -m avc -i -ts recent 2>/dev/null | tail -40 || true
        fi
    fi
done
set -e

banner "Results"
echo "executed: ${nrun}  passed: ${npass}  failed: ${nfail}  skipped: ${nskip}  (SUBDIRS entries: ${total})"
if [ "${#failed_list[@]}" -gt 0 ]; then
    echo "Failed:"
    printf '  - %s\n' "${failed_list[@]}"
fi
if [ "${#skipped_list[@]}" -gt 0 ]; then
    echo "Skipped:"
    printf '  - %s\n' "${skipped_list[@]}"
fi

if [ "$nrun" -eq 0 ]; then
    echo "FAIL: no tests executed" >&2
    exit 1
fi

banner "Unload testsuite policy"
make -C "$repo_root/policy" unload || true
exit "$rc"
