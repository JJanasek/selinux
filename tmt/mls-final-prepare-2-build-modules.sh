#!/bin/bash
set -eo pipefail

dnf install -y policycoreutils-devel

# Stage missing interface files
cp $TMT_TREE/tmt/mls-cloudinit-fix/networkmanager-manage-rw-conf.if /usr/share/selinux/devel/include/contrib/
cp $TMT_TREE/tmt/mls-cloudinit-fix/ssh-read-server-keys.if /usr/share/selinux/devel/include/contrib/
cp $TMT_TREE/tmt/mls-cloudinit-fix/sysnetwork-manage-config-sockets.if /usr/share/selinux/devel/include/system/

mkdir -p /root/build && cd /root/build
cp $TMT_TREE/tmt/mls-cloudinit-fix/cloudform.* .
cp $TMT_TREE/tmt/mls-ssh-pipes-fix/mlssshpipes.te .
cp $TMT_TREE/tmt/mls-udev-ptrace-fix/udevptrace.te .

# Five narrowly-targeted udev_t fixes that replace the old blanket
# `semanage permissive -n -a udev_t` workaround; see each module's own
# .te comment block for the AVC it closes.
cp $TMT_TREE/tmt/mls-udev-nsfs-fix/udevnsfs.te .
cp $TMT_TREE/tmt/mls-udev-rlimit-fix/udevrlimit.te .
cp $TMT_TREE/tmt/mls-udev-cgroup-fix/udevcgroup.te .
cp $TMT_TREE/tmt/mls-udev-kobjectuevent-fix/udevkobjectuevent.te .
cp $TMT_TREE/tmt/mls-udev-tmpfs-fix/udevtmpfs.te .

make -f /usr/share/selinux/devel/Makefile cloudform.pp mlssshpipes.pp udevptrace.pp udevnsfs.pp udevrlimit.pp udevcgroup.pp udevkobjectuevent.pp udevtmpfs.pp

# Load modules into the inactive MLS store (-n) without hot-reloading
semodule -n -i cloudform.pp mlssshpipes.pp udevptrace.pp udevnsfs.pp udevrlimit.pp udevcgroup.pp udevkobjectuevent.pp udevtmpfs.pp
semodule -l | grep -E '^(cloudform|mlssshpipes|udevptrace|udevnsfs|udevrlimit|udevcgroup|udevkobjectuevent|udevtmpfs)\b'
