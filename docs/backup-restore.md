# Backup and Restore

Day-to-day usage of the three scripts and a full disaster recovery walkthrough.

## The Three Scripts at a Glance

| Script | Runs on | Triggered by |
|---|---|---|
| `homelab-backup` | Docker host VM (e.g. `tesseract`) | Cron, weekly |
| `restore-stacks` | Proxmox host (e.g. `pizza`) | You, manually, when rebuilding a VM |
| `homelab-restore` | Inside the new VM | Cloud-init on first boot (automatic) |

---

## NAS Share Setup (backup VM)

`homelab-backup` requires the NAS share to be already mounted — it doesn't mount it itself. Add a persistent fstab entry on the docker host VM:

```bash
sudo mkdir -p /mnt/nas
```

Add to `/etc/fstab` (substitute your actual NAS IP and share name):

```
<NAS_IP>:/<NAS_SHARE>  /mnt/nas  nfs  defaults,_netdev  0  0
```

The `_netdev` flag tells systemd to wait for the network before mounting — without it, the mount fails on boot and cron never gets a working share. Test with:

```bash
sudo mount -a
ls /mnt/nas    # should show any existing backup folders
```

> **NAS_IP and NAS_SHARE appear in two places**: `.env` on the Proxmox host (used by `restore-stacks`) and `vars.pkrvars.hcl` (baked into the VM image by Packer). If you change your NAS IP, update both.

---

## homelab-backup

Installed at `/usr/local/bin/homelab-backup` on the docker host VM. Stops each stack, tars the entire folder (compose file + bind-mounted data), copies it to the NAS, and restarts the stack.

**Dry run first:**

```bash
homelab-backup --dry-run
```

**Real run:**

```bash
homelab-backup
```

**Useful overrides:**

```bash
# Different compose root or backup destination
COMPOSE_ROOT=/home/your-username/compose BACKUP_DEST=/mnt/nas homelab-backup

# Skip specific stacks
SKIP_STACKS="scratch-project test-stuff" homelab-backup

# Keep local tar.gz copies in /tmp after copying to the share (debugging)
KEEP_LOCAL_COPIES=1 homelab-backup
```

**Schedule weekly via cron** (`crontab -e` on the docker host VM, every Sunday at 3am):

```cron
0 3 * * 0 /usr/local/bin/homelab-backup
```

The script writes timestamped output to `~/homelab-backup.log` via `tee` — no cron redirect needed.

> The NAS share must be mounted via `/etc/fstab` before this runs — cron has no interactive session to trigger an automount, and the script aborts with a clear error if the destination is not there.

**Check it worked:**

```bash
tail -50 ~/homelab-backup.log
ls /mnt/nas/     # should show a new dated folder
```

---

## restore-stacks

Runs on the Proxmox host. Clones a fresh VM from the `lando-calrissian` template, writes a cloud-init snippet that triggers `homelab-restore` on first boot, and starts the VM. No polling, no SCP — the VM takes it from there.

**Dry run first:**

```bash
./scripts/restore-stacks --vmid=105 --name=tesseract-v2 --dry-run
```

**Restore from the latest backup:**

```bash
./scripts/restore-stacks --vmid=105 --name=tesseract-v2
```

**Restore from a specific backup:**

```bash
./scripts/restore-stacks --vmid=105 --name=tesseract-v2 --backup-timestamp=2026-06-15_03-00-01
```

| Flag | Required | Meaning |
|---|---|---|
| `--vmid` | yes | New VM ID — must not already be in use (`qm list` to check) |
| `--name` | yes | Display name in the Proxmox UI |
| `--backup-timestamp` | no | Dated folder name on the NAS — omit to use the latest |
| `--dry-run` | no | Print the plan without cloning or starting anything |

The script reads `TEMPLATE_ID`, `COMPOSE_USER`, `NAS_IP`, `NAS_SHARE`, `SSH_KEYS_URL`, and `TAILSCALE_AUTH_KEY` from `.env` in the repo root — copy `.env.example` to `.env` and fill it in before running. `SSH_KEYS_URL` is required and must return at least one key or the script aborts.

**Watch restore progress** (once the VM has booted and you have its IP):

```bash
ssh your-username@<vm-ip> 'sudo journalctl -fu cloud-final'
```

---

## homelab-restore

Installed at `/usr/local/bin/homelab-restore` on every VM cloned from the template. Normally triggered automatically by the cloud-init snippet — you don't need to run it by hand.

Run it manually to re-restore an already-running VM (e.g. to roll back to an older backup, or to re-run after a failed first-boot restore):

**Dry run (no root needed):**

```bash
homelab-restore --dry-run
homelab-restore --dry-run 2026-06-15_03-00-01
```

**Real run, latest backup:**

```bash
sudo homelab-restore
```

**Real run, specific backup:**

```bash
sudo homelab-restore 2026-06-15_03-00-01
```

Config is read from `/etc/homelab-restore.env` (baked in by Packer). Override any value with an env var:

```bash
sudo NAS_IP=192.168.1.200 homelab-restore
```

---

## Disaster Recovery — Full Walkthrough

```bash
# 1. Backups run automatically on the docker host VM every Sunday at 3am.
#    Verify the latest one is there before you need it:
ls /mnt/nas/    # on the docker host VM

# 2. Something goes wrong with tesseract. Destroy the old VM from the Proxmox host:
qm destroy 101

# 3. Restore from the latest backup (on the Proxmox host):
./scripts/restore-stacks --vmid=101 --name=tesseract

# 4. The VM boots and restores all stacks automatically.
#    Watch it happen:
ssh your-username@<new-vm-ip> 'sudo journalctl -fu cloud-final'

# 5. Verify everything is up:
ssh your-username@<new-vm-ip> 'docker ps'
```

End to end: a few minutes, most of it waiting for the VM to boot and for `docker compose up -d` to pull images.

**To restore from a specific older backup instead of the latest:**

```bash
# List available backups on the NAS
ls /mnt/nas/

# Pass the timestamp to restore-stacks
./scripts/restore-stacks --vmid=101 --name=tesseract --backup-timestamp=2026-06-08_03-00-01
```
