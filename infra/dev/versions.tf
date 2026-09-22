terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Inktree's bucket, our own prefix. They occupy dev/terraform.tfstate with the
  # project-level layer, so this one sits beside it rather than on top of it.
  backend "gcs" {
    bucket = "inktree-dailycare-dev-terraform-state"
    prefix = "application/dev"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
