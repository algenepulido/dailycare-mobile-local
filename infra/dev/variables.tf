variable "project_id" {
  description = "The dev project. Staging and production get their own directory rather than a workspace, so a wrong -var cannot point this at the wrong one."
  type        = string
  default     = "inktree-dailycare-dev"
}

variable "region" {
  description = "us-central1. The gcp.resourceLocations org policy allows US only, so anything else fails at apply rather than at review."
  type        = string
  default     = "us-central1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "database_tier" {
  description = "Smallest that runs PostgreSQL 14 comfortably. Dev holds synthetic data and a handful of rows; the budget alert at USD 150 is several times this."
  type        = string
  default     = "db-g1-small"
}
