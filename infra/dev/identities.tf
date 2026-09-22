# Inktree's, read rather than created. Terraform that creates a service account it does not
# own will destroy it on the first apply that decides it should not exist, and these four
# are what every Cloud Run revision runs as.

data "google_service_account" "api" {
  account_id = "dc-${var.environment}-api"
  project    = var.project_id
}

data "google_service_account" "retention" {
  account_id = "dc-${var.environment}-retention"
  project    = var.project_id
}

data "google_service_account" "integration" {
  account_id = "dc-${var.environment}-integration"
  project    = var.project_id
}

data "google_service_account" "backup" {
  account_id = "dc-${var.environment}-backup"
  project    = var.project_id
}
