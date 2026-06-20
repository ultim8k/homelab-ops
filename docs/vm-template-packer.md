# Building the VM Template with Packer

Builds the `lando-calrissian` cloud-init template automatically using Packer. Reproducible — run `packer build` and get the exact same image every time. This is the preferred path over the [manual process](vm-template-manual.md).

## Prerequisites

- Packer installed locally — [packer.io](https://developer.hashicorp.com/packer/install)
- Proxmox VE installed and running — see [proxmox-host-setup.md](proxmox-host-setup.md)
- A Proxmox API token with VM permissions (see below)
- A Debian netinstall ISO URL + checksum — [debian.org/CD/netinst](https://www.debian.org/CD/netinst/)

## 1. Create a Proxmox API Token for Packer

In the Proxmox web UI:

1. **Datacenter → Permissions → Users** — create a `packer` user (realm: Proxmox VE authentication server)
2. **Datacenter → Permissions → API Tokens** — create a token for that user, uncheck "Privilege Separation"
3. **Datacenter → Permissions → Add → User Permission** — assign the following role to the `packer` user on `/`:
   - `VM.Allocate`, `VM.Clone`, `VM.Config.CDROM`, `VM.Config.CPU`, `VM.Config.Disk`, `VM.Config.HWType`, `VM.Config.Memory`, `VM.Config.Network`, `VM.Config.Options`, `Datastore.AllocateSpace`, `Datastore.AllocateTemplate`, `Sys.Modify`

Note the token ID (`packer@pve!packer`) and secret — you'll need both in the next step.

## 2. Configure Your Variables

```bash
cp packer/lando-calrissian/vars.pkrvars.hcl.example packer/lando-calrissian/vars.pkrvars.hcl
```

Edit `vars.pkrvars.hcl` and fill in all values. Key ones:

| Variable | What it is |
|---|---|
| `proxmox_url` | `https://YOUR_PROXMOX_IP:8006/api2/json` |
| `proxmox_username` | `packer@pve!packer` (user@realm!tokenid) |
| `proxmox_token` | the token secret |
| `proxmox_node` | node name shown in the Proxmox UI |
| `compose_user` | the non-root user who will own stacks on every cloned VM |
| `compose_user_password` | temporary password used only during this build |
| `ssh_public_key` | your SSH public key — goes into `~/.ssh/authorized_keys` |
| `nas_ip` | NAS IP — baked into `/etc/homelab-restore.env` in the image |
| `iso_url` / `iso_checksum` | Debian netinstall ISO URL and SHA256 checksum |

## 3. Update the Preseed

`packer/lando-calrissian/http/preseed.cfg` has two placeholders that must match your vars:

- `passwd/username` → must match `compose_user`
- `passwd/user-password` and `passwd/user-password-again` → must match `compose_user_password`

These can't be injected automatically since the preseed is served as a static file.

## 4. Install the Proxmox Packer Plugin

```bash
cd packer/lando-calrissian
packer init lando-calrissian.pkr.hcl
```

This downloads the `hashicorp/proxmox` plugin declared in the `required_plugins` block.

## 5. Validate

```bash
packer validate -var-file=vars.pkrvars.hcl lando-calrissian.pkr.hcl
```

## 6. Build

```bash
packer build -var-file=vars.pkrvars.hcl lando-calrissian.pkr.hcl
```

Packer will:
1. Boot a Debian netinstall ISO on Proxmox using the preseed
2. SSH in once the install finishes
3. Install Docker, Tailscale, and NAS clients
4. Copy `homelab-backup` and `homelab-restore` into `/usr/local/bin/`
5. Write `/etc/homelab-restore.env` from your vars
6. Add your SSH public key
7. Convert the VM to a template

The build takes roughly 10–20 minutes depending on network speed.

## Updating the Template

Edit `lando-calrissian.pkr.hcl` (add packages, change provisioner steps, etc.), then:

```bash
# Remove the old template first — Packer can't overwrite it
sudo qm destroy 9000   # on the Proxmox host

# Rebuild
packer build -var-file=vars.pkrvars.hcl lando-calrissian.pkr.hcl
```

> Destroying the template does **not** affect clones that are already running.

## What Gets Baked In

| What | Where in image | Set by |
|---|---|---|
| Docker + docker compose | system packages | shell provisioner |
| Tailscale (not enrolled) | system packages | shell provisioner |
| `nfs-common` | system packages | shell provisioner |
| `qemu-guest-agent` | system packages | shell provisioner |
| `homelab-backup` | `/usr/local/bin/` | file provisioner |
| `homelab-restore` | `/usr/local/bin/` | file provisioner |
| NAS IP, share, user | `/etc/homelab-restore.env` | shell provisioner |
| Your SSH public key | `~/.ssh/authorized_keys` | shell provisioner |

Tailscale enrollment (`tailscale up`) is **not** baked in — it runs at first boot via the cloud-init snippet that `restore-stacks` generates, using `TAILSCALE_AUTH_KEY` from `.env`.
