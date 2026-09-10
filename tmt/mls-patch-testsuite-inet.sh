#!/bin/bash
# Patch selinux-testsuite's test_inet_socket.te before /run/main loads
# test_policy. See mls-final-copr-test.fmf "Problem B".
set -euo pipefail

sts_policy=$(find /var/ARTIFACTS /var/tmp -maxdepth 12 -type f \
    -path '*/discover/selinux-testsuite/tests/policy/test_inet_socket.te' 2>/dev/null | head -n1)

if [ -z "$sts_policy" ]; then
    echo "FAIL: discover/selinux-testsuite/tests/policy/test_inet_socket.te not found" >&2
    exit 1
fi

marker='mls-final-copr-test: skip mcs_constrained on test_inet_server_t for MLS'
if grep -qF "$marker" "$sts_policy"; then
    echo "Already patched: $sts_policy"
    exit 0
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
