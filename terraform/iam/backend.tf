terraform {
  backend "local" {
    path = "../state/iam.tfstate"
  }
}
