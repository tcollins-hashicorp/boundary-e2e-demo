terraform {
  required_version = ">= 1.6.0"
  required_providers {
    boundary = {
      source  = "hashicorp/boundary"
      version = "~> 1.3"
    }
  }
}
