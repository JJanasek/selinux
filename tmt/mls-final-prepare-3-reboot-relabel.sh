#!/bin/bash
set -eo pipefail

source $TMT_TREE/tmt/prepare_for_mls.sh
prepare_for_mls_reboot
prepare_for_mls_force_relabel
