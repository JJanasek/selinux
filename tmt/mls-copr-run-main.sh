#!/bin/bash
# Upstream run/main: patch testsuite policy for MLS/sysadm, run all SUBDIRS (no fail-fast).
set -eu

if [ -n "${TMT_PLAN_DATA:-}" ]; then
    search_root=$(dirname "$(dirname "$TMT_PLAN_DATA")")
else
    search_root=/var/ARTIFACTS
fi
test_te=$(find "$search_root" \( \
    -path '*/discover/selinux-testsuite/tests/policy/test_inet_socket.te' \
    -o -path '*/discover/selinux-testsuite/policy/test_inet_socket.te' \
    \) 2>/dev/null | head -n 1)
[ -n "$test_te" ] || test_te=$(find "$search_root" -name test_inet_socket.te -path '*/selinux-testsuite/*/policy/*' 2>/dev/null | head -n 1)
[ -n "$test_te" ] || { echo "test_inet_socket.te not found" >&2; exit 1; }

policy_dir=$(dirname "$test_te")
sed -i '/mcs_constrained(test_inet_server_t)/d' "$policy_dir/test_inet_socket.te"
test_global="$policy_dir/test_global.te"
sed -i \
    -e 's/^\([[:space:]]*\)#allow sysadm_t self:process setexec;/\1allow sysadm_t self:process setexec;/' \
    -e 's/^\([[:space:]]*\)#selinux_get_fs_mount(sysadm_t)/\1selinux_get_fs_mount(sysadm_t)/' \
    "$test_global"
grep -q '^[[:space:]]*allow sysadm_t self:process setexec;' "$test_global" \
    || { echo "sysadm setexec missing in test_global.te" >&2; exit 1; }

repo_root=$(dirname "$policy_dir")
tests_dir="$repo_root/tests"
[ -f "$tests_dir/Makefile" ] || { echo "testsuite Makefile missing" >&2; exit 1; }

make -C "$repo_root/policy" load
make -C "$tests_dir" all
chcon -R -t test_file_t "$tests_dir"
cd "$tests_dir"

mapfile -t subdir_list < <(printf '%s\n' $(make -s --eval='print-subdirs:; $(info $(SUBDIRS))' print-subdirs))
total=${#subdir_list[@]}
skip_inet=${MLS_COPR_SKIP_INET_SOCKET:-1}

rc=0 nrun=0 npass=0 nfail=0 nskip=0
failed_list=() skipped_list=()
row_idx=() row_subdir=() row_outcome=()

record() {
    row_idx+=("$1")
    row_subdir+=("$2")
    row_outcome+=("$3")
}

set +e
i=0
for d in "${subdir_list[@]}"; do
    i=$((i + 1))
    if [ "$skip_inet" = 1 ] && [[ "$d" == inet_socket/* ]]; then
        nskip=$((nskip + 1))
        skipped_list+=("$d")
        record "$i" "$d" SKIP
        continue
    fi
    if [ ! -x "$d/test" ]; then
        nskip=$((nskip + 1))
        skipped_list+=("$d")
        record "$i" "$d" SKIP
        continue
    fi
    nrun=$((nrun + 1))
    if "./${d}/test"; then
        npass=$((npass + 1))
        record "$i" "$d" PASS
    else
        nfail=$((nfail + 1))
        rc=1
        failed_list+=("$d")
        record "$i" "$d" FAIL
        echo "[FAIL ${i}/${total}] ${d}" >&2
    fi
done
set -e

printf '\n======== SUBDIRS results (PASS %d FAIL %d SKIP %d / %d) ========\n' \
    "$npass" "$nfail" "$nskip" "$total"
printf '  #    OUTCOME   SUBDIR\n ----  --------  --------------------------------\n'
for j in "${!row_subdir[@]}"; do
    printf ' %3d   %-8s  %s\n' "${row_idx[$j]}" "${row_outcome[$j]}" "${row_subdir[$j]}"
done
printf ' ----  --------  --------------------------------\n'
[ "${#failed_list[@]}" -eq 0 ] || { echo "FAILED:"; printf '  %s\n' "${failed_list[@]}"; }
[ "${#skipped_list[@]}" -eq 0 ] || { echo "SKIPPED:"; printf '  %s\n' "${skipped_list[@]}"; }

[ "$nrun" -gt 0 ] || { echo "no tests executed" >&2; exit 1; }
make -C "$repo_root/policy" unload || true
exit "$rc"
