# VM Operations

Day-to-day operations on running VMs: cloning, resizing, modifying in place, and USB/PCI passthrough.

## Cloning the Template

**Full clone** (independent disk — used by `restore-stacks`):

```bash
sudo qm clone 9000 101 --name my-vm --full
sudo qm start 101
```

**Linked clone** (shares base disk, saves space — fine for short-lived VMs):

```bash
sudo qm clone 9000 101 --name my-vm
sudo qm start 101
```

If the clone comes up with no network, go to **Proxmox web UI → VM → Cloud-Init tab → set IP Config (net0) to `dhcp` → Regenerate Image**, then start it.

## Resizing Memory on a Running VM

```bash
sudo qm set <vmid> --memory 6144
sudo qm reboot <vmid>
```

Memory is not hot-pluggable — the new value takes effect after reboot, not immediately. Check the host's available RAM first to avoid over-allocating:

```bash
free -h                      # on the Proxmox host
sudo dmidecode -t memory     # confirms actual installed RAM
```

## Auto-start on Host Boot

```bash
sudo qm set <vmid> --onboot 1
```

Verify:

```bash
sudo qm config <vmid> | grep onboot
```

Should return `onboot: 1`. To disable: `--onboot 0`.

## Modify In Place vs. Rebuild from Template

**Modify in place** when the change is specific to one VM and you don't want it in every future clone — e.g. installing a kernel module for USB passthrough on one stack's VM.

**Rebuild the template** when the change should apply to every VM cloned from it — e.g. adding a new package, updating the NAS IP, changing `homelab-restore`. See [vm-template-packer.md](vm-template-packer.md) for the rebuild process.

---

## USB & Bluetooth Passthrough

Passing through a physical USB device from the Proxmox host into a guest VM. Documented here because the cloud kernel that ships with the template lacks USB host drivers — passthrough requires extra steps on the specific VM that needs it.

### 1. Identify the Device on the Host

```bash
lsusb
```

Note the vendor:product ID, e.g. `0b05:190e` for an ASUS Bluetooth dongle.

### 2. Prevent the Host from Claiming the Device

If it's a Bluetooth dongle, the host's `btusb` module will grab it automatically — including after every reset or replug. Blacklist it permanently:

```bash
echo "blacklist btusb" | sudo tee /etc/modprobe.d/blacklist-bluetooth.conf
sudo update-initramfs -u -k all
sudo systemctl disable --now bluetooth.service
sudo systemctl mask bluetooth.service
sudo reboot
```

After reboot:

```bash
lsmod | grep btusb      # should be empty
lsusb -t                # device should show Driver=[none]
```

> For other device types, check `lsusb -t` for the `Driver=` field to identify which module is holding it.

### 3. Install the Regular Kernel in the Guest VM

Cloud kernels have no USB host controller drivers. Inside the **specific VM** that needs passthrough:

```bash
apt update && apt install linux-image-amd64
nano /etc/default/grub   # set GRUB_TIMEOUT=10 so you can interact with the menu if needed
update-grub && reboot
```

If it boots back into the cloud kernel, remove it to eliminate ambiguity:

```bash
apt remove linux-image-*-cloud-amd64 linux-image-cloud-amd64 -y
update-grub && reboot
```

Confirm:

```bash
uname -r          # should show e.g. 6.12.90+deb13.1-amd64, no "cloud"
lsmod | grep -i usb
```

### 4. Attach the Device to the VM

Use **vendor:product ID**, not bus-port notation — bus/port numbers can shift across reboots and caused silent failures in testing even when the device appeared attached at the QEMU level:

```bash
sudo qm set <vmid> --usb0 host=0b05:190e
```

Do **not** add `usb3=1` for low/full-speed devices like Bluetooth dongles — forcing USB3 mode caused enumeration to silently fail.

Then stop/start the VM (a guest reboot is not enough — USB passthrough is applied when the QEMU process starts):

```bash
sudo qm stop <vmid>
sudo qm start <vmid>
```

### 5. Verify Inside the Guest

```bash
lsusb -t
dmesg | tail -20
hciconfig          # for Bluetooth
```

### 6. Bluetooth Firmware (Realtek dongles)

Realtek-based dongles need a firmware blob not in Debian's main repo:

```bash
sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
apt update && apt install firmware-realtek -y
rmmod btusb && modprobe btusb
hciconfig hci0 up
```

### 7. Expose to a Docker Container

```yaml
services:
  homeassistant:
    network_mode: host
    privileged: true
    volumes:
      - /var/run/dbus:/var/run/dbus:ro
```

`network_mode: host` is required for mDNS and device discovery. `privileged: true` plus the D-Bus mount gives the container access to BlueZ on the host VM.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Device in `qm config` but never appears in guest `lsusb` | Cloud kernel has no USB host drivers | Install `linux-image-amd64`, remove cloud kernel |
| Device disappears after host reboot | Host module re-claimed it | Blacklist module + `update-initramfs -u` + reboot host |
| `host=bus-port` doesn't enumerate in guest | Bus/port mismatch across reboots | Use `host=vendor:product` |
| `firmware: failed to load rtl_bt/*.bin` | Missing non-free firmware | Enable `non-free-firmware`, install `firmware-realtek` |
| New USB config not applied after guest reboot | Reboot doesn't restart the QEMU process | Use `qm stop` + `qm start` from the Proxmox host |
