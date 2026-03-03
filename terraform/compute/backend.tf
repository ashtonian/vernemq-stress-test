terraform {
  backend "local" {
    path = "../state/compute.tfstate"
  }
}
