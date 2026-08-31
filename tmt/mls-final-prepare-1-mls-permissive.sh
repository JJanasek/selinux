#!/bin/bash
set -eo pipefail

dnf install -y selinux-policy-mls policycoreutils-python-utils audit

source $TMT_TREE/tmt/prepare_for_mls.sh
prepare_for_mls_configure

# Stay permissive for the initial relabel reboot
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config

# Preserve SSH host keys across reboots to maintain tmt connection
mkdir -p /etc/cloud/cloud.cfg.d
echo 'ssh_deletekeys: false' > /etc/cloud/cloud.cfg.d/99-preserve-ssh-host-keys.cfg

# Capture the context cloud-init actually runs under via a bootcmd
# subprocess (inherits cloud-init's live domain, no exec transition of
# its own) -- cloud-init-main.service is too short-lived to catch later.
cat > /etc/cloud/cloud.cfg.d/98-selinux-context-check.cfg <<'CICFG'
bootcmd:
  - [ sh, -c, "id -Z > /var/log/cloud-init-selinux-context.log 2>&1" ]
CICFG

# Reset cloud-init state to force a full run under MLS
cloud-init clean --logs
