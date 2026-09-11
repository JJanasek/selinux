#!/bin/bash
# Load selinux-testsuite test_policy early (before /run/main) and capture
# audit/journal evidence if runcon into test_inet_server_t fails.
# Informational only (always exit 0). See mls-final-copr-test.fmf order 2.9.
set -x

sts_tests_dir=$(find /var/ARTIFACTS /var/tmp -maxdepth 8 -type d \
    -path '*/discover/selinux-testsuite/tests' 2>/dev/null | head -n1)
echo "=== selinux-testsuite tests dir: ${sts_tests_dir:-NOT FOUND} ==="

if [ -z "$sts_tests_dir" ]; then
    echo "SKIP: testsuite tree not found"
    exit 0
fi

policy_dir="$sts_tests_dir/policy"
tcp_dir="$sts_tests_dir/tests/inet_socket/tcp"

echo "=== id -Z ==="
id -Z

echo "=== make -C policy load (early, same as run/main preamble) ==="
if ! make -C "$policy_dir" load; then
    echo "WARN: policy load failed; skipping runcon repro"
    exit 0
fi

if [ ! -x "$tcp_dir/server" ]; then
    echo "=== building inet_socket/tcp binaries ==="
    make -C "$tcp_dir" all || true
fi

if [ -x "$tcp_dir/server" ]; then
    echo "=== ls -laZ $tcp_dir/server ==="
    ls -laZ "$tcp_dir/server" 2>&1
    echo "=== runcon repro: test_inet_client_t (/bin/true) ==="
    runcon -t test_inet_client_t /bin/true 2>&1 || true
    echo "=== runcon repro: test_inet_server_t (/bin/true) ==="
    runcon -t test_inet_server_t /bin/true 2>&1 || true
    echo "=== runcon repro: test_inet_server_t on testsuite server binary ==="
    runcon -t test_inet_server_t "$tcp_dir/server" 2>&1 || true
else
    echo "WARN: $tcp_dir/server not executable; skipping runcon repro"
fi

echo "=== ausearch AVC,USER_AVC --input-logs -ts recent ==="
ausearch -m AVC,USER_AVC --input-logs -ts recent -i 2>&1 | \
    grep -i -E 'test_inet|runcon|test_file|execute|transition|setexec|mcs_constrained' || true

echo "=== full ausearch AVC,USER_AVC --input-logs -ts recent (unfiltered tail) ==="
ausearch -m AVC,USER_AVC --input-logs -ts recent -i 2>&1 | tail -n 80 || true

echo "=== journalctl -b --no-pager (avc|selinux|denied|test_inet|runcon) ==="
journalctl -b --no-pager 2>&1 | \
    grep -i -E 'avc|selinux.*denied|test_inet|runcon' | tail -n 120 || true

echo "=== dmesg (avc / denied) ==="
dmesg 2>/dev/null | grep -i -E 'avc|denied|test_inet|runcon' | tail -n 80 || true

exit 0
