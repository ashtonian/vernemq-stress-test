terraform {
  backend "local" {
    path = "../state/network.tfstate"
  }
}
