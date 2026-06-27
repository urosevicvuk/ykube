terraform {
  backend "local" {
    path = "../states/03-talos-configure.tfstate"
  }
}
