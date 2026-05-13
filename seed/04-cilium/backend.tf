terraform {
  backend "local" {
    path = "../states/04-cilium.tfstate"
  }
}
