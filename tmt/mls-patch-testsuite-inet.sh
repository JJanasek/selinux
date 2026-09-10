#!/bin/bash
# Patch selinux-testsuite's test_inet_socket.te before the selinux-testsuite
# discover phase runs /run/main (make -C policy load). Must live in an
# earlier discover phase than the fmf testsuite -- see mls-final-copr-test.fmf
# "Problem B".
set -euo pipefail

marker='mls-final-copr-test: skip mcs_constrained on test_inet_server_t for MLS'

patch_one() {
    local sts_policy="$1"
    if grep -qF "$marker" "$sts_policy"; then
        echo "Already patched: $sts_policy"
        return 0
    fi
    python3 - "$sts_policy" "$marker" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
marker = sys.argv[2]
text = path.read_text()

needle = """# We need to ensure that the test domain is MCS constrained.
## newer systems, e.g. Fedora and RHEL >= 7.x
ifdef(`mcs_constrained', `
	mcs_constrained(test_inet_server_t)
')
## older systems, e.g. RHEL == 6.x
ifdef(`mcs_untrusted_proc', `
	mcs_untrusted_proc(test_inet_server_t)
')"""

replacement = f"""# {marker}
# (mcs_constrained / mcs_untrusted_proc on test_inet_server_t removed for MLS:
#  runcon into the server domain fails with Permission denied while the
#  client domain without these macros works -- TF bc9ce803.)"""

if needle not in text:
    sys.exit("FAIL: test_inet_socket.te layout changed; update mls-patch-testsuite-inet.sh")

path.write_text(text.replace(needle, replacement, 1))
print(f"Patched {path}")
PY
}

mapfile -t candidates < <(
    find /var/ARTIFACTS /var/tmp -maxdepth 14 -type f \
        -path '*/discover/selinux-testsuite/tests/policy/test_inet_socket.te' 2>/dev/null \
        | sort -u
)

if [ "${#candidates[@]}" -eq 0 ]; then
    echo "FAIL: discover/selinux-testsuite/tests/policy/test_inet_socket.te not found" >&2
    exit 1
fi

for sts_policy in "${candidates[@]}"; do
    patch_one "$sts_policy"
    if grep -qE 'mcs_constrained\(test_inet_server_t\)|mcs_untrusted_proc\(test_inet_server_t\)' \
        "$sts_policy"; then
        echo "FAIL: $sts_policy still contains MCS server macros after patch" >&2
        exit 1
    fi
    if ! grep -qF "$marker" "$sts_policy"; then
        echo "FAIL: patch marker missing in $sts_policy" >&2
        exit 1
    fi
    echo "Verified: $sts_policy has no mcs_* on test_inet_server_t"
done
