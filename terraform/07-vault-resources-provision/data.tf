data "terraform_remote_state" "vault_init" {
  backend = "local"
  config = {
    path = "../states/06-vault-init.tfstate"
  }
}
