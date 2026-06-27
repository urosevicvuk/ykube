terraform {
  backend "local" {
    path = "../states/05-argocd.tfstate"
  }
}
