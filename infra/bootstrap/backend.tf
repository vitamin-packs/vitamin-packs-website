terraform {
  backend "s3" {
    bucket       = "lrjonline-vitamin-packs-tf-state"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
  }
}