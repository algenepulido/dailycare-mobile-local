# The instance has no public address - sql.restrictPublicIp makes that unskippable rather
# than a setting somebody could change in a hurry - so everything below exists to give
# Cloud Run a way to reach it that is not the internet.

resource "google_compute_network" "main" {
  name                    = "dc-${var.environment}"
  project                 = var.project_id
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "dc-${var.environment}-${var.region}"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.main.id
  ip_cidr_range = "10.10.0.0/24"

  # Every request that reaches the database should be attributable to a revision, and flow
  # logs are how that stays true when the application's own logs are the thing in question.
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# The range Google puts managed services in. Cloud SQL's private address comes from here,
# and it has to be allocated before the peering that hands it over.
resource "google_compute_global_address" "private_services" {
  name          = "dc-${var.environment}-private-services"
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
}

# Cloud Run is serverless and has no network of its own, so it borrows one through this.
# It bills about USD 10 a month flat with no idle discount, which is the thing worth tearing
# down if dev sits unused for a stretch.
resource "google_vpc_access_connector" "main" {
  name    = "dc-${var.environment}-conn"
  project = var.project_id
  region  = var.region

  subnet { name = google_compute_subnetwork.connector.name }

  min_instances = 2
  max_instances = 3
}

# The connector wants a subnet to itself, /28, unused by anything else.
resource "google_compute_subnetwork" "connector" {
  name          = "dc-${var.environment}-conn"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.main.id
  ip_cidr_range = "10.10.1.0/28"
}
