terraform {
  backend "local" {
    path = "../states/01-proxmox-iso-upload.tfstate"
  }
}
