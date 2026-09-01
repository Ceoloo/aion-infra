output "network_id" {
  description = "Self-link/ID of the VPC network."
  value       = google_compute_network.vpc.id
}

output "network_name" {
  description = "Name of the VPC network."
  value       = google_compute_network.vpc.name
}

output "subnet_id" {
  description = "ID of the runtime subnet (used for Cloud Run Direct VPC egress)."
  value       = google_compute_subnetwork.runtime.id
}

output "private_vpc_connection" {
  description = "The service-networking connection Cloud SQL depends on (ordering handle)."
  value       = google_service_networking_connection.private_services.id
}
