packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# ---- Proxmox connection -------------------------------------------------------

variable "proxmox_url"      { type = string }
variable "proxmox_username" { type = string }
variable "proxmox_token"    { type = string; sensitive = true }
variable "proxmox_node"     { type = string }

# ---- VM identity -------------------------------------------------------------

variable "vm_id"   { type = number; default = 9000 }
variable "vm_name" { type = string; default = "lando-calrissian" }

# ---- Hardware ----------------------------------------------------------------

variable "storage_pool" { type = string; default = "data" }
variable "bridge"       { type = string; default = "vmbr0" }
variable "cores"        { type = number; default = 2 }
variable "memory"       { type = number; default = 2048 }
variable "disk_size"    { type = string; default = "20G" }

# ---- OS image ----------------------------------------------------------------
# Point at a Debian netinstall ISO. Download the URL and checksum from:
# https://www.debian.org/CD/netinst/

variable "iso_url"      { type = string }
variable "iso_checksum" { type = string }

# ---- Guest user --------------------------------------------------------------

variable "compose_user"          { type = string }
variable "compose_user_password" { type = string; sensitive = true }
variable "ssh_public_key"        { type = string }

# ---- NAS ---------------------------------------------------------------------

variable "nas_ip"    { type = string }
variable "nas_share" { type = string; default = "homelab-backups" }

# ==============================================================================

source "proxmox-iso" "lando-calrissian" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  insecure_skip_tls_verify = true
  node                     = var.proxmox_node

  vm_id   = var.vm_id
  vm_name = var.vm_name

  iso_url          = var.iso_url
  iso_checksum     = var.iso_checksum
  iso_storage_pool = "local"
  unmount_iso      = true

  cores  = var.cores
  memory = var.memory

  disks {
    type         = "scsi"
    disk_size    = var.disk_size
    storage_pool = var.storage_pool
  }

  network_adapters {
    bridge = var.bridge
    model  = "virtio"
  }

  # Enable cloud-init drive so cloned VMs can receive cloud-init config.
  cloud_init              = true
  cloud_init_storage_pool = var.storage_pool

  # Packer serves the http/ directory locally during the build so the
  # installer can fetch the preseed over HTTP.
  http_directory = "http"

  boot_wait = "10s"
  boot_command = [
    "<esc><wait>",
    "auto url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg<enter>"
  ]

  ssh_username = var.compose_user
  ssh_password = var.compose_user_password
  ssh_timeout  = "30m"

  template_name        = var.vm_name
  template_description = "Docker host template — Debian, Docker, Tailscale, NAS clients. Built by Packer on ${formatdate("YYYY-MM-DD", timestamp())}."
}

# ==============================================================================

build {
  sources = ["source.proxmox-iso.lando-calrissian"]

  # Upload the scripts that will live permanently in this image.
  provisioner "file" {
    source      = "${path.root}/../../scripts/homelab-backup"
    destination = "/tmp/homelab-backup"
  }

  provisioner "file" {
    source      = "${path.root}/../../scripts/homelab-restore"
    destination = "/tmp/homelab-restore"
  }

  provisioner "shell" {
    inline = [
      # Packages
      "sudo apt-get update -qq",
      "sudo apt-get install -y qemu-guest-agent curl wget nano rsync htop tmux nfs-common",

      # Docker
      "curl -fsSL https://get.docker.com | sudo sh",
      "sudo usermod -aG docker ${var.compose_user}",

      # Tailscale (install only — not enrolled here)
      "curl -fsSL https://tailscale.com/install.sh | sudo sh",

      # Install scripts
      "sudo mv /tmp/homelab-backup  /usr/local/bin/homelab-backup",
      "sudo mv /tmp/homelab-restore /usr/local/bin/homelab-restore",
      "sudo chmod +x /usr/local/bin/homelab-backup /usr/local/bin/homelab-restore",

      # Write NAS config — read by homelab-restore on first boot
      "printf 'NAS_IP=${var.nas_ip}\\nNAS_SHARE=${var.nas_share}\\nCOMPOSE_USER=${var.compose_user}\\n' | sudo tee /etc/homelab-restore.env > /dev/null",
      "sudo chmod 600 /etc/homelab-restore.env",

      # Add SSH public key
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh",
      "echo '${var.ssh_public_key}' >> ~/.ssh/authorized_keys",
      "chmod 600 ~/.ssh/authorized_keys",

      # Cleanup
      "sudo apt-get clean",
      "sudo cloud-init clean",
    ]
  }

}
