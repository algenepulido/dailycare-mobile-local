resource "google_sql_database_instance" "main" {
  name             = "dc-${var.environment}-pg"
  project          = var.project_id
  region           = var.region
  database_version = "POSTGRES_14"

  # The model in docs/architecture is applied to this instance by migrate.sh, and it is
  # PostgreSQL 14 that every one of the 489 checks runs against. A minor version is fine;
  # a major one is a different set of answers about row-level security.

  depends_on = [google_service_networking_connection.private_services]

  settings {
    tier              = var.database_tier
    availability_type = "ZONAL" # dev. Production is a separate decision at the M6 gate.
    disk_autoresize   = true
    disk_size         = 10
    disk_type         = "PD_SSD"

    ip_configuration {
      # No public address. The org policy refuses one anyway; saying it here means the
      # config is correct on its own rather than only while somebody else's policy holds.
      ipv4_enabled    = false
      private_network = google_compute_network.main.id

      # Inktree flagged that their own platform module leaves this unset and their scanner
      # reports it, and said explicitly this is the one place not to copy them. Without it
      # an unencrypted connection inside the VPC is accepted.
      ssl_mode = "ENCRYPTED_ONLY"
    }

    database_flags {
      # So the four service accounts can connect as themselves rather than with a shared
      # password. The instanceUser grants Inktree added are inert until this is on.
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    database_flags {
      # Every statement that changes data, with the application's app.user_id in the log
      # line. The audit triggers are the record; this is the thing that notices when
      # somebody has been at the database outside the application.
      name  = "cloudsql.enable_pgaudit"
      value = "on"
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "09:00" # UTC, which is the small hours in US facilities
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7

      backup_retention_settings {
        # Not the six years the audit window needs. A daily backup is for getting the
        # service back, and the long retention is backup-recovery.sql's job through
        # exports to the backup bucket - which is also what restore-drill.sh rehearses.
        retained_backups = 14
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 9
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled = true
      # Off, both of them. Query insights with either on records parameter values, and the
      # parameter to a care-record query is a resident.
      record_application_tags = false
      record_client_address   = false
    }
  }

  # dev holds synthetic data, but a dropped instance is still a day of rebuilding.
  deletion_protection = true
}

resource "google_sql_database" "dailycare" {
  name     = "dailycare"
  project  = var.project_id
  instance = google_sql_database_instance.main.name
}

# One database user per service account, so a connection is attributable to a workload
# rather than to a shared password. The name is the account email with the domain suffix
# removed, which is what Cloud SQL expects for IAM authentication.
# Declared here so a new instance has it from the first migration. On dev it was added by
# hand during the cutover, which is exactly the kind of thing that is true on one instance
# and absent on the next.
resource "google_sql_user" "migrate" {
  name     = trimsuffix(data.google_service_account.migrate.email, ".gserviceaccount.com")
  project  = var.project_id
  instance = google_sql_database_instance.main.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_sql_user" "api" {
  name     = trimsuffix(data.google_service_account.api.email, ".gserviceaccount.com")
  project  = var.project_id
  instance = google_sql_database_instance.main.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_sql_user" "retention" {
  name     = trimsuffix(data.google_service_account.retention.email, ".gserviceaccount.com")
  project  = var.project_id
  instance = google_sql_database_instance.main.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_sql_user" "integration" {
  name     = trimsuffix(data.google_service_account.integration.email, ".gserviceaccount.com")
  project  = var.project_id
  instance = google_sql_database_instance.main.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_sql_user" "backup" {
  name     = trimsuffix(data.google_service_account.backup.email, ".gserviceaccount.com")
  project  = var.project_id
  instance = google_sql_database_instance.main.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}
