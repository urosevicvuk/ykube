terraform {
  backend "local" {
    path = "../states/02-proxmox-provision.tfstate"
  }
}
