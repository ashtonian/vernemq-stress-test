terraform {
  backend "local" {
    path = "../state/monitoring.tfstate"
  }
}
