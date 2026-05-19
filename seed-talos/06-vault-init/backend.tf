terraform {
  backend "local" {
    path = "../states/06-vault-init.tfstate"
  }
}
