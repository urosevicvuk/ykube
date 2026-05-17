data "terraform_remote_state" "talos_configure" {
  backend = "local"
  config = {
    path = "../states/03-talos-configure.tfstate"
  }
}
