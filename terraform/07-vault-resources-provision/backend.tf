terraform {
  backend "local" {
    path = "../states/07-vault-resources-provision.tfstate"
  }
}
