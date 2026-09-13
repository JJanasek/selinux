# MLS COPR plan — debugging extras

Not used by production plan `/tmt/mls-final-copr-test`. For investigation
runs on `mls-final-copr-test` (or a dedicated debug branch).

| Script | Role |
|--------|------|
| `mls-boot-cloudinit-avc-check.sh` | cloud-init done + boot AVC dump |
| `mls-testsuite-run-main-diag.sh` | ausearch/journal after `run/main` |

Optional plan: `/tmt/debug/mls-copr/mls-final-copr-test-debug` (same prepare
as COPR test, extra discover tests).

Forensic prepare snippets (e.g. `id -Z` bootcmd via cloud.cfg.d) live in
`mls.fmf` / `mls-final-prepare.sh` on investigation branches, not in
`mls-final-copr-prepare.sh`.
