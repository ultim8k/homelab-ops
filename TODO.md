# TODO

Known gaps — not urgent but worth tracking.

## Backup retention policy

`homelab-backup` creates a new timestamped folder on the NAS on every run and never removes old ones. The NAS will fill up over time. Options: add a `--keep=N` flag that deletes all but the N most recent folders after a successful run, or manage retention manually on the NAS.

## SMB/CIFS support

Currently NFS only. SMB may be worth adding later for broader NAS compatibility (Synology, TrueNAS, etc. all support both). Would need to reintroduce `cifs-utils` in the Packer/manual template, a credentials file (or secrets manager), and a `mount -t cifs` path in `homelab-restore`.

## Archive integrity check

`homelab-restore` extracts archives with `tar -xzf` directly. A corrupted archive fails mid-extraction and can leave a stack in a partial state. A `tar -tzf` pass before extracting would catch corruption early and produce a clearer error.
