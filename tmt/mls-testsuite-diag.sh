#!/bin/bash
# Diagnostic-only test for Problem A (see mls-final-copr-test.fmf's
# description): the real Testing Farm run d1bebfbc-9770-4a68-a193-
# a193-9dbe285ab1cd/d1bebfbc-9770-4a68-a193-9dbe285ab1cd showed
# /selinux-testsuite/tmt/tests/run/main erroring out with:
#   libsemanage.semanage_direct_install_file: Unable to read file
#   test_policy/test_policy.pp. (Permission denied).
# during `semodule -i test_policy/test_policy.pp ...` -- but that run
# captured no ausearch/ls -Z evidence for it (tmt's own artifact copying
# only kept output.txt for that testcase), so the root cause (real MLS
# `mlsconstrain`/range-transition AVC vs. a plain DAC/ownership issue from
# the preceding `make` step) is not yet confirmed with hard evidence.
#
# This test runs strictly between /selinux-testsuite/tmt/tests/run/main
# (order: 3, where the failure happens) and .../unprepare (order: 5,
# which does not touch /var/log/audit/audit.log) -- so ausearch here still
# covers the run/main failure. It is purely informational: it always
# exits 0 and must never gate the plan's pass/fail result, since its only
# purpose is to capture real evidence for a future selinux-policy ticket
# (see also mls-testsuite-diag-run-main-evidence in this plan's
# discover/execute data for how to read the results).
set -x

# The selinux-testsuite `how: fmf` discover phase clones into a per-run,
# randomly-named workdir (e.g. .../work-XXXXXXXX/tmt/mls-final-copr-test/
# discover/selinux-testsuite/tests) -- find it instead of hardcoding it.
sts_tests_dir=$(find /var/ARTIFACTS /var/tmp -maxdepth 8 -type d \
    -path '*/discover/selinux-testsuite/tests' 2>/dev/null | head -n1)
echo "=== selinux-testsuite tests dir: ${sts_tests_dir:-NOT FOUND} ==="

if [ -n "$sts_tests_dir" ]; then
    pp_dir="$sts_tests_dir/policy/test_policy"
    pp_file="$pp_dir/test_policy.pp"

    echo "=== ls -laZ $pp_dir ==="
    ls -laZ "$pp_dir" 2>&1

    echo "=== stat $pp_file ==="
    stat "$pp_file" 2>&1

    echo "=== matchpathcon $pp_file (expected label per file_contexts) ==="
    matchpathcon "$pp_file" 2>&1

    echo "=== stat of the parent tree up to the workdir root (DAC bits/owners along the path) ==="
    d="$pp_dir"
    while [ "$d" != "/" ] && [ "$d" != "." ]; do
        stat -c '%A %U:%G %n' "$d" 2>&1
        d=$(dirname "$d")
    done
else
    echo "Could not locate the selinux-testsuite tests dir; skipping file-level checks."
fi

echo "=== current shell's own SELinux context (id -Z) ==="
id -Z

echo "=== full sestatus ==="
sestatus

echo "=== AVC/USER_AVC denials since /prepare-system reset the audit log ==="
# --input-logs, same rationale as mls-final-copr-execute.sh: without it
# ausearch silently reads stdin instead of the real audit log whenever
# stdin isn't a TTY. ausearch itself exits 1 on "nothing found", so `|| true`
# throughout to keep this script from aborting under `set -e` semantics
# (not set here, but kept consistent/defensive).
ausearch -m AVC,USER_AVC --input-logs -ts recent -i 2>&1 || true

echo "=== full recent audit trail mentioning semodule/test_policy/semanage (any DAC-only denials, USER_* records, etc. that -m AVC,USER_AVC alone might miss) ==="
ausearch --input-logs -ts recent -i 2>&1 | grep -i -C5 'semodule\|test_policy\|semanage' || true

# Always pass: this test only exists to collect evidence, never to gate
# the plan's result.
exit 0
