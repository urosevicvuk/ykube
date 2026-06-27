data "terraform_remote_state" "talos_factory" {
  backend = "local"
  config = {
    path = "../states/00-talos-factory.tfstate"
  }
}
