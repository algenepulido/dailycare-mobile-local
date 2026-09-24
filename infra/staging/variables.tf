variable "project_id" {
  description = "The staging project. Its own directory rather than a workspace, so a wrong -var cannot point this at the wrong one."
  type        = string
  default     = "inktree-dailycare-staging"
}

variable "region" {
  description = "us-central1. The gcp.resourceLocations org policy allows US only, so anything else fails at apply rather than at review."
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "stg, matching the dc-stg-* service accounts Inktree created. The identities are read by this name."
  type        = string
  default     = "stg"
}

variable "database_tier" {
  description = "The same as dev. Staging holds synthetic data too - that is what environments.sql enforces - and sizing it like production would cost like production for a database nobody queries."
  type        = string
  default     = "db-g1-small"
}
