# Inktree's, read rather than created. Terraform that creates a service account it does not
# own will destroy it on the first apply that decides it should not exist, and these four
# are what every Cloud Run revision runs as.

# The identity that owns the schema and is the only thing that changes it.
#
# Separate from the four the running system connects as, which is the whole point: those
# read and write rows under the policies, and this one is the migration. They were the
# same account holding the same superuser password until 24 September.
data "google_service_account" "migrate" {
  account_id = "dc-${var.environment}-migrate"
  project    = var.project_id
}

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
