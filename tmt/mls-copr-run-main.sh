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
policy_dir=$(find "$search_root" -type d -path '*/discover/selinux-testsuite/policy' 2>/dev/null | head -n 1)
if [ -z "$policy_dir" ]; then
    policy_dir=$(find "$search_root" -type d -name policy -path '*/selinux-testsuite/*' 2>/dev/null | head -n 1)
fi
if [ -z "$policy_dir" ] || [ ! -f "$policy_dir/test_inet_socket.te" ]; then
    echo "selinux-testsuite policy/ not found under ${search_root}" >&2
    exit 1
fi

test_te="$policy_dir/test_inet_socket.te"
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
    -e 's/^#allow sysadm_t self:process setexec;/allow sysadm_t self:process setexec;/' \
    -e 's/^#selinux_get_fs_mount(sysadm_t)/selinux_get_fs_mount(sysadm_t)/' \
    "$test_global"
if ! grep -q '^allow sysadm_t self:process setexec;' "$test_global"; then
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
echo "Context: $(id -Z); SELinux: $(getenforce)"
echo "Will run up to ${total} tests from tests/Makefile SUBDIRS (no fail-fast)."

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
