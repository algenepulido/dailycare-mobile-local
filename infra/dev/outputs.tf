output "instance_connection_name" {
  description = "What the Cloud SQL connector wants. Not a secret."
  value       = google_sql_database_instance.main.connection_name
}

output "media_bucket" { value = google_storage_bucket.media.name }
output "backup_bucket" { value = google_storage_bucket.backup.name }
output "vpc_connector" { value = google_vpc_access_connector.main.id }

output "migrate_note" {
  description = "The model still has to be applied. The instance is empty until it is."
  value       = "docs/architecture/migrate.sh -d dailycare --with-roles, through the proxy"
}
