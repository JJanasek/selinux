#!/bin/bash
# Upstream /run/main, plus MLS workaround for testsuite policy/test_inet_socket.te.
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
exec make test
