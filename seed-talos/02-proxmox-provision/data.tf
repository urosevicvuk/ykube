data "terraform_remote_state" "proxmox_iso" {
  backend = "local"
  config = {
    path = "../states/01-proxmox-iso-upload.tfstate"
  }
}
