terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Staging's own bucket, in staging's own project. A shared bucket with two prefixes
  # would work and would also mean one set of credentials reaches both environments'
  # state, which is the thing separate environments exist to prevent.
  backend "gcs" {
    bucket = "inktree-dailycare-staging-terraform-state"
    prefix = "application/staging"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
