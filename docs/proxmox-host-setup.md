# Proxmox VE Setup on Debian 13 (Trixie)

Installing Proxmox VE on top of a plain Debian 13 install — not using the official Proxmox ISO.

## Prerequisites

- Debian 13 (Trixie) installed with SSH server and standard utilities only — no desktop environment
- Static IP configured (or a DHCP reservation on your router)

## Check Your Hardware

Before sizing VMs, confirm what the host actually has — sellers' listings aren't always accurate.

```bash
free -h                   # current RAM
sudo dmidecode -t memory  # installed DIMMs, slots, max capacity
lscpu                     # CPU cores and threads
lsblk && df -h            # disks and partitions
```

## Configure Hostname

Proxmox requires the hostname to resolve to the actual LAN IP, not `127.0.1.1`.

Edit `/etc/hosts` so it looks like this:

```
127.0.0.1       localhost
<your-lan-ip>   <hostname>.<your-domain> <hostname>
```

Verify with `hostname -f` — should return the full FQDN.

## Add Proxmox Repository

```bash
sudo wget -O /etc/apt/keyrings/proxmox-release-trixie.gpg \
  https://download.proxmox.com/debian/proxmox-release-trixie.gpg

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/proxmox-release-trixie.gpg] \
  http://download.proxmox.com/debian/pve trixie pve-no-subscription" | \
  sudo tee /etc/apt/sources.list.d/pve-install-repo.list

sudo apt update
```

## Install Proxmox VE

```bash
sudo apt full-upgrade -y
sudo apt install proxmox-ve postfix open-iscsi chrony -y
```

When Postfix asks for configuration type, select **Local only**. If prompted about GPG key files, select **Y** to use the package maintainer's version.

## Disable the Enterprise Repository

The enterprise repo requires a paid subscription. Comment it out:

```bash
sudo nano /etc/apt/sources.list.d/pve-enterprise.sources
```

Add `#` to the start of every line. Run `sudo apt update` to confirm no errors.

## Configure Storage

If you left unpartitioned space on your disk during Debian install, create a partition for VM storage:

```bash
sudo fdisk /dev/nvme0n1
# n → new partition, accept all defaults, w → write and exit
```

Set up an LVM-thin pool for VM disk images. LVM (Logical Volume Manager) lets you manage disk space as named logical volumes rather than fixed partitions. The "thin" part means disk space is allocated on demand as VMs actually write data, not upfront — so a VM can be given a 32GB disk while the pool only commits real space as it fills. This also makes snapshots cheap (only changed blocks are stored) and `qm clone` fast (linked clones share the base image and only diverge on writes).

```bash
sudo pvcreate /dev/nvme0n1p3
sudo vgcreate pve /dev/nvme0n1p3
sudo lvcreate -l 100%FREE --thinpool pve/data
```

Set up swap:

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## Configure Network Bridge

VMs need a bridge interface to reach your local network.

```bash
sudo nano /etc/network/interfaces
```

Replace the main interface config with:

```
auto enp2s0f0
iface enp2s0f0 inet manual

auto vmbr0
iface vmbr0 inet dhcp
    bridge-ports enp2s0f0
    bridge-stp off
    bridge-fd 0
```

Replace `enp2s0f0` with your actual interface name (`ip link` to check). Then apply:

```bash
sudo systemctl restart networking
```

## Reboot and Verify

```bash
sudo reboot
uname -r    # should show something like 6.x.x-x-pve
```

## Web UI

Open `https://<your-ip>:8006` in a browser. Accept the certificate warning. Log in with `root` and your Debian root password. Dismiss the "No valid subscription" popup — expected for homelab use.

## Add the LVM-Thin Storage to Proxmox

The LVM-thin pool exists at the Linux level after the previous step, but Proxmox keeps its own list of storage backends in `/etc/pve/storage.cfg` and doesn't discover pools automatically. This step registers it under the name `data` so that `qm`, Packer, and the web UI can all reference it when creating or cloning VM disks.

Via the CLI (simpler):

```bash
pvesm add lvmthin data --vgname pve --thinpool data --content images,rootdir
```

Or via the web UI — **Datacenter → Storage → Add → LVM-Thin**:

- ID: `data`
- Volume group: `pve`
- Thin pool: `data`
- Content: Disk image, Container

## Enable Snippets Storage

Required for `restore-stacks` to attach cloud-init configs to new VMs:

```bash
pvesm set local --content vztmpl,iso,backup,snippets
```

---

## Maintenance

### Adjusting VM Memory or CPU

If a VM is swapping or feels slow, check both sides before bumping allocation:

```bash
# Inside the VM:
free -h    # if `available` is near zero, it's genuinely maxed out

# On the Proxmox host:
free -h                   # current headroom
sudo dmidecode -t memory  # actual installed RAM — don't guess
```

Bump the allocation:

```bash
sudo qm set <vmid> --memory 6144   # MB
sudo qm set <vmid> --cores 4
sudo qm reboot <vmid>
```

Memory and CPU changes take effect after reboot, not immediately. A plain `qm reboot` is enough — unlike USB passthrough changes, which need a full `qm stop` + `qm start`.

---

## Optional: USB Passthrough Host-Side Prep

Only needed if you plan to pass a USB device through to a VM (e.g. a Bluetooth dongle for Home Assistant). The host must not claim the device itself or the VM will never see it.

For the guest-side steps (kernel, firmware, attaching the device), see [vm-operations.md](vm-operations.md).

**Identify the device:**

```bash
lsusb && lsusb -t
```

Look for `Driver=[none]` — if a driver is bound (e.g. `btusb` for Bluetooth), the host is claiming it.

**Blacklist the driver permanently:**

```bash
echo "blacklist btusb" | sudo tee /etc/modprobe.d/blacklist-bluetooth.conf
sudo update-initramfs -u -k all
sudo systemctl disable --now bluetooth.service
sudo systemctl mask bluetooth.service
sudo reboot
```

After reboot:

```bash
lsmod | grep btusb    # should be empty
lsusb -t              # device should show Driver=[none]
```
