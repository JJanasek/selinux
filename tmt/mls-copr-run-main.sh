#!/bin/bash
# Upstream /run/main, plus MLS workaround for testsuite policy/test_inet_socket.te.
# Runs every SUBDIRS */test (no fail-fast); exits non-zero if any failed.
set -eux

if [ -n "${TMT_PLAN_DATA:-}" ]; then
    search_root=$(dirname "$(dirname "$TMT_PLAN_DATA")")
else
    search_root=/var/ARTIFACTS
fi
test_te=$(find "$search_root" -path '*/discover/selinux-testsuite/policy/test_inet_socket.te' 2>/dev/null | head -n 1)
if [ -z "$test_te" ]; then
    test_te=$(find "$search_root" -name 'test_inet_socket.te' 2>/dev/null | head -n 1)
fi
if [ -z "$test_te" ]; then
    echo "test_inet_socket.te not found under ${search_root}" >&2
    exit 1
fi
sed -i '/mcs_constrained(test_inet_server_t)/d' "$test_te"
if grep -q 'mcs_constrained(test_inet_server_t)' "$test_te"; then
    echo "mcs_constrained(test_inet_server_t) still present in ${test_te}" >&2
    exit 1
fi

tests_root=$(find "$search_root" -type d -path '*/discover/selinux-testsuite/tests' 2>/dev/null | head -n 1)
if [ -z "$tests_root" ]; then
    echo "selinux-testsuite tests/ tree not found" >&2
    exit 1
fi
cd "$tests_root"

make all
chcon -R -t test_file_t .

subdirs=$(make -pn 2>/dev/null | awk '/^SUBDIRS = / { $1 = $2 = ""; sub(/^ /, ""); print; exit }')
if [ -z "$subdirs" ]; then
    echo "FAIL: could not read SUBDIRS from Makefile" >&2
    exit 1
fi

id -Z
getenforce

rc=0
set +e
for d in $subdirs; do
    if [ ! -x "$d/test" ]; then
        echo "SKIP: ${d}/test (missing or not executable)" >&2
        continue
    fi
    echo "======== ${d}/test ========"
    if ! "./${d}/test"; then
        rc=1
    fi
done
set -e
exit "$rc"
