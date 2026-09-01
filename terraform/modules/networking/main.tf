# ============================================================================
# Networking module — minimal private network for Cloud Run ⇄ Cloud SQL.
# ============================================================================
# The smallest secure design that keeps Postgres OFF the public internet
# (aion-docs/architecture/security-model.md; aion-infra §13). It provisions:
#
#   * one VPC + one regional subnet (no default network, no NAT, no public IPs);
#   * a Private Services Access (PSA) range so Cloud SQL gets a PRIVATE IP;
#   * Cloud Run v2 reaches the DB via Direct VPC egress (no connector resource),
#     using this subnet — see the runtime module.
#
# There is no ingress firewall rule that exposes the database: the only inbound
# path to the runtime is Cloud Run's managed HTTPS front door, and the database
# accepts connections only from inside the VPC over the private path.

resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  description             = "AION ${var.environment} — private network for runtime ⇄ database."
}

resource "google_compute_subnetwork" "runtime" {
  project                  = var.project_id
  name                     = "${var.name_prefix}-runtime-subnet"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.runtime_subnet_cidr
  private_ip_google_access = true
  description              = "Subnet used by Cloud Run Direct VPC egress."

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Reserved range advertised to Google's service-producer network so managed
# Cloud SQL can be assigned an address on the private path.
resource "google_compute_global_address" "private_services" {
  project       = var.project_id
  name          = "${var.name_prefix}-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.vpc.id
  description   = "Private Services Access range for managed Cloud SQL."
}

resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
}

# Explicit deny-all ingress baseline. Cloud SQL private connectivity does not
# require an ingress allow rule on the consumer VPC; egress from the runtime
# subnet to the DB traverses the peered service-producer network. Keeping an
# explicit low-priority deny documents the default-closed posture.
resource "google_compute_firewall" "deny_all_ingress" {
  project     = var.project_id
  name        = "${var.name_prefix}-deny-all-ingress"
  network     = google_compute_network.vpc.id
  direction   = "INGRESS"
  priority    = 65534
  description = "Default-closed: nothing reaches VPC hosts from outside."

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
}
