# The photographs. A photograph attached to a care record is part of that record, so the
# controls here are the same shape as the ones on the record itself: it can be written, it
# can be read, and it can be removed by one thing on a schedule.

resource "google_storage_bucket" "media" {
  name     = "${var.project_id}-media"
  project  = var.project_id
  location = var.region

  # IAM only. With ACLs in play a member could be granted on an object directly and the
  # bucket policy would be the wrong place to look for why.
  uniform_bucket_level_access = true

  # The org policy already forecloses allUsers. Stated here as well so the bucket is
  # correct on its own terms rather than only while somebody else's policy holds.
  public_access_prevention = "enforced"

  versioning {
    # A photograph that a bug overwrites is a care record that changed with no trace. The
    # API cannot overwrite - objectCreator forbids it - and this is the second answer, for
    # anything that runs as something else.
    enabled = true
  }

  # Deliberately no lifecycle rule. Retention is a handshake: the database decides a record
  # is past its window and the retention job removes the object, so a rule here would delete
  # photographs on a schedule the audit trail knows nothing about.

  labels = {
    environment = var.environment
    contains    = "phi"
  }
}

resource "google_storage_bucket" "backup" {
  name     = "${var.project_id}-backup"
  project  = var.project_id
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning { enabled = true }

  labels = {
    environment = var.environment
    contains    = "phi"
  }
}

# ── the retention handshake, as IAM ───────────────────────────────────────────
#
# objectCreator and objectViewer rather than objectAdmin. objectAdmin includes
# objects.delete, and GCS also requires objects.delete to overwrite an existing object - so
# the split is what stops the API replacing a photograph as well as removing one. The first
# draft of gcp-iam.sql gave the API objectAdmin and the checks caught it.

resource "google_storage_bucket_iam_member" "api_writes" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${data.google_service_account.api.email}"
}

resource "google_storage_bucket_iam_member" "api_reads" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${data.google_service_account.api.email}"
}

# The only identity that may delete from the media bucket, and the only one that should
# ever hold objectAdmin on it.
resource "google_storage_bucket_iam_member" "retention_deletes" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${data.google_service_account.retention.email}"
}

resource "google_storage_bucket_iam_member" "backup_owns_its_bucket" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${data.google_service_account.backup.email}"
}
