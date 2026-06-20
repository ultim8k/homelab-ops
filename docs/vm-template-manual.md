# Building the VM Template Manually

Creates the `lando-calrissian` cloud-init template by downloading a Debian cloud image, customising it with `virt-customize`, and importing it into Proxmox. This is the fallback path — use [vm-template-packer.md](vm-template-packer.md) for the automated, reproducible build.

## Prerequisites

- Proxmox VE installed and running — see [proxmox-host-setup.md](proxmox-host-setup.md)
- LVM-thin storage pool configured (e.g. `data`)
- Network bridge configured (e.g. `vmbr0`)

## 1. Download the Debian Cloud Image

```bash
wget https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
```

Verify checksum against https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS:

```bash
sha512sum debian-13-genericcloud-amd64.qcow2
```

## 2. Install virt-customize

```bash
sudo apt install libguestfs-tools -y
```

## 3. Customise the Image

> **Important:** `virt-customize` runs commands in a sandboxed environment with **no network access by default**. Any `--run-command` that needs internet (like the Docker install script) will silently fail without the `--network` flag.

```bash
sudo virt-customize --network -a debian-13-genericcloud-amd64.qcow2 \
  --install qemu-guest-agent,curl,wget,nano,rsync,htop,tmux,nfs-common \
  --run-command "curl -fsSL https://get.docker.com | sh" \
  --run-command "systemctl enable docker" \
  --run-command "systemctl enable systemd-networkd" \
  --run-command "systemctl enable systemd-resolved" \
  --run-command "curl -fsSL https://tailscale.com/install.sh | sh"
```

This takes a few minutes as it boots the image internally. Tailscale is installed but **not** enrolled — `tailscale up` requires an auth key and runs per-VM at first boot, not during image build.

## 4. Copy the homelab scripts into the image

These scripts need to live at `/usr/local/bin/` in every cloned VM:

```bash
sudo virt-customize -a debian-13-genericcloud-amd64.qcow2 \
  --copy-in scripts/homelab-backup:/usr/local/bin/ \
  --copy-in scripts/homelab-restore:/usr/local/bin/ \
  --run-command "chmod +x /usr/local/bin/homelab-backup /usr/local/bin/homelab-restore"
```

Then write the NAS config that `homelab-restore` reads on first boot. Use the same values as `nas_ip`, `nas_share`, and `compose_user` from your `vars.pkrvars.hcl`. Create the file locally first and upload it — `virt-customize` doesn't handle multi-line `--write` arguments reliably:

```bash
cat > /tmp/homelab-restore.env <<EOF
NAS_IP=<nas_ip>
NAS_SHARE=<nas_share>
COMPOSE_USER=<compose_user>
EOF

sudo virt-customize -a debian-13-genericcloud-amd64.qcow2 \
  --upload /tmp/homelab-restore.env:/etc/homelab-restore.env \
  --run-command "chmod 600 /etc/homelab-restore.env"

rm /tmp/homelab-restore.env
```

## 5. Resize the Image

```bash
qemu-img resize debian-13-genericcloud-amd64.qcow2 32G
```

Cloud-init's `growpart` module expands the root partition automatically on first boot.

## 6. Create the Template VM

```bash
sudo qm create 9000 --name lando-calrissian --memory 4096 --cores 2 --net0 virtio,bridge=vmbr0
```

> VM ID `9000` is a convention for templates. Use any ID above 100.
>
> Check your host's actual installed RAM before setting memory — verify with `sudo dmidecode -t memory`. Every clone inherits this value at creation time.

## 7. Import and Attach the Disk

```bash
sudo qm importdisk 9000 debian-13-genericcloud-amd64.qcow2 data
sudo qm set 9000 --scsihw virtio-scsi-pci --scsi0 data:vm-9000-disk-0
sudo qm set 9000 --ide2 data:cloudinit
sudo qm set 9000 --boot c --bootdisk scsi0
sudo qm set 9000 --serial0 socket --vga serial0
```

## 8. Configure Cloud-Init

Fetch your SSH public keys from the URL configured in `.env` (`SSH_KEYS_URL`):

```bash
source .env   # or paste the URL directly
curl -fsSL "$SSH_KEYS_URL" -o ~/authorized_keys
[[ -s ~/authorized_keys ]] || { echo "No keys returned from $SSH_KEYS_URL"; exit 1; }
sudo qm set 9000 --sshkeys ~/authorized_keys
sudo qm set 9000 --ciuser <your-username>
sudo qm set 9000 --ipconfig0 ip=dhcp
```

## 9. Convert to Template

```bash
sudo qm template 9000
```

The template appears in the Proxmox web UI with a template icon.

## Updating the Template

Download a fresh image and repeat steps 1–9. Destroy the old template first:

```bash
sudo qm destroy 9000
```

> Destroying the template does **not** affect clones that are already running.

## Notes

- The `genericcloud` image is optimised for KVM. Use the `generic` image if you have hardware compatibility issues.
- Default SSH user on Debian cloud images is `debian`, overridden by `--ciuser`.
- Cloud kernels lack USB host controller drivers — see [vm-operations.md](vm-operations.md) if you need USB/PCI passthrough on a specific clone.
